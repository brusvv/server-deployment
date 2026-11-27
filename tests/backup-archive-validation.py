#!/usr/bin/env python3
"""Regression tests for privileged backup archive validation."""
from __future__ import annotations

import pathlib
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "lib" / "backup_archive.py"
ALLOWED = ("/opt/remnawave", "/opt/mtproxyl", "/opt/server-deployment/config")


def make_archive(path: pathlib.Path, entries: list[tuple[str, bytes, str]]) -> None:
    with tarfile.open(path, "w:gz") as archive:
        for name, payload, kind in entries:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = payload.decode()
                archive.addfile(info)
            elif kind == "hardlink":
                info.type = tarfile.LNKTYPE
                info.linkname = payload.decode()
                archive.addfile(info)
            else:
                info.size = len(payload)
                import io
                archive.addfile(info, io.BytesIO(payload))


def check(path: pathlib.Path, expected: bool) -> None:
    result = subprocess.run(
        ["python3", str(VALIDATOR), str(path), *ALLOWED],
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode == 0) is expected, (
        f"{path.name}: expected valid={expected}, got {result.returncode}\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="backup-archive-test-") as tmp:
        folder = pathlib.Path(tmp)
        valid = folder / "valid.tar.gz"
        make_archive(valid, [
            ("opt/remnawave/docker-compose.yml", b"services: {}", "file"),
            ("opt/remnawave/", b"", "dir"),
            ("opt/server-deployment/config/ports.env", b"PORT=443", "file"),
        ])
        # Directory entries may appear after descendants in a tar archive; the
        # validator checks names and member types, not extraction order.
        check(valid, True)

        malicious = [
            ("../etc/cron.d/pwned", b"x", "file"),
            ("/etc/cron.d/pwned", b"x", "file"),
            ("etc/cron.d/pwned", b"x", "file"),
            ("opt/remnawave/link", b"../../etc", "symlink"),
            ("opt/remnawave/hardlink", b"opt/remnawave/docker-compose.yml", "hardlink"),
        ]
        for index, entry in enumerate(malicious):
            archive = folder / f"bad-{index}.tar.gz"
            make_archive(archive, [entry])
            check(archive, False)

        duplicate = folder / "duplicate.tar.gz"
        make_archive(duplicate, [
            ("opt/remnawave/file", b"first", "file"),
            ("opt/remnawave/file", b"second", "file"),
        ])
        check(duplicate, False)

        symlink = folder / "archive-link.tar.gz"
        symlink.symlink_to(valid)
        check(symlink, False)

    print("Backup archive validation tests passed.")


if __name__ == "__main__":
    main()
