use super::*;
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::AtomicUsize;

static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Fixture {
    root: PathBuf,
    cfg: Config,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "maintenance-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(root.join("units")).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(root.join("units/writer.service"), "active").unwrap();
        fs::write(root.join("units/cron.timer"), "active").unwrap();
        fs::write(root.join("live"), "matching-files").unwrap();
        let systemctl = root.join("systemctl");
        let shell = String::from_utf8(
            Command::new("sh")
                .args(["-c", "command -v sh"])
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap();
        fs::write(
            &systemctl,
            format!(
                r#"#!{}
set -eu
root='{}'
case "$1" in
  show) if [ "$2" = --property=LoadState ]; then printf loaded; else cat "$root/units/$4" 2>/dev/null || printf inactive; fi ;;
  stop) printf 'stop:%s\n' "$2" >> "$root/events"; printf inactive > "$root/units/$2" ;;
  start)
    test ! -f "$root/pending.json"
    printf 'start:%s\n' "$2" >> "$root/events"
    printf active > "$root/units/$2" ;;
  *) exit 1 ;;
esac
"#,
                shell.trim(),
                root.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&systemctl, fs::Permissions::from_mode(0o700)).unwrap();
        let task = |name: &str| Task {
            name: name.into(),
            command: vec![
                "sh".into(),
                "-c".into(),
                format!("printf '%s\\n' '{name}' >> '{}/events'", root.display()),
            ],
            timeout_seconds: 5,
            success_exit_codes: vec![0],
            weekdays: vec![],
        };
        let cfg = Config {
            state_directory: root.clone(),
            systemctl: systemctl.to_str().unwrap().into(),
            mountpoint: "true".into(),
            date: "date".into(),
            stop_timeout_seconds: 1,
            minimum_free_bytes: 0,
            keep_successful_runs: 7,
            required_mounts: vec![],
            conflicting_units: vec![],
            participants: BTreeMap::from([(
                "application".into(),
                Participant {
                    prepare: Some(task("prepare")),
                    capture: Some(task("capture")),
                    resume: Some(task("resume")),
                    backup_sources: vec![root.join("live")],
                    writer_units: vec!["writer.service".into(), "setup.service".into()],
                    activator_units: vec!["cron.timer".into()],
                    resume_units: vec!["writer.service".into()],
                },
            )]),
            archive_tasks: vec![task("archive")],
            storage_tasks: vec![task("storage")],
            recovery_tasks: vec![task("recover")],
        };
        Self { root, cfg }
    }
    fn events(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("events"))
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect()
    }
    fn task_script(&mut self, phase: &str, script: &str) {
        let task = match phase {
            "prepare" => self
                .cfg
                .participants
                .get_mut("application")
                .unwrap()
                .prepare
                .as_mut()
                .unwrap(),
            "capture" => self
                .cfg
                .participants
                .get_mut("application")
                .unwrap()
                .capture
                .as_mut()
                .unwrap(),
            "resume" => self
                .cfg
                .participants
                .get_mut("application")
                .unwrap()
                .resume
                .as_mut()
                .unwrap(),
            "archive" => &mut self.cfg.archive_tasks[0],
            "storage" => &mut self.cfg.storage_tasks[0],
            "recover" => &mut self.cfg.recovery_tasks[0],
            _ => panic!("unknown phase"),
        };
        task.command[2].push_str(&format!("; {script}"));
    }
    fn pending_state(&self) -> State {
        let directory = self.root.join("runs/interrupted");
        fs::create_dir_all(directory.join("application/export")).unwrap();
        State {
            config: self.cfg.clone(),
            run_directory: directory,
            phase: "maintain_storage".into(),
            prepared: vec!["application".into()],
            guarded_units: vec!["writer.service".into(), "cron.timer".into()],
            restart_units: vec!["writer.service".into(), "cron.timer".into()],
            suspended: true,
            owner_pid: std::process::id(),
            owner_boot: boot_id().unwrap(),
            process_group: None,
            process_boot: boot_id().unwrap(),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn phases_suspend_after_capture_and_restore_only_original_daemons() {
    let fixture = Fixture::new();
    run(fixture.cfg.clone()).unwrap();
    let events = fixture.events();
    let index = |name| events.iter().position(|event| event == name).unwrap();
    assert!(index("prepare") < index("capture"));
    assert!(index("capture") < index("stop:writer.service"));
    assert!(index("stop:writer.service") < index("archive"));
    assert!(index("archive") < index("storage"));
    assert!(index("storage") < index("recover"));
    assert!(index("recover") < index("resume"));
    assert!(index("resume") < index("start:writer.service"));
    assert!(!events.iter().any(|event| event == "start:setup.service"));
    assert!(!fixture.root.join("pending.json").exists());
}

#[test]
fn repeat_runs_use_distinct_exports_and_inactive_units_stay_inactive() {
    let fixture = Fixture::new();
    fs::write(fixture.root.join("units/writer.service"), "inactive").unwrap();
    run(fixture.cfg.clone()).unwrap();
    run(fixture.cfg.clone()).unwrap();
    assert_eq!(fs::read_dir(fixture.root.join("runs")).unwrap().count(), 2);
    assert!(!fixture
        .events()
        .iter()
        .any(|event| event == "start:writer.service"));
}

#[test]
fn missing_archive_aborts_without_preparation() {
    let mut fixture = Fixture::new();
    fixture.cfg.archive_tasks.clear();
    assert!(run(fixture.cfg.clone()).is_err());
    assert!(fixture.events().is_empty());
    assert!(!fixture.root.join("pending.json").exists());
}

#[test]
fn partial_preparation_is_resumed_and_capture_is_skipped() {
    let mut fixture = Fixture::new();
    fixture.task_script("prepare", "exit 1");
    assert!(run(fixture.cfg.clone()).is_err());
    let events = fixture.events();
    assert!(events.contains(&"resume".into()));
    assert!(!events.contains(&"capture".into()));
    assert!(!events.contains(&"archive".into()));
    assert!(!fixture.root.join("pending.json").exists());
}

#[test]
fn failed_capture_never_archives_stale_exports() {
    let mut fixture = Fixture::new();
    fs::create_dir_all(fixture.root.join("runs/old/application/export")).unwrap();
    fs::write(fixture.root.join("runs/old/application/export/dump"), "old").unwrap();
    fixture.task_script("capture", "exit 1");
    assert!(run(fixture.cfg.clone()).is_err());
    assert!(!fixture.events().contains(&"archive".into()));
    assert!(!fixture.events().contains(&"storage".into()));
}

#[test]
fn archive_failure_skips_storage_and_remains_a_failure_after_resume() {
    let mut fixture = Fixture::new();
    fixture.task_script("archive", "exit 1");
    assert!(run(fixture.cfg.clone()).is_err());
    assert!(!fixture.events().contains(&"storage".into()));
    assert!(fixture.events().contains(&"start:writer.service".into()));
    let run = fs::read_dir(fixture.root.join("runs"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let result: serde_json::Value = read_json(&run.join("result.json")).unwrap();
    assert_eq!(result["success"], false);
}

#[test]
fn unresolved_recovery_keeps_writers_blocked_and_can_be_retried() {
    let mut fixture = Fixture::new();
    fixture.task_script("recover", "test -f \"$MAINTENANCE_STATE_DIR/repaired\"");
    assert!(run(fixture.cfg.clone()).is_err());
    assert!(fixture.root.join("pending.json").exists());
    assert!(!fixture.events().contains(&"resume".into()));
    assert!(!fixture.events().contains(&"start:writer.service".into()));
    fs::write(fixture.root.join("repaired"), "").unwrap();
    recover(&fixture.cfg).unwrap();
    assert!(!fixture.root.join("pending.json").exists());
    assert!(fixture.events().contains(&"start:writer.service".into()));
}

#[test]
fn recovery_uses_saved_hooks_even_after_configuration_changes() {
    let mut fixture = Fixture::new();
    fixture.pending_state().save().unwrap();
    fixture.cfg.participants.clear();
    fixture.cfg.recovery_tasks.clear();
    recover(&fixture.cfg).unwrap();
    assert!(fixture.events().contains(&"recover".into()));
    assert!(fixture.events().contains(&"resume".into()));
}

#[test]
fn resume_failure_keeps_gate_and_continues_other_cleanup() {
    let mut fixture = Fixture::new();
    fixture.task_script("resume", "exit 1");
    assert!(run(fixture.cfg.clone()).is_err());
    assert!(fixture.root.join("pending.json").exists());
    assert!(!fixture.events().contains(&"start:writer.service".into()));
}

#[test]
fn timeout_stops_hook_before_cleanup() {
    let mut fixture = Fixture::new();
    fixture.task_script("archive", "exec sleep 30");
    fixture.cfg.archive_tasks[0].timeout_seconds = 1;
    assert!(run(fixture.cfg.clone()).is_err());
    assert!(fixture.events().contains(&"resume".into()));
    assert!(!fixture.events().contains(&"storage".into()));
    assert!(!fixture.root.join("pending.json").exists());
}

#[test]
fn lock_and_live_session_are_required_for_storage_admission() {
    let fixture = Fixture::new();
    fixture.pending_state().save().unwrap();
    let lock = exclusive(&fixture.root).unwrap();
    assert!(exclusive(&fixture.root).is_err());
    check_storage_fd(&fixture.root, lock.as_raw_fd()).unwrap();
    let unrelated = File::open(fixture.root.join("live")).unwrap();
    assert!(check_storage_fd(&fixture.root, unrelated.as_raw_fd()).is_err());
    let mut state = fixture.pending_state();
    state.phase = "archive".into();
    state.save().unwrap();
    assert!(check_storage_fd(&fixture.root, lock.as_raw_fd()).is_err());
    state.phase = "maintain_storage".into();
    state.suspended = false;
    state.save().unwrap();
    assert!(check_storage_fd(&fixture.root, lock.as_raw_fd()).is_err());
    state.suspended = true;
    state.save().unwrap();
    drop(lock);
    let stale = File::open(fixture.root.join("lock")).unwrap();
    assert!(check_storage_fd(&fixture.root, stale.as_raw_fd()).is_err());
}

#[test]
fn fresh_export_directory_and_sources_are_passed_to_archive() {
    let mut fixture = Fixture::new();
    fixture.task_script("capture", "printf fresh > \"$MAINTENANCE_EXPORT_DIR/dump\"");
    fixture.task_script("archive", "test -f \"$MAINTENANCE_SOURCES_FILE\"; test \"$(cat \"$MAINTENANCE_RUN_DIR/application/export/dump\")\" = fresh");
    run(fixture.cfg.clone()).unwrap();
}
