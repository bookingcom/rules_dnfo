"""Bzlmod module extensions for rules_dnfo."""

load("@dnf5-prebuilt//dnf5-prebuilt:extensions.bzl", _dnf5 = "dnf5")

# Re-expose the dnf5 extension so downstream consumers do not need an explicit dependency
# on @dnf5-prebuilt.
dnf5 = _dnf5
dnfo = _dnf5
