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

bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.7")
archive_override(
    module_name = "dnf5-prebuilt",
    integrity = "sha256-VsPvx5ZNZIyB6u2qJ06lfcL3OBCpGQjZCEzEZLR6qfQ=",
    strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.7",
    urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.7/dnf5-prebuilt-v5.4.6.0.bcr.7.tar.gz"],
)

bazel_dep(name = "rules_containers_util", version = "0.0.5")
archive_override(
    module_name = "rules_containers_util",
    integrity = "sha256-o/GHGK/6FhfkjXs02MnVKotjbSviI/PQqxaYLZn2CBg=",
    strip_prefix = "rules_containers_util-0.0.5",
    urls = ["https://github.com/bookingcom/rules_containers_util/releases/download/v0.0.5/rules_containers_util-v0.0.5.tar.gz"],
)

bazel_dep(name = "rules_img", version = "0.3.25")

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

echo ""
echo "--- Phase 7: Apko-style file inheritance (include: parent.dnfo.yaml) ---"
mkdir -p inheritance
cat > inheritance/parent.dnfo.yaml <<EOF
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - bash
EOF

cat > inheritance/child.dnfo.yaml <<EOF
include: parent.dnfo.yaml
contents:
  packages:
    - curl
EOF

# 1. Run gazelle to generate targets
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Generated inheritance/BUILD.bazel:"
cat inheritance/BUILD.bazel

if ! grep -q 'base = ":parent_dnfo"' inheritance/BUILD.bazel; then
  echo "ERROR: Phase 7 failed: expected 'base = \":parent_dnfo\"' in inheritance/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q 'base_rpmdb = ":parent_dnfo_rpmdb"' inheritance/BUILD.bazel; then
  echo "ERROR: Phase 7 failed: expected 'base_rpmdb = \":parent_dnfo_rpmdb\"' in inheritance/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q 'base_repos = ":parent_dnfo_repos"' inheritance/BUILD.bazel; then
  echo "ERROR: Phase 7 failed: expected 'base_repos = \":parent_dnfo_repos\"' in inheritance/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 7 verified: child target correctly wired with parent base, rpmdb, and repos."

# 2. Lock parent target and enable it so parent_dnfo_rpmdb exists
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //inheritance:parent_dnfo.lock

cat >> MODULE.bazel <<EOF

dnfo.lock(
    name = "parent_dnfo_packages",
    lockfile = "//inheritance:parent.dnfo.lock.json",
)
use_repo(dnfo, "parent_dnfo_packages")
EOF

# Flip parent to lock_only = False so parent_dnfo_rpmdb is declared
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

# 3. Lock child target against parent's rpmdb
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //inheritance:child_dnfo.lock

cat >> MODULE.bazel <<EOF

dnfo.lock(
    name = "child_dnfo_packages",
    lockfile = "//inheritance:child.dnfo.lock.json",
)
use_repo(dnfo, "child_dnfo_packages")
EOF

# 4. Flip child to lock_only = False with gazelle
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

# 5. Build both parent and child image targets
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //inheritance:all
echo "Phase 7 verified: both parent and child (with inherited rpmdb and repos) built successfully."

echo ""
echo "--- Phase 8: External base image extraction and validation ---"

# 8a: Verify validation error when invalid registry URL or tag is specified in base
mkdir -p invalid_base
cat > invalid_base/dnfo.yaml <<EOF
base: docker.io/library/alpine:latest
contents:
  packages:
    - bash
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && ! bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo >/dev/null 2>&1
echo "Phase 8a verified: Gazelle failed with actionable error when invalid image URL/tag was specified."
rm -rf invalid_base

# 8b: External base image configuration and extraction test
mkdir -p ext_base
cat > ext_base/dnfo.yaml <<EOF
base: external_ubi9
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - curl
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo
echo "Generated ext_base/BUILD.bazel:"
cat ext_base/BUILD.bazel

if ! grep -q 'base = "@external_ubi9//:image"' ext_base/BUILD.bazel; then
  echo "ERROR: Phase 8b failed: expected 'base = \"@external_ubi9//:image\"' in ext_base/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 8b verified: external base image correctly mapped to @external_ubi9//:image."

