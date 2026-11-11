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
bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.7")
archive_override(
    module_name = "dnf5-prebuilt",
    integrity = "sha256-VsPvx5ZNZIyB6u2qJ06lfcL3OBCpGQjZCEzEZLR6qfQ=",
    strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.7",
    urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.7/dnf5-prebuilt-v5.4.6.0.bcr.7.tar.gz"],
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
   When `base: <image_name>` is used, `rules_dnfo` uses `image_extract` from `rules_containers_util` (which flattens the image using `rules_img` and extracts target files):
   - Extracts `rpmdb.sqlite` from the base image (`/var/lib/rpm/rpmdb.sqlite` by default, or configurable via `base_rpmdb_file`) and passes it to `rpm_lock` and `rpm_mark`.
   - Optionally extracts base repository configurations (via `base_repo_file` / `base_repos`) and configures them in `dnf_config`.
   - Stacks the newly assembled RPM layer on top of `@<image_name>//:image` using `rules_img`.

> [!NOTE]
> External base images must be pulled via `rules_img` in `MODULE.bazel`. Direct registry URLs (e.g. `docker.io/library/alpine`) in `base:` are rejected with an actionable error directing you to use `images.pull`.

---

## Installing Files into the Image (`files:`)

As opposed to `apko` (which restricts image specifications strictly to package manager dependencies), `rules_dnfo` allows you to install arbitrary files from either your repository or pulled/generated by Bazel directly into specified paths within the container image.

### Syntax and Features

You can declare files either at the root level (`files:`) or under `contents:` (`contents.files:`). Both mapping syntax and list syntax with optional permission modes (`mode` or `permissions`), user ownership (`uid`, `uname`), and group ownership (`gid`, `gname`) are supported:

#### Key-Value Mapping Syntax

```yaml
files:
  # From the repository (resolved relative to dnfo.yaml as :app.conf)
  /etc/myapp/app.conf: app.conf

  # Target from another Bazel package in the workspace
  /etc/ssl/cert.pem: //certs:cert.pem

  # Target pulled by Bazel from an external repository with custom permissions
  /usr/local/bin/mytool:
    source: "@my_tools//:mytool"
    mode: "0755"
```

#### List Syntax

```yaml
files:
  - source: configs/server.conf
    path: /etc/server.conf
    mode: "0644"
  - source: "@downloaded_binaries//:agent"
    path: /usr/bin/agent
    mode: "0755"
    uid: 1000
    gid: 1000
```

### Gazelle Automation

When you run `bazel run //:gazelle-dnfo`, Gazelle automatically:
1. Resolves relative repository paths to package targets (e.g. `app.conf` -> `:app.conf`, `../common/file.txt` -> `//common:file.txt`).
2. Preserves external Bazel-pulled labels (e.g. `@my_tools//:mytool`).
3. Generates the corresponding `files = ...` attribute on `dnfo_image` in `BUILD.bazel`.
4. Assembles an isolated file layer via `rules_img` stacked cleanly on top of the RPM package layer and base image.
5. If an image specification contains only files without RPM packages, Gazelle automatically enables the image target (`lock_only = False`) without requiring lockfile generation.

---

## Path Exclusions & Locale Filtering (`exclude_paths:`, `locale:`)

`rules_dnfo` supports minimal container layers by allowing you to filter out unused locale catalogs and exclude arbitrary directory and file paths from the assembled RPM layer.

### Setting the Locale (`locale:`, `install_langs:`)

You can specify the language locale(s) to retain in your image (mimicking DNF `--setopt=install_langs=...` and RPM `%_install_langs`):

```yaml
# In dnfo.yaml (top-level or under contents:)
locale: en_US.UTF-8

# Or multiple locales:
# locales:
#   - en_US.UTF-8
#   - nl_NL.UTF-8
```

When configured:
1. `rules_dnfo` passes `install_langs` to `dnf_config`, guiding DNF5 dependency resolution and configuration.
2. `rpm_layer` filters translation catalogs in `/usr/share/locale` and `/usr/lib/locale`, eliminating hundreds of megabytes of unused languages while retaining the specified locale(s) and base C/POSIX locales.
3. Automatically sets the container's `LANG` environment variable (e.g. `LANG=en_US.UTF-8`) in the image manifest if not already explicitly defined in `environment:`.

### Excluding Paths and Minimal Layers (`exclude_paths:`, `exclude_patterns:`)

By default, `rules_dnfo` produces minimal container layers by automatically excluding documentation (`*/share/doc/*`, `*/share/info/*`), man pages (`*/share/man/*`), license notices (`*/share/licenses/*`), and `.build-id` debug links via `dnf5-prebuilt`.

You can exclude additional directory trees or file patterns, or selectively toggle default exclusions:

```yaml
# In dnfo.yaml (top-level or under contents:)
exclude_paths:
  - /etc/skel
  - /usr/share/zoneinfo

exclude_patterns:
  - "*.a"
  - "*/cracklib/*"

# Optionally preserve license notices for compliance:
exclude_licenses: false
```

- **Path Normalization**: Absolute paths (e.g. `/etc/skel`) and relative patterns are automatically normalized and expanded so they match entries during `bsdtar` extraction.
- **Exclusion Toggles**: Boolean flags `exclude_docs`, `exclude_man`, `exclude_licenses`, and `exclude_build_id` can be set to `true` or `false` in `dnfo.yaml`.

---

## License

Apache License 2.0.
