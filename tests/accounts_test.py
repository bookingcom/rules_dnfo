"""Unit tests verifying standard system accounts, groups, and secondary group membership."""

import os
import stat
import tarfile
import unittest


class TestAccountsAndGroups(unittest.TestCase):
    def _resolve_path(self, relpath):
        runfiles_dir = os.environ.get("RUNFILES_DIR")
        if runfiles_dir:
            candidate = os.path.join(runfiles_dir, "_main", relpath)
            if os.path.exists(candidate):
                return candidate
            candidate = os.path.join(runfiles_dir, "rules_dnfo", relpath)
            if os.path.exists(candidate):
                return candidate
        test_srcdir = os.environ.get("TEST_SRCDIR")
        if test_srcdir:
            candidate = os.path.join(test_srcdir, "_main", relpath)
            if os.path.exists(candidate):
                return candidate
            candidate = os.path.join(test_srcdir, "rules_dnfo", relpath)
            if os.path.exists(candidate):
                return candidate
        if os.path.exists(relpath):
            return relpath
        raise FileNotFoundError(f"Could not find runfile: {relpath}")

    def test_system_accounts_and_secondary_groups(self):
        layer_path = self._resolve_path("tests/test_accounts_image_base_layer.tgz")
        with tarfile.open(layer_path, "r:gz") as tar:
            # Check /etc/passwd
            passwd_member = tar.getmember("etc/passwd")
            self.assertIsNotNone(passwd_member)
            self.assertEqual(stat.S_IMODE(passwd_member.mode), 0o644)
            passwd_lines = tar.extractfile(passwd_member).read().decode().strip().split("\n")
            passwd_by_user = {}
            for line in passwd_lines:
                parts = line.split(":")
                passwd_by_user[parts[0]] = {
                    "uid": int(parts[2]),
                    "gid": int(parts[3]),
                    "home": parts[5],
                    "shell": parts[6],
                }

            # Verify standard system accounts
            self.assertIn("root", passwd_by_user)
            self.assertEqual(passwd_by_user["root"]["uid"], 0)
            self.assertEqual(passwd_by_user["root"]["gid"], 0)

            self.assertIn("nobody", passwd_by_user)
            self.assertEqual(passwd_by_user["nobody"]["uid"], 65534)
            self.assertEqual(passwd_by_user["nobody"]["gid"], 65534)

            self.assertIn("bin", passwd_by_user)
            self.assertEqual(passwd_by_user["bin"]["uid"], 1)

            self.assertIn("daemon", passwd_by_user)
            self.assertEqual(passwd_by_user["daemon"]["uid"], 2)

            self.assertIn("adm", passwd_by_user)
            self.assertEqual(passwd_by_user["adm"]["uid"], 3)

            # Verify user-defined account
            self.assertIn("customuser", passwd_by_user)
            self.assertEqual(passwd_by_user["customuser"]["uid"], 2000)
            self.assertEqual(passwd_by_user["customuser"]["gid"], 2000)

            # Check /etc/group
            group_member = tar.getmember("etc/group")
            self.assertIsNotNone(group_member)
            self.assertEqual(stat.S_IMODE(group_member.mode), 0o644)
            group_lines = tar.extractfile(group_member).read().decode().strip().split("\n")
            group_by_name = {}
            for line in group_lines:
                parts = line.split(":")
                group_by_name[parts[0]] = {
                    "gid": int(parts[2]),
                    "members": parts[3].split(",") if parts[3] else [],
                }

            # Verify standard system groups
            for expected_group in ["root", "tty", "wheel", "users", "nobody", "bin", "daemon"]:
                self.assertIn(expected_group, group_by_name)

            self.assertEqual(group_by_name["tty"]["gid"], 5)
            self.assertEqual(group_by_name["wheel"]["gid"], 10)
            self.assertEqual(group_by_name["users"]["gid"], 100)
            self.assertEqual(group_by_name["nobody"]["gid"], 65534)

            # Verify secondary group membership in wheel
            self.assertIn("customuser", group_by_name["wheel"]["members"])

            # Verify custom group
            self.assertIn("customgroup", group_by_name)
            self.assertEqual(group_by_name["customgroup"]["gid"], 2000)


if __name__ == "__main__":
    unittest.main()