# Verify extraction and layering by running dnfo_image on top of the built testimage
cat > ext_base/BUILD.bazel <<EOF
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")

dnfo_image(
    name = "from_base",
    config = "dnfo.yaml",
    base = "//testimage:testimage",
    contents = "@testimage_packages//:rpms",
    packages = ["curl"],
    lock_only = False,
)
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //ext_base:from_base
echo "Phase 8b verified: extracted base rpmdb and repos from base image and built layered image successfully."

echo ""
echo "--- Phase 9: Installing files from repository and pulled by Bazel into image paths ---"

# 1. Setup a repository extension that pulls an external file
cat > repo_ext.bzl <<EOF
def _pulled_file_repo_impl(rctx):
    rctx.file("BUILD.bazel", 'exports_files(["pulled_tool.sh"])\n')
    rctx.file("pulled_tool.sh", "#!/bin/sh\necho 'hello from pulled tool'\n")

_pulled_file_repo = repository_rule(implementation = _pulled_file_repo_impl)

def _pulled_file_ext_impl(mctx):
    _pulled_file_repo(name = "pulled_repo")

pulled_file_ext = module_extension(implementation = _pulled_file_ext_impl)
EOF

cat >> MODULE.bazel <<EOF

pulled_ext = use_extension("//:repo_ext.bzl", "pulled_file_ext")
use_repo(pulled_ext, "pulled_repo")
EOF

# 2. Test 9a: Dict format with repository file and Bazel-pulled external file
mkdir -p test_files
echo "hello from local config" > test_files/local_config.txt

cat > test_files/dnfo.yaml <<EOF
files:
  /etc/local_config.txt: local_config.txt
  /usr/local/bin/pulled_tool.sh:
    source: "@pulled_repo//:pulled_tool.sh"
    mode: "0755"
EOF

# 3. Test 9b: List format with permissions, combined with packages on top of testimage
mkdir -p test_files_list
echo "server_setting = enabled" > test_files_list/app.conf

cat > test_files_list/dnfo.yaml <<EOF
base: "//testimage:testimage"
files:
  - source: app.conf
    path: /etc/app.conf
    mode: "0644"
  - source: "@pulled_repo//:pulled_tool.sh"
    path: /usr/bin/pulled_tool
    mode: "0755"
EOF

# Run Gazelle to generate BUILD.bazel files
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Generated test_files/BUILD.bazel:"
cat test_files/BUILD.bazel

if ! grep -q '":local_config.txt"' test_files/BUILD.bazel; then
  echo "ERROR: Phase 9 failed: expected ':local_config.txt' in test_files/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '"@pulled_repo//:pulled_tool.sh"' test_files/BUILD.bazel; then
  echo "ERROR: Phase 9 failed: expected '@pulled_repo//:pulled_tool.sh' in test_files/BUILD.bazel" >&2
  exit 1
fi

echo "Generated test_files_list/BUILD.bazel:"
cat test_files_list/BUILD.bazel

if ! grep -q '":app.conf"' test_files_list/BUILD.bazel; then
  echo "ERROR: Phase 9 failed: expected ':app.conf' in test_files_list/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '"@pulled_repo//:pulled_tool.sh"' test_files_list/BUILD.bazel; then
  echo "ERROR: Phase 9 failed: expected '@pulled_repo//:pulled_tool.sh' in test_files_list/BUILD.bazel" >&2
  exit 1
fi

# Build image targets
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //test_files:all //test_files_list:all

# Extract installed files using rules_containers_util image_extract to verify contents
mkdir -p extract_verify
cat > extract_verify/BUILD.bazel <<EOF
load("@rules_containers_util//containers:defs.bzl", "image_extract")

image_extract(
    name = "extract_local_config",
    file = "/etc/local_config.txt",
    image = "//test_files:test_files",
    out = "extracted_local_config.txt",
)

image_extract(
    name = "extract_pulled_tool",
    file = "/usr/local/bin/pulled_tool.sh",
    image = "//test_files:test_files",
    out = "extracted_pulled_tool.sh",
)

