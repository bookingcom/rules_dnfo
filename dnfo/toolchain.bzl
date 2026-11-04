"""dnfo toolchain definitions."""

DnfoInfo = provider(
    doc = "dnfo distribution information.",
    fields = {
        "dnfo": "File: the dnfo executable to run in actions.",
        "files": "depset of File: all files of the distribution.",
        "version": "string: version.",
    },
)

def _dnfo_toolchain_impl(ctx):
    all_files = ctx.files.files + [ctx.file.dnfo]
    files = depset(all_files)
    info = DnfoInfo(
        dnfo = ctx.file.dnfo,
        files = files,
        version = ctx.attr.version,
    )
    return [
        platform_common.ToolchainInfo(dnfo_info = info),
        DefaultInfo(files = files),
    ]

dnfo_toolchain = rule(
    implementation = _dnfo_toolchain_impl,
    doc = "Defines a dnfo toolchain.",
    attrs = {
        "dnfo": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The dnfo executable.",
        ),
        "files": attr.label_list(
            allow_files = True,
            doc = "All files of the distribution.",
        ),
        "version": attr.string(
            default = "",
            doc = "Version of the tool.",
        ),
    },
)

def _current_dnfo_toolchain_impl(ctx):
    info = ctx.toolchains[Label("//dnfo:toolchain_type")].dnfo_info
    exe = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = exe,
        target_file = info.dnfo,
        is_executable = True,
    )
    make_vars = {"DNFO": exe.path}
    return [
        info,
        DefaultInfo(
            executable = exe,
            files = depset([exe]),
            runfiles = ctx.runfiles(transitive_files = info.files).merge(ctx.runfiles([exe])),
        ),
        platform_common.TemplateVariableInfo(make_vars),
    ]

current_dnfo_toolchain = rule(
    implementation = _current_dnfo_toolchain_impl,
    doc = "Exposes the resolved dnfo binary.",
    executable = True,
    toolchains = ["//dnfo:toolchain_type"],
)
