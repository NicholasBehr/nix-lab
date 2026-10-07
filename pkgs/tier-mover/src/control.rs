use crate::{
    config::{Config, Usage},
    fs::{self, Root},
    transaction,
};
use anyhow::{ensure, Context, Result};
use std::{fs::File, path::Path, process::Command};

pub fn command(program: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("execute {program}"))?;
    ensure!(
        out.status.success(),
        "{program} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    Ok(String::from_utf8(out.stdout)?.trim().into())
}

pub fn validate_mounts(cfg: &Config, roots: &[&Root]) -> Result<()> {
    for root in roots {
        root.check()?;
        if cfg.require_mountpoints || cfg.expected_filesystems.contains_key(&root.path) {
            let path = root.path.to_str().context("mount root must be UTF-8")?;
            let text = command(
                "findmnt",
                &["--json", "--mountpoint", path, "--output", "SOURCE,FSTYPE"],
            )?;
            let value: serde_json::Value = serde_json::from_str(&text)?;
            let mounts = value["filesystems"]
                .as_array()
                .context("not a mountpoint")?;
            ensure!(mounts.len() == 1, "ambiguous mountpoint");
            if let Some(expected) = cfg.expected_filesystems.get(&root.path) {
                let actual = mounts[0]["source"]
                    .as_str()
                    .context("missing mount source")?;
                let same_device = actual == expected.device
                    || (actual.starts_with("/dev/")
                        && expected.device.starts_with("/dev/")
                        && std::fs::canonicalize(actual)?
                            == std::fs::canonicalize(&expected.device)?);
                ensure!(
                    same_device && mounts[0]["fstype"].as_str() == Some(&expected.fs_type),
                    "unexpected filesystem at {:?}",
                    root.path
                );
            }
        }
    }
    if cfg.usage == Usage::Zfs {
        let dataset = cfg.zfs_dataset.as_deref().unwrap();
        let mount = command("zfs", &["get", "-H", "-o", "value", "mountpoint", dataset])?;
        ensure!(
            Path::new(&mount) == cfg.source,
            "zfsDataset does not match source mountpoint"
        );
    }
    Ok(())
}

pub fn acquire_state(cfg: &Config) -> Result<(Root, File)> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    if !cfg.state_directory.exists() {
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&cfg.state_directory)?;
        File::open(cfg.state_directory.parent().context("no state parent")?)?.sync_all()?;
    }
    let state = Root::new(&cfg.state_directory)?;
    let m = state.file.metadata()?;
    ensure!(
        m.uid() == unsafe { libc::geteuid() } && m.mode() & 0o777 == 0o700,
        "state directory must be private and owned by the mover"
    );
    let lock = state.open(Path::new("lock"), libc::O_RDWR | libc::O_CREAT, 0o600)?;
    fs::lock(&lock).context("another mover is running")?;
    Ok((state, lock))
}

pub fn quiesce(cfg: &Config, state: &Root) -> Result<()> {
    let marker = Path::new("maintenance.json");
    for unit in &cfg.require_inactive_units {
        let status = command(
            "systemctl",
            &["show", "--property=ActiveState", "--value", unit],
        )?;
        ensure!(
            status == "inactive" || status == "failed",
            "conflicting service is running: {unit}"
        );
    }
    if !state.exists(marker)? {
        let mut active = vec![];
        for unit in &cfg.quiesce_units {
            let status = command(
                "systemctl",
                &["show", "--property=ActiveState", "--value", unit],
            )?;
            if status == "active" || status == "activating" || status == "reloading" {
                active.push(unit.clone());
            }
        }
        // NixOS adds ConditionPathExists=!marker to every configured consumer.
        // Persist the restart list BEFORE stopping anything.
        transaction::durable_json(state, marker, &active)?;
    }
    for unit in &cfg.quiesce_units {
        command("systemctl", &["stop", unit])?;
        let status = command(
            "systemctl",
            &["show", "--property=ActiveState", "--value", unit],
        )?;
        ensure!(
            status == "inactive" || status == "failed",
            "consumer is still running: {unit}"
        );
    }
    // The maintenance marker guards new starts. Check again to close the race
    // between the first observation and durable marker creation.
    for unit in &cfg.require_inactive_units {
        let status = command(
            "systemctl",
            &["show", "--property=ActiveState", "--value", unit],
        )?;
        if status != "inactive" && status != "failed" {
            let conflict = anyhow::anyhow!("conflicting service started during quiesce: {unit}");
            resume(state).context("failed to roll back quiesce after conflict")?;
            return Err(conflict);
        }
    }
    Ok(())
}

pub fn resume(state: &Root) -> Result<()> {
    let marker = Path::new("maintenance.json");
    if !state.exists(marker)? {
        return Ok(());
    }
    ensure!(
        !has_journals(state)?,
        "unfinished transactions; consumers remain stopped"
    );
    let units: Vec<String> = serde_json::from_reader(state.open(marker, libc::O_RDONLY, 0)?)?;
    // Keep a durable restart list across power loss between unblocking and start.
    transaction::durable_json(state, Path::new("resume.json"), &units)?;
    state.unlink(marker)?;
    finish_resume(state)
}

pub fn finish_resume(state: &Root) -> Result<()> {
    let name = Path::new("resume.json");
    if !state.exists(name)? {
        return Ok(());
    }
    let units: Vec<String> = serde_json::from_reader(state.open(name, libc::O_RDONLY, 0)?)?;
    let mut errors = vec![];
    for unit in units {
        if let Err(e) = command("systemctl", &["start", &unit]) {
            errors.push(format!("{unit}: {e:#}"));
        }
    }
    ensure!(
        errors.is_empty(),
        "could not resume consumers: {}",
        errors.join("; ")
    );
    state.unlink(name)?;
    Ok(())
}

pub fn has_journals(state: &Root) -> Result<bool> {
    Ok(fs::entries(&state.file)?.iter().any(|n| {
        n.to_string_lossy().starts_with("transaction-") && n.to_string_lossy().ends_with(".json")
    }))
}
