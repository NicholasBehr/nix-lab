import argparse
import dataclasses
import fcntl
import json
import logging
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path

LOGGER = logging.getLogger("storage-mover")
TEMP_PREFIX = ".storage-mover-tmp-"
PENDING_DIRECTORY = "storage-mover-pending"
TEMP_TOKEN_PATTERN = re.compile(r"^[0-9a-f]{32}$")
STAGED_MARKER_PATTERN = re.compile(r"^\.[0-9a-f]{32}\.new$")
SIZE_PATTERN = re.compile(r"^(\d+)([KMGTPE]?)(?:I?B)?$", re.IGNORECASE)


@dataclasses.dataclass(frozen=True)
class Candidate:
    path: Path
    relative_path: Path
    size: int
    atime_ns: int
    mtime_ns: int
    device: int
    inode: int


def parse_size(value: str) -> int:
    match = SIZE_PATTERN.fullmatch(value.strip())
    if match is None:
        raise argparse.ArgumentTypeError(
            f"invalid size {value!r}; use bytes or a K/M/G/T/P/E suffix"
        )
    amount = int(match.group(1))
    suffix = match.group(2).upper()
    exponent = "KMGTPE".find(suffix) + 1 if suffix else 0
    return amount * (1024**exponent)


def format_size(value: int) -> str:
    amount = float(value)
    for suffix in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if amount < 1024 or suffix == "PiB":
            return f"{amount:.2f} {suffix}"
        amount /= 1024
    raise AssertionError("unreachable")


def is_excluded(path: Path, excluded_names: set[str]) -> bool:
    return any(part in excluded_names for part in path.parts)


def scan_cache(
    source: Path,
    excluded_names: set[str],
) -> tuple[int, list[Candidate], int]:
    candidates: list[Candidate] = []
    seen_inodes: set[tuple[int, int]] = set()
    skipped_hardlinks = 0
    total_size = 0

    for root, directory_names, file_names in os.walk(source):
        root_path = Path(root)
        directory_names[:] = [
            name
            for name in directory_names
            if name not in excluded_names and not name.startswith(TEMP_PREFIX)
        ]

        for name in file_names:
            path = root_path / name
            relative_path = path.relative_to(source)
            if name.startswith(TEMP_PREFIX) or is_excluded(
                relative_path, excluded_names
            ):
                continue

            try:
                file_stat = path.lstat()
            except FileNotFoundError:
                continue

            if not stat.S_ISREG(file_stat.st_mode):
                continue

            inode_key = (file_stat.st_dev, file_stat.st_ino)
            if inode_key not in seen_inodes:
                total_size += file_stat.st_size
                seen_inodes.add(inode_key)

            # Moving one name would not release a hard-linked inode and could
            # break workflows such as torrent seeding. Leave the whole inode
            # in cache until only one link remains.
            if file_stat.st_nlink > 1:
                skipped_hardlinks += 1
                continue

            candidates.append(
                Candidate(
                    path=path,
                    relative_path=relative_path,
                    size=file_stat.st_size,
                    atime_ns=file_stat.st_atime_ns,
                    mtime_ns=file_stat.st_mtime_ns,
                    device=file_stat.st_dev,
                    inode=file_stat.st_ino,
                )
            )

    candidates.sort(key=lambda candidate: (candidate.atime_ns, str(candidate.path)))
    return total_size, candidates, skipped_hardlinks


def same_file_state(candidate: Candidate, file_stat: os.stat_result) -> bool:
    return all(
        (
            file_stat.st_dev == candidate.device,
            file_stat.st_ino == candidate.inode,
            file_stat.st_size == candidate.size,
            file_stat.st_mtime_ns == candidate.mtime_ns,
            file_stat.st_nlink == 1,
        )
    )


