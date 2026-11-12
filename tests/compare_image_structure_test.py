"""Unit and integration tests for compare_image_structure."""

import io
import os
import tarfile
import tempfile
import unittest

from tests.compare_image_structure import (
    _resolve_dir_symlinks,
    compare_structures,
    compute_effective_filesystem,
)


def create_tar_with_members(tar_path: str, members: list):
    """Helper to synthesize a tarball with given members.

    Each item in members is a dict:
    - name: str
    - type: 'dir', 'symlink', or 'file'
    - linkname: str (if symlink)
    - content: bytes (if file)
    """
    with tarfile.open(tar_path, "w") as t:
        for m in members:
            ti = tarfile.TarInfo(name=m["name"])
            m_type = m.get("type", "file")
            if m_type == "dir":
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                t.addfile(ti)
            elif m_type == "symlink":
                ti.type = tarfile.SYMTYPE
                ti.linkname = m["linkname"]
                ti.mode = 0o777
                t.addfile(ti)
            else:
                content = m.get("content", b"test")
                ti.type = tarfile.REGTYPE
                ti.size = len(content)
                ti.mode = 0o644
                t.addfile(ti, io.BytesIO(content))


class TestCompareImageStructure(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_resolve_dir_symlinks(self):
        symlinks = {
            "lib64": "usr/lib64",
            "bin": "usr/bin",
            "nested/link": "usr/target",
        }
        self.assertEqual(_resolve_dir_symlinks("lib64", symlinks), "usr/lib64")
        self.assertEqual(_resolve_dir_symlinks("lib64/sub", symlinks), "usr/lib64/sub")
        self.assertEqual(_resolve_dir_symlinks("bin", symlinks), "usr/bin")
        self.assertEqual(_resolve_dir_symlinks("etc", symlinks), "etc")
        self.assertEqual(_resolve_dir_symlinks("", symlinks), "")

    def test_usr_merge_symlink_dereferencing(self):
        """Simulates the issue #36 bug scenario where unflattened layer had lib64/libgcc_s.so.1

        and flattened layer has canonical usr/lib64/libgcc_s.so.1 with lib64 -> usr/lib64.
        """
        layer_unflat = os.path.join(self.temp_dir.name, "unflat.tar")
        create_tar_with_members(layer_unflat, [
            {"name": "usr", "type": "dir"},
            {"name": "usr/lib64", "type": "dir"},
            {"name": "lib64", "type": "symlink", "linkname": "usr/lib64"},
            {"name": "lib64/libgcc_s.so.1", "type": "symlink", "linkname": "libgcc_s-14.so.1"},
            {"name": "usr/lib64/libgcc_s-14.so.1", "type": "file"},
        ])

        layer_flat = os.path.join(self.temp_dir.name, "flat.tar")
        create_tar_with_members(layer_flat, [
            {"name": "usr", "type": "dir"},
            {"name": "usr/lib64", "type": "dir"},
            {"name": "lib64", "type": "symlink", "linkname": "usr/lib64"},
            {"name": "usr/lib64/libgcc_s.so.1", "type": "symlink", "linkname": "libgcc_s-14.so.1"},
            {"name": "usr/lib64/libgcc_s-14.so.1", "type": "file"},
        ])

        # Both compute to the exact same canonical path: usr/lib64/libgcc_s.so.1
        self.assertTrue(compare_structures("linux/amd64", [layer_flat], [layer_unflat]))

    def test_detects_missing_file_in_flattened(self):
        layer_unflat = os.path.join(self.temp_dir.name, "unflat_missing.tar")
        create_tar_with_members(layer_unflat, [
            {"name": "usr", "type": "dir"},
            {"name": "usr/lib64", "type": "dir"},
            {"name": "usr/lib64/libgcc_s.so.1", "type": "file"},
        ])

        layer_flat = os.path.join(self.temp_dir.name, "flat_missing.tar")
        create_tar_with_members(layer_flat, [
            {"name": "usr", "type": "dir"},
            {"name": "usr/lib64", "type": "dir"},
        ])

        # Must fail because libgcc_s.so.1 is missing from flattened
        self.assertFalse(compare_structures("linux/amd64", [layer_flat], [layer_unflat]))

    def test_whiteouts_handling(self):
        layer_0 = os.path.join(self.temp_dir.name, "layer0.tar")
        create_tar_with_members(layer_0, [
            {"name": "etc", "type": "dir"},
            {"name": "etc/old.conf", "type": "file"},
            {"name": "etc/keep.conf", "type": "file"},
        ])

        layer_1 = os.path.join(self.temp_dir.name, "layer1.tar")
        create_tar_with_members(layer_1, [
            {"name": "etc/.wh.old.conf", "type": "file"},
        ])

        fs = compute_effective_filesystem([layer_0, layer_1])
        self.assertIn("etc/keep.conf", fs)
        self.assertNotIn("etc/old.conf", fs)


if __name__ == "__main__":
    unittest.main()
