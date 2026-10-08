//! Fixed maintenance lifecycle; application hooks are opaque foreground commands.
use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::Write,
    os::{
        fd::AsRawFd,
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Task {
    name: String,
    command: Vec<String>,
    timeout_seconds: u64,
    success_exit_codes: Vec<i32>,
    #[serde(default)]
    weekdays: Vec<u32>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Participant {
    prepare: Option<Task>,
    capture: Option<Task>,
    resume: Option<Task>,
    backup_sources: Vec<PathBuf>,
    writer_units: Vec<String>,
    activator_units: Vec<String>,
    resume_units: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Config {
    state_directory: PathBuf,
    systemctl: String,
    mountpoint: String,
    date: String,
    stop_timeout_seconds: u64,
    minimum_free_bytes: u64,
    keep_successful_runs: usize,
    required_mounts: Vec<PathBuf>,
    conflicting_units: Vec<String>,
    participants: BTreeMap<String, Participant>,
    archive_tasks: Vec<Task>,
    storage_tasks: Vec<Task>,
    recovery_tasks: Vec<Task>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct State {
    config: Config,
    run_directory: PathBuf,
    phase: String,
    prepared: Vec<String>,
    guarded_units: Vec<String>,
    restart_units: Vec<String>,
    suspended: bool,
    owner_pid: u32,
    owner_boot: String,
    process_group: Option<i32>,
    process_boot: String,
}

fn log(message: impl std::fmt::Display) {
    eprintln!("maintenance: {message}");
}
fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    serde_json::from_reader(File::open(path)?).with_context(|| format!("read {path:?}"))
}
fn sync_dir(path: &Path) -> Result<()> {
    File::open(path)?.sync_all().context("sync directory")
}
fn sync_tree(path: &Path) -> Result<()> {
    let kind = fs::symlink_metadata(path)?.file_type();
    if kind.is_dir() {
        for entry in fs::read_dir(path)? {
            sync_tree(&entry?.path())?;
        }
        sync_dir(path)
    } else if kind.is_file() {
        File::open(path)?.sync_all().context("sync export file")
    } else {
        ensure!(
            kind.is_symlink(),
            "exports must contain regular files, directories or symlinks"
        );
        Ok(())
    }
}
fn durable_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let temporary = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    serde_json::to_writer_pretty(&mut file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
    sync_dir(path.parent().context("missing parent")?)
}
fn remove_durable(path: &Path) -> Result<()> {
    fs::remove_file(path)?;
    sync_dir(path.parent().context("missing parent")?)
}
fn boot_id() -> Result<String> {
    #[cfg(target_os = "linux")]
    {
        Ok(fs::read_to_string("/proc/sys/kernel/random/boot_id")?
            .trim()
            .into())
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok("test-boot".into())
    }
}
fn exclusive(root: &Path) -> Result<File> {
    fs::create_dir_all(root)?;
    let metadata = root.metadata()?;
    ensure!(
        metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0,
        "state directory must be private and owned by the runner"
    );
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(root.join("lock"))?;
    ensure!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "another maintenance run is active"
    );
    Ok(lock)
}
impl State {
    fn save(&self) -> Result<()> {
        durable_json(&self.config.state_directory.join("pending.json"), self)
    }
    fn phase(&mut self, name: &str) -> Result<()> {
        self.phase = name.into();
        self.save()?;
        log(format!("phase {name}"));
        Ok(())
    }
}

fn group_running(pgid: i32) -> Result<bool> {
    #[cfg(target_os = "linux")]
    {
        // Zombies cannot modify files. Include children left by a hook's parent.
        for entry in fs::read_dir("/proc")? {
            let entry = entry?;
            if entry.file_name().to_string_lossy().parse::<u32>().is_err() {
                continue;
            }
            let text = match fs::read_to_string(entry.path().join("stat")) {
                Ok(text) => text,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e.into()),
            };
            let fields: Vec<_> = text
                .rsplit_once(')')
                .context("invalid proc stat")?
                .1
                .split_whitespace()
                .collect();
            if fields[2].parse::<i32>()? == pgid && !["Z", "X"].contains(&fields[0]) {
                return Ok(true);
            }
        }
        Ok(false)
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok(unsafe { libc::kill(-pgid, 0) } == 0)
    }
}
fn stop_group(pgid: i32, grace: u64) -> Result<()> {
    for (signal, seconds) in [(libc::SIGTERM, grace), (libc::SIGKILL, 5)] {
        if !group_running(pgid)? {
            return Ok(());
        }
        unsafe {
            libc::kill(-pgid, signal);
        }
        let deadline = Instant::now() + Duration::from_secs(seconds);
        while group_running(pgid)? && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(25));
        }
    }
    ensure!(
        !group_running(pgid)?,
        "process group {pgid} remains alive; writers stay blocked"
    );
    Ok(())
}

