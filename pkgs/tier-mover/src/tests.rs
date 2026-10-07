use super::*;
use std::{
    fs::File,
    io::Write,
    os::unix::fs::DirBuilderExt,
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Sandbox {
    root: PathBuf,
}
impl Sandbox {
    fn new() -> Self {
        let name = format!(
            "tier-mover-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let root = std::env::temp_dir().join(name);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&root)
            .unwrap();
        for dir in ["source", "destination-1", "destination-2", "state"] {
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(dir))
                .unwrap();
        }
        Self {
            root: std::fs::canonicalize(root).unwrap(),
        }
    }
    fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn write_pattern(path: &Path, bytes: usize, value: u8) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut file = File::create(path).unwrap();
    file.write_all(&vec![value; bytes]).unwrap();
    file.sync_all().unwrap();
}

fn roots(s: &Sandbox) -> (Root, Vec<Root>, Root) {
    let source = Root::new(&s.path("source")).unwrap();
    let destinations = vec![
        Root::new(&s.path("destination-1")).unwrap(),
        Root::new(&s.path("destination-2")).unwrap(),
    ];
    let state = Root::new(&s.path("state")).unwrap();
    (source, destinations, state)
}

#[test]
fn crash_recovery_never_loses_the_file() {
    for point in ["intent", "prepared", "published", "unstaged", "unlinked"] {
        let sandbox = Sandbox::new();
        let relative = Path::new("album/photo.bin");
        write_pattern(&sandbox.path("source").join(relative), 256 * 1024, 0x5a);
        let (source, destinations, state) = roots(&sandbox);
        let _lock = transaction::stage_lock(&destinations[0]).unwrap();
        let identity = Identity::of(
            &source
                .open(relative, libc::O_RDONLY, 0)
                .unwrap()
                .metadata()
                .unwrap(),
        );
        transaction::FAIL_AT.with(|fail| *fail.borrow_mut() = Some(point));
        assert!(transaction::move_file(
            &source,
            &destinations,
            0,
            &state,
            relative,
            &identity,
            || Ok(())
        )
        .is_err());
        transaction::FAIL_AT.with(|fail| *fail.borrow_mut() = None);
        assert!(
            sandbox.path("source").join(relative).exists()
                || sandbox.path("destination-1").join(relative).exists()
        );
        transaction::recover(&source, &destinations, &state).unwrap();
        assert!(!control::has_journals(&state).unwrap());
        if sandbox.path("source").join(relative).exists() {
            let identity = Identity::of(
                &source
                    .open(relative, libc::O_RDONLY, 0)
                    .unwrap()
                    .metadata()
                    .unwrap(),
            );
            transaction::move_file(
                &source,
                &destinations,
                0,
                &state,
                relative,
                &identity,
                || Ok(()),
            )
            .unwrap();
        }
        assert!(!sandbox.path("source").join(relative).exists());
        assert_eq!(
            std::fs::read(sandbox.path("destination-1").join(relative)).unwrap(),
            vec![0x5a; 256 * 1024]
        );
    }
}

#[test]
fn concurrent_scheduler_uses_multiple_destinations() {
    let sandbox = Sandbox::new();
    for i in 0..6 {
        write_pattern(
            &sandbox.path("source").join(format!("file-{i}.bin")),
            256 * 1024,
            i,
        );
    }
    let (source, destinations, state) = roots(&sandbox);
    let _locks = destinations
        .iter()
        .map(transaction::stage_lock)
        .collect::<Result<Vec<_>>>()
        .unwrap();
    let cfg = Config {
        source: sandbox.path("source"),
        destinations: vec![sandbox.path("destination-1"), sandbox.path("destination-2")],
        state_directory: sandbox.path("state"),
        require_mountpoints: false,
        allow_same_filesystem: true,
        usage: Usage::DirectoryAllocated,
        start_above_used: "1B".into(),
        stop_at_used: "0B".into(),
        initial_min_file_size: "1B".into(),
        minimum_file_size: "1B".into(),
        destination_free_reserve: "0B".into(),
        minimum_modification_age_seconds: 0,
        accounting_settle_seconds: 0,
        max_parallel_moves: 2,
        ..Config::default()
    };
    let limits = cfg.validate().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    assert!(move_concurrent(&source, &destinations, &state, &cfg, &limits, deadline).unwrap());
    assert_eq!(usage(&source, &cfg, deadline).unwrap(), 0);
    let count = |dir: &str| {
        std::fs::read_dir(sandbox.path(dir))
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name() != ".tier-mover")
            .count()
    };
    assert!(count("destination-1") > 0);
    assert!(count("destination-2") > 0);
}

#[test]
fn threshold_reduction_does_not_count_as_no_progress() {
    let sandbox = Sandbox::new();
    write_pattern(&sandbox.path("source/file.bin"), 256 * 1024, 0x5a);
    let (source, destinations, state) = roots(&sandbox);
    let _locks = destinations
        .iter()
        .map(transaction::stage_lock)
        .collect::<Result<Vec<_>>>()
        .unwrap();
    let cfg = Config {
        source: sandbox.path("source"),
        destinations: vec![sandbox.path("destination-1"), sandbox.path("destination-2")],
        state_directory: sandbox.path("state"),
        require_mountpoints: false,
        allow_same_filesystem: true,
        usage: Usage::DirectoryAllocated,
        start_above_used: "1B".into(),
        stop_at_used: "0B".into(),
        initial_min_file_size: "1M".into(),
        minimum_file_size: "1B".into(),
        size_threshold_percent: 50,
        destination_free_reserve: "0B".into(),
        minimum_modification_age_seconds: 0,
        accounting_settle_seconds: 0,
        no_progress_limit: 1,
        max_parallel_moves: 2,
        ..Config::default()
    };
    let limits = cfg.validate().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);

    assert!(move_concurrent(&source, &destinations, &state, &cfg, &limits, deadline).unwrap());
    assert_eq!(usage(&source, &cfg, deadline).unwrap(), 0);
}

#[test]
fn allocated_blocks_drive_prediction_for_sparse_files() {
    let sandbox = Sandbox::new();
    let path = sandbox.path("source/sparse.bin");
    let file = File::create(&path).unwrap();
    file.set_len(1024 * 1024 * 1024).unwrap();
    let candidate = Candidate {
        relative: "sparse.bin".into(),
        identity: Identity::of(&file.metadata().unwrap()),
    };
    assert_eq!(candidate.identity.size, 1024 * 1024 * 1024);
    assert!(reclaim_estimate(&candidate) < candidate.identity.size);
}

#[test]
fn fallback_open_rejects_symlinks() {
    use std::os::unix::fs::symlink;
    let sandbox = Sandbox::new();
    write_pattern(&sandbox.path("source/real/file.bin"), 32, 0x2a);
    symlink("real", sandbox.path("source/link")).unwrap();
    let source = Root::new(&sandbox.path("source")).unwrap();
    assert!(source
        .open_fallback(Path::new("link/file.bin"), libc::O_RDONLY, 0)
        .is_err());
    assert!(source
        .open_fallback(Path::new("real/file.bin"), libc::O_RDONLY, 0)
        .is_ok());
}
