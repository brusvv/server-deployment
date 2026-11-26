#!/usr/bin/env python3
"""Regression tests for privileged backup archive validation."""
import io
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from backup_archive import ArchiveValidationError, validate_archive


class BackupArchiveTests(unittest.TestCase):
    def make_archive(self, root: Path, entries):
        archive = root / "test.tar.gz"
        with tarfile.open(archive, "w:gz") as tf:
            for name, kind, target in entries:
                info = tarfile.TarInfo(name)
                if kind == "file":
                    payload = b"test"
                    info.size = len(payload)
                    tf.addfile(info, io.BytesIO(payload))
                elif kind == "dir":
                    info.type = tarfile.DIRTYPE
                    tf.addfile(info)
                elif kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = target
                    tf.addfile(info)
                elif kind == "hardlink":
                    info.type = tarfile.LNKTYPE
                    info.linkname = target
                    tf.addfile(info)
                elif kind == "suid_file":
                    payload = b"test"
                    info.mode = 0o4755
                    info.size = len(payload)
                    tf.addfile(info, io.BytesIO(payload))
        return str(archive)

    def test_accepts_file_and_directory_inside_allowed_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = self.make_archive(root, [
                ("opt/remnawave", "dir", ""),
                ("opt/remnawave/config.yml", "file", ""),
            ])
            validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_parent_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = self.make_archive(Path(tmp), [("opt/remnawave/../../etc/passwd", "file", "")])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_paths_outside_allowed_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = self.make_archive(Path(tmp), [("etc/passwd", "file", "")])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = self.make_archive(Path(tmp), [
                ("opt/remnawave/link", "symlink", "../../../../etc"),
            ])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_writes_through_archive_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = self.make_archive(Path(tmp), [
                ("opt/remnawave/link", "symlink", "."),
                ("opt/remnawave/link/payload", "file", ""),
            ])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_hardlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = self.make_archive(Path(tmp), [
                ("opt/remnawave/file", "file", ""),
                ("opt/remnawave/alias", "hardlink", "opt/remnawave/file"),
            ])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_setuid_or_setgid_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = self.make_archive(Path(tmp), [
                ("opt/remnawave/unsafe-binary", "suid_file", ""),
            ])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"])

    def test_rejects_existing_destination_symlink_for_regular_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            filesystem_root = root / "filesystem"
            destination_dir = filesystem_root / "opt" / "remnawave"
            destination_dir.mkdir(parents=True)
            outside = root / "outside"
            outside.write_text("must not be followed", encoding="utf-8")
            (destination_dir / "config.yml").symlink_to(outside)
            archive = self.make_archive(root, [
                ("opt/remnawave/config.yml", "file", ""),
            ])
            with self.assertRaises(ArchiveValidationError):
                validate_archive(archive, ["/opt/remnawave"], str(filesystem_root))


if __name__ == "__main__":
    unittest.main(verbosity=2)