fn execute(
    state: &mut State,
    lock: &File,
    task: &Task,
    participant: Option<&str>,
    cleaning: bool,
) -> Result<()> {
    ensure!(
        cleaning || !CANCELLED.load(Ordering::Relaxed),
        "run cancelled"
    );
    ensure!(
        !task.command.is_empty() && task.timeout_seconds > 0,
        "invalid task {}",
        task.name
    );
    log(&task.name);
    let fd = lock.as_raw_fd();
    let mut command = Command::new(&task.command[0]);
    command
        .args(&task.command[1..])
        .env("MAINTENANCE_STATE_DIR", &state.config.state_directory)
        .env("MAINTENANCE_RUN_DIR", &state.run_directory)
        .env(
            "MAINTENANCE_SOURCES_FILE",
            state.run_directory.join("sources.json"),
        )
        .env("MAINTENANCE_LOCK_FD", fd.to_string());
    if let Some(name) = participant {
        command
            .env(
                "MAINTENANCE_PARTICIPANT_DIR",
                state.run_directory.join(name),
            )
            .env(
                "MAINTENANCE_EXPORT_DIR",
                state.run_directory.join(name).join("export"),
            );
    }
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() < 0 || libc::fcntl(fd, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .with_context(|| format!("spawn {}", task.name))?;
    let pgid = child.id() as i32;
    state.process_group = Some(pgid);
    state.process_boot = boot_id()?;
    if let Err(error) = state.save() {
        stop_group(pgid, state.config.stop_timeout_seconds)?;
        child.wait()?;
        return Err(error);
    }
    let deadline = Instant::now() + Duration::from_secs(task.timeout_seconds);
    let outcome = (|| {
        loop {
            if let Some(status) = child.try_wait()? {
                let lingering = group_running(pgid)?;
                stop_group(pgid, state.config.stop_timeout_seconds)?;
                ensure!(!lingering, "{} left background children", task.name);
                ensure!(
                    status
                        .code()
                        .is_some_and(|code| task.success_exit_codes.contains(&code)),
                    "{} failed: {status}",
                    task.name
                );
                if status.code() != Some(0) {
                    log(format!(
                        "{} completed with warning exit {:?}",
                        task.name,
                        status.code()
                    ));
                }
                return Ok(());
            }
            if (!cleaning && CANCELLED.load(Ordering::Relaxed)) || Instant::now() >= deadline {
                // Reap the parent first after signalling; portable test hosts
                // otherwise count its zombie as a live process group.
                unsafe {
                    libc::kill(-pgid, libc::SIGTERM);
                }
                let grace = Instant::now() + Duration::from_secs(state.config.stop_timeout_seconds);
                while child.try_wait()?.is_none() && Instant::now() < grace {
                    thread::sleep(Duration::from_millis(25));
                }
                if child.try_wait()?.is_none() {
                    unsafe {
                        libc::kill(-pgid, libc::SIGKILL);
                    }
                }
                child.wait()?;
                stop_group(pgid, state.config.stop_timeout_seconds)?;
                bail!("{} cancelled or timed out", task.name);
            }
            thread::sleep(Duration::from_millis(25));
        }
    })();
    if !group_running(pgid)? {
        state.process_group = None;
        state.save()?;
    }
    outcome
}

fn systemctl(cfg: &Config, args: &[&str]) -> Result<String> {
    // Use a subprocess deadline even for stop/start jobs waiting on dependencies.
    let mut child = Command::new(&cfg.systemctl)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(cfg.stop_timeout_seconds);
    loop {
        if child.try_wait()?.is_some() {
            break;
        }
        if Instant::now() >= deadline {
            child.kill()?;
            child.wait()?;
            bail!("systemctl {args:?} timed out");
        }
        thread::sleep(Duration::from_millis(25));
    }
    let output = child.wait_with_output()?;
    ensure!(output.status.success(), "systemctl {args:?} failed");
    Ok(String::from_utf8(output.stdout)?.trim().into())
}
fn active(cfg: &Config, unit: &str) -> Result<String> {
    systemctl(cfg, &["show", "--property=ActiveState", "--value", unit])
}
fn preflight_space(cfg: &Config) -> Result<()> {
    let path = CString::new(cfg.state_directory.as_os_str().as_bytes())?;
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::statvfs(path.as_ptr(), &mut stats) } == 0,
        "cannot check export free space"
    );
    let available = (stats.f_bavail as u128) * (stats.f_frsize as u128);
    ensure!(
        available >= cfg.minimum_free_bytes as u128,
        "insufficient free space for maintenance exports"
    );
    Ok(())
}
fn prune_successful_runs(cfg: &Config) -> Result<()> {
    let mut completed = vec![];
    for entry in fs::read_dir(cfg.state_directory.join("runs"))? {
        let path = entry?.path();
        if let Ok(value) = read_json::<serde_json::Value>(&path.join("result.json")) {
            if value["success"] == true {
                completed.push(path);
            }
        }
    }
    completed.sort();
    let remove = completed.len().saturating_sub(cfg.keep_successful_runs);
    for path in completed.into_iter().take(remove) {
        fs::remove_dir_all(path)?;
    }
    sync_dir(&cfg.state_directory.join("runs"))
}
fn suspend(state: &mut State) -> Result<()> {
    for unit in &state.guarded_units {
        systemctl(&state.config, &["stop", unit])?;
        ensure!(
            ["inactive", "failed"].contains(&active(&state.config, unit)?.as_str()),
            "unit did not stop: {unit}"
        );
    }
    state.suspended = true;
    state.save()
}
fn finish_restarts(cfg: &Config) -> Result<()> {
    let path = cfg.state_directory.join("restarting.json");
    if !path.exists() {
        return Ok(());
    }
    let units: Vec<String> = read_json(&path)?;
    for unit in units {
        systemctl(cfg, &["start", &unit])?;
        ensure!(
            active(cfg, &unit)? == "active",
            "could not restore active unit: {unit}"
        );
    }
    remove_durable(&path)
}
fn cleanup(state: &mut State, lock: &File) -> Result<()> {
    if let Some(pgid) = state.process_group {
        if state.process_boot == boot_id()? {
            stop_group(pgid, state.config.stop_timeout_seconds)?;
        }
        state.process_group = None;
        state.save()?;
    }
    suspend(state)?;
    state.phase("recovery")?;
    for task in state.config.recovery_tasks.clone() {
        execute(state, lock, &task, None, true)?;
    }
    state.phase("resume")?;
    let mut errors = vec![];
    for name in state.prepared.clone().into_iter().rev() {
        if let Some(hook) = state.config.participants[&name].resume.clone() {
            if let Err(error) = execute(state, lock, &hook, Some(&name), true) {
                errors.push(format!("{error:#}"));
            }
            // Do not run further cleanup while a timed-out process can write.
            ensure!(
                state.process_group.is_none(),
                "resume process remains alive"
            );
        }
    }
    ensure!(errors.is_empty(), "resume failed: {}", errors.join("; "));
    durable_json(
        &state.config.state_directory.join("restarting.json"),
        &state.restart_units,
    )?;
    remove_durable(&state.config.state_directory.join("pending.json"))?;
    finish_restarts(&state.config)
}
fn recover(cfg: &Config) -> Result<()> {
    let lock = exclusive(&cfg.state_directory)?;
    let pending = cfg.state_directory.join("pending.json");
    if pending.exists() {
        let mut state: State = read_json(&pending)?;
        ensure!(
            state.config.state_directory == cfg.state_directory,
            "recovery state directory mismatch"
        );
        state.owner_pid = std::process::id();
        state.owner_boot = boot_id()?;
        state.save()?;
        cleanup(&mut state, &lock)
    } else {
        finish_restarts(cfg)
    }
}
fn run(cfg: Config) -> Result<()> {
    let lock = exclusive(&cfg.state_directory)?;
    ensure!(
        !cfg.state_directory.join("pending.json").exists()
            && !cfg.state_directory.join("restarting.json").exists(),
        "unfinished run: start maintenance-recover.service first"
    );
    ensure!(
        cfg.participants.is_empty() || !cfg.archive_tasks.is_empty(),
        "no archive task configured; refusing to suspend applications"
    );
    preflight_space(&cfg)?;
    for mount in &cfg.required_mounts {
        ensure!(
            Command::new(&cfg.mountpoint)
                .arg("--quiet")
                .arg(mount)
                .status()?
                .success(),
            "required mount absent: {mount:?}"
        );
    }
    for unit in &cfg.conflicting_units {
        ensure!(
            ["inactive", "failed"].contains(&active(&cfg, unit)?.as_str()),
            "conflicting maintenance unit active: {unit}"
        );
    }
    let guarded: BTreeSet<_> = cfg
        .participants
        .values()
        .flat_map(|p| p.writer_units.iter().chain(&p.activator_units))
        .cloned()
        .collect();
    let eligible: BTreeSet<_> = cfg
        .participants
        .values()
        .flat_map(|p| p.resume_units.iter().chain(&p.activator_units))
        .cloned()
        .collect();
    let mut restart = vec![];
    for unit in &guarded {
        ensure!(
            systemctl(&cfg, &["show", "--property=LoadState", "--value", unit])? == "loaded",
            "unknown writer/activator: {unit}"
        );
        let status = active(&cfg, unit)?;
        ensure!(
            !["activating", "deactivating", "reloading"].contains(&status.as_str()),
            "unit transitioning: {unit}; retry later"
        );
        if status == "active" && eligible.contains(unit) {
            restart.push(unit.clone());
        }
    }
    let run_id = format!(
        "{}-{}",
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),
        std::process::id()
    );
    let directory = cfg.state_directory.join("runs").join(run_id);
    fs::create_dir_all(&directory)?;
    sync_dir(&cfg.state_directory)?;
    sync_dir(directory.parent().context("missing runs directory")?)?;
    for name in cfg.participants.keys() {
        fs::create_dir_all(directory.join(name).join("export"))?;
        sync_dir(&directory)?;
        sync_dir(&directory.join(name))?;
    }
    let mut state = State {
        config: cfg,
        run_directory: directory.clone(),
        phase: "prepare".into(),
        prepared: vec![],
        guarded_units: guarded.into_iter().collect(),
        restart_units: restart,
        suspended: false,
        owner_pid: std::process::id(),
        owner_boot: boot_id()?,
        process_group: None,
        process_boot: boot_id()?,
    };
    state.save()?; // Engage startup guards before application preparation.
    let work = (|| -> Result<()> {
        state.phase("prepare")?;
        for (name, participant) in state.config.participants.clone() {
            state.prepared.push(name.clone());
            state.save()?; // Resume even preparation that fails halfway.
            if let Some(task) = participant.prepare {
                execute(&mut state, &lock, &task, Some(&name), false)?;
            }
        }
        state.phase("capture")?;
        let mut sources = BTreeSet::new();
        for (name, participant) in state.config.participants.clone() {
            if let Some(task) = participant.capture {
                execute(&mut state, &lock, &task, Some(&name), false)?;
                sources.insert(directory.join(name).join("export"));
            }
            sources.extend(participant.backup_sources);
        }
        for source in &sources {
            ensure!(source.exists(), "backup source absent: {source:?}");
        }
        durable_json(&directory.join("sources.json"), &sources)?;
        durable_json(
            &directory.join("capture.json"),
            &serde_json::json!({"complete": true, "sources": sources}),
        )?;
        suspend(&mut state)?;
        state.phase("archive")?;
        for task in state.config.archive_tasks.clone() {
            execute(&mut state, &lock, &task, None, false)?;
        }
        state.phase("maintain_storage")?;
        suspend(&mut state)?;
        let weekday: u32 =
            String::from_utf8(Command::new(&state.config.date).arg("+%u").output()?.stdout)?
                .trim()
                .parse()?;
        for task in state.config.storage_tasks.clone() {
            if task.weekdays.is_empty() || task.weekdays.contains(&weekday) {
                execute(&mut state, &lock, &task, None, false)?;
            }
        }
        Ok(())
    })();
    let mut errors = vec![];
    if let Err(error) = work {
        log(format!("failed: {error:#}"));
        errors.push(format!("{error:#}"));
    }
    if let Err(error) = cleanup(&mut state, &lock) {
        log(format!(
            "cleanup failed; recovery state retained: {error:#}"
        ));
        errors.push(format!("cleanup: {error:#}"));
    }
    durable_json(
        &directory.join("result.json"),
        &serde_json::json!({"success": errors.is_empty(), "errors": errors}),
    )?;
    ensure!(errors.is_empty(), "{}", errors.join("; "));
    if let Err(error) = prune_successful_runs(&state.config) {
        log(format!("could not prune old exports: {error:#}"));
    }
    log("completed");
    Ok(())
}

