#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts/sbom"

echo "=== Starting rules_dnfo SBOM E2E Test ==="
echo "Repo root: ${REPO_ROOT}"
echo "Artifacts destination: ${ARTIFACTS_DIR}"

mkdir -p "${ARTIFACTS_DIR}"

# 1. Build and validate SBOM and SPDX targets from examples
echo ""
echo "--- Step 1: Building SBOM and SPDX targets in examples ---"
INVOCATION_ID=$(uuidgen)
echo "Invocation ID: ${INVOCATION_ID}"
bazel build --invocation_id="${INVOCATION_ID}" \
  //examples/minimal:minimal_spdx \
  //examples/minimal:minimal_cyclonedx \
  //examples/minimal:minimal_x86_64_spdx \
  //examples/minimal:minimal_aarch64_spdx \
  //examples/certificates:certificates_spdx \
  //examples/certificates:certificates_cyclonedx

echo "Validating minimal multi-arch SPDX..."
python3 "${SCRIPT_DIR}/validate_sbom.py" \
  --spdx "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_spdx.json" \
  --expected-pkgs bash coreutils

echo "Validating minimal multi-arch CycloneDX..."
python3 "${SCRIPT_DIR}/validate_sbom.py" \
  --cyclonedx "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_cyclonedx.json" \
  --expected-pkgs bash coreutils

echo "Validating minimal x86_64 single-arch SPDX..."
python3 "${SCRIPT_DIR}/validate_sbom.py" \
  --spdx "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_x86_64_spdx.json" \
  --expected-pkgs bash coreutils \
  --expected-arch x86_64

echo "Validating minimal aarch64 single-arch SPDX..."
python3 "${SCRIPT_DIR}/validate_sbom.py" \
  --spdx "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_aarch64_spdx.json" \
  --expected-pkgs bash coreutils \
  --expected-arch aarch64

echo "Validating certificates SPDX..."
python3 "${SCRIPT_DIR}/validate_sbom.py" \
  --spdx "${REPO_ROOT}/bazel-bin/examples/certificates/certificates_spdx.json" \
  --expected-pkgs bash ca-certificates

# 2. Copy artifacts for workflow upload
echo ""
echo "--- Step 2: Copying generated SBOM artifacts ---"
cp -f "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_spdx.json" "${ARTIFACTS_DIR}/minimal_spdx.json"
cp -f "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_cyclonedx.json" "${ARTIFACTS_DIR}/minimal_cyclonedx.json"
cp -f "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_x86_64_spdx.json" "${ARTIFACTS_DIR}/minimal_x86_64_spdx.json"
cp -f "${REPO_ROOT}/bazel-bin/examples/minimal/minimal_aarch64_spdx.json" "${ARTIFACTS_DIR}/minimal_aarch64_spdx.json"
cp -f "${REPO_ROOT}/bazel-bin/examples/certificates/certificates_spdx.json" "${ARTIFACTS_DIR}/certificates_spdx.json"
cp -f "${REPO_ROOT}/bazel-bin/examples/certificates/certificates_cyclonedx.json" "${ARTIFACTS_DIR}/certificates_cyclonedx.json"

ls -la "${ARTIFACTS_DIR}"

# 3. Test scratch downstream workspace to ensure SBOM targets are generated automatically
echo ""
echo "--- Step 3: Testing downstream workspace SBOM generation ---"
WORK_DIR="$(mktemp -d -t dnfo-sbom-e2e-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

cd "${WORK_DIR}"
touch .bazelrc

if [[ -d "${HOME}/.cache/bazel/repository-cache" ]]; then
  echo "common --repository_cache=${HOME}/.cache/bazel/repository-cache" >> .bazelrc
fi

if [[ -f "${REPO_ROOT}/.bazelrc.user" ]]; then
  cp -f "${REPO_ROOT}/.bazelrc.user" .bazelrc.user
  echo "try-import %workspace%/.bazelrc.user" >> .bazelrc
fi