def is_open(path: Path, fuser: Path) -> bool:
    result = subprocess.run(
        [str(fuser), "-s", str(path)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    LOGGER.warning(
        "fuser failed with status %d; treating file as open: %s",
        result.returncode,
        path,
    )
    return True


def fsync_directory(path: Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def pending_marker_path(state_directory: Path, token: str) -> Path:
    return state_directory / token


def register_pending_temporary(
    state_directory: Path,
    relative_path: Path,
    token: str,
) -> None:
    """Durably record a temporary file before rsync is allowed to create it."""
    marker = pending_marker_path(state_directory, token)
    staged_marker = state_directory / f".{token}.new"
    payload = json.dumps(
        {"relative_path": os.fspath(relative_path)},
        ensure_ascii=False,
    )

    marker_fd = os.open(
        staged_marker,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        with os.fdopen(marker_fd, "w", encoding="utf-8") as marker_file:
            marker_file.write(payload)
            marker_file.write("\n")
            marker_file.flush()
            os.fsync(marker_file.fileno())
    except BaseException:
        try:
            staged_marker.unlink()
        except FileNotFoundError:
            pass
        raise

    os.replace(staged_marker, marker)
    fsync_directory(state_directory)


def remove_pending_marker(marker: Path, state_directory: Path) -> None:
    try:
        marker.unlink()
    except FileNotFoundError:
        return
    fsync_directory(state_directory)


def validated_temporary_path(
    marker: Path,
    destination_root: Path,
) -> Path:
    token = marker.name
    if TEMP_TOKEN_PATTERN.fullmatch(token) is None:
        raise ValueError(f"invalid pending marker name: {marker.name}")

    with marker.open("r", encoding="utf-8") as marker_file:
        payload = json.load(marker_file)
    if not isinstance(payload, dict) or not isinstance(
        payload.get("relative_path"), str
    ):
        raise TypeError("pending marker has an invalid payload")

    relative_path = Path(payload["relative_path"])
    if any(
        (
            relative_path.is_absolute(),
            ".." in relative_path.parts,
            relative_path.name != f"{TEMP_PREFIX}{token}",
        )
    ):
        raise ValueError("pending marker contains an unsafe temporary path")
    return destination_root / relative_path


def cleanup_stale_temporaries(
    state_directory: Path,
    destination_root: Path,
    fuser: Path,
    minimum_age: int,
    dry_run: bool,
) -> int:
    """Remove only old destination temporaries recorded by this mover."""
    failures = 0
    cutoff_ns = time.time_ns() - minimum_age * 1_000_000_000

    # A staged marker is written before its final marker and before rsync starts.
    # With the single-instance lock held, any leftover .new file is abandoned.
    for marker in state_directory.iterdir():
        if not STAGED_MARKER_PATTERN.fullmatch(marker.name):
            continue
        if dry_run:
            LOGGER.info("would remove abandoned staged marker: %s", marker)
            continue
        try:
            marker.unlink()
            fsync_directory(state_directory)
        except OSError as error:
            LOGGER.error("failed to remove staged marker %s: %s", marker, error)
            failures += 1

    for marker in state_directory.iterdir():
        if TEMP_TOKEN_PATTERN.fullmatch(marker.name) is None:
            continue
        try:
            marker_stat = marker.lstat()
            if not stat.S_ISREG(marker_stat.st_mode):
                raise ValueError("pending marker is not a regular file")
            temporary = validated_temporary_path(marker, destination_root)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            LOGGER.error("invalid pending marker %s: %s", marker, error)
            failures += 1
            continue

        try:
            temporary_stat = temporary.lstat()
        except FileNotFoundError:
            if dry_run:
                LOGGER.info("would remove completed pending marker: %s", marker)
                continue
            try:
                remove_pending_marker(marker, state_directory)
            except OSError as error:
                LOGGER.error("failed to remove pending marker %s: %s", marker, error)
                failures += 1
            continue
        except OSError as error:
            LOGGER.error("failed to inspect pending temporary %s: %s", temporary, error)
            failures += 1
            continue

        if marker_stat.st_ctime_ns > cutoff_ns:
            LOGGER.info("leaving recent pending temporary: %s", temporary)
            continue
        if not stat.S_ISREG(temporary_stat.st_mode):
            LOGGER.error("pending temporary is not a regular file: %s", temporary)
            failures += 1
            continue
        if is_open(temporary, fuser):
            LOGGER.warning("leaving open pending temporary: %s", temporary)
            failures += 1
            continue
        if dry_run:
            LOGGER.info("would remove stale temporary: %s", temporary)
            continue

        try:
            temporary.unlink()
            fsync_directory(temporary.parent)
            remove_pending_marker(marker, state_directory)
        except OSError as error:
            LOGGER.error("failed to remove stale temporary %s: %s", temporary, error)
            failures += 1
            continue
        LOGGER.info("removed stale temporary: %s", temporary)

    return failures


def copy_directory_metadata(source: Path, destination: Path) -> None:
    source_stat = source.stat()
    os.chown(destination, source_stat.st_uid, source_stat.st_gid)
    shutil.copystat(source, destination, follow_symlinks=False)


def ensure_destination_parent(
    source_root: Path,
    destination_root: Path,
    relative_parent: Path,
) -> None:
    source_path = source_root
    destination_path = destination_root
    for component in relative_parent.parts:
        source_path /= component
        destination_path /= component
        try:
            destination_path.mkdir()
        except FileExistsError:
            continue
        copy_directory_metadata(source_path, destination_path)


def files_identical(first: Path, second: Path) -> bool:
    try:
        first_stat = first.stat()
        second_stat = second.stat()
    except FileNotFoundError:
        return False
    if first_stat.st_size != second_stat.st_size:
        return False

    chunk_size = 8 * 1024 * 1024
    with first.open("rb") as first_file, second.open("rb") as second_file:
        while True:
            first_chunk = first_file.read(chunk_size)
            second_chunk = second_file.read(chunk_size)
            if first_chunk != second_chunk:
                return False
            if not first_chunk:
                return True


def remove_duplicate_source(
    candidate: Candidate,
    destination: Path,
    fuser: Path,
) -> bool:
    try:
        if is_open(candidate.path, fuser):
            LOGGER.warning("leaving open source in cache: %s", candidate.path)
            return False
        source_stat = candidate.path.stat()
        if not same_file_state(candidate, source_stat):
            LOGGER.warning(
                "source changed while checking duplicate: %s", candidate.path
            )
            return False
        if not files_identical(candidate.path, destination):
            LOGGER.error(
                "destination exists with different content; leaving source: %s",
                destination,
            )
            return False
        source_stat = candidate.path.stat()
    except FileNotFoundError:
        return True
    except OSError as error:
        LOGGER.error("failed to verify duplicate %s: %s", candidate.path, error)
        return False
    try:
        if not same_file_state(candidate, source_stat) or is_open(
            candidate.path, fuser
        ):
            LOGGER.warning("source became active while checking: %s", candidate.path)
            return False
        candidate.path.unlink()
    except OSError as error:
        LOGGER.error("failed to remove duplicate %s: %s", candidate.path, error)
        return False
    LOGGER.info("removed verified duplicate source: %s", candidate.relative_path)
    return True


def move_candidate(
    candidate: Candidate,
    source_root: Path,
    destination_root: Path,
    state_directory: Path,
    rsync: Path,
    fuser: Path,
    minimum_mtime_age: int,
    dry_run: bool,
) -> bool:
    now_ns = time.time_ns()
    if now_ns - candidate.mtime_ns < minimum_mtime_age * 1_000_000_000:
        LOGGER.info("skipping recently modified file: %s", candidate.relative_path)
        return False

    if is_open(candidate.path, fuser):
        LOGGER.info("skipping open file: %s", candidate.relative_path)
        return False

    destination = destination_root / candidate.relative_path
    if dry_run:
        LOGGER.info(
            "would move %s (%s)",
            candidate.relative_path,
            format_size(candidate.size),
        )
        return True

    try:
        ensure_destination_parent(
            source_root,
            destination_root,
            candidate.relative_path.parent,
        )
    except OSError as error:
        LOGGER.error(
            "failed to prepare destination for %s: %s",
            candidate.relative_path,
            error,
        )
        return False

    if os.path.lexists(destination):
        return remove_duplicate_source(candidate, destination, fuser)

    token = uuid.uuid4().hex
    temporary = destination.with_name(f"{TEMP_PREFIX}{token}")
    marker = pending_marker_path(state_directory, token)
    marker_registered = False
    try:
        register_pending_temporary(
            state_directory,
            temporary.relative_to(destination_root),
            token,
        )
        marker_registered = True
        subprocess.run(
            [
                str(rsync),
                "--archive",
                "--acls",
                "--xattrs",
                "--numeric-ids",
                "--sparse",
                "--fsync",
                "--protect-args",
                "--",
                str(candidate.path),
                str(temporary),
            ],
            check=True,
        )

        copied_stat = temporary.stat()
        if copied_stat.st_size != candidate.size:
            raise RuntimeError(
                f"size mismatch for {candidate.relative_path}: "
                f"expected {candidate.size}, copied {copied_stat.st_size}"
            )

        try:
            source_stat = candidate.path.stat()
        except FileNotFoundError:
            raise RuntimeError(f"source disappeared: {candidate.path}") from None
        if not same_file_state(candidate, source_stat):
            raise RuntimeError(f"source changed during copy: {candidate.path}")
        if is_open(candidate.path, fuser):
            raise RuntimeError(f"source was opened during copy: {candidate.path}")
        if os.path.lexists(destination):
            raise RuntimeError(f"destination appeared during copy: {destination}")

        # Publish the complete copy first. The NVMe branch remains first in
        # /data until unlink, so clients never observe the temporary file.
        temporary.rename(destination)
        fsync_directory(destination.parent)

        candidate.path.unlink()
        LOGGER.info(
            "moved %s (%s)",
            candidate.relative_path,
            format_size(candidate.size),
        )
        return True
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        LOGGER.error("failed to move %s: %s", candidate.relative_path, error)
        return False
    finally:
        temporary_is_absent = False
        try:
            temporary.unlink()
        except FileNotFoundError:
            temporary_is_absent = True
        except OSError as error:
            LOGGER.error("failed to remove temporary %s: %s", temporary, error)
        else:
            temporary_is_absent = True
            try:
                fsync_directory(temporary.parent)
            except OSError as error:
                LOGGER.error(
                    "failed to persist temporary cleanup for %s: %s",
                    temporary,
                    error,
                )

        if marker_registered and temporary_is_absent:
            try:
                remove_pending_marker(marker, state_directory)
            except OSError as error:
                LOGGER.error("failed to remove pending marker %s: %s", marker, error)


def remove_empty_directories(source: Path, excluded_names: set[str]) -> None:
    for root, directory_names, _file_names in os.walk(source, topdown=False):
        root_path = Path(root)
        for name in directory_names:
            path = root_path / name
            relative_path = path.relative_to(source)
            if is_excluded(relative_path, excluded_names):
                continue
            try:
                path.rmdir()
            except OSError:
                pass


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evict least-recently-accessed files from a fast branch",
    )
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--limit", required=True, type=parse_size)
    parser.add_argument("--rsync", required=True, type=Path)
    parser.add_argument("--fuser", required=True, type=Path)
    parser.add_argument("--minimum-mtime-age", type=int, default=300)
    parser.add_argument("--stale-temp-age", type=int, default=3600)
    parser.add_argument("--allow-non-mounts", action="store_true")
    parser.add_argument(
        "--exclude-name",
        action="append",
        default=[".snapraid", ".zfs", "lost+found"],
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def run_mover(
    arguments: argparse.Namespace,
    source: Path,
    destination: Path,
) -> int:
    excluded_names = set(arguments.exclude_name)
    state_directory = source / ".snapraid" / PENDING_DIRECTORY
    if arguments.dry_run:
        cleanup_failures = (
            cleanup_stale_temporaries(
                state_directory,
                destination,
                arguments.fuser,
                arguments.stale_temp_age,
                True,
            )
            if state_directory.is_dir()
            else 0
        )
    else:
        try:
            state_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(state_directory, 0o700)
            cleanup_failures = cleanup_stale_temporaries(
                state_directory,
                destination,
                arguments.fuser,
                arguments.stale_temp_age,
                False,
            )
        except OSError as error:
            LOGGER.error("failed to prepare mover state directory: %s", error)
            return 1

    total_size, candidates, skipped_hardlinks = scan_cache(source, excluded_names)
    LOGGER.info(
        "cache contains %s; eviction limit is %s",
        format_size(total_size),
        format_size(arguments.limit),
    )
    if skipped_hardlinks:
        LOGGER.warning("skipped %d hard-linked path(s)", skipped_hardlinks)
    if total_size <= arguments.limit:
        return 1 if cleanup_failures else 0

    remaining_size = total_size
    for candidate in candidates:
        if remaining_size <= arguments.limit:
            break
        if move_candidate(
            candidate,
            source,
            destination,
            state_directory,
            arguments.rsync,
            arguments.fuser,
            arguments.minimum_mtime_age,
            arguments.dry_run,
        ):
            remaining_size -= candidate.size

    if arguments.dry_run:
        LOGGER.info("dry-run projected cache size: %s", format_size(remaining_size))
        return 1 if cleanup_failures else 0

    remove_empty_directories(source, excluded_names)
    final_size, _candidates, _skipped_hardlinks = scan_cache(source, excluded_names)
    LOGGER.info("cache size after eviction: %s", format_size(final_size))
    if (final_size > arguments.limit or cleanup_failures) and cleanup_failures:
        LOGGER.error("failed to clean up %d stale temporary item(s)", cleanup_failures)
    if final_size > arguments.limit:
        LOGGER.error(
            "cache remains above limit, likely because files were open, "
            "recently modified, hard-linked, or failed to copy"
        )
    if final_size > arguments.limit or cleanup_failures:
        return 1
    return 0


def main() -> int:
    arguments = parse_arguments()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    source = arguments.source.resolve()
    destination = arguments.destination.resolve()
    if source == destination or source in destination.parents:
        LOGGER.error("destination must not be inside the source")
        return 2
    if destination in source.parents:
        LOGGER.error("source must not be inside the destination")
        return 2
    if arguments.minimum_mtime_age < 0 or arguments.stale_temp_age < 0:
        LOGGER.error("age arguments must not be negative")
        return 2
    if not arguments.allow_non_mounts:
        for name, path in (("source", source), ("destination", destination)):
            if not path.is_mount():
                LOGGER.error("%s is not a mounted filesystem: %s", name, path)
                return 2

    lock_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            LOGGER.error("another mover is already running for %s", source)
            return 2
        return run_mover(arguments, source, destination)
    finally:
        os.close(lock_fd)


if __name__ == "__main__":
    sys.exit(main())
