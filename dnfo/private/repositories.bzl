"""Repository rules fetching prebuilt dnfo distributions."""

load(":platforms.bzl", "PLATFORMS")

_DIST_BUILD = """\
load("@rules_dnfo//dnfo:toolchain.bzl", "dnfo_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["bin/dnfo"])

filegroup(
    name = "files",
    srcs = glob(["**"], exclude = ["BUILD.bazel", "REPO.bazel"]),
)

dnfo_toolchain(
    name = "dnfo_toolchain",
    dnfo = "bin/dnfo",
    files = [":files"],
    version = "{version}",
)
"""

def _dnfo_dist_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        integrity = rctx.attr.integrity,
        stripPrefix = "dnfo",
    )
    rctx.file("BUILD.bazel", _DIST_BUILD.format(version = rctx.attr.version))

dnfo_dist_repository = repository_rule(
    implementation = _dnfo_dist_repository_impl,
    doc = "Downloads one prebuilt dnfo distribution archive.",
    attrs = {
        "integrity": attr.string(doc = "SRI hash of the archive; empty only for local testing."),
        "urls": attr.string_list(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

def _dnfo_toolchains_repository_impl(rctx):
    content = []
    if rctx.attr.from_source:
        content.append("""\
toolchain(
    name = "source_toolchain",
    toolchain = "@rules_dnfo//cmd/dnfo:dnfo_toolchain",
    toolchain_type = "@rules_dnfo//dnfo:toolchain_type",
)
""")
    else:
        for platform in rctx.attr.platforms:
            content.append("""\
toolchain(
    name = "{platform}_toolchain",
    exec_compatible_with = {constraints},
    toolchain = "@{repo}//:dnfo_toolchain",
    toolchain_type = "@rules_dnfo//dnfo:toolchain_type",
)
""".format(
                platform = platform,
                constraints = repr(PLATFORMS[platform]),
                repo = rctx.attr.dist_repos[platform],
            ))
    rctx.file("BUILD.bazel", "\n".join(content))

dnfo_toolchains_repository = repository_rule(
    implementation = _dnfo_toolchains_repository_impl,
    doc = "Declares toolchains for dnfo.",
    attrs = {
        "dist_repos": attr.string_dict(doc = "platform -> name of its dist_repository"),
        "platforms": attr.string_list(),
        "from_source": attr.bool(default = False),
    },
)
