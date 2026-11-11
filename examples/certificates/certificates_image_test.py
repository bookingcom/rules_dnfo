"""E2E test verifying certificate store generation in dnfo_image."""

import os
import stat
import tarfile
import unittest


def find_runfile(path: str) -> str:
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "_main")
    if test_srcdir:
        candidates = [
            os.path.join(test_srcdir, test_workspace, path),
            os.path.join(test_srcdir, path),
            os.path.join(test_srcdir, "rules_dnfo", path),
        ]
        for c in candidates:
            if os.path.exists(c):
                return c
    if os.path.exists(path):
        return path
    for root, _, files in os.walk("."):
        if os.path.basename(path) in files:
            return os.path.join(root, os.path.basename(path))
    raise FileNotFoundError(f"Cannot find runfile for {path}")


class TestCertificatesImage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_layer_path = find_runfile("examples/certificates/certificates_base_layer.tgz")
        cls.files_layer_path = find_runfile("examples/certificates/certificates_files_layer.tgz")

    def test_trust_store_bundle(self):
        with tarfile.open(self.base_layer_path, "r:gz") as tar:
            bundle_member = tar.getmember("etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
            self.assertIsNotNone(bundle_member)
            # File mode should be 0444
            self.assertEqual(stat.S_IMODE(bundle_member.mode), 0o444)

            content = tar.extractfile(bundle_member).read().decode()
            cert_count = content.count("-----BEGIN CERTIFICATE-----")
            # 118 server-auth certs from ca-certificates + corp-root.crt + inline-root.crt = 120
            self.assertEqual(cert_count, 120)

    def test_trust_store_directory_hash(self):
        with tarfile.open(self.base_layer_path, "r:gz") as tar:
            members = tar.getmembers()
            symlinks = [
                m
                for m in members
                if m.issym()
                and m.name.startswith("etc/pki/ca-trust/extracted/pem/directory-hash/")
                and m.name.endswith(".0")
            ]
            self.assertGreaterEqual(len(symlinks), 120)
            for s in symlinks:
                self.assertTrue(s.linkname.endswith(".pem"))

    def test_java_cacerts_keystore(self):
        with tarfile.open(self.base_layer_path, "r:gz") as tar:
            cacerts_member = tar.getmember("etc/pki/ca-trust/extracted/java/cacerts")
            self.assertIsNotNone(cacerts_member)
            self.assertGreater(cacerts_member.size, 0)
            self.assertEqual(stat.S_IMODE(cacerts_member.mode), 0o444)

    def test_anchors_in_files_layer(self):
        with tarfile.open(self.files_layer_path, "r:gz") as tar:
            corp_anchor = tar.getmember("etc/pki/ca-trust/source/anchors/corp-root.crt")
            inline_anchor = tar.getmember("etc/pki/ca-trust/source/anchors/inline-root.crt")
            self.assertIsNotNone(corp_anchor)
            self.assertIsNotNone(inline_anchor)
            self.assertEqual(stat.S_IMODE(corp_anchor.mode), 0o644)
            self.assertEqual(stat.S_IMODE(inline_anchor.mode), 0o644)


if __name__ == "__main__":
    unittest.main()
