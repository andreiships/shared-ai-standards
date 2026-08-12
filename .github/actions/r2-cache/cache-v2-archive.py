#!/usr/bin/env python3
"""Create and restore the constrained archive format used by R2 cache v2."""

from __future__ import annotations

import argparse
import glob
import gzip
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tarfile
import tempfile
import uuid

MAX_MEMBERS = 100_000
MAX_UNCOMPRESSED_BYTES = 512 * 1024 * 1024


class CacheArchiveError(Exception):
    """An archive or source path violated the cache contract."""


def _require_safe_platform() -> None:
    missing: list[str] = []
    for flag in ("O_DIRECTORY", "O_NOFOLLOW"):
        if not hasattr(os, flag):
            missing.append(flag)
    for function in (os.open, os.mkdir, os.stat, os.unlink, os.rename):
        if function not in os.supports_dir_fd:
            missing.append(f"{function.__name__}(dir_fd)")
    if os.stat not in os.supports_follow_symlinks:
        missing.append("stat(follow_symlinks)")
    if missing:
        raise CacheArchiveError(
            "platform lacks race-safe archive primitives: " + ", ".join(missing)
        )


def _within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def _source_namespace(path: Path, workspace: Path, home: Path) -> tuple[str, Path]:
    resolved = path.resolve(strict=True)
    if _within(resolved, workspace) and resolved != workspace:
        return "workspace", resolved.relative_to(workspace)
    if _within(resolved, home) and resolved != home:
        return "home", resolved.relative_to(home)
    raise CacheArchiveError(f"source path is outside allowed roots: {path}")


