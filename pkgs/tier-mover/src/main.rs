mod config;
mod control;
mod fs;
mod transaction;

use anyhow::{bail, ensure, Context, Result};
use config::{Config, Limits, Usage};
use fs::{Identity, Root};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: libc::c_int) {
    CANCELLED.store(true, Ordering::Relaxed);
}

#[derive(Debug)]
struct Candidate {
    relative: PathBuf,
    identity: Identity,
}

fn check(deadline: Instant) -> Result<()> {
    ensure!(!CANCELLED.load(Ordering::Relaxed), "cancelled");
    ensure!(Instant::now() < deadline, "maximum run time reached");
    Ok(())
}

fn scan(
    source: &Root,
    cfg: &Config,
    deadline: Instant,
    eligibility: bool,
) -> Result<Vec<Candidate>> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let mut queue = vec![PathBuf::from(".")];
    let mut files = vec![];
    let mut excluded = 0u64;
    let mut hardlinked = 0u64;
    let mut recently_changed = 0u64;
    let mut invalid_timestamp = 0u64;
    let mut unsafe_or_unreadable = 0u64;
    let mut first_open_error = None;
    while let Some(dir) = queue.pop() {
        check(deadline)?;
        let directory = source.open(&dir, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
        for name in fs::entries(&directory)? {
            check(deadline)?;
            let relative = if dir == Path::new(".") {
                PathBuf::from(name)
            } else {
                dir.join(name)
            };
            if relative.starts_with(transaction::STAGING) || relative.starts_with(".zfs") {
                continue;
            }
            if eligibility && cfg.exclude.iter().any(|p| relative.starts_with(p)) {
                excluded += 1;
                continue;
            }
            let file = match source.open(&relative, libc::O_RDONLY | fs::noatime(), 0) {
                Ok(f) => f,
                Err(e) => {
                    unsafe_or_unreadable += 1;
                    if first_open_error.is_none() {
                        first_open_error = Some(format!("{relative:?}: {e:#}"));
                    }
                    continue;
                }
            };
            let metadata = file.metadata()?;
            if metadata.is_dir() {
                queue.push(relative);
                continue;
            }
            if !metadata.is_file() {
                continue;
            }
            let identity = Identity::of(&metadata);
            if eligibility {
                if identity.links != 1 {
                    hardlinked += 1;
                    continue;
                }
                if identity.mtime < 0
                    || identity.ctime < 0
                    || identity.mtime as u64 > now
                    || identity.ctime as u64 > now
                {
                    invalid_timestamp += 1;
                    continue;
                }
                if now.saturating_sub(identity.mtime.max(identity.ctime) as u64)
                    < cfg.minimum_modification_age_seconds
                {
                    recently_changed += 1;
                    continue;
                }
            }
            files.push(Candidate { relative, identity });
        }
    }
    files.sort_by(|a, b| {
        (a.identity.atime, a.identity.atime_ns, &a.relative).cmp(&(
            b.identity.atime,
            b.identity.atime_ns,
            &b.relative,
        ))
    });
    if eligibility {
        eprintln!(
            "scan complete: eligibleFiles={}, excludedEntries={excluded}, hardlinkedFiles={hardlinked}, recentlyChangedFiles={recently_changed}, invalidTimestampFiles={invalid_timestamp}, unsafeOrUnreadableEntries={unsafe_or_unreadable}",
            files.len()
        );
        if let Some(error) = first_open_error {
            eprintln!("first unsafe or unreadable entry: {error}");
        }
    }
    Ok(files)
}

fn usage(source: &Root, cfg: &Config, deadline: Instant) -> Result<u64> {
    match cfg.usage {
        Usage::Filesystem => source.used(),
        Usage::Zfs => Ok(control::command(
            "zfs",
            &[
                "get",
                "-H",
                "-p",
                "-o",
                "value",
                "used",
                cfg.zfs_dataset.as_deref().unwrap(),
            ],
        )?
        .parse()?),
        Usage::DirectoryAllocated => {
            let mut seen = HashSet::new();
            Ok(scan(source, cfg, deadline, false)?
                .iter()
                .filter(|c| seen.insert((c.identity.dev, c.identity.ino)))
                .fold(0u64, |total, c| {
                    total.saturating_add(c.identity.blocks.saturating_mul(512))
                }))
        }
    }
}

fn reclaim_estimate(candidate: &Candidate) -> u64 {
    candidate.identity.blocks.saturating_mul(512)
}

