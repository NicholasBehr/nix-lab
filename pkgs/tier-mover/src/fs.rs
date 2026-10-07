//! Filesystem operations are relative to pinned directory descriptors. Linux uses
//! openat2 to reject symlinks and nested mounts; the Unix fallback supports tests.
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, CString, OsStr, OsString},
    fs::{File, Metadata},
    io::{self, Read, Seek, SeekFrom, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::{OsStrExt, OsStringExt},
            fs::MetadataExt,
        },
    },
    path::{Path, PathBuf},
};

pub fn cvt(n: libc::c_int) -> io::Result<libc::c_int> {
    if n < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(n)
    }
}
fn cpath(p: &Path) -> Result<CString> {
    Ok(CString::new(p.as_os_str().as_bytes())?)
}

#[derive(Debug)]
pub struct Root {
    pub path: PathBuf,
    pub file: File,
    pub identity: Identity,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Identity {
    pub dev: u64,
    pub ino: u64,
    pub size: u64,
    pub blocks: u64,
    pub links: u64,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub atime: i64,
    pub atime_ns: i64,
    pub mtime: i64,
    pub mtime_ns: i64,
    pub ctime: i64,
    pub ctime_ns: i64,
}
impl Identity {
    pub fn of(m: &Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            size: m.size(),
            blocks: m.blocks(),
            links: m.nlink(),
            mode: m.mode(),
            uid: m.uid(),
            gid: m.gid(),
            atime: m.atime(),
            atime_ns: m.atime_nsec(),
            mtime: m.mtime(),
            mtime_ns: m.mtime_nsec(),
            ctime: m.ctime(),
            ctime_ns: m.ctime_nsec(),
        }
    }
    pub fn same_inode(&self, other: &Self) -> bool {
        self.dev == other.dev && self.ino == other.ino
    }
    pub fn unchanged(&self, other: &Self) -> bool {
        // The mover opens with O_NOATIME. Ignore atime here so incidental readers
        // do not make crash recovery delete or overwrite anything incorrectly.
        self.same_inode(other)
            && self.size == other.size
            && self.links == other.links
            && self.mode == other.mode
            && self.uid == other.uid
            && self.gid == other.gid
            && self.mtime == other.mtime
            && self.mtime_ns == other.mtime_ns
            && self.ctime == other.ctime
            && self.ctime_ns == other.ctime_ns
    }
}

pub fn noatime() -> i32 {
    #[cfg(target_os = "linux")]
    {
        libc::O_NOATIME
    }
    #[cfg(not(target_os = "linux"))]
    {
        0
    }
}

