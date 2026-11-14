#!/usr/bin/env python3
"""Validation utility for SPDX and CycloneDX SBOMs produced by rules_dnfo."""

import argparse
import json
import sys


def validate_spdx(path, expected_pkgs=None, expected_arch=None):
    print(f"Validating SPDX SBOM: {path}")
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)

    assert "spdxVersion" in doc, f"Missing spdxVersion in {path}"
    assert doc["spdxVersion"].startswith("SPDX-"), f"Unexpected spdxVersion: {doc['spdxVersion']}"
    assert doc.get("SPDXID") == "SPDXRef-DOCUMENT", f"Unexpected SPDXID: {doc.get('SPDXID')}"

    packages = doc.get("packages", [])
    print(f"  SPDX: found {len(packages)} packages.")
    assert len(packages) > 0, f"Expected non-empty packages in {path}"

    purls = []
    for pkg in packages:
        for ref in pkg.get("externalRefs", []):
            if ref.get("referenceType") == "purl":
                purl = ref.get("referenceLocator", "")
                assert purl.startswith("pkg:rpm/"), f"Unexpected PURL scheme in {purl}"
                purls.append(purl)

    if expected_pkgs:
        for name in expected_pkgs:
            matches = [p for p in purls if p.startswith(f"pkg:rpm/oracle/{name}@")]
            assert len(matches) >= 1, f"Expected package {name} in {path}, but found none"

    if expected_arch:
        for p in purls:
            assert f"arch={expected_arch}" in p or "arch=noarch" in p, f"Unexpected architecture in {p}, expected {expected_arch} or noarch"

    print(f"  SPDX validation passed for {path}.")


def validate_cyclonedx(path, expected_components=None):
    print(f"Validating CycloneDX SBOM: {path}")
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)

    assert doc.get("bomFormat") == "CycloneDX", f"Unexpected bomFormat: {doc.get('bomFormat')}"
    components = doc.get("components", [])
    print(f"  CycloneDX: found {len(components)} components.")
    assert len(components) > 0, f"Expected non-empty components in {path}"

    purls = [c.get("purl") for c in components if c.get("purl")]
    for p in purls:
        assert p.startswith("pkg:rpm/"), f"Unexpected CycloneDX PURL scheme in {p}"

    if expected_components:
        for name in expected_components:
            matches = [p for p in purls if p.startswith(f"pkg:rpm/oracle/{name}@")]
            assert len(matches) >= 1, f"Expected component {name} in {path}, but found none"

    print(f"  CycloneDX validation passed for {path}.")


def main():
    parser = argparse.ArgumentParser(description="Validate SPDX and CycloneDX SBOMs")
    parser.add_argument("--spdx", nargs="*", default=[], help="SPDX SBOM files to validate")
    parser.add_argument("--cyclonedx", nargs="*", default=[], help="CycloneDX SBOM files to validate")
    parser.add_argument("--expected-pkgs", nargs="*", default=[], help="Expected package names")
    parser.add_argument("--expected-arch", default=None, help="Expected architecture")
    args = parser.parse_args()

    for p in args.spdx:
        validate_spdx(p, expected_pkgs=args.expected_pkgs, expected_arch=args.expected_arch)
    for p in args.cyclonedx:
        validate_cyclonedx(p, expected_components=args.expected_pkgs)


if __name__ == "__main__":
    main()
