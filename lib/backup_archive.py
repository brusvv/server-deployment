#!/usr/bin/env python3
"""Validate server-deployment backup archives before privileged extraction."""
from __future__ import annotations

import os
import posixpath
import sys
import tarfile
from pathlib import Path


class ArchiveValidationError(ValueError):
    pass


def _inside(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def validate_archive(archive: str, allowed_roots: list[str], filesystem_root: str = "/") -> None:
    roots = [os.path.abspath(root).lstrip("/") for root in allowed_roots]
    roots = [root.rstrip("/") for root in roots if root.rstrip("/")]
    if not roots:
        raise ArchiveValidationError("No allowed restore paths were configured")

    try:
        tf = tarfile.open(archive, "r:gz")
    except (OSError, tarfile.TarError) as exc:
        raise ArchiveValidationError(f"Cannot read backup archive: {exc}") from exc

    with tf:
        members = tf.getmembers()
        if not members:
            raise ArchiveValidationError("Backup archive is empty")

        names: set[str] = set()
        symlinks: set[str] = set()
        normalized: list[tuple[tarfile.TarInfo, str]] = []

        for member in members:
            name = member.name
            if not name or name.startswith("/") or "\x00" in name:
                raise ArchiveValidationError(f"Unsafe absolute or empty archive path: {name!r}")

            # Tar archives produced from absolute source paths have their leading
            # slash stripped by GNU tar. Reject traversal instead of normalizing it.
            parts = name.split("/")
            if any(part in ("", ".", "..") for part in parts):
                # A trailing slash on a directory is harmless.
                if not (member.isdir() and parts[-1] == "" and all(p not in ("", ".", "..") for p in parts[:-1])):
                    raise ArchiveValidationError(f"Unsafe archive path: {name!r}")
                name = name.rstrip("/")

            if not name or name in names:
                raise ArchiveValidationError(f"Duplicate or invalid archive path: {name!r}")
            names.add(name)

            if not any(_inside(name, root) for root in roots):
                raise ArchiveValidationError(f"Path is outside configured backup roots: {name}")

            if not (member.isfile() or member.isdir() or member.issym()):
                raise ArchiveValidationError(f"Unsupported archive entry type: {name}")

            if member.mode & 0o7000:
                raise ArchiveValidationError(f"Special permission bits are not allowed in backups: {name}")

            if member.islnk():
                raise ArchiveValidationError(f"Hard links are not allowed in backups: {name}")

            if member.issym():
                link = member.linkname
                if not link or link.startswith("/") or "\x00" in link:
                    raise ArchiveValidationError(f"Unsafe symlink target in {name}: {link!r}")
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), link))
                if target == ".." or target.startswith("../") or not any(_inside(target, root) for root in roots):
                    raise ArchiveValidationError(f"Symlink escapes configured backup roots: {name} -> {link}")
                symlinks.add(name)

            normalized.append((member, name))

        # No later archive member may be placed below a symlink created by the
        # same archive, regardless of member order.
        for _, name in normalized:
            parts = name.split("/")
            for index in range(1, len(parts)):
                parent = "/".join(parts[:index])
                if parent in symlinks:
                    raise ArchiveValidationError(f"Archive writes through symlink {parent}: {name}")

            # Do not let extraction traverse a pre-existing symlink in /opt,
            # /var, or any configured destination hierarchy.
            parent_path = Path(filesystem_root)
            for part in parts[:-1]:
                parent_path = parent_path / part
                if parent_path.is_symlink():
                    raise ArchiveValidationError(f"Destination parent is a symlink: {parent_path}")

            destination = Path(filesystem_root).joinpath(*parts)
            if not member.issym() and destination.is_symlink():
                raise ArchiveValidationError(f"Destination is an existing symlink: {destination}")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("Usage: backup_archive.py ARCHIVE ALLOWED_ROOT [ALLOWED_ROOT ...]", file=sys.stderr)
        return 2
    try:
        validate_archive(argv[1], argv[2:])
    except ArchiveValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print("Archive validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
