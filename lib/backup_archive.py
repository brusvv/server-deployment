#!/usr/bin/env python3
"""Validate server-deployment backup archives before privileged extraction."""
from __future__ import annotations

import argparse
import pathlib
import sys
import tarfile


def _relative_root(value: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(value)
    if not path.is_absolute():
        raise ValueError(f"Allowed restore root must be absolute: {value}")
    normalized = pathlib.PurePosixPath(*path.parts[1:])
    if not normalized.parts:
        raise ValueError("Restoring to filesystem root is not an allowed backup scope")
    return normalized


def validate_archive(archive: pathlib.Path, roots: list[str]) -> None:
    allowed = [_relative_root(root) for root in roots]
    seen: set[pathlib.PurePosixPath] = set()
    regular_files = 0

    with tarfile.open(archive, mode="r:gz") as bundle:
        members = bundle.getmembers()
        if not members:
            raise ValueError("Backup archive is empty")
        for member in members:
            raw = pathlib.PurePosixPath(member.name)
            if raw.is_absolute() or not raw.parts or ".." in raw.parts:
                raise ValueError(f"Unsafe archive path: {member.name!r}")

            name = pathlib.PurePosixPath(*[part for part in raw.parts if part not in ("", ".")])
            if not name.parts or name in seen:
                raise ValueError(f"Empty or duplicate archive path: {member.name!r}")
            seen.add(name)

            if not any(name == root or root in name.parents for root in allowed):
                raise ValueError(f"Archive path is outside configured backup roots: {member.name!r}")

            # Links and special files can redirect privileged extraction or create
            # unexpected filesystem objects. Current backups only need regular files
            # and directories.
            if not (member.isdir() or member.isfile()):
                raise ValueError(f"Unsupported archive member type: {member.name!r}")
            if member.isfile():
                regular_files += 1

    if regular_files == 0:
        raise ValueError("Backup archive contains no regular files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("allowed_roots", nargs="+")
    args = parser.parse_args()
    try:
        if args.archive.is_symlink() or not args.archive.is_file():
            raise ValueError("Backup archive must be a regular, non-symlink file")
        validate_archive(args.archive, args.allowed_roots)
    except (OSError, tarfile.TarError, ValueError) as exc:
        print(f"Invalid backup archive: {exc}", file=sys.stderr)
        return 1
    print("Backup archive validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