fn destination_need(candidate: &Candidate, reserve: u64) -> Option<u64> {
    // A compressed or sparse source may expand at the destination. Reserve its
    // logical length plus a small allowance for filesystem metadata.
    candidate
        .identity
        .size
        .checked_add(reserve)?
        .checked_add(1024 * 1024)
}

fn dry_run_plan(
    source: &Root,
    destinations: &[Root],
    cfg: &Config,
    limits: &Limits,
    deadline: Instant,
) -> Result<bool> {
    let candidates = scan(source, cfg, deadline, true)?;
    let mut attempted = HashSet::new();
    let mut threshold = limits.initial;
    let current = usage(source, cfg, deadline)?;
    let mut predicted = current;
    let mut free = destinations
        .iter()
        .map(|root| root.space())
        .collect::<Result<Vec<_>>>()?;
    loop {
        check(deadline)?;
        if predicted <= limits.stop {
            return Ok(true);
        }
        let mut selected = None;
        for (ci, candidate) in candidates.iter().enumerate() {
            if attempted.contains(&ci) || candidate.identity.size < threshold {
                continue;
            }
            attempted.insert(ci);
            if destinations
                .iter()
                .map(|d| d.exists(&candidate.relative))
                .collect::<Result<Vec<_>>>()?
                .iter()
                .any(|v| *v)
            {
                eprintln!("skip {:?}: destination conflict", candidate.relative);
                continue;
            }
            let Some(need) = destination_need(candidate, limits.reserve) else {
                continue;
            };
            if let Some((di, _)) = free
                .iter()
                .enumerate()
                .filter(|(_, (bytes, inodes))| *inodes > 0 && *bytes >= need)
                .max_by_key(|(_, (bytes, _))| *bytes)
            {
                selected = Some((ci, di, need));
                break;
            }
        }
        if let Some((ci, di, need)) = selected {
            free[di].0 = free[di].0.saturating_sub(need - limits.reserve);
            free[di].1 = free[di].1.saturating_sub(1);
            predicted = predicted.saturating_sub(reclaim_estimate(&candidates[ci]));
            eprintln!(
                "would move {:?} -> {:?}; predictedUsedBytes={predicted}",
                candidates[ci].relative, destinations[di].path
            );
            continue;
        }
        if threshold == limits.minimum {
            eprintln!("target not reached in dry run: no eligible files or destination capacity remain; predictedUsedBytes={predicted}");
            return Ok(false);
        }
        threshold = config::shrink(threshold, limits.minimum, cfg.size_threshold_percent);
        eprintln!("minimum file size reduced to {threshold} bytes");
    }
}