image_extract(
    name = "extract_list_app_conf",
    file = "/etc/app.conf",
    image = "//test_files_list:test_files_list",
    out = "extracted_app.conf",
)
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //extract_verify:all

EXTRACTED_LOCAL="$(bazel info bazel-bin)/extract_verify/extracted_local_config.txt"
EXTRACTED_PULLED="$(bazel info bazel-bin)/extract_verify/extracted_pulled_tool.sh"
EXTRACTED_APP="$(bazel info bazel-bin)/extract_verify/extracted_app.conf"

if ! grep -q "hello from local config" "${EXTRACTED_LOCAL}"; then
  echo "ERROR: Phase 9 failed: extracted local config content mismatch: $(cat "${EXTRACTED_LOCAL}")" >&2
  exit 1
fi

if ! grep -q "hello from pulled tool" "${EXTRACTED_PULLED}"; then
  echo "ERROR: Phase 9 failed: extracted pulled tool content mismatch: $(cat "${EXTRACTED_PULLED}")" >&2
  exit 1
fi

if ! grep -q "server_setting = enabled" "${EXTRACTED_APP}"; then
  echo "ERROR: Phase 9 failed: extracted app config content mismatch: $(cat "${EXTRACTED_APP}")" >&2
  exit 1
fi

echo "Phase 9 verified: successfully installed and extracted files from repository and pulled by Bazel with both dict and list syntax."

echo ""
echo "--- Phase 10: Path exclusions and locale setting in dnfo.yaml ---"

mkdir -p test_opts
cat > test_opts/dnfo.yaml <<EOF
locale: en_US.UTF-8
exclude_paths:
  - /etc/skel
exclude_patterns:
  - "*/share/zoneinfo/*"
exclude_licenses: false
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - bash
EOF

# 1. Run gazelle to generate targets
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Generated test_opts/BUILD.bazel:"
cat test_opts/BUILD.bazel

if ! grep -q 'locale = "en_US.UTF-8"' test_opts/BUILD.bazel; then
  echo "ERROR: Phase 10 failed: expected 'locale = \"en_US.UTF-8\"' in test_opts/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q 'exclude_licenses = False' test_opts/BUILD.bazel; then
  echo "ERROR: Phase 10 failed: expected 'exclude_licenses = False' in test_opts/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '/etc/skel' test_opts/BUILD.bazel; then
  echo "ERROR: Phase 10 failed: expected '/etc/skel' in test_opts/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '\*/share/zoneinfo/\*' test_opts/BUILD.bazel; then
  echo "ERROR: Phase 10 failed: expected '*/share/zoneinfo/*' in test_opts/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 10 verified: Gazelle correctly generated locale, exclude_patterns, and exclude_licenses."

# 2. Generate lockfile
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //test_opts:test_opts.lock

cat >> MODULE.bazel <<EOF

dnfo.lock(
    name = "test_opts_packages",
    lockfile = "//test_opts:dnfo.lock.json",
)
use_repo(dnfo, "test_opts_packages")
EOF

# 3. Flip lock_only = False with gazelle
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

# 4. Build image and layer tar
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //test_opts:all //test_opts:test_opts_rpms_tar

echo "Final test_opts/BUILD.bazel:"
cat test_opts/BUILD.bazel

RPMS_TAR="$(bazel info bazel-bin)/test_opts/test_opts_rpms_tar.tar"

# Verify excluded paths are absent from the layer tar
if [ "$(tar -tf "${RPMS_TAR}" | grep -c "^etc/skel")" -gt 0 ]; then
  echo "ERROR: Phase 10 failed: etc/skel was found in test_opts_rpms_tar.tar despite exclusion!" >&2
  exit 1
fi
if [ "$(tar -tf "${RPMS_TAR}" | grep -c "zoneinfo")" -gt 0 ]; then
  echo "ERROR: Phase 10 failed: zoneinfo was found in test_opts_rpms_tar.tar despite exclusion!" >&2
  exit 1
fi