cat > MODULE.bazel <<EOF
module(name = "e2e_sbom_downstream_test")

bazel_dep(name = "rules_dnfo", version = "0.0.1")
local_path_override(
    module_name = "rules_dnfo",
    path = "${REPO_ROOT}",
)

bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.9")
archive_override(
    module_name = "dnf5-prebuilt",
    integrity = "sha256-7hKAFCj7ORn5LTY2MIJtawX0E0Ky/ue3cHAuaaYhsS4=",
    strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.9",
    urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.9/dnf5-prebuilt-v5.4.6.0.bcr.9.tar.gz"],
)

bazel_dep(name = "rules_containers_util", version = "0.0.5")
archive_override(
    module_name = "rules_containers_util",
    integrity = "sha256-o/GHGK/6FhfkjXs02MnVKotjbSviI/PQqxaYLZn2CBg=",
    strip_prefix = "rules_containers_util-0.0.5",
    urls = ["https://github.com/bookingcom/rules_containers_util/releases/download/v0.0.5/rules_containers_util-v0.0.5.tar.gz"],
)

archive_override(
    module_name = "supply_chain_tools",
    integrity = "sha256-YpP3ZodjRBBKIAgyOXhRMyGDIs4oqsC0MEC8VHn1pRM=",
    strip_prefix = "supply_chain_tools-0.0.3/tools",
    urls = ["https://github.com/bazel-contrib/supply-chain/releases/download/supply_chain_tools-0.0.3/supply_chain_tools-0.0.3.tar.gz"],
)

archive_override(
    module_name = "supply-chain-go",
    integrity = "sha256-iUcy/deO90HaWGFS4Zas+KctlULjXawYEPlqnWQK5s0=",
    strip_prefix = "supply-chain-go-0.0.11/lib/supplychain-go",
    urls = ["https://github.com/bazel-contrib/supply-chain/releases/download/supply-chain-go-0.0.11/supply-chain-go-0.0.11.tar.gz"],
)

bazel_dep(name = "rules_img", version = "0.3.25")
bazel_dep(name = "tar.bzl", version = "0.10.9")

bsd_tar_toolchains = use_extension("@tar.bzl//tar:extensions.bzl", "toolchains")
use_repo(bsd_tar_toolchains, "bsd_tar_toolchains")
register_toolchains("@bsd_tar_toolchains//:all")

dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")
dnfo.lock(
    name = "test_pkgs",
    lockfile = "//app:dnfo.lock.json",
)
use_repo(dnfo, "test_pkgs")
EOF

mkdir -p app
cp "${REPO_ROOT}/examples/minimal/dnfo.x86_64.lock.json" app/dnfo.lock.json
cat > app/BUILD.bazel <<EOF
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")

dnfo_image(
    name = "app_image",
    architecture = "x86_64",
    config = "dnfo.yaml",
    contents = "@test_pkgs//:rpms",
    lock_only = False,
    packages = [
        "bash",
        "coreutils",
    ],
)
EOF
touch app/dnfo.yaml

INVOCATION_ID=$(uuidgen)
echo "Invocation ID: ${INVOCATION_ID}"
bazel build --invocation_id="${INVOCATION_ID}" //app:app_image_spdx //app:app_image_cyclonedx

python3 "${SCRIPT_DIR}/validate_sbom.py" \
  --spdx "${WORK_DIR}/bazel-bin/app/app_image_spdx.json" \
  --cyclonedx "${WORK_DIR}/bazel-bin/app/app_image_cyclonedx.json" \
  --expected-pkgs bash coreutils

cp -f "${WORK_DIR}/bazel-bin/app/app_image_spdx.json" "${ARTIFACTS_DIR}/downstream_app_image_spdx.json"
cp -f "${WORK_DIR}/bazel-bin/app/app_image_cyclonedx.json" "${ARTIFACTS_DIR}/downstream_app_image_cyclonedx.json"

echo "=== rules_dnfo SBOM E2E Test PASSED successfully! ==="
