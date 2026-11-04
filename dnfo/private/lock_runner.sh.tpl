#!/usr/bin/env bash
set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  {
    echo >&2 "ERROR: cannot find @bazel_tools//tools/bash/runfiles:runfiles.bash"
    exit 1
  }
f=
set -e
# --- end runfiles.bash initialization v3 ---

TOOL="$(rlocation "%{TOOL_RLOCATION}")"
CONFIG="$(rlocation "%{CONFIG_RLOCATION}")"
DEST="${BUILD_WORKSPACE_DIRECTORY}/%{DEST_PATH}"
TMP_OUT="$(mktemp)"
trap 'rm -f "${TMP_OUT}"' EXIT

DNF5_ARG=""
if [[ -n "%{DNF5_RLOCATION}" ]]; then
  DNF5_PATH="$(rlocation "%{DNF5_RLOCATION}")"
  DNF5_ARG="--dnf5=${DNF5_PATH}"
fi

RPM_ARG=""
if [[ -n "%{RPM_RLOCATION}" ]]; then
  RPM_PATH="$(rlocation "%{RPM_RLOCATION}")"
  RPM_ARG="--rpm=${RPM_PATH}"
fi

"${TOOL}" lock %{RUN_ARGS} ${DNF5_ARG} ${RPM_ARG} --output="${TMP_OUT}" "${CONFIG}"

mkdir -p "$(dirname "${DEST}")"
cp -f "${TMP_OUT}" "${DEST}"
echo "Lockfile updated at: ${DEST}"