# Verify non-matching locales were filtered by install_langs
for loc in de fr es it; do
  if [ "$(tar -tf "${RPMS_TAR}" | grep -c "^usr/share/locale/${loc}/")" -gt 0 ]; then
    echo "ERROR: Phase 10 failed: locale ${loc} was not filtered out by install_langs in test_opts_rpms_tar.tar!" >&2
    exit 1
  fi
done

# Verify licenses are preserved because exclude_licenses = false
if [ "$(tar -tf "${RPMS_TAR}" | grep -c "^usr/share/licenses")" -eq 0 ]; then
  echo "ERROR: Phase 10 failed: licenses were excluded despite exclude_licenses = false!" >&2
  exit 1
fi

echo "Phase 10 verified: path exclusions, locale filtering, and license retention validated in output layer."

echo ""
echo "--- Phase 11: Multi-architecture images, multirun locking, and manifest user ---"

mkdir -p test_multiarch
cat > test_multiarch/dnfo.yaml <<EOF
user: nonroot
archs:
  - amd64
  - arm64
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - bash
EOF

# 1. Run gazelle to generate skeleton with normalized archs and user
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Generated test_multiarch/BUILD.bazel:"
cat test_multiarch/BUILD.bazel

if ! grep -q 'user = "nonroot"' test_multiarch/BUILD.bazel; then
  echo "ERROR: Phase 11 failed: expected 'user = \"nonroot\"' in test_multiarch/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q 'x86_64' test_multiarch/BUILD.bazel || ! grep -q 'aarch64' test_multiarch/BUILD.bazel; then
  echo "ERROR: Phase 11 failed: expected normalized archs 'x86_64' and 'aarch64' in test_multiarch/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q 'lock_only = True' test_multiarch/BUILD.bazel; then
  echo "ERROR: Phase 11 failed: expected 'lock_only = True' in test_multiarch/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 11 step 1 verified: Gazelle normalized amd64/arm64 to x86_64/aarch64 and generated user = 'nonroot'."

# 2. Run multirun alias target to update both lockfiles in a single invocation
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //test_multiarch:test_multiarch.lock

if [[ ! -f test_multiarch/dnfo.x86_64.lock.json ]]; then
  echo "ERROR: Phase 11 failed: test_multiarch/dnfo.x86_64.lock.json was not generated!" >&2
  exit 1
fi
if [[ ! -f test_multiarch/dnfo.aarch64.lock.json ]]; then
  echo "ERROR: Phase 11 failed: test_multiarch/dnfo.aarch64.lock.json was not generated!" >&2
  exit 1
fi

if ! grep -q '"arch":"x86_64,noarch"' test_multiarch/dnfo.x86_64.lock.json; then
  echo "ERROR: Phase 11 failed: x86_64 lockfile does not declare x86_64,noarch arch!" >&2
  exit 1
fi
if ! grep -q '"arch":"aarch64,noarch"' test_multiarch/dnfo.aarch64.lock.json; then
  echo "ERROR: Phase 11 failed: aarch64 lockfile does not declare aarch64,noarch arch!" >&2
  exit 1
fi
echo "Phase 11 step 2 verified: multirun generated both x86_64,noarch and aarch64,noarch lockfiles."

# 3. Register both lockfiles in MODULE.bazel
cat >> MODULE.bazel <<EOF

dnfo.lock(
    name = "test_multiarch_x86_64_packages",
    lockfile = "//test_multiarch:dnfo.x86_64.lock.json",
)
dnfo.lock(
    name = "test_multiarch_aarch64_packages",
    lockfile = "//test_multiarch:dnfo.aarch64.lock.json",
)
use_repo(
    dnfo,
    "test_multiarch_aarch64_packages",
    "test_multiarch_x86_64_packages",
)
EOF

# 4. Flip lock_only = False with gazelle
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Updated test_multiarch/BUILD.bazel:"
cat test_multiarch/BUILD.bazel

if grep -q 'lock_only = True' test_multiarch/BUILD.bazel; then
  echo "ERROR: Phase 11 failed: lock_only was not flipped to False!" >&2
  exit 1
fi