fn move_concurrent(
    source: &Root,
    destinations: &[Root],
    state: &Root,
    cfg: &Config,
    limits: &Limits,
    deadline: Instant,
) -> Result<bool> {
    let candidates = scan(source, cfg, deadline, true)?;
    let mut attempted = HashSet::new();
    let mut threshold = limits.initial;
    let mut stagnant = 0;
    let mut measured = usage(source, cfg, deadline)?;
    let mut predicted = measured;
    let mut destination_available = destinations
        .iter()
        .map(|destination| destination.space().map(|(free, _)| free))
        .collect::<Result<Vec<_>>>()?;
    let mut busy = vec![false; destinations.len()];
    let mut active = 0usize;
    let mut completed_since_measurement = false;
    let mut first_error: Option<anyhow::Error> = None;

    let roots: Vec<_> = std::iter::once(source).chain(destinations.iter()).collect();
    control::validate_mounts(cfg, &roots)?;

    std::thread::scope(|scope| -> Result<bool> {
        let (done_tx, done_rx) = mpsc::channel::<(usize, usize, Result<()>)>();
        let mut senders = Vec::with_capacity(destinations.len());
        for di in 0..destinations.len() {
            let (task_tx, task_rx) = mpsc::sync_channel::<usize>(0);
            senders.push(task_tx);
            let done = done_tx.clone();
            let candidates = &candidates;
            scope.spawn(move || {
                while let Ok(ci) = task_rx.recv() {
                    let candidate = &candidates[ci];
                    let result = transaction::move_file(
                        source,
                        destinations,
                        di,
                        state,
                        &candidate.relative,
                        &candidate.identity,
                        || check(deadline),
                    );
                    if done.send((di, ci, result)).is_err() {
                        break;
                    }
                }
            });
        }

        loop {
            check(deadline)?;
            let can_dispatch =
                first_error.is_none() && predicted > limits.stop && active < cfg.max_parallel_moves;
            let mut dispatched = false;
            if can_dispatch {
                'candidate: for (ci, candidate) in candidates.iter().enumerate() {
                    if attempted.contains(&ci) || candidate.identity.size < threshold {
                        continue;
                    }
                    let Some(need) = destination_need(candidate, limits.reserve) else {
                        attempted.insert(ci);
                        continue;
                    };
                    if destinations
                        .iter()
                        .map(|d| d.exists(&candidate.relative))
                        .collect::<Result<Vec<_>>>()?
                        .iter()
                        .any(|v| *v)
                    {
                        attempted.insert(ci);
                        eprintln!("skip {:?}: destination conflict", candidate.relative);
                        continue;
                    }
                    let mut choices = Vec::new();
                    for (di, destination) in destinations.iter().enumerate() {
                        let (_, inodes) = destination.space()?;
                        if inodes > 0 && destination_available[di] >= need {
                            choices.push((di, destination_available[di]));
                        }
                    }
                    if choices.is_empty() {
                        attempted.insert(ci);
                        eprintln!("skip {:?}: no destination has capacity", candidate.relative);
                        continue;
                    }
                    choices.sort_by_key(|(di, free)| (std::cmp::Reverse(*free), *di));
                    if let Some((di, _)) = choices.into_iter().find(|(di, _)| !busy[*di]) {
                        attempted.insert(ci);
                        busy[di] = true;
                        active += 1;
                        destination_available[di] =
                            destination_available[di].saturating_sub(need - limits.reserve);
                        predicted = predicted.saturating_sub(reclaim_estimate(candidate));
                        eprintln!(
                            "dispatch {:?} -> {:?}; predictedUsedBytes={predicted}",
                            candidate.relative, destinations[di].path
                        );
                        senders[di].send(ci).context("destination worker stopped")?;
                        dispatched = true;
                        break 'candidate;
                    }
                    // A fitting disk is busy. Preserve global atime ordering by
                    // waiting rather than passing this file for a younger one.
                    break 'candidate;
                }
            }
            if dispatched {
                continue;
            }

            if active > 0 {
                let (di, ci, result) = done_rx.recv().context("all destination workers stopped")?;
                active -= 1;
                busy[di] = false;
                match result {
                    Ok(()) => completed_since_measurement = true,
                    Err(e) => {
                        if first_error.is_none() {
                            first_error =
                                Some(e.context(format!("move {:?}", candidates[ci].relative)));
                        }
                    }
                }
                // Keep filling free destinations using the shared prediction.
                // Once all in-flight reservations drain, reconcile it against
                // authoritative source usage before deciding to stop or shrink.
                if active > 0 {
                    continue;
                }
            }

            if let Some(error) = first_error.take() {
                return Err(error);
            }
            if !completed_since_measurement {
                let any_at_threshold = candidates
                    .iter()
                    .enumerate()
                    .any(|(ci, c)| !attempted.contains(&ci) && c.identity.size >= threshold);
                ensure!(
                    !any_at_threshold,
                    "scheduler could not dispatch an eligible candidate"
                );
                if threshold == limits.minimum {
                    eprintln!("target not reached: no eligible files remain; usedBytes={measured}");
                    return Ok(false);
                }
                threshold = config::shrink(threshold, limits.minimum, cfg.size_threshold_percent);
                eprintln!("minimum file size reduced to {threshold} bytes");
                continue;
            }
            for _ in 0..cfg.accounting_settle_seconds {
                check(deadline)?;
                std::thread::sleep(Duration::from_secs(1));
            }
            let next = usage(source, cfg, deadline)?;
            eprintln!(
                "usedBytes={next}, predictedUsedBytes={predicted}, targetBytes={}",
                limits.stop
            );
            if next >= measured {
                stagnant += 1;
            } else {
                stagnant = 0;
            }
            measured = next;
            predicted = measured;
            completed_since_measurement = false;
            if measured <= limits.stop {
                return Ok(true);
            }
            if stagnant >= cfg.no_progress_limit {
                eprintln!("target not reached: no measured reclamation; check snapshots and usage accounting");
                return Ok(false);
            }

            let any_at_threshold = candidates
                .iter()
                .enumerate()
                .any(|(ci, c)| !attempted.contains(&ci) && c.identity.size >= threshold);
            if !any_at_threshold {
                if threshold == limits.minimum {
                    eprintln!("target not reached: no eligible files remain; usedBytes={measured}");
                    return Ok(false);
                }
                threshold = config::shrink(threshold, limits.minimum, cfg.size_threshold_percent);
                eprintln!("minimum file size reduced to {threshold} bytes");
            }
        }
    })
}