fn check_storage_fd(root: &Path, fd: i32) -> Result<()> {
    let state: State = read_json(&root.join("pending.json"))?;
    ensure!(
        state.config.state_directory == root
            && state.suspended
            && ["maintain_storage", "recovery"].contains(&state.phase.as_str()),
        "storage requires an active suspended maintenance session"
    );
    ensure!(
        state.owner_boot == boot_id()? && unsafe { libc::kill(state.owner_pid as i32, 0) } == 0,
        "maintenance owner is no longer alive"
    );
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::fstat(fd, &mut metadata) } == 0,
        "missing inherited maintenance lock"
    );
    let expected = root.join("lock").metadata()?;
    ensure!(
        metadata.st_dev as u64 == expected.dev() && metadata.st_ino as u64 == expected.ino(),
        "wrong inherited lock"
    );
    // The inherited open file description must own the lock. A separate open
    // description must fail to acquire it; a stale file cannot authorize work.
    let other = File::open(root.join("lock"))?;
    ensure!(
        unsafe { libc::flock(other.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0,
        "maintenance lock is not held"
    );
    ensure!(
        unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "inherited descriptor does not own the maintenance lock"
    );
    Ok(())
}

fn main_result() -> Result<()> {
    unsafe {
        libc::umask(0o077);
        libc::signal(libc::SIGTERM, cancel as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, cancel as *const () as libc::sighandler_t);
    }
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("run" | "recover") if args.len() == 3 && args[1] == "--config" => {
            let cfg: Config = read_json(Path::new(&args[2]))?;
            if args[0] == "run" { run(cfg) } else { recover(&cfg) }
        }
        Some("check-storage") if args.len() == 2 => {
            let fd = std::env::var("MAINTENANCE_LOCK_FD").context("storage may only be invoked by maintenance")?.parse()?;
            check_storage_fd(Path::new(&args[1]), fd)
        }
        Some("remember") if args.len() == 3 => {
            let path = PathBuf::from(std::env::var("MAINTENANCE_PARTICIPANT_DIR")?).join("application-state.json");
            let mut value: BTreeMap<String, serde_json::Value> = if path.exists() { read_json(&path)? } else { BTreeMap::new() };
            value.insert(args[1].clone(), serde_json::from_str(&args[2])?);
            durable_json(&path, &value)
        }
        Some("publish") if args.len() == 3 => {
            let directory = PathBuf::from(std::env::var("MAINTENANCE_EXPORT_DIR")?);
            ensure!(args[1..].iter().all(|name| !name.is_empty() && !name.contains('/') && name != "." && name != ".."), "publish accepts export filenames only");
            let source = directory.join(&args[1]);
            let destination = directory.join(&args[2]);
            sync_tree(&source)?;
            fs::rename(source, destination)?;
            sync_dir(&directory)
        }
        _ => bail!("usage: maintenance-runner run|recover --config FILE; check-storage STATE_DIR; remember KEY JSON; publish TEMP_NAME FINAL_NAME"),
    }
}
fn main() {
    if let Err(error) = main_result() {
        log(format!("{error:#}"));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests;