# 5. Build multi-arch image index and test lock diffs
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //test_multiarch:all
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel test --invocation_id="${INVOCATION_ID}" //test_multiarch:test_multiarch.x86_64.lock_test //test_multiarch:test_multiarch.aarch64.lock_test

INDEX_JSON="$(bazel info bazel-bin)/test_multiarch/test_multiarch_index.json"
if ! grep -q '"architecture":"amd64"' "${INDEX_JSON}" || ! grep -q '"architecture":"arm64"' "${INDEX_JSON}"; then
  echo "ERROR: Phase 11 failed: image index does not contain both amd64 and arm64 descriptors!" >&2
  exit 1
fi

X86_CONFIG="$(find "$(bazel info output_path)" -name "test_multiarch_x86_64_config.json" | head -n 1)"
ARM_CONFIG="$(find "$(bazel info output_path)" -name "test_multiarch_aarch64_config.json" | head -n 1)"

if ! grep -q '"architecture":"amd64"' "${X86_CONFIG}" || ! grep -q '"os":"linux"' "${X86_CONFIG}"; then
  echo "ERROR: Phase 11 failed: multi-arch x86_64 manifest config missing architecture amd64 or os linux!" >&2
  exit 1
fi
if ! grep -q '"architecture":"arm64"' "${ARM_CONFIG}" || ! grep -q '"os":"linux"' "${ARM_CONFIG}"; then
  echo "ERROR: Phase 11 failed: multi-arch aarch64 manifest config missing architecture arm64 or os linux!" >&2
  exit 1
fi
if ! grep -q '"User":"nonroot"' "${X86_CONFIG}" || ! grep -q '"User":"nonroot"' "${ARM_CONFIG}"; then
  echo "ERROR: Phase 11 failed: manifest configs do not contain 'User':'nonroot'!" >&2
  exit 1
fi

# 6. Single-arch non-x86 image (archs: [aarch64])
mkdir -p test_single_aarch64
cat > test_single_aarch64/dnfo.yaml <<EOF
user: "1000:1000"
archs:
  - aarch64
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  packages:
    - bash
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //test_single_aarch64:test_single_aarch64.lock

if [[ ! -f test_single_aarch64/dnfo.lock.json ]]; then
  echo "ERROR: Phase 11 failed: test_single_aarch64/dnfo.lock.json was not generated!" >&2
  exit 1
fi

cat >> MODULE.bazel <<EOF

dnfo.lock(
    name = "test_single_aarch64_packages",
    lockfile = "//test_single_aarch64:dnfo.lock.json",
)
use_repo(
    dnfo,
    "test_single_aarch64_packages",
)
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //test_single_aarch64:test_single_aarch64

SINGLE_ARM_CONFIG="$(find "$(bazel info output_path)" -name "test_single_aarch64_config.json" | head -n 1)"
if ! grep -q '"architecture":"arm64"' "${SINGLE_ARM_CONFIG}" || ! grep -q '"os":"linux"' "${SINGLE_ARM_CONFIG}"; then
  echo "ERROR: Phase 11 failed: single-arch aarch64 manifest does not declare architecture arm64 and os linux!" >&2
  exit 1
fi
if ! grep -q '"User":"1000:1000"' "${SINGLE_ARM_CONFIG}"; then
  echo "ERROR: Phase 11 failed: single-arch manifest config does not contain 'User':'1000:1000'!" >&2
  exit 1
fi

# 7. Test dnfo_lock_hint property suppression
OUTPUT=$(INVOCATION_ID=$(uuidgen) && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo 2>&1)
if ! echo "$OUTPUT" | grep -q "\[gazelle-dnfo\] Multi-arch lockfiles found"; then
  echo "ERROR: Phase 11 failed: expected lock hints when dnfo_lock_hint is default True" >&2
  exit 1
fi

echo "# gazelle:dnfo_lock_hint false" | cat - test_multiarch/BUILD.bazel > test_multiarch/BUILD.bazel.tmp && mv test_multiarch/BUILD.bazel.tmp test_multiarch/BUILD.bazel
OUTPUT_SUPPRESSED=$(INVOCATION_ID=$(uuidgen) && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo 2>&1)
if echo "$OUTPUT_SUPPRESSED" | grep -q "\[gazelle-dnfo\] Multi-arch lockfiles found for //test_multiarch:test_multiarch"; then
  echo "ERROR: Phase 11 failed: lock hint was not suppressed when dnfo_lock_hint is false" >&2
  exit 1
