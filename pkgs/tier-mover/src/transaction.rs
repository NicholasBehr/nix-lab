use crate::fs::{self, Identity, Root};
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    io::Write,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

pub const STAGING: &str = ".tier-mover";
const PAYLOAD: &str = ".tier-mover/payload";

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Transaction {
    pub version: u32,
    pub source: PathBuf,
    pub destination: PathBuf,
    pub source_root: Identity,
    pub destination_root: Identity,
    pub relative: Vec<u8>,
    pub original: Identity,
    pub prepared: Option<Identity>,
}

pub fn durable_json<T: Serialize>(state: &Root, name: &Path, value: &T) -> Result<()> {
    let temp = name.with_extension("new");
    // Only our private state directory contains these temporary files.
    if state.exists(&temp)? {
        state.unlink(&temp)?;
    }
    let mut file = state.open(&temp, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.sync_all()?;
    std::fs::rename(state.path.join(&temp), state.path.join(name))?;
    state.file.sync_all()?;
    Ok(())
}

pub fn stage_lock(destination: &Root) -> Result<File> {
    destination.mkdir(Path::new(STAGING))?;
    let dir = destination.open(Path::new(STAGING), libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
    let m = dir.metadata()?;
    ensure!(
        m.uid() == unsafe { libc::geteuid() } && m.mode() & 0o777 == 0o700,
        "staging directory must be private and owned by the mover"
    );
    let file = destination.open(
        Path::new(".tier-mover/lock"),
        libc::O_RDWR | libc::O_CREAT,
        0o600,
    )?;
    fs::lock(&file).context("another mover owns this destination")?;
    Ok(file)
}

fn ensure_parents(source: &Root, destination: &Root, relative: &Path) -> Result<()> {
    let mut parent = PathBuf::new();
    if let Some(dir) = relative.parent() {
        for component in dir.components() {
            parent.push(component.as_os_str());
            let src = source.open(&parent, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
            let created = destination.mkdir(&parent)?;
            let dst = destination.open(&parent, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
            if created {
                fs::preserve(&src, &dst)?;
                dst.sync_all()?;
            } else {
                let s = src.metadata()?;
                let d = dst.metadata()?;
                ensure!(
                    s.uid() == d.uid() && s.gid() == d.gid() && s.mode() == d.mode(),
                    "directory permissions differ for {parent:?}"
                );
                #[cfg(target_os = "linux")]
                ensure!(
                    fs::xattrs(&src)? == fs::xattrs(&dst)?,
                    "directory xattrs differ for {parent:?}"
                );
            }
        }
    }
    Ok(())
}

pub fn journal_name(index: usize) -> PathBuf {
    format!("transaction-{index}.json").into()
}

pub fn move_file(
    source: &Root,
    destinations: &[Root],
    index: usize,
    state: &Root,
    relative: &Path,
    expected: &Identity,
    check: impl Fn() -> Result<()>,
) -> Result<()> {
    let destination = &destinations[index];
    source.check()?;
    destination.check()?;
    check()?;
    let mut input = source.open(relative, libc::O_RDONLY | fs::noatime(), 0)?;
    let m = input.metadata()?;
    ensure!(
        m.is_file() && m.nlink() == 1 && expected.unchanged(&Identity::of(&m)),
        "source changed"
    );
    for root in destinations {
        ensure!(
            !root.exists(relative)?,
            "destination conflict for {relative:?}"
        );
    }
    ensure!(
        !destination.exists(Path::new(PAYLOAD))?,
        "unowned staging file; inspect before proceeding"
    );
    let name = journal_name(index);
    ensure!(!state.exists(&name)?, "unfinished transaction");
    let mut tx = Transaction {
        version: 1,
        source: source.path.clone(),
        destination: destination.path.clone(),
        source_root: source.identity.clone(),
        destination_root: destination.identity.clone(),
        relative: fs::name_bytes(relative),
        original: expected.clone(),
        prepared: None,
    };
    durable_json(state, &name, &tx)?;
    checkpoint("intent")?;
    let mut output = destination.open(
        Path::new(PAYLOAD),
        libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | fs::noatime(),
        0o600,
    )?;
    fs::copy_sparse(&mut input, &mut output, &check)?;
    ensure!(
        fs::equal_contents(&mut input, &mut output, &check)?,
        "copy verification failed"
    );
    ensure!(
        expected.unchanged(&Identity::of(&input.metadata()?)),
        "source changed during copy"
    );
    fs::preserve(&input, &output)?;
    output.sync_all()?;
    destination.parent(Path::new(PAYLOAD))?.sync_all()?;
    tx.prepared = Some(Identity::of(&output.metadata()?));
    durable_json(state, &name, &tx)?;
    checkpoint("prepared")?;
    check()?;
    source.check()?;
    destination.check()?;
    ensure_parents(source, destination, relative)?;
    for root in destinations {
        ensure!(!root.exists(relative)?, "destination appeared during copy");
    }
    ensure!(
        expected.unchanged(&Identity::of(
            &source
                .open(relative, libc::O_RDONLY | fs::noatime(), 0)?
                .metadata()?
        )),
        "source path changed"
    );
    destination.publish(Path::new(PAYLOAD), relative)?;
    checkpoint("published")?;
    // The prepared journal + destination inode identify publication even when
    // power fails before any subsequent journal write.
    destination.unlink(Path::new(PAYLOAD))?;
    checkpoint("unstaged")?;
    ensure!(
        expected.unchanged(&Identity::of(
            &source
                .open(relative, libc::O_RDONLY | fs::noatime(), 0)?
                .metadata()?
        )),
        "source path changed before deletion"
    );
    source.unlink(relative)?;
    drop(input);
    checkpoint("unlinked")?;
    state.unlink(&name)?;
    eprintln!(
        "moved {:?} -> {:?}, logicalBytes={}",
        source.path.join(relative),
        destination.path.join(relative),
        expected.size
    );
    Ok(())
}

pub fn recover(source: &Root, destinations: &[Root], state: &Root) -> Result<()> {
    for entry in fs::entries(&state.file)? {
        let name = Path::new(&entry);
        if !entry.to_string_lossy().starts_with("transaction-")
            || name.extension() != Some(std::ffi::OsStr::new("json"))
        {
            continue;
        }
        let tx: Transaction = serde_json::from_reader(state.open(name, libc::O_RDONLY, 0)?)?;
        ensure!(
            tx.version == 1
                && tx.source == source.path
                && tx.source_root.same_inode(&source.identity),
            "journal source identity changed"
        );
        let destination = destinations
            .iter()
            .find(|d| d.path == tx.destination)
            .context("journal destination no longer configured")?;
        ensure!(
            tx.destination_root.same_inode(&destination.identity),
            "journal destination identity changed"
        );
        source.check()?;
        destination.check()?;
        let rel = fs::from_bytes(&tx.relative);
        ensure!(
            crate::config::relative(rel) && !rel.starts_with(STAGING),
            "unsafe journal path"
        );
        let published = destination.exists(rel)?;
        if published {
            let prepared = tx
                .prepared
                .as_ref()
                .context("unexpected destination; preserving both copies")?;
            let mut output = destination.open(rel, libc::O_RDONLY | fs::noatime(), 0)?;
            let actual = Identity::of(&output.metadata()?);
            ensure!(
                actual.same_inode(prepared)
                    && actual.size == prepared.size
                    && actual.mtime == prepared.mtime
                    && actual.mtime_ns == prepared.mtime_ns,
                "published destination changed; preserving both copies"
            );
            if source.exists(rel)? {
                let mut input = source.open(rel, libc::O_RDONLY | fs::noatime(), 0)?;
                ensure!(
                    tx.original.unchanged(&Identity::of(&input.metadata()?)),
                    "source changed; preserving both copies"
                );
                ensure!(
                    fs::equal_contents(&mut input, &mut output, || Ok(()))?,
                    "recovery content conflict"
                );
                // Reapply and verify metadata before deleting a surviving source.
                fs::preserve(&input, &output)?;
                output.sync_all()?;
                destination.parent(rel)?.sync_all()?;
                source.unlink(rel)?;
            }
        } else {
            ensure!(
                source.exists(rel)?,
                "both source and published destination missing"
            );
            // Unpublished data is disposable; the source is always authoritative.
        }
        if destination.exists(Path::new(PAYLOAD))? {
            let staged = destination.open(Path::new(PAYLOAD), libc::O_RDONLY | fs::noatime(), 0)?;
            if let Some(prepared) = &tx.prepared {
                ensure!(
                    prepared.same_inode(&Identity::of(&staged.metadata()?)),
                    "staging inode changed"
                );
            }
            destination.unlink(Path::new(PAYLOAD))?;
        }
        state.unlink(name)?;
        eprintln!("recovered transaction {:?}", name);
    }
    Ok(())
}

// Failure injection is compiled only into the unit-test binary.
#[cfg(test)]
thread_local! { pub static FAIL_AT: std::cell::RefCell<Option<&'static str>> = const { std::cell::RefCell::new(None) }; }
fn checkpoint(_name: &str) -> Result<()> {
    #[cfg(test)]
    FAIL_AT.with(|point| {
        ensure!(*point.borrow() != Some(_name), "injected crash at {_name}");
        Ok(())
    })?;
    Ok(())
}