impl Root {
    pub fn new(path: &Path) -> Result<Self> {
        ensure!(
            std::fs::canonicalize(path)? == path,
            "root must be canonical and contain no symlinks: {path:?}"
        );
        let fd = cvt(unsafe {
            libc::open(
                cpath(path)?.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        let file = unsafe { File::from_raw_fd(fd) };
        let identity = Identity::of(&file.metadata()?);
        Ok(Self {
            path: path.into(),
            file,
            identity,
        })
    }
    pub fn open(&self, rel: &Path, flags: i32, mode: u32) -> Result<File> {
        ensure!(
            rel == Path::new(".") || crate::config::relative(rel),
            "unsafe relative path: {rel:?}"
        );
        #[cfg(target_os = "linux")]
        {
            #[repr(C)]
            struct OpenHow {
                flags: u64,
                mode: u64,
                resolve: u64,
            }
            let how = OpenHow {
                flags: (flags | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK) as u64,
                mode: mode as u64,
                resolve: 0x01 | 0x04 | 0x08,
            }; // NO_XDEV | NO_SYMLINKS | BENEATH
            let result = cvt(unsafe {
                libc::syscall(
                    libc::SYS_openat2,
                    self.file.as_raw_fd(),
                    cpath(rel)?.as_ptr(),
                    &how,
                    std::mem::size_of::<OpenHow>(),
                ) as i32
            });
            let fd = match result {
                Ok(fd) => fd,
                Err(error) if error.raw_os_error() == Some(libc::ENOSYS) => {
                    return self.open_fallback(rel, flags, mode);
                }
                Err(error) => {
                    return Err(error).with_context(|| format!("open {rel:?} with openat2"))
                }
            };
            let file = unsafe { File::from_raw_fd(fd) };
            ensure!(
                file.metadata()?.dev() == self.identity.dev,
                "crossed filesystem boundary"
            );
            Ok(file)
        }
        #[cfg(not(target_os = "linux"))]
        {
            self.open_fallback(rel, flags, mode)
        }
    }

    pub(crate) fn open_fallback(&self, rel: &Path, flags: i32, mode: u32) -> Result<File> {
        let mut parent = self.file.try_clone()?;
        let parts: Vec<_> = rel.components().collect();
        for part in &parts[..parts.len() - 1] {
            let fd = cvt(unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    cpath(Path::new(part.as_os_str()))?.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            })
            .with_context(|| format!("open directory component {:?}", part.as_os_str()))?;
            parent = unsafe { File::from_raw_fd(fd) };
            ensure!(
                parent.metadata()?.dev() == self.identity.dev,
                "crossed filesystem boundary at {:?}",
                part.as_os_str()
            );
        }
        let fd = cvt(unsafe {
            libc::openat(
                parent.as_raw_fd(),
                cpath(Path::new(
                    parts.last().context("empty relative path")?.as_os_str(),
                ))?
                .as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                mode,
            )
        })
        .with_context(|| format!("open {rel:?} with openat fallback"))?;
        let file = unsafe { File::from_raw_fd(fd) };
        ensure!(
            file.metadata()?.dev() == self.identity.dev,
            "crossed filesystem boundary"
        );
        Ok(file)
    }
    pub fn check(&self) -> Result<()> {
        let current = Root::new(&self.path)?;
        ensure!(
            current.identity.same_inode(&self.identity),
            "root filesystem changed: {:?}",
            self.path
        );
        Ok(())
    }
    pub fn parent(&self, rel: &Path) -> Result<File> {
        let p = rel
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        self.open(p, libc::O_RDONLY | libc::O_DIRECTORY, 0)
    }
    pub fn exists(&self, rel: &Path) -> Result<bool> {
        let parent = match self.parent(rel) {
            Ok(p) => p,
            Err(e) if is_not_found(&e) => return Ok(false),
            Err(e) => return Err(e),
        };
        let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
        match cvt(unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                cpath(Path::new(rel.file_name().context("no filename")?))?.as_ptr(),
                st.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        }) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }
    pub fn unlink(&self, rel: &Path) -> Result<()> {
        let parent = self.parent(rel)?;
        cvt(unsafe {
            libc::unlinkat(
                parent.as_raw_fd(),
                cpath(Path::new(rel.file_name().context("no filename")?))?.as_ptr(),
                0,
            )
        })?;
        parent.sync_all()?;
        Ok(())
    }
    pub fn mkdir(&self, rel: &Path) -> Result<bool> {
        let parent = self.parent(rel)?;
        let r = cvt(unsafe {
            libc::mkdirat(
                parent.as_raw_fd(),
                cpath(Path::new(rel.file_name().context("no filename")?))?.as_ptr(),
                0o700,
            )
        });
        match r {
            Ok(_) => {
                parent.sync_all()?;
                Ok(true)
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                self.open(rel, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
                Ok(false)
            }
            Err(e) => Err(e.into()),
        }
    }
    pub fn publish(&self, staging: &Path, target: &Path) -> Result<()> {
        let src = self.parent(staging)?;
        let dst = self.parent(target)?;
        // linkat atomically publishes a complete inode and never replaces a name.
        cvt(unsafe {
            libc::linkat(
                src.as_raw_fd(),
                cpath(Path::new(staging.file_name().unwrap()))?.as_ptr(),
                dst.as_raw_fd(),
                cpath(Path::new(target.file_name().unwrap()))?.as_ptr(),
                0,
            )
        })?;
        dst.sync_all()?;
        Ok(())
    }
    pub fn space(&self) -> Result<(u64, u64)> {
        let mut s = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        cvt(unsafe { libc::fstatvfs(self.file.as_raw_fd(), s.as_mut_ptr()) })?;
        let s = unsafe { s.assume_init() };
        ensure!(s.f_flag & libc::ST_RDONLY == 0, "read-only destination");
        Ok((
            (s.f_bavail as u64).saturating_mul(s.f_frsize),
            s.f_favail as u64,
        ))
    }
    pub fn used(&self) -> Result<u64> {
        let mut s = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        cvt(unsafe { libc::fstatvfs(self.file.as_raw_fd(), s.as_mut_ptr()) })?;
        let s = unsafe { s.assume_init() };
        Ok((s.f_blocks as u64)
            .saturating_sub(s.f_bfree as u64)
            .saturating_mul(s.f_frsize))
    }
}

pub fn is_not_found(e: &anyhow::Error) -> bool {
    e.downcast_ref::<io::Error>()
        .is_some_and(|e| e.kind() == io::ErrorKind::NotFound)
}

pub fn entries(dir: &File) -> Result<Vec<OsString>> {
    let fd = cvt(unsafe { libc::dup(dir.as_raw_fd()) })?;
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        unsafe {
            libc::close(fd);
        }
        return Err(io::Error::last_os_error().into());
    }
    struct Stream(*mut libc::DIR);
    impl Drop for Stream {
        fn drop(&mut self) {
            unsafe {
                libc::closedir(self.0);
            }
        }
    }
    let guard = Stream(stream);
    let mut names = vec![];
    loop {
        #[cfg(target_os = "linux")]
        unsafe {
            *libc::__errno_location() = 0;
        }
        #[cfg(target_os = "macos")]
        unsafe {
            *libc::__error() = 0;
        }
        let entry = unsafe { libc::readdir(guard.0) };
        if entry.is_null() {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(0) {
                return Err(error.into());
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            names.push(OsString::from_vec(name.to_vec()));
        }
    }
    names.sort();
    Ok(names)
}

#[cfg(target_os = "linux")]
pub fn xattrs(file: &File) -> Result<std::collections::BTreeMap<Vec<u8>, Vec<u8>>> {
    let fd = file.as_raw_fd();
    let size = unsafe { libc::flistxattr(fd, std::ptr::null_mut(), 0) };
    if size < 0 {
        return Err(io::Error::last_os_error().into());
    }
    ensure!(size <= 1024 * 1024, "oversized xattr list");
    let mut list = vec![0u8; size as usize];
    let n = unsafe { libc::flistxattr(fd, list.as_mut_ptr().cast(), list.len()) };
    if n < 0 {
        return Err(io::Error::last_os_error().into());
    }
    list.truncate(n as usize);
    let mut result = std::collections::BTreeMap::new();
    for name in list.split(|b| *b == 0).filter(|s| !s.is_empty()) {
        let c = CString::new(name)?;
        let n = unsafe { libc::fgetxattr(fd, c.as_ptr(), std::ptr::null_mut(), 0) };
        if n < 0 {
            return Err(io::Error::last_os_error().into());
        }
        ensure!(n <= 16 * 1024 * 1024, "oversized xattr");
        let mut value = vec![0u8; n as usize];
        let n = unsafe { libc::fgetxattr(fd, c.as_ptr(), value.as_mut_ptr().cast(), value.len()) };
        if n < 0 {
            return Err(io::Error::last_os_error().into());
        }
        value.truncate(n as usize);
        result.insert(name.to_vec(), value);
    }
    Ok(result)
}

pub fn preserve(source: &File, destination: &File) -> Result<()> {
    let m = source.metadata()?;
    cvt(unsafe { libc::fchown(destination.as_raw_fd(), m.uid(), m.gid()) })?;
    cvt(unsafe { libc::fchmod(destination.as_raw_fd(), (m.mode() & 0o7777) as libc::mode_t) })?;
    #[cfg(target_os = "linux")]
    {
        let attrs = xattrs(source)?;
        for name in xattrs(destination)?
            .keys()
            .filter(|name| !attrs.contains_key(*name))
        {
            cvt(unsafe {
                libc::fremovexattr(
                    destination.as_raw_fd(),
                    CString::new(name.as_slice())?.as_ptr(),
                )
            })?;
        }
        for (name, value) in &attrs {
            cvt(unsafe {
                libc::fsetxattr(
                    destination.as_raw_fd(),
                    CString::new(name.as_slice())?.as_ptr(),
                    value.as_ptr().cast(),
                    value.len(),
                    0,
                )
            })?;
        }
        ensure!(xattrs(destination)? == attrs, "xattr preservation failed");
    }
    let times = [
        libc::timespec {
            tv_sec: m.atime(),
            tv_nsec: m.atime_nsec() as _,
        },
        libc::timespec {
            tv_sec: m.mtime(),
            tv_nsec: m.mtime_nsec() as _,
        },
    ];
    cvt(unsafe { libc::futimens(destination.as_raw_fd(), times.as_ptr()) })?;
    let d = destination.metadata()?;
    ensure!(
        m.uid() == d.uid()
            && m.gid() == d.gid()
            && m.mode() == d.mode()
            && m.mtime() == d.mtime()
            && m.mtime_nsec() == d.mtime_nsec()
            && m.atime() == d.atime()
            && m.atime_nsec() == d.atime_nsec(),
        "metadata preservation failed"
    );
    Ok(())
}

pub fn copy_sparse(
    source: &mut File,
    destination: &mut File,
    check: impl Fn() -> Result<()>,
) -> Result<()> {
    let mut buffer = vec![0u8; 1024 * 1024];
    let mut length = 0;
    loop {
        check()?;
        let n = source.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        if buffer[..n].iter().all(|b| *b == 0) {
            destination.seek(SeekFrom::Current(n as i64))?;
        } else {
            destination.write_all(&buffer[..n])?;
        }
        length += n as u64;
    }
    destination.set_len(length)?;
    Ok(())
}

pub fn equal_contents(a: &mut File, b: &mut File, check: impl Fn() -> Result<()>) -> Result<bool> {
    if a.metadata()?.len() != b.metadata()?.len() {
        return Ok(false);
    }
    a.rewind()?;
    b.rewind()?;
    let mut left = vec![0u8; 1024 * 1024];
    let mut right = vec![0u8; left.len()];
    loop {
        check()?;
        let n = a.read(&mut left)?;
        if n == 0 {
            return Ok(true);
        }
        b.read_exact(&mut right[..n])?;
        if left[..n] != right[..n] {
            return Ok(false);
        }
    }
}

pub fn name_bytes(path: &Path) -> Vec<u8> {
    path.as_os_str().as_bytes().to_vec()
}
pub fn from_bytes(bytes: &[u8]) -> &Path {
    Path::new(OsStr::from_bytes(bytes))
}
pub fn lock(file: &File) -> Result<()> {
    cvt(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) })?;
    Ok(())
}