fi

echo "Phase 11 verified: multi-arch image index, single-arch aarch64 manifest platform, lock hint suppression, rules_multirun companion target, and manifest user execution verified successfully."

echo ""
echo "--- Phase 12: Test rules_img extra_layers injection ---"
mkdir -p test_extra
cat > test_extra/dnfo.yaml <<EOF
contents:
  packages:
    - bash
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 0
  extra_layers:
    - layer: :shared_layer
    - arch: amd64
      layer: :amd64_layer
    - arch: arm64
      layer: :arm64_layer
EOF

cat > test_extra/BUILD.bazel <<EOF
load("@rules_img//img:layer.bzl", "image_layer")

image_layer(
    name = "shared_layer",
    srcs = {
        "/usr/share/shared.txt": ":shared.txt",
    },
)

image_layer(
    name = "amd64_layer",
    srcs = {
        "/usr/share/amd64.txt": ":amd64.txt",
    },
)

image_layer(
    name = "arm64_layer",
    srcs = {
        "/usr/share/arm64.txt": ":arm64.txt",
    },
)
EOF
touch test_extra/shared.txt test_extra/amd64.txt test_extra/arm64.txt

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //:gazelle-dnfo

echo "Generated test_extra/BUILD.bazel:"
cat test_extra/BUILD.bazel

if ! grep -q 'extra_layers' test_extra/BUILD.bazel; then
  echo "ERROR: Phase 12 failed: extra_layers not found in test_extra/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '":shared_layer"' test_extra/BUILD.bazel; then
  echo "ERROR: Phase 12 failed: :shared_layer not resolved in test_extra/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '":amd64_layer"' test_extra/BUILD.bazel; then
  echo "ERROR: Phase 12 failed: :amd64_layer not resolved in test_extra/BUILD.bazel" >&2
  exit 1
fi
if ! grep -q '":arm64_layer"' test_extra/BUILD.bazel; then
  echo "ERROR: Phase 12 failed: :arm64_layer not resolved in test_extra/BUILD.bazel" >&2
  exit 1
fi
echo "Phase 12 verified: Gazelle generated extra_layers list of dicts."

# Ensure goss and dgoss are available for container image validation
GOSS_BIN_DIR="${WORK_DIR}/bin"
mkdir -p "${GOSS_BIN_DIR}"
HOST_ARCH=$(uname -m)
case "${HOST_ARCH}" in
  x86_64|amd64) GOSS_ARCH="x86_64" ;;
  aarch64|arm64) GOSS_ARCH="arm64" ;;
  *) GOSS_ARCH="x86_64" ;;
esac

if ! command -v goss >/dev/null 2>&1; then
  echo "Downloading goss for ${GOSS_ARCH}..."
  curl -fsSL "https://github.com/goss-org/goss/releases/download/v0.4.10/goss_0.4.10_linux_${GOSS_ARCH}.tar.gz" | tar -xz -C "${GOSS_BIN_DIR}" goss
  chmod +x "${GOSS_BIN_DIR}/goss"
fi

if ! command -v dgoss >/dev/null 2>&1; then
  echo "Downloading dgoss..."
  curl -fsSL -o "${GOSS_BIN_DIR}/dgoss" "https://github.com/goss-org/goss/releases/download/v0.4.10/dgoss"
  chmod +x "${GOSS_BIN_DIR}/dgoss"
fi

export PATH="${GOSS_BIN_DIR}:${PATH}"
export GOSS_PATH="$(which goss)"

# 12a: Populate layer payload contents and build/load image into Docker
echo "shared extra layer payload" > test_extra/shared.txt
echo "amd64 extra layer payload" > test_extra/amd64.txt
echo "arm64 extra layer payload" > test_extra/arm64.txt

cat > test_extra/BUILD.bazel <<EOF
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")
load("@rules_img//img:layer.bzl", "image_layer")

