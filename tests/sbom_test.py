"""Tests for SBOM and SPDX generation in rules_dnfo."""

import json
import os
import sys
import unittest


class SbomTest(unittest.TestCase):

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

    def test_minimal_multiarch_spdx(self):
        path = self._resolve_path("examples/minimal/minimal_spdx.json")
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)

        self.assertIn("spdxVersion", doc)
        self.assertTrue(doc["spdxVersion"].startswith("SPDX-"))
        self.assertEqual(doc.get("SPDXID"), "SPDXRef-DOCUMENT")

        packages = doc.get("packages", [])
        self.assertGreaterEqual(len(packages), 50)

        purls = []
        for pkg in packages:
            for ref in pkg.get("externalRefs", []):
                if ref.get("referenceType") == "purl":
                    purls.append(ref.get("referenceLocator"))

        # Verify essential RPMs and both architectures exist
        x86_bash = [p for p in purls if p.startswith("pkg:rpm/oracle/bash@") and "arch=x86_64" in p]
        arm_bash = [p for p in purls if p.startswith("pkg:rpm/oracle/bash@") and "arch=aarch64" in p]
        self.assertTrue(len(x86_bash) >= 1, "Missing x86_64 bash in multi-arch SPDX")
        self.assertTrue(len(arm_bash) >= 1, "Missing aarch64 bash in multi-arch SPDX")

    def test_minimal_multiarch_cyclonedx(self):
        path = self._resolve_path("examples/minimal/minimal_cyclonedx.json")
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)

        self.assertEqual(doc.get("bomFormat"), "CycloneDX")
        self.assertEqual(doc.get("specVersion"), "1.6")

        components = doc.get("components", [])
        self.assertGreaterEqual(len(components), 50)

        purls = [c.get("purl") for c in components if c.get("purl")]
        x86_coreutils = [p for p in purls if p.startswith("pkg:rpm/oracle/coreutils@") and "arch=x86_64" in p]
        arm_coreutils = [p for p in purls if p.startswith("pkg:rpm/oracle/coreutils@") and "arch=aarch64" in p]
        self.assertTrue(len(x86_coreutils) >= 1, "Missing x86_64 coreutils in multi-arch CycloneDX")
        self.assertTrue(len(arm_coreutils) >= 1, "Missing aarch64 coreutils in multi-arch CycloneDX")

    def test_minimal_per_arch_spdx(self):
        x86_path = self._resolve_path("examples/minimal/minimal_x86_64_spdx.json")
        with open(x86_path, "r", encoding="utf-8") as f:
            x86_doc = json.load(f)

        x86_purls = []
        for pkg in x86_doc.get("packages", []):
            for ref in pkg.get("externalRefs", []):
                if ref.get("referenceType") == "purl":
                    x86_purls.append(ref.get("referenceLocator"))

        self.assertTrue(any(p.startswith("pkg:rpm/oracle/bash@") for p in x86_purls))
        self.assertFalse(any("arch=aarch64" in p for p in x86_purls), "x86_64 SPDX should not contain aarch64 packages")

        arm_path = self._resolve_path("examples/minimal/minimal_aarch64_spdx.json")
        with open(arm_path, "r", encoding="utf-8") as f:
            arm_doc = json.load(f)

        arm_purls = []
        for pkg in arm_doc.get("packages", []):
            for ref in pkg.get("externalRefs", []):
                if ref.get("referenceType") == "purl":
                    arm_purls.append(ref.get("referenceLocator"))

        self.assertTrue(any(p.startswith("pkg:rpm/oracle/bash@") for p in arm_purls))
        self.assertFalse(any("arch=x86_64" in p for p in arm_purls), "aarch64 SPDX should not contain x86_64 packages")

    def test_certificates_spdx(self):
        path = self._resolve_path("examples/certificates/certificates_spdx.json")
        with open(path, "r", encoding="utf-8") as f:
            doc = json.load(f)

        packages = doc.get("packages", [])
        purls = []
        for pkg in packages:
            for ref in pkg.get("externalRefs", []):
                if ref.get("referenceType") == "purl":
                    purls.append(ref.get("referenceLocator"))

        ca_certs = [p for p in purls if "ca-certificates" in p]
        self.assertTrue(len(ca_certs) >= 1, "Missing ca-certificates in certificates SPDX")


if __name__ == "__main__":
    unittest.main()
