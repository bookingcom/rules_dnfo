"""Public API of rules_dnfo."""

load("@supply_chain_tools//sbom:cyclonedx.bzl", _cyclonedx = "cyclonedx")
load("@supply_chain_tools//sbom:sbom.bzl", _sbom = "sbom")
load("@supply_chain_tools//sbom:spdx.bzl", _spdx = "spdx")
load("//dnfo/private:dnfo_image.bzl", _dnfo_image = "dnfo_image")

cyclonedx = _cyclonedx
dnfo_image = _dnfo_image
sbom = _sbom
spdx = _spdx