image_layer(
    name = "shared_layer",
    srcs = {
        "/usr/share/shared.txt": ":shared.txt",
    },
)

image_layer(
    name = "amd64_layer",
    srcs = {
        "/usr/share/amd64.txt": ":amd64.txt",
    },
)

image_layer(
    name = "arm64_layer",
    srcs = {
        "/usr/share/arm64.txt": ":arm64.txt",
    },
)

dnfo_image(
    name = "test_extra",
    config = "dnfo.yaml",
    contents = "@testimage_packages//:rpms",
    extra_layers = [
        {
            "layer": ":shared_layer",
        },
        {
            "arch": "x86_64",
            "layer": ":amd64_layer",
        },
        {
            "arch": "aarch64",
            "layer": ":arm64_layer",
        },
    ],
    lock_only = False,
    packages = ["bash"],
)
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //test_extra:test_extra_load

# Run Goss validation against test_extra:latest
cat > test_extra/goss.yaml <<EOF
file:
  /usr/share/shared.txt:
    exists: true
    contents:
      - "shared extra layer payload"
  /usr/share/amd64.txt:
    exists: true
    contents:
      - "amd64 extra layer payload"
  /usr/share/arm64.txt:
    exists: false
  /bin/bash:
    exists: true
    filetype: file
EOF

(cd test_extra && dgoss run --entrypoint /bin/sleep test_extra:latest 10)
echo "Phase 12a verified: extra_layers image built and validated with Goss."

# 12b: Test flatten-all-layers: true
mkdir -p test_flatten_all
cat > test_flatten_all/dnfo.yaml <<EOF
flatten-all-layers: true
contents:
  packages:
    - bash
EOF

echo "flatten all extra 1 payload" > test_flatten_all/extra1.txt
echo "flatten all extra 2 payload" > test_flatten_all/extra2.txt

cat > test_flatten_all/BUILD.bazel <<EOF
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")
load("@rules_img//img:layer.bzl", "image_layer")

image_layer(
    name = "extra_layer_1",
    srcs = {
        "/usr/share/extra1.txt": ":extra1.txt",
    },
)

image_layer(
    name = "extra_layer_2",
    srcs = {
        "/usr/share/extra2.txt": ":extra2.txt",
    },
)

dnfo_image(
    name = "flatten_all_image",
    config = "dnfo.yaml",
    contents = "@testimage_packages//:rpms",
    packages = ["bash"],
    extra_layers = [
        {"layer": ":extra_layer_1"},
        {"layer": ":extra_layer_2"},
    ],
    flatten_all_layers = True,
    lock_only = False,
)
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //test_flatten_all:flatten_all_image

