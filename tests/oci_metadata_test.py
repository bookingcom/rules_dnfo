"""Unit tests verifying OCI metadata: ports, volumes, paths, env_file."""

import json
import os
import stat
import tarfile
import unittest


class TestOciMetadata(unittest.TestCase):
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

    def test_image_config_metadata(self):
        config_path = self._resolve_path("tests/test_oci_metadata_dnfo_config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        cfg = data.get("config", {})

        # ExposedPorts
        exposed_ports = cfg.get("ExposedPorts", {})
        self.assertIn("80/tcp", exposed_ports)
        self.assertIn("8080/tcp", exposed_ports)

        # Volumes
        volumes = cfg.get("Volumes", {})
        self.assertIn("/var/log", volumes)
        self.assertIn("/var/lib/data", volumes)

        # Env from env_file
        env_list = cfg.get("Env", [])
        self.assertIn("TEST_ENV_VAR=hello_from_file", env_list)
        self.assertIn("ANOTHER_VAR=value123", env_list)

    def test_paths_in_base_and_files_layers(self):
        # 1. Base layer contains extra directory /var/log/app
        base_layer_path = self._resolve_path("tests/test_oci_metadata_dnfo_base_layer.tgz")
        with tarfile.open(base_layer_path, "r:gz") as tar:
            dir_member = tar.getmember("var/log/app")
            self.assertIsNotNone(dir_member)
            self.assertTrue(dir_member.isdir())
            self.assertEqual(stat.S_IMODE(dir_member.mode), 0o755)
            self.assertEqual(dir_member.uid, 1000)
            self.assertEqual(dir_member.gid, 1000)

        # 2. Files layer contains empty file /var/run/app.pid and symlink /etc/ssl/cert.pem
        files_layer_path = self._resolve_path("tests/test_oci_metadata_dnfo_files_layer.tgz")
        with tarfile.open(files_layer_path, "r:gz") as tar:
            file_member = tar.getmember("var/run/app.pid")
            self.assertIsNotNone(file_member)
            self.assertTrue(file_member.isreg())
            self.assertEqual(stat.S_IMODE(file_member.mode), 0o644)
            self.assertEqual(file_member.uid, 0)
            self.assertEqual(file_member.gid, 0)
            self.assertEqual(file_member.size, 0)

            symlink_member = tar.getmember("etc/ssl/cert.pem")
            self.assertIsNotNone(symlink_member)
            self.assertTrue(symlink_member.issym())
            self.assertEqual(symlink_member.linkname, "/etc/pki/tls-ca-bundle.pem")

    def test_child_paths_layer(self):
        # Child image with base inherits base and generates dedicated paths layer
        paths_layer_path = self._resolve_path("tests/test_oci_child_paths_dnfo_paths_layer.tgz")
        with tarfile.open(paths_layer_path, "r:gz") as tar:
            dir_member = tar.getmember("opt/custom")
            self.assertIsNotNone(dir_member)
            self.assertTrue(dir_member.isdir())
            self.assertEqual(stat.S_IMODE(dir_member.mode), 0o700)


if __name__ == "__main__":
    unittest.main()
