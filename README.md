# rules_dnfo

Declarative, hermetic container image builder for Bazel using **DNF5**, **RPM** packages, and **rules_img**.

Inspired by [rules_apko](https://github.com/chainguard-dev/rules_apko), `rules_dnfo` lets you construct lightweight, reproducible OCI and Docker-compatible container images directly from RPM package repositories without needing Dockerfiles, virtualization, or root daemons.

## Features

- **Declarative Image Specifications**: Define packages, repositories, accounts, entrypoints, and environment variables in clean YAML syntax (`*dnfo*.ya?ml`).
- **Gazelle-Driven 3-Phase Workflow**: Orion Gazelle extension (`gazelle-dnfo`) generates and maintains `BUILD.bazel` targets automatically.
- **Hermetic DNF5 Dependency Solving**: Transitive RPM dependency resolution and lockfile generation powered by [dnf5-prebuilt](https://github.com/bookingcom/dnf5-prebuilt).
- **Reproducible Lockfiles**: Locks resolved RPM packages with SRI integrity hashes into `dnfo.lock.json`.
- **GPG Key Verification**: RPM package authenticity verified via GPG keys through `rpm_layer`.
- **Fast Layer Assembly**: Seamless integration with `rules_img` (`rpm_layer`, `linux_skeleton`, `etc_passwd`, `image_load`) for multi-layer container assembly and instant local image loading (`bazel run //path/to:image.load`).

---

## Installation

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dnfo", version = "0.0.1")

# dnf5-prebuilt dependency override (until published to BCR)
bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.5")
archive_override(
    module_name = "dnf5-prebuilt",
    integrity = "sha256-Plm67w2RlJ/trfQaAczblLpMa6zFjcMO3xDW5cHpp4Q=",
    strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.5",
    urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.5/dnf5-prebuilt-v5.4.6.0.bcr.5.tar.gz"],
)
```

> [!NOTE]
> Dependencies like `rules_img`, `aspect_gazelle_prebuilt`, `buildifier_prebuilt`, and prebuilt `dnf5` toolchains are brought in transitively by `rules_dnfo`.

To configure Gazelle in your root `BUILD.bazel` (aliased as `gazelle-dnfo` so it does not collide with existing `//:gazelle` targets):

```starlark
alias(
    name = "gazelle-dnfo",
    actual = "@rules_dnfo//dnfo:gazelle",
)

alias(
    name = "gazelle-dnfo.check",
    actual = "@rules_dnfo//dnfo:gazelle.check",
)

alias(
    name = "update",
    actual = "@rules_dnfo//dnfo:update",
)
```

---

## The 3-Phase Image Introduction Workflow

Introducing a new container image is an automated 3-phase process orchestrated by `gazelle-dnfo` and `dnf5-prebuilt`.

### Step 1: Generate the BUILD Skeleton

Create a `dnfo.yaml` (or any `*dnfo*.yaml` / `*dnfo*.yml` file) in your package:

```yaml
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/$basearch/
      gpgcheck: 1
      gpgkey: https://yum.oracle.com/RPM-GPG-KEY-oracle-ol10
  packages:
    - bash
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

Run Gazelle:

```bash
bazel run //:gazelle-dnfo
```

Gazelle detects the configuration, parses the repositories and packages, generates `BUILD.bazel` with `lock_only = True`, and prints instructions for the next steps.

> [!NOTE]
> Setting `lock_only = True` initially declares only the `.lock` target, preventing repo-wide commands (`bazel build //...` or `bazel test //...`) from failing with missing package repository errors before the lock file has been generated and declared in `MODULE.bazel`.

### Step 2: Generate the Lockfile

Run the companion lock target generated in your package:

```bash
bazel run //path/to:image.lock
```

This invokes `dnf5-prebuilt` to resolve all transitive dependencies and outputs `dnfo.lock.json` with SRI integrity hashes.

### Step 3: Register Lock in MODULE.bazel and Flip Flag

Register the generated lockfile in `MODULE.bazel`:

```starlark
dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")
dnfo.lock(
    name = "image_packages",
    lockfile = "//path/to:dnfo.lock.json",
)
use_repo(dnfo, "image_packages")
```

Run Gazelle:

```bash
bazel run //:gazelle-dnfo
```

Gazelle detects that `dnfo.lock.json` is present on disk and flips `lock_only = False` in `BUILD.bazel`, enabling the complete image build pipeline.

---

### Automated Onboarding & Update Tool

Instead of performing the steps manually, `rules_dnfo` provides an automated tool that orchestrates the entire workflow (Gazelle skeleton generation, lockfile generation via `dnf5-prebuilt`, `MODULE.bazel` registration via `buildozer`, and lock flag flipping):

```bash
bazel run @rules_dnfo//dnfo:update
```

When new packages or repositories are added to any `dnfo.yaml`, running this command automatically synchronizes the build targets and refreshes the lockfiles.

---

## Building and Running Images

Once enabled, build the container image target:

```bash
bazel build //path/to:image
```

Or load it directly into Docker/Podman:

```bash
bazel run //path/to:image.load
```

---

## File Inheritance & Layering

`rules_dnfo` supports two primary approaches for building on top of base layers: inheriting from another `dnfo.yaml` file (apko-style) or layering on top of an external container image pulled via `rules_img`.

### Apko-Style File Inheritance (`include:`)

You can inherit from a parent `dnfo` configuration using the `include:` directive (following [apko file format](https://github.com/chainguard-dev/apko/blob/main/docs/apko_file.md#includes)).

When `include: <path>` is used, `gazelle-dnfo` automatically:
1. Sets `base` to the parent container image target (e.g. `:parent` or `//pkg:parent`).
2. References the parent's RPM database (`base_rpmdb = ":parent_rpmdb"`), allowing `dnf5` and `rpm_mark` to solve and record child packages on top of what is already installed in the parent.
3. Forwards the parent's repository definitions (`base_repos = ":parent_repos"`), so the child automatically has access to the parent's package repositories without duplicating configuration.

Example `child.dnfo.yaml`:

```yaml
include: parent.dnfo.yaml

contents:
  packages:
    - curl
    - jq
```

`include:` accepts relative file paths (`parent.dnfo.yaml`, `../base/base.dnfo.yaml`), absolute workspace labels (`//images/base:base.dnfo.yaml`), or target labels (`:parent`). Lists of included files are also supported.

### Layering on Top of an External Base Image (`base:`)

To build on top of an external container image (such as Red Hat UBI, Fedora, CentOS Stream, or Oracle Linux), pull the image in `MODULE.bazel` using `rules_img`, and reference it by name in your `dnfo.yaml`:

1. **Pull the base image in `MODULE.bazel`**:
   ```starlark
   images = use_extension("@rules_img//img:extensions.bzl", "images")
   images.pull(
       name = "ubi9",
       digest = "sha256:...",
       repository = "registry.access.redhat.com/ubi9",
   )
   use_repo(images, "ubi9")
   ```

2. **Reference the pulled image in your `dnfo.yaml`**:
   ```yaml
   base: ubi9

   contents:
     packages:
       - curl
   ```

3. **Automatic Extraction**:
   When `base: <image_name>` is used, `rules_dnfo` invokes `dnfo_extract_base` to hermetically inspect the base image layers:
   - Extracts `/var/lib/rpm/rpmdb.sqlite` from the base image layers and passes it to `rpm_lock` and `rpm_mark`.
   - Extracts any `/etc/yum.repos.d/*.repo` files from the base image and configures them in `dnf_config`.
   - Stacks the newly assembled RPM layer on top of `@<image_name>//:image` using `rules_img`.

> [!NOTE]
> External base images must be pulled via `rules_img` in `MODULE.bazel`. Direct registry URLs (e.g. `docker.io/library/alpine`) in `base:` are rejected with an actionable error directing you to use `images.pull`.

---

## License

Apache License 2.0.
