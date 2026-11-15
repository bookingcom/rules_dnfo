"""Unit tests verifying automatic CA trust store synthesis in dnfo_image."""

import os
import stat
import tarfile
import unittest


class TestCACertificatesSynthesis(unittest.TestCase):
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

    def test_auto_synthesis_ca_certificates(self):
        base_layer = self._resolve_path("tests/test_auto_certificates_image_base_layer.tgz")
        with tarfile.open(base_layer, "r:gz") as tar:
            # Check bundle
            bundle_member = tar.getmember("etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
            self.assertIsNotNone(bundle_member)
            self.assertEqual(stat.S_IMODE(bundle_member.mode), 0o444)
            bundle_content = tar.extractfile(bundle_member).read().decode()
            self.assertGreater(bundle_content.count("-----BEGIN CERTIFICATE-----"), 100)

            # Check directory hashes
            hash_members = [
                m
                for m in tar.getmembers()
                if m.issym()
                and m.name.startswith("etc/pki/ca-trust/extracted/pem/directory-hash/")
                and m.name.endswith(".0")
            ]
            self.assertGreaterEqual(len(hash_members), 100)

            # Check java keystore
            cacerts_member = tar.getmember("etc/pki/ca-trust/extracted/java/cacerts")
            self.assertIsNotNone(cacerts_member)
            self.assertGreater(cacerts_member.size, 0)
            self.assertEqual(stat.S_IMODE(cacerts_member.mode), 0o444)

        files_layer = self._resolve_path("tests/test_auto_certificates_image_files_layer.tgz")
        with tarfile.open(files_layer, "r:gz") as tar:
            openssl_member = tar.getmember("etc/pki/ca-trust/extracted/openssl/ca-bundle.trust.crt")
            self.assertIsNotNone(openssl_member)
            self.assertTrue(openssl_member.issym())
            self.assertEqual(openssl_member.linkname, "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")

    def test_auto_synthesis_p11_kit_trust(self):
        base_layer = self._resolve_path("tests/test_auto_p11_kit_trust_image_base_layer.tgz")
        with tarfile.open(base_layer, "r:gz") as tar:
            bundle_member = tar.getmember("etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
            self.assertIsNotNone(bundle_member)
            self.assertEqual(stat.S_IMODE(bundle_member.mode), 0o444)
            bundle_content = tar.extractfile(bundle_member).read().decode()
            self.assertGreater(bundle_content.count("-----BEGIN CERTIFICATE-----"), 100)

        files_layer = self._resolve_path("tests/test_auto_p11_kit_trust_image_files_layer.tgz")
        with tarfile.open(files_layer, "r:gz") as tar:
            openssl_member = tar.getmember("etc/pki/ca-trust/extracted/openssl/ca-bundle.trust.crt")
            self.assertIsNotNone(openssl_member)
            self.assertTrue(openssl_member.issym())
            self.assertEqual(openssl_member.linkname, "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")

    def test_disabled_certificates(self):
        base_layer = self._resolve_path("tests/test_disabled_certificates_image_base_layer.tgz")
        with tarfile.open(base_layer, "r:gz") as tar:
            names = tar.getnames()
            self.assertNotIn("etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", names)
            self.assertNotIn("etc/pki/ca-trust/extracted/java/cacerts", names)


if __name__ == "__main__":
    unittest.main()
