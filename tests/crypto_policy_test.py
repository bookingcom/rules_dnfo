"""Unit tests verifying crypto-policies synthesis in dnfo_image."""

import os
import stat
import tarfile
import unittest

_EXPECTED_BACKENDS = [
    "bind",
    "gnutls",
    "java",
    "krb5",
    "libreswan",
    "libssh",
    "nss",
    "openssh",
    "opensshserver",
    "openssl_fips",
    "opensslcnf",
    "rpm-sequoia",
    "sequoia",
]


class TestCryptoPolicy(unittest.TestCase):
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

    def test_default_crypto_policy(self):
        layer_path = self._resolve_path("tests/test_crypto_policy_image_files_layer.tgz")
        with tarfile.open(layer_path, "r:gz") as tar:
            # Check config
            cfg = tar.getmember("etc/crypto-policies/config")
            self.assertIsNotNone(cfg)
            self.assertEqual(stat.S_IMODE(cfg.mode), 0o644)
            cfg_content = tar.extractfile(cfg).read().decode()
            self.assertEqual(cfg_content.strip(), "DEFAULT")

            # Check state/current
            current = tar.getmember("etc/crypto-policies/state/current")
            self.assertIsNotNone(current)
            self.assertEqual(stat.S_IMODE(current.mode), 0o644)
            current_content = tar.extractfile(current).read().decode()
            self.assertEqual(current_content.strip(), "DEFAULT")

            # Check all 13 backends
            for b in _EXPECTED_BACKENDS:
                dest = f"etc/crypto-policies/back-ends/{b}.config"
                m = tar.getmember(dest)
                self.assertIsNotNone(m, f"Missing backend symlink {dest}")
                self.assertTrue(m.issym(), f"Expected symlink for {dest}")
                expected_target = f"/usr/share/crypto-policies/DEFAULT/{b}.txt"
                self.assertEqual(m.linkname, expected_target)

    def test_fips_crypto_policy(self):
        layer_path = self._resolve_path("tests/test_crypto_policy_fips_image_files_layer.tgz")
        with tarfile.open(layer_path, "r:gz") as tar:
            # Check config
            cfg = tar.getmember("etc/crypto-policies/config")
            self.assertIsNotNone(cfg)
            cfg_content = tar.extractfile(cfg).read().decode()
            self.assertEqual(cfg_content.strip(), "FIPS")

            # Check opensslcnf symlink
            m = tar.getmember("etc/crypto-policies/back-ends/opensslcnf.config")
            self.assertIsNotNone(m)
            self.assertTrue(m.issym())
            self.assertEqual(m.linkname, "/usr/share/crypto-policies/FIPS/opensslcnf.txt")


if __name__ == "__main__":
    unittest.main()
