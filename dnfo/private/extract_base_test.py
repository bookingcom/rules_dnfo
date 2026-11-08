"""Unit test for extract_base.py."""

import io
import os
import sqlite3
import tarfile
import tempfile
import unittest

from dnfo.private.extract_base import extract_from_layers

class ExtractBaseTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmpdir.cleanup()

    def _create_tar(self, files):
        path = os.path.join(self.tmpdir.name, f"layer_{len(os.listdir(self.tmpdir.name))}.tar")
        with tarfile.open(path, "w") as tar:
            for name, content in files.items():
                ti = tarfile.TarInfo(name=name)
                ti.size = len(content)
                tar.addfile(ti, io.BytesIO(content))
        return path

    def test_empty_layers(self):
        out_rpmdb = os.path.join(self.tmpdir.name, "rpmdb.sqlite")
        out_repos = os.path.join(self.tmpdir.name, "base.repo")

        extract_from_layers([], out_rpmdb, out_repos)

        self.assertTrue(os.path.isfile(out_rpmdb))
        conn = sqlite3.connect(out_rpmdb)
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        self.assertEqual(cursor.fetchone(), (1,))
        conn.close()

        self.assertTrue(os.path.isfile(out_repos))
        with open(out_repos, "r") as f:
            content = f.read()
            self.assertIn("No repository configurations found", content)

    def test_extract_rpmdb_and_repos(self):
        rpmdb_content = b"SQLite format 3\x00custom_rpmdb_bytes"
        repo1_content = b"[repo1]\nname=Repo 1\nbaseurl=https://example.com/1\n"
        repo2_content = b"[repo2]\nname=Repo 2\nbaseurl=https://example.com/2\n"

        layer1 = self._create_tar({
            "var/lib/rpm/rpmdb.sqlite": rpmdb_content,
            "etc/yum.repos.d/repo1.repo": repo1_content,
        })
        layer2 = self._create_tar({
            "etc/yum.repos.d/repo2.repo": repo2_content,
        })

        out_rpmdb = os.path.join(self.tmpdir.name, "out_rpmdb.sqlite")
        out_repos = os.path.join(self.tmpdir.name, "out_repos.repo")

        extract_from_layers([layer1, layer2], out_rpmdb, out_repos)

        with open(out_rpmdb, "rb") as f:
            self.assertEqual(f.read(), rpmdb_content)

        with open(out_repos, "rb") as f:
            content = f.read()
            self.assertIn(b"[repo1]", content)
            self.assertIn(b"[repo2]", content)

    def test_whiteouts(self):
        rpmdb_content = b"SQLite format 3\x00test"
        repo1_content = b"[repo1]\nname=Repo 1\n"
        repo2_content = b"[repo2]\nname=Repo 2\n"

        layer1 = self._create_tar({
            "usr/lib/sysimage/rpm/rpmdb.sqlite": rpmdb_content,
            "etc/yum.repos.d/repo1.repo": repo1_content,
            "etc/yum.repos.d/repo2.repo": repo2_content,
        })
        layer2 = self._create_tar({
            "etc/yum.repos.d/.wh.repo1.repo": b"",
        })

        out_rpmdb = os.path.join(self.tmpdir.name, "out_rpmdb.sqlite")
        out_repos = os.path.join(self.tmpdir.name, "out_repos.repo")

        extract_from_layers([layer1, layer2], out_rpmdb, out_repos)

        with open(out_rpmdb, "rb") as f:
            self.assertEqual(f.read(), rpmdb_content)

        with open(out_repos, "rb") as f:
            content = f.read()
            self.assertNotIn(b"[repo1]", content)
            self.assertIn(b"[repo2]", content)

if __name__ == "__main__":
    unittest.main()