def _copy_source_entry(source_parent_fd: int, name: str, destination: Path) -> None:
    try:
        details = os.stat(name, dir_fd=source_parent_fd, follow_symlinks=False)
    except OSError as error:
        raise CacheArchiveError(f"unable to inspect cache source: {name}") from error
    if stat.S_ISDIR(details.st_mode):
        destination.mkdir(parents=True, exist_ok=True)
        try:
            source_fd = os.open(name, _directory_flags(), dir_fd=source_parent_fd)
        except OSError as error:
            raise CacheArchiveError(f"unsupported source type: {name}") from error
        try:
            for entry in sorted(os.scandir(source_fd), key=lambda item: item.name):
                _copy_source_entry(source_fd, entry.name, destination / entry.name)
        finally:
            os.close(source_fd)
        destination.chmod(details.st_mode & 0o777)
        return
    if not stat.S_ISREG(details.st_mode):
        raise CacheArchiveError(f"unsupported source type: {name}")
    if details.st_nlink != 1:
        raise CacheArchiveError(f"hardlinked source file: {name}")
    flags = os.O_RDONLY | os.O_NOFOLLOW
    try:
        source_fd = os.open(name, flags, dir_fd=source_parent_fd)
    except OSError as error:
        raise CacheArchiveError(f"unsupported source type: {name}") from error
    try:
        opened = os.fstat(source_fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            raise CacheArchiveError(f"hardlinked or unsupported source file: {name}")
        if (opened.st_dev, opened.st_ino) != (details.st_dev, details.st_ino):
            raise CacheArchiveError(f"cache source changed during pack: {name}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with os.fdopen(os.dup(source_fd), "rb") as source, destination.open("xb") as output:
            shutil.copyfileobj(source, output)
        destination.chmod(opened.st_mode & 0o777)
    finally:
        os.close(source_fd)


def _tar_filter(member: tarfile.TarInfo) -> tarfile.TarInfo:
    if not (member.isfile() or member.isdir()):
        raise CacheArchiveError(f"unsupported source type: {member.name}")
    member.uid = 0
    member.gid = 0
    member.uname = ""
    member.gname = ""
    member.mtime = 0
    member.mode &= 0o777
    return member


def pack(archive: Path, workspace: Path, home: Path, patterns: list[str]) -> None:
    workspace = workspace.resolve(strict=True)
    home = home.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="r2-cache-v2-pack-") as temp:
        staging = Path(temp)
        copied = False
        root_fds = {
            "workspace": os.open(workspace, _directory_flags()),
            "home": os.open(home, _directory_flags()),
        }
        try:
            for raw_pattern in patterns:
                pattern = os.path.expanduser(raw_pattern)
                matches = sorted(Path(item) for item in glob.glob(pattern, recursive=True))
                for source in matches:
                    if not source.exists() and not source.is_symlink():
                        continue
                    if source.is_symlink():
                        raise CacheArchiveError(f"unsupported source type: {source}")
                    namespace, relative = _source_namespace(source, workspace, home)
                    destination = staging / namespace / relative
                    parent_fd = _open_directory_at(
                        root_fds[namespace], tuple(relative.parts[:-1]), str(source), create=False
                    )
                    try:
                        _copy_source_entry(parent_fd, relative.parts[-1], destination)
                    finally:
                        os.close(parent_fd)
                    copied = True
        finally:
            for root_fd in root_fds.values():
                os.close(root_fd)

        if not copied:
            raise CacheArchiveError("no cache paths matched")

        archive.parent.mkdir(parents=True, exist_ok=True)
        temporary_archive = archive.with_suffix(f"{archive.suffix}.partial")
        try:
            with temporary_archive.open("wb") as raw:
                with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w") as tar:
                        for namespace in ("workspace", "home"):
                            source = staging / namespace
                            if source.exists():
                                tar.add(source, arcname=namespace, recursive=True, filter=_tar_filter)
            temporary_archive.replace(archive)
        finally:
            temporary_archive.unlink(missing_ok=True)


def _member_destination(member: tarfile.TarInfo, workspace: Path, home: Path) -> Path:
    pure = PurePosixPath(member.name)
    if pure.is_absolute() or ".." in pure.parts or len(pure.parts) < 1:
        raise CacheArchiveError(f"unsafe archive member: {member.name}")
    roots = {"workspace": workspace, "home": home}
    root = roots.get(pure.parts[0])
    if root is None:
        raise CacheArchiveError(f"unsafe archive member: {member.name}")
    if len(pure.parts) == 1:
        return root
    destination = root.joinpath(*pure.parts[1:])
    if not _within(destination.parent.resolve(strict=False), root):
        raise CacheArchiveError(f"unsafe archive member: {member.name}")
    return destination


def _validate_existing_destination(destination: Path, member: tarfile.TarInfo) -> None:
    try:
        details = destination.lstat()
    except FileNotFoundError:
        return
    if member.isdir() and stat.S_ISDIR(details.st_mode):
        return
    if member.isfile() and stat.S_ISREG(details.st_mode) and details.st_nlink == 1:
        return
    raise CacheArchiveError(f"unsafe existing destination: {member.name}")


def _directory_flags() -> int:
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_directory_at(
    root_fd: int,
    parts: tuple[str, ...],
    member_name: str,
    *,
    create: bool,
) -> int:
    current_fd = os.dup(root_fd)
    try:
        for component in parts:
            try:
                next_fd = os.open(component, _directory_flags(), dir_fd=current_fd)
            except FileNotFoundError:
                if not create:
                    raise CacheArchiveError(f"missing archive destination: {member_name}") from None
                try:
                    os.mkdir(component, 0o700, dir_fd=current_fd)
                except FileExistsError:
                    pass
                next_fd = os.open(component, _directory_flags(), dir_fd=current_fd)
            except OSError as error:
                raise CacheArchiveError(f"unsafe existing destination: {member_name}") from error
            os.close(current_fd)
            current_fd = next_fd
        return current_fd
    except Exception:
        os.close(current_fd)
        raise


def _validate_entry_at(parent_fd: int, name: str, member: tarfile.TarInfo) -> None:
    try:
        details = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if member.isdir() and stat.S_ISDIR(details.st_mode):
        return
    if member.isfile() and stat.S_ISREG(details.st_mode) and details.st_nlink == 1:
        return
    raise CacheArchiveError(f"unsafe existing destination: {member.name}")


def _ensure_directory_at(root_fd: int, parts: tuple[str, ...], member: tarfile.TarInfo) -> None:
    if not parts:
        return
    parent_fd = _open_directory_at(root_fd, parts[:-1], member.name, create=True)
    try:
        name = parts[-1]
        _validate_entry_at(parent_fd, name, member)
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            pass
        directory_fd = os.open(name, _directory_flags(), dir_fd=parent_fd)
        os.close(directory_fd)
    except OSError as error:
        raise CacheArchiveError(f"unsafe existing destination: {member.name}") from error
    finally:
        os.close(parent_fd)


def _write_file_at(
    tar: tarfile.TarFile,
    member: tarfile.TarInfo,
    root_fd: int,
    parts: tuple[str, ...],
) -> None:
    if not parts:
        raise CacheArchiveError(f"unsafe archive member: {member.name}")
    parent_fd = _open_directory_at(root_fd, parts[:-1], member.name, create=True)
    temporary_name = f".r2-cache-v2-{uuid.uuid4().hex}.partial"
    temporary_created = False
    try:
        name = parts[-1]
        _validate_entry_at(parent_fd, name, member)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        descriptor = os.open(temporary_name, flags, 0o600, dir_fd=parent_fd)
        temporary_created = True
        source = tar.extractfile(member)
        if source is None:
            os.close(descriptor)
            raise CacheArchiveError(f"archive member has no body: {member.name}")
        with source, os.fdopen(descriptor, "wb") as output:
            shutil.copyfileobj(source, output)
            os.fchmod(output.fileno(), member.mode & 0o777)
        os.rename(
            temporary_name,
            name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        temporary_created = False
    finally:
        if temporary_created:
            try:
                os.unlink(temporary_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        os.close(parent_fd)


def _apply_directory_mode(root_fd: int, parts: tuple[str, ...], member: tarfile.TarInfo) -> None:
    if not parts:
        return
    directory_fd = _open_directory_at(root_fd, parts, member.name, create=False)
    try:
        os.fchmod(directory_fd, member.mode & 0o777)
    finally:
        os.close(directory_fd)


def restore(archive: Path, workspace: Path, home: Path) -> None:
    workspace = workspace.resolve(strict=True)
    home = home.resolve(strict=True)
    destinations: dict[str, tuple[Path, str, tuple[str, ...]]] = {}
    seen_destinations: set[Path] = set()
    member_count = 0
    total_size = 0
    with tarfile.open(archive, mode="r:gz") as tar:
        for member in tar:
            member_count += 1
            if member_count > MAX_MEMBERS:
                raise CacheArchiveError("archive contains too many members")
            if not (member.isfile() or member.isdir()):
                raise CacheArchiveError(f"unsupported archive member type: {member.name}")
            if member.size < 0:
                raise CacheArchiveError(f"invalid archive member size: {member.name}")
            if member.isfile():
                total_size += member.size
                if total_size > MAX_UNCOMPRESSED_BYTES:
                    raise CacheArchiveError("archive expands beyond the allowed size")
            if member.name in destinations:
                raise CacheArchiveError(f"duplicate archive member: {member.name}")
            destination = _member_destination(member, workspace, home)
            if destination in seen_destinations:
                raise CacheArchiveError(f"duplicate archive destination: {member.name}")
            pure = PurePosixPath(member.name)
            destinations[member.name] = (destination, pure.parts[0], tuple(pure.parts[1:]))
            seen_destinations.add(destination)

    root_fds = {
        "workspace": os.open(workspace, _directory_flags()),
        "home": os.open(home, _directory_flags()),
    }
    try:
        directories: list[tuple[int, tuple[str, ...], tarfile.TarInfo]] = []
        with tarfile.open(archive, mode="r:gz") as tar:
            extracted_members = 0
            for member in tar:
                extracted_members += 1
                if member.name not in destinations:
                    raise CacheArchiveError(f"archive changed during restore: {member.name}")
                destination, namespace, parts = destinations[member.name]
                # This early check gives clear diagnostics; descriptor-relative
                # traversal and replacement below provide the race-safe boundary.
                _validate_existing_destination(destination, member)
                root_fd = root_fds[namespace]
                if member.isdir():
                    _ensure_directory_at(root_fd, parts, member)
                    directories.append((root_fd, parts, member))
                else:
                    _write_file_at(tar, member, root_fd, parts)
            if extracted_members != member_count:
                raise CacheArchiveError("archive changed during restore")
        for root_fd, parts, member in sorted(
            directories, key=lambda entry: len(entry[1]), reverse=True
        ):
            _apply_directory_mode(root_fd, parts, member)
    finally:
        for root_fd in root_fds.values():
            os.close(root_fd)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("pack", "restore"):
        child = subparsers.add_parser(command)
        child.add_argument("--archive", type=Path, required=True)
        child.add_argument("--workspace", type=Path, required=True)
        child.add_argument("--home", type=Path, required=True)
        if command == "pack":
            child.add_argument("--path", action="append", default=[], required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        _require_safe_platform()
        if args.command == "pack":
            pack(args.archive, args.workspace, args.home, args.path)
        else:
            restore(args.archive, args.workspace, args.home)
    except (CacheArchiveError, OSError, tarfile.TarError) as error:
        print(f"r2-cache-v2: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
