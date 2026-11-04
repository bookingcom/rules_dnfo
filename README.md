# rules_dnfo

Declarative, hermetic container image builder for Bazel using **DNF5** and **RPM** packages.

Inspired by [rules_apko](https://github.com/chainguard-dev/rules_apko), `rules_dnfo` lets you construct lightweight, secure OCI and Docker-compatible container images directly from RPM package repositories without needing Dockerfiles or root daemons.

## Features

- **Declarative Image Specifications**: Define packages, repositories, accounts, entrypoints, and environment variables in a clean YAML syntax similar to `apko.yaml`.
- **Hermetic DNF5 Solver**: Resolves transitive package dependencies with [dnf5-prebuilt](https://github.com/bookingcom/dnf5-prebuilt).
- **Reproducible Lockfiles**: Locks all resolved packages with SRI integrity hashes into `dnfo.lock.json`.
- **One-Command Lock Updates**: Automatically generates companion `.lock` targets (`bazel run //path/to:image.lock`).
- **Direct OCI & Tarball Outputs**: Outputs OCI directory layouts or container layer tarballs ready for container runtimes or rulesets like `rules_oci` / `rules_img`.
- **Multi-Platform Prebuilts & From-Source Builds**: Precompiled binaries across `linux_amd64`, `linux_arm64`, `osx_amd64`, and `osx_arm64`, with source build fallback.

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dnfo", version = "0.0.1")

# dnf5-prebuilt dependency override (until published to BCR)
bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.3")
archive_override(
    module_name = "dnf5-prebuilt",
    integrity = "sha256-Lsvj4dkCXXnGO7+cX4ZNAAmkrN6fLgHkYn1R0jkt1zc=",
    strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.3",
    urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.3/dnf5-prebuilt-v5.4.6.0.bcr.3.tar.gz"],
)

dnf5 = use_extension("@dnf5-prebuilt//dnf5-prebuilt:extensions.bzl", "dnf5")
dnf5.toolchains()
use_repo(dnf5, "dnf5_toolchains")
register_toolchains("@dnf5_toolchains//:all")

dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")
dnfo.toolchains()
use_repo(dnfo, "dnfo_toolchains")
register_toolchains("@dnfo_toolchains//:all")
```

## Quick Start

### 1. Define your container in `dnfo.yaml`

```yaml
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/$basearch/
      gpgcheck: 0
  packages:
    - bash
    - coreutils
    - curl

entrypoint:
  command: /bin/bash

cmd: "-l"

work-dir: /home

environment:
  PATH: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  TERM: xterm

accounts:
  users:
    - username: nonroot
      uid: 65532
      gid: 65532
  groups:
    - groupname: nonroot
      gid: 65532

archs:
  - x86_64
```

### 2. Declare the image in `BUILD.bazel`

```starlark
load("@rules_dnfo//dnfo:defs.bzl", "dnfo_image")

dnfo_image(
    name = "my_image",
    config = "dnfo.yaml",
    architecture = "x86_64",
    output = "oci",
)
```

### 3. Generate or refresh the lockfile

Run the automatically generated `.lock` companion target:

```bash
bazel run //:my_image.lock
```

This writes or updates `dnfo.lock.json` in the workspace directory.

### 4. Build the container image

```bash
bazel build //:my_image
```

## License

Apache License 2.0.