fn run() -> Result<i32> {
    let mut args = std::env::args().skip(1);
    let mut config_path = None;
    let mut dry_run = false;
    let mut assume_quiescent = false;
    let mut recover_only = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" => config_path = Some(args.next().context("--config requires a path")?),
            "--dry-run" => dry_run = true,
            "--assume-quiescent" => assume_quiescent = true,
            "--recover-only" => recover_only = true,
            "--help" | "-h" => {
                println!("tier-mover --config FILE [--dry-run | --recover-only] [--assume-quiescent]\nExit codes: 0 target reached/not needed/dry run; 2 incomplete; 1 error.\nWithout configured quiesceUnits, actual moves require --assume-quiescent.");
                return Ok(0);
            }
            _ => bail!("unknown argument: {arg}"),
        }
    }
    ensure!(
        !(dry_run && recover_only),
        "choose either dry-run or recover-only"
    );
    let cfg: Config = serde_json::from_reader(std::fs::File::open(
        config_path.context("--config is required")?,
    )?)?;
    let limits = cfg.validate()?;
    ensure!(
        dry_run || assume_quiescent || !cfg.quiesce_units.is_empty(),
        "stop all consumers and pass --assume-quiescent, or configure guarded quiesceUnits"
    );
    #[cfg(not(target_os = "linux"))]
    ensure!(
        cfg.usage == Usage::DirectoryAllocated && !cfg.require_mountpoints,
        "non-Linux builds support directory tests only"
    );
    unsafe {
        libc::signal(libc::SIGTERM, cancel as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, cancel as *const () as libc::sighandler_t);
    }
    let deadline = Instant::now()
        .checked_add(Duration::from_secs(cfg.maximum_run_seconds))
        .context("run deadline overflow")?;
    let source = Root::new(&cfg.source).context("open source root")?;
    let destinations = cfg
        .destinations
        .iter()
        .map(|p| Root::new(p).with_context(|| format!("open destination root {p:?}")))
        .collect::<Result<Vec<_>>>()?;
    for d in &destinations {
        ensure!(
            cfg.allow_same_filesystem || source.identity.dev != d.identity.dev,
            "source and destination share a filesystem"
        );
    }
    let mut devices = HashSet::new();
    ensure!(
        cfg.allow_same_filesystem || destinations.iter().all(|d| devices.insert(d.identity.dev)),
        "destinations must be separate filesystems"
    );
    let roots: Vec<_> = std::iter::once(&source)
        .chain(destinations.iter())
        .collect();
    control::validate_mounts(&cfg, &roots).context("validate storage mounts")?;
    let (state, _lock) = control::acquire_state(&cfg).context("acquire state lock")?;
    let pending = control::has_journals(&state)? || state.exists(Path::new("maintenance.json"))?;
    if dry_run {
        ensure!(!pending, "recovery is required before planning");
        let used = usage(&source, &cfg, deadline)?;
        eprintln!(
            "dry run: usedBytes={used}, startAboveBytes={}",
            limits.start
        );
        if used > limits.start {
            dry_run_plan(&source, &destinations, &cfg, &limits, deadline)?;
        }
        return Ok(0);
    }
    if !pending {
        control::finish_resume(&state)?;
    }
    if !pending && (recover_only || usage(&source, &cfg, deadline)? <= limits.start) {
        eprintln!("no movement needed");
        return Ok(0);
    }
    control::quiesce(&cfg, &state)?;
    let _destination_locks = destinations
        .iter()
        .map(transaction::stage_lock)
        .collect::<Result<Vec<_>>>()?;
    transaction::recover(&source, &destinations, &state)?;
    let outcome = if recover_only {
        Ok(true)
    } else {
        move_concurrent(&source, &destinations, &state, &cfg, &limits, deadline)
    };
    // Unpublished copies can be discarded; published copies are verified before
    // removing the source. If recovery is ambiguous, retain the maintenance gate.
    transaction::recover(&source, &destinations, &state)
        .context("recovery failed; consumers remain stopped")?;
    control::resume(&state)?;
    Ok(if outcome? { 0 } else { 2 })
}

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("tier-mover: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests;
