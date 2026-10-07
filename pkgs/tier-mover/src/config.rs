use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Component, Path, PathBuf},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ExpectedFilesystem {
    pub device: String,
    pub fs_type: String,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Usage {
    Filesystem,
    Zfs,
    DirectoryAllocated,
}

#[derive(Debug, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct Config {
    pub source: PathBuf,
    pub destinations: Vec<PathBuf>,
    pub state_directory: PathBuf,
    pub expected_filesystems: BTreeMap<PathBuf, ExpectedFilesystem>,
    pub require_mountpoints: bool,
    pub allow_same_filesystem: bool,
    pub usage: Usage,
    pub zfs_dataset: Option<String>,
    pub start_above_used: String,
    pub stop_at_used: String,
    pub initial_min_file_size: String,
    pub minimum_file_size: String,
    pub size_threshold_percent: u64,
    pub destination_free_reserve: String,
    pub minimum_modification_age_seconds: u64,
    pub maximum_run_seconds: u64,
    pub accounting_settle_seconds: u64,
    pub no_progress_limit: u64,
    pub max_parallel_moves: usize,
    pub exclude: Vec<PathBuf>,
    pub quiesce_units: Vec<String>,
    pub require_inactive_units: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            source: PathBuf::new(),
            destinations: vec![],
            state_directory: PathBuf::new(),
            expected_filesystems: BTreeMap::new(),
            require_mountpoints: true,
            allow_same_filesystem: false,
            usage: Usage::Filesystem,
            zfs_dataset: None,
            start_above_used: "2T".into(),
            stop_at_used: "1800G".into(),
            initial_min_file_size: "40G".into(),
            minimum_file_size: "1M".into(),
            size_threshold_percent: 90,
            destination_free_reserve: "100G".into(),
            minimum_modification_age_seconds: 3600,
            maximum_run_seconds: 7200,
            accounting_settle_seconds: 5,
            no_progress_limit: 3,
            max_parallel_moves: 2,
            exclude: vec![".snapraid".into(), ".zfs".into(), "lost+found".into()],
            quiesce_units: vec![],
            require_inactive_units: vec![],
        }
    }
}

pub struct Limits {
    pub start: u64,
    pub stop: u64,
    pub initial: u64,
    pub minimum: u64,
    pub reserve: u64,
}

pub fn bytes(s: &str) -> Result<u64> {
    let split = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
    let n: u64 = s[..split]
        .parse()
        .context("size must start with an unsigned integer")?;
    let factor: u64 = match &s[split..] {
        "" | "B" => 1,
        "K" | "KiB" => 1 << 10,
        "M" | "MiB" => 1 << 20,
        "G" | "GiB" => 1 << 30,
        "T" | "TiB" => 1 << 40,
        "KB" => 1_000,
        "MB" => 1_000_000,
        "GB" => 1_000_000_000,
        "TB" => 1_000_000_000_000,
        _ => bail!("invalid size unit: {s:?}"),
    };
    n.checked_mul(factor).context("size overflows u64")
}

pub fn relative(path: &Path) -> bool {
    !path.as_os_str().is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)))
}

pub fn shrink(current: u64, minimum: u64, percent: u64) -> u64 {
    minimum.max((current - 1).min(((current as u128 * percent as u128) / 100) as u64))
}

impl Config {
    pub fn validate(&self) -> Result<Limits> {
        let l = Limits {
            start: bytes(&self.start_above_used)?,
            stop: bytes(&self.stop_at_used)?,
            initial: bytes(&self.initial_min_file_size)?,
            minimum: bytes(&self.minimum_file_size)?,
            reserve: bytes(&self.destination_free_reserve)?,
        };
        ensure!(
            l.stop < l.start,
            "stopAtUsed must be less than startAboveUsed"
        );
        ensure!(
            l.minimum > 0 && l.minimum <= l.initial,
            "invalid file size range"
        );
        ensure!(
            (1..100).contains(&self.size_threshold_percent),
            "sizeThresholdPercent must be 1..99"
        );
        ensure!(
            self.maximum_run_seconds > 0 && self.no_progress_limit > 0,
            "run bounds must be positive"
        );
        ensure!(
            self.max_parallel_moves > 0,
            "maxParallelMoves must be positive"
        );
        ensure!(!self.destinations.is_empty(), "no destinations configured");
        if self.usage == Usage::Zfs {
            ensure!(
                self.zfs_dataset
                    .as_ref()
                    .is_some_and(|s| !s.is_empty() && !s.starts_with('-')),
                "zfs usage requires zfsDataset"
            );
        }
        ensure!(
            !self.allow_same_filesystem || self.usage == Usage::DirectoryAllocated,
            "allowSameFilesystem is only supported with directoryAllocated test accounting"
        );
        let roots: Vec<_> = std::iter::once(&self.source)
            .chain(self.destinations.iter())
            .chain(std::iter::once(&self.state_directory))
            .collect();
        for (i, a) in roots.iter().enumerate() {
            ensure!(
                a.is_absolute() && a.as_path() != Path::new("/"),
                "roots must be absolute non-root paths"
            );
            ensure!(
                a.components()
                    .all(|c| matches!(c, Component::RootDir | Component::Normal(_))),
                "invalid root path"
            );
            for b in roots.iter().skip(i + 1) {
                ensure!(
                    !a.starts_with(b) && !b.starts_with(a),
                    "storage/state roots overlap"
                );
            }
        }
        ensure!(
            self.expected_filesystems
                .keys()
                .all(|p| p == &self.source || self.destinations.contains(p)),
            "filesystem expectation for unknown root"
        );
        ensure!(
            self.exclude.iter().all(|p| relative(p)),
            "exclusions must be relative paths"
        );
        ensure!(
            self.quiesce_units
                .iter()
                .chain(self.require_inactive_units.iter())
                .all(|u| u.ends_with(".service")
                    && u.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-_.@".contains(&b))),
            "invalid service unit name"
        );
        Ok(l)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn size_units_and_overflow() {
        assert_eq!(bytes("40G").unwrap(), 40 << 30);
        assert_eq!(bytes("2T").unwrap(), 2 << 40);
        assert_eq!(bytes("2GB").unwrap(), 2_000_000_000);
        for invalid in ["-1G", "1.5G", "G", "1P", "18446744073709551615T", " 1G"] {
            assert!(bytes(invalid).is_err(), "{invalid}");
        }
    }
    #[test]
    fn threshold_always_reaches_floor() {
        let mut threshold = u64::MAX;
        for _ in 0..10_000 {
            if threshold == 1 {
                return;
            }
            let next = shrink(threshold, 1, 99);
            assert!(next < threshold);
            threshold = next;
        }
        panic!("did not converge");
    }
    #[test]
    fn reject_path_escape() {
        for p in ["", "/etc/passwd", "../foo", "foo/../bar"] {
            assert!(!relative(Path::new(p)));
        }
        assert!(relative(Path::new("photos/holiday.jpg")));
    }
}
