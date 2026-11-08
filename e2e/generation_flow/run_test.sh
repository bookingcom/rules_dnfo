#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== Starting rules_dnfo 3-Phase E2E Flow Test ==="
echo "Repo root: ${REPO_ROOT}"

WORK_DIR="$(mktemp -d -t dnfo-e2e-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

cd "${WORK_DIR}"
echo "Test workspace created at: ${WORK_DIR}"

# 1. Setup workspace files
touch .bazelrc

# Reuse repository cache if available to prevent network flakiness
if [[ -d "${HOME}/.cache/bazel/repository-cache" ]]; then
  echo "common --repository_cache=${HOME}/.cache/bazel/repository-cache" >> .bazelrc
fi

# Copy BuildBuddy / remote cache credentials if present
if [[ -f "${REPO_ROOT}/.bazelrc.user" ]]; then
  cp -f "${REPO_ROOT}/.bazelrc.user" .bazelrc.user
  echo "try-import %workspace%/.bazelrc.user" >> .bazelrc
fi

cat > MODULE.bazel <<EOF
module(name = "e2e_flow_test")

bazel_dep(name = "rules_dnfo", version = "0.0.1")
local_path_override(
    module_name = "rules_dnfo",
    path = "${REPO_ROOT}",
)

bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.5")
archive_override(
    module_name = "dnf5-prebuilt",
    integrity = "sha256-Plm67w2RlJ/trfQaAczblLpMa6zFjcMO3xDW5cHpp4Q=",
    strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.5",
    urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.5/dnf5-prebuilt-v5.4.6.0.bcr.5.tar.gz"],
)

bazel_dep(name = "tar.bzl", version = "0.10.9")

bsd_tar_toolchains = use_extension("@tar.bzl//tar:extensions.bzl", "toolchains")
use_repo(bsd_tar_toolchains, "bsd_tar_toolchains")
register_toolchains("@bsd_tar_toolchains//:all")
EOF

cat > BUILD.bazel <<EOF
alias(
    name = "gazelle-dnfo",
    actual = "@rules_dnfo//dnfo:gazelle",
)

alias(
    name = "update",
    actual = "@rules_dnfo//dnfo:update",
)
EOF

mkdir -p testimage
# Note: ONLY dnfo.yaml exists in testimage/ (no BUILD.bazel, no dnfo.lock.json)
cat > testimage/dnfo.yaml <<EOF
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - bash
    - curl

entrypoint:
  command: /bin/bash

cmd: "-l"

work-dir: /home
EOF

echo ""
echo "--- Phase 1: Call gazelle-dnfo to generate skeleton BUILD.bazel ---"
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

if [[ ! -f testimage/BUILD.bazel ]]; then
  echo "ERROR: Phase 1 failed: testimage/BUILD.bazel was not generated!" >&2
  exit 1
fi

echo "Generated testimage/BUILD.bazel:"
cat testimage/BUILD.bazel

if ! grep -q 'lock_only = True' testimage/BUILD.bazel; then
  echo "ERROR: Phase 1 failed: expected 'lock_only = True' in testimage/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 1 verified: lock_only = True skeleton generated."

echo ""
echo "--- Phase 2: Call bazel to generate the lockfile ---"
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //testimage:testimage.lock

if [[ ! -f testimage/dnfo.lock.json ]]; then
  echo "ERROR: Phase 2 failed: testimage/dnfo.lock.json was not generated!" >&2
  exit 1
fi

if ! grep -q '"install_order"' testimage/dnfo.lock.json; then
  echo "ERROR: Phase 2 failed: invalid lockfile without install_order" >&2
  exit 1
fi
echo "Phase 2 verified: valid dnf5 lockfile generated at testimage/dnfo.lock.json."

echo ""
echo "--- Phase 3: Update MODULE.bazel using re-exposed rules_dnfo extension and flip flag with gazelle ---"
cat >> MODULE.bazel <<EOF

dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")
dnfo.lock(
    name = "testimage_packages",
    lockfile = "//testimage:dnfo.lock.json",
)
use_repo(dnfo, "testimage_packages")
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Updated testimage/BUILD.bazel:"
cat testimage/BUILD.bazel

if ! grep -q 'lock_only = False' testimage/BUILD.bazel; then
  echo "ERROR: Phase 3 failed: expected 'lock_only = False' in testimage/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 3 verified: flag flipped to lock_only = False and image targets fully enabled."

echo ""
echo "--- Phase 3b: Validate calling gazelle a 3rd time changes nothing (idempotent) ---"
BEFORE_HASH=$(sha256sum testimage/BUILD.bazel | cut -d' ' -f1)
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo
AFTER_HASH=$(sha256sum testimage/BUILD.bazel | cut -d' ' -f1)

if [[ "${BEFORE_HASH}" != "${AFTER_HASH}" ]]; then
  echo "ERROR: Phase 3b failed: 3rd gazelle run unexpectedly modified testimage/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 3b verified: 3rd gazelle run is idempotent (0 changes)."

echo ""
echo "--- Phase 4: Build container image targets ---"
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //testimage:all

echo ""
echo "--- Phase 4b: Verify skeleton omission when filesystem RPM or include_skeleton=False is set ---"
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel query --invocation_id="${INVOCATION_ID}" "//testimage:testimage_skeleton" >/dev/null 2>&1
echo "Verified: testimage_skeleton correctly created for standard scratch image."

mkdir -p testskel
cat > testskel/BUILD.bazel <<EOF
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")

dnfo_image(
    name = "skel_false",
    config = "dnfo.yaml",
    contents = "//testimage:testimage_rpms_layer",
    include_skeleton = False,
    lock_only = False,
    packages = ["bash"],
)

dnfo_image(
    name = "skel_fs",
    config = "dnfo.yaml",
    contents = "//testimage:testimage_rpms_layer",
    lock_only = False,
    packages = [
        "filesystem",
        "bash",
    ],
)
EOF
touch testskel/dnfo.yaml

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && ! bazel query --invocation_id="${INVOCATION_ID}" "//testskel:skel_false_skeleton" >/dev/null 2>&1
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && ! bazel query --invocation_id="${INVOCATION_ID}" "//testskel:skel_fs_skeleton" >/dev/null 2>&1
rm -rf testskel
echo "Phase 4b verified: skeleton target correctly omitted when include_skeleton=False or filesystem package is present."

echo ""
echo "--- Phase 5: Add a new package to dnfo.yaml and verify lock drift & automated update ---"
cat > testimage/dnfo.yaml <<EOF
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - bash
    - curl
    - which

entrypoint:
  command: /bin/bash

cmd: "-l"

work-dir: /home
EOF

# Update BUILD.bazel with gazelle to include 'which' in packages
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo
if ! grep -q 'which' testimage/BUILD.bazel; then
  echo "ERROR: Phase 5 failed: expected 'which' package in testimage/BUILD.bazel" >&2
  exit 1
fi

# Verify that lock_test detects drift and fails before lock is updated
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && ! bazel test --invocation_id="${INVOCATION_ID}" //testimage:testimage.lock_test >/dev/null 2>&1
echo "Phase 5 verified: lock drift test correctly detected mismatch and failed."

# Run automated updater tool to refresh lockfile
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:update

# Verify lockfile now contains 'which' and lock_test passes
if ! grep -q 'which' testimage/dnfo.lock.json; then
  echo "ERROR: Phase 5 failed: expected 'which' package in testimage/dnfo.lock.json after update" >&2
  exit 1
fi

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel test --invocation_id="${INVOCATION_ID}" //testimage:testimage.lock_test
echo "Phase 5 verified: automated updater updated lockfile, lock_test now passes."

echo ""
echo "--- Phase 6: Build container image with new package ---"
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //testimage:all

echo "=== rules_dnfo 3-Phase E2E Flow Test PASSED successfully! ==="
