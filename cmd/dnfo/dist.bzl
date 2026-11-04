"""Builds distribution archives for dnfo across supported platforms."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@tar.bzl//tar:tar.bzl", "tar_rule")

DEFAULT_VERSION = "0.0.1"

_PLATFORM_CONFIGS = {
    "linux_amd64": {
        "//command_line_option:platforms": ["@rules_go//go/toolchain:linux_amd64"],
    },
    "linux_arm64": {
        "//command_line_option:platforms": ["@rules_go//go/toolchain:linux_arm64"],
    },
    "osx_amd64": {
        "//command_line_option:platforms": ["@rules_go//go/toolchain:darwin_amd64"],
    },
    "osx_arm64": {
        "//command_line_option:platforms": ["@rules_go//go/toolchain:darwin_arm64"],
    },
}

def _multiplatform_transition_impl(_settings, _attr):
    return {
        platform: {
            "//command_line_option:platforms": cfg["//command_line_option:platforms"],
        }
        for platform, cfg in _PLATFORM_CONFIGS.items()
    }

_multiplatform_transition = transition(
    implementation = _multiplatform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _dist_mtree_impl(ctx):
    exe = ctx.file.binary
    lines = [
        "dnfo uid=0 gid=0 time=0 mode=0755 type=dir",
        "dnfo/bin uid=0 gid=0 time=0 mode=0755 type=dir",
        "dnfo/bin/dnfo uid=0 gid=0 time=0 mode=0755 type=file content=" + exe.path,
    ]
    out = ctx.actions.declare_file(ctx.label.name + ".spec")
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

dist_mtree = rule(
    implementation = _dist_mtree_impl,
    attrs = {
        "binary": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)

def dnfo_distribution(name, binary, **kwargs):
    dist_mtree(
        name = name + "_mtree",
        binary = binary,
        **kwargs
    )
    tar_rule(
        name = name,
        srcs = [binary],
        mtree = name + "_mtree",
        compress = "gzip",
        out = name + ".tar.gz",
        **kwargs
    )

def _multiplatform_dist_impl(ctx):
    flag_val = ctx.attr._version_flag[BuildSettingInfo].value if ctx.attr._version_flag else ""
    version = ctx.var.get("version") or flag_val or ctx.attr.version or DEFAULT_VERSION
    out_files = []
    output_groups = {}
    for platform, target in ctx.split_attr.target.items():
        src_file = target[DefaultInfo].files.to_list()[0]
        out_file = ctx.actions.declare_file("dnfo-%s-%s.tar.gz" % (version, platform))
        ctx.actions.symlink(output = out_file, target_file = src_file)
        out_files.append(out_file)
        output_groups[platform] = depset([out_file])

    return [
        DefaultInfo(files = depset(out_files)),
        OutputGroupInfo(**output_groups),
    ]

multiplatform_dnfo_dist = rule(
    implementation = _multiplatform_dist_impl,
    attrs = {
        "target": attr.label(
            cfg = _multiplatform_transition,
            mandatory = True,
        ),
        "version": attr.string(
            default = "",
        ),
        "_version_flag": attr.label(
            default = "//cmd/dnfo:version",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