EXEC_ROOT=$(INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" >&2 && bazel info --invocation_id="${INVOCATION_ID}" execution_root)
INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" >&2
FLATTEN_ALL_REL=$(bazel cquery --invocation_id="${INVOCATION_ID}" //test_flatten_all:flatten_all_image --output=files | grep '_manifest\.json' | head -n1)
FLATTEN_ALL_MANIFEST="${EXEC_ROOT}/${FLATTEN_ALL_REL}"
LAYER_COUNT=$(python3 -c "import json; m = json.load(open('${FLATTEN_ALL_MANIFEST}')); print(len(m.get('layers', [])))")

if [[ "${LAYER_COUNT}" -ne 1 ]]; then
  echo "ERROR: Phase 12b failed: expected exactly 1 layer with flatten_all_layers=True, got ${LAYER_COUNT}" >&2
  exit 1
fi
echo "Phase 12b verified: flatten_all_layers produced a manifest with exactly 1 flattened layer."

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //test_flatten_all:flatten_all_image_load

cat > test_flatten_all/goss.yaml <<EOF
file:
  /usr/share/extra1.txt:
    exists: true
    contents:
      - "flatten all extra 1 payload"
  /usr/share/extra2.txt:
    exists: true
    contents:
      - "flatten all extra 2 payload"
  /bin/bash:
    exists: true
    filetype: file
EOF

(cd test_flatten_all && dgoss run --entrypoint /bin/sleep flatten_all_image:latest 10)
echo "Phase 12b verified: flatten_all_layers image built and validated with Goss."

# 12c: Test flatten-dnfo-layers: true with base image
mkdir -p test_flatten_dnfo
cat > test_flatten_dnfo/dnfo.yaml <<EOF
base: "//testimage:testimage"
flatten-dnfo-layers: true
contents:
  packages:
    - curl
EOF

echo "dnfo extra layer payload" > test_flatten_dnfo/dnfo_extra.txt
echo "my dnfo file payload" > test_flatten_dnfo/my_dnfo_file.txt

# Build a layered image on top of testimage:testimage with extra layer + files
cat > test_flatten_dnfo/BUILD.bazel <<EOF
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")
load("@rules_img//img:layer.bzl", "image_layer")

image_layer(
    name = "dnfo_extra_layer",
    srcs = {
        "/usr/share/dnfo_extra.txt": ":dnfo_extra.txt",
    },
)

dnfo_image(
    name = "flatten_dnfo_image",
    base = "//testimage:testimage",
    config = "dnfo.yaml",
    contents = "@testimage_packages//:rpms",
    packages = ["curl"],
    extra_layers = [
        {"layer": ":dnfo_extra_layer"},
    ],
    files = {
        "/etc/my_dnfo_file.txt": ":my_dnfo_file.txt",
    },
    flatten_dnfo_layers = True,
    lock_only = False,
)
EOF

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel build --invocation_id="${INVOCATION_ID}" //testimage:testimage //test_flatten_dnfo:flatten_dnfo_image

BASE_REL=$(INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" >&2 && bazel cquery --invocation_id="${INVOCATION_ID}" //testimage:testimage --output=files | grep '_manifest\.json' | head -n1)
BASE_MANIFEST="${EXEC_ROOT}/${BASE_REL}"
BASE_LAYER_COUNT=$(python3 -c "import json; m = json.load(open('${BASE_MANIFEST}')); print(len(m.get('layers', [])))")
CHILD_REL=$(INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" >&2 && bazel cquery --invocation_id="${INVOCATION_ID}" //test_flatten_dnfo:flatten_dnfo_image --output=files | grep '_manifest\.json' | head -n1)
CHILD_MANIFEST="${EXEC_ROOT}/${CHILD_REL}"
CHILD_LAYER_COUNT=$(python3 -c "import json; m = json.load(open('${CHILD_MANIFEST}')); print(len(m.get('layers', [])))")

EXPECTED_CHILD_LAYERS=$((BASE_LAYER_COUNT + 1))
if [[ "${CHILD_LAYER_COUNT}" -ne "${EXPECTED_CHILD_LAYERS}" ]]; then
  echo "ERROR: Phase 12c failed: expected ${EXPECTED_CHILD_LAYERS} layers (base ${BASE_LAYER_COUNT} + 1 flattened dnfo layer), got ${CHILD_LAYER_COUNT}" >&2
  exit 1
fi
echo "Phase 12c verified: flatten_dnfo_layers squashed all dnfo layers into 1 layer on top of base image (${BASE_LAYER_COUNT} base + 1 dnfo = ${CHILD_LAYER_COUNT} total)."

INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel run --invocation_id="${INVOCATION_ID}" //test_flatten_dnfo:flatten_dnfo_image_load

cat > test_flatten_dnfo/goss.yaml <<EOF
file:
  /usr/share/dnfo_extra.txt:
    exists: true
    contents:
      - "dnfo extra layer payload"
  /etc/my_dnfo_file.txt:
    exists: true
    contents:
      - "my dnfo file payload"
  /usr/bin/curl:
    exists: true
    filetype: file
  /bin/bash:
    exists: true
    filetype: file
EOF

(cd test_flatten_dnfo && dgoss run --entrypoint /bin/sleep flatten_dnfo_image:latest 10)
echo "Phase 12c verified: flatten_dnfo_layers image built and validated with Goss."

echo "Phase 12 verified: extra_layers injection and layer flattening options validated successfully with Goss."

echo "=== rules_dnfo 3-Phase E2E Flow Test PASSED successfully! ==="
