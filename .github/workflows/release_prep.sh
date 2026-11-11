#!/usr/bin/env bash
# Prepares a release: creates the source archive used by the Bazel Central Registry
# and prints the release notes.
#
# Usage: .github/workflows/release_prep.sh <tag>
set -o errexit -o nounset -o pipefail

TAG=$1
VERSION=${TAG#v}
PREFIX="rules_dnfo-${VERSION}"
ARCHIVE="rules_dnfo-${TAG}.tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive --format=tar --prefix="${PREFIX}/" "${TAG}" | tar -x -C "$work"

# Stamp the module version.
sed -i.bak "0,/version = \".*\"/s//version = \"${VERSION}\"/" "$work/$PREFIX/MODULE.bazel"
rm -f "$work/$PREFIX/MODULE.bazel.bak"

tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@0" -C "$work" -cf - "$PREFIX" | gzip -n >"$ARCHIVE"

SHA256=$(openssl dgst -sha256 -binary "$ARCHIVE" | base64)

cat <<NOTES
# rules_dnfo ${VERSION}

## Using Bzlmod

Add to your \`MODULE.bazel\`:

\`\`\`starlark
bazel_dep(name = "rules_dnfo", version = "${VERSION}")
\`\`\`

If \`rules_dnfo\` is not yet available in your registry, you can use \`archive_override\`:

\`\`\`starlark
bazel_dep(name = "rules_dnfo", version = "${VERSION}")
archive_override(
    module_name = "rules_dnfo",
    integrity = "sha256-${SHA256}",
    strip_prefix = "${PREFIX}",
    urls = ["https://github.com/bookingcom/rules_dnfo/releases/download/${TAG}/${ARCHIVE}"],
)
\`\`\`

> [!NOTE]
> Until \`dnf5-prebuilt\` and \`rules_containers_util\` are published to BCR, you must configure their overrides in your \`MODULE.bazel\`:
>
> \`\`\`starlark
> bazel_dep(name = "dnf5-prebuilt", version = "5.4.6.0.bcr.7")
> archive_override(
>     module_name = "dnf5-prebuilt",
>     integrity = "sha256-VsPvx5ZNZIyB6u2qJ06lfcL3OBCpGQjZCEzEZLR6qfQ=",
>     strip_prefix = "dnf5-prebuilt-5.4.6.0.bcr.7",
>     urls = ["https://github.com/bookingcom/dnf5-prebuilt/releases/download/v5.4.6.0.bcr.7/dnf5-prebuilt-v5.4.6.0.bcr.7.tar.gz"],
> )
>
> bazel_dep(name = "rules_containers_util", version = "0.0.5")
> archive_override(
>     module_name = "rules_containers_util",
>     integrity = "sha256-o/GHGK/6FhfkjXs02MnVKotjbSviI/PQqxaYLZn2CBg=",
>     strip_prefix = "rules_containers_util-0.0.5",
>     urls = ["https://github.com/bookingcom/rules_containers_util/releases/download/v0.0.5/rules_containers_util-v0.0.5.tar.gz"],
> )
> \`\`\`

### Gazelle Configuration

Configure Gazelle in your root \`BUILD.bazel\`:

\`\`\`starlark
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
\`\`\`

### Example

Create a \`dnfo.yaml\` in your package:

\`\`\`yaml
contents:
  repositories:
    - id: baseos
      name: BaseOS
      baseurl: https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/\$basearch/
      gpgcheck: 1
      gpgkey: https://yum.oracle.com/RPM-GPG-KEY-oracle-ol10
  packages:
    - bash
    - coreutils

entrypoint:
  command: /bin/bash

cmd: "-l"
\`\`\`

Then generate targets:

\`\`\`bash
bazel run //:gazelle-dnfo
\`\`\`
NOTES
