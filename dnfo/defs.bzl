"""Public API of rules_dnfo."""

load("//dnfo:toolchain.bzl", _DnfoInfo = "DnfoInfo", _current_dnfo_toolchain = "current_dnfo_toolchain", _dnfo_toolchain = "dnfo_toolchain")
load("//dnfo/private:dnfo_image.bzl", _dnfo_image = "dnfo_image")
load("//dnfo/private:dnfo_lock.bzl", _dnfo_lock = "dnfo_lock")
load("//dnfo/private:translate_lock.bzl", _translate_lock = "translate_lock")

DnfoInfo = _DnfoInfo
current_dnfo_toolchain = _current_dnfo_toolchain
dnfo_toolchain = _dnfo_toolchain
dnfo_image = _dnfo_image
dnfo_lock = _dnfo_lock
translate_lock = _translate_lock
