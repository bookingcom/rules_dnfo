"""Implementation of dnfo_lock rule."""

DNF5_TOOLCHAIN_TYPE = "@dnf5-prebuilt//dnf5-prebuilt:toolchain_type"
DNFO_TOOLCHAIN_TYPE = "//dnfo:toolchain_type"

def _dnfo_lock_impl(ctx):
    out = ctx.outputs.out or ctx.actions.declare_file(ctx.label.name + ".lock.json")
    dnfo_info = ctx.toolchains[Label(DNFO_TOOLCHAIN_TYPE)].dnfo_info

    dnf5_info = None
    if DNF5_TOOLCHAIN_TYPE in ctx.toolchains:
        dnf5_info = ctx.toolchains[DNF5_TOOLCHAIN_TYPE].dnf5_info

    args = ctx.actions.args()
    args.add("lock")
    args.add("--output=" + out.path)
    if ctx.attr.arch:
        args.add("--arch=" + ctx.attr.arch)
    if ctx.attr.releasever:
        args.add("--releasever=" + ctx.attr.releasever)

    inputs = [ctx.file.config]
    transitive_inputs = [dnfo_info.files]

    if dnf5_info:
        args.add("--dnf5=" + dnf5_info.dnf5.path)
        args.add("--rpm=" + dnf5_info.rpm.path)
        transitive_inputs.append(dnf5_info.files)

    args.add(ctx.file.config.path)

    ctx.actions.run(
        mnemonic = "DnfoLock",
        progress_message = "Generating dnfo lockfile %s" % out.short_path,
        executable = dnfo_info.dnfo,
        arguments = [args],
        inputs = depset(inputs, transitive = transitive_inputs),
        outputs = [out],
    )

    runner_script = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    out_dest = ctx.attr.out.name if ctx.attr.out else (ctx.file.config.basename.rsplit(".", 1)[0] + ".lock.json")
    dest_path = (ctx.label.package + "/" + out_dest) if ctx.label.package else out_dest

    run_args = []
    if ctx.attr.arch:
        run_args.append("--arch=" + ctx.attr.arch)
    if ctx.attr.releasever:
        run_args.append("--releasever=" + ctx.attr.releasever)

    tool_rel = dnfo_info.dnfo.short_path
    tool_rlocation = tool_rel[3:] if tool_rel.startswith("../") else ((ctx.workspace_name or "_main") + "/" + tool_rel)

    config_rel = ctx.file.config.short_path
    config_rlocation = config_rel[3:] if config_rel.startswith("../") else ((ctx.workspace_name or "_main") + "/" + config_rel)

    dnf5_rlocation = ""
    rpm_rlocation = ""
    if dnf5_info:
        d_rel = dnf5_info.dnf5.short_path
        dnf5_rlocation = d_rel[3:] if d_rel.startswith("../") else ((ctx.workspace_name or "_main") + "/" + d_rel)
        r_rel = dnf5_info.rpm.short_path
        rpm_rlocation = r_rel[3:] if r_rel.startswith("../") else ((ctx.workspace_name or "_main") + "/" + r_rel)

    ctx.actions.expand_template(
        template = ctx.file._runner_template,
        output = runner_script,
        substitutions = {
            "%{CONFIG_RLOCATION}": config_rlocation,
            "%{DEST_PATH}": dest_path,
            "%{DNF5_RLOCATION}": dnf5_rlocation,
            "%{RPM_RLOCATION}": rpm_rlocation,
            "%{RUN_ARGS}": " ".join(run_args),
            "%{TOOL_RLOCATION}": tool_rlocation,
        },
        is_executable = True,
    )

    runfiles_files = [ctx.file.config, out]
    runfiles = ctx.runfiles(
        files = runfiles_files,
        transitive_files = depset(transitive = transitive_inputs),
    ).merge(ctx.attr._runfiles_lib[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            files = depset([out]),
            executable = runner_script,
            runfiles = runfiles,
        ),
    ]

dnfo_lock = rule(
    implementation = _dnfo_lock_impl,
    doc = "Generates a hermetic RPM lockfile from a dnfo YAML image definition.",
    attrs = {
        "config": attr.label(
            mandatory = True,
            allow_single_file = [".yaml", ".yml"],
            doc = "The dnfo.yaml configuration file.",
        ),
        "arch": attr.string(
            default = "x86_64",
            doc = "Target architecture.",
        ),
        "releasever": attr.string(
            doc = "Distribution release version.",
        ),
        "out": attr.output(
            doc = "Output lockfile name.",
        ),
        "_runner_template": attr.label(
            default = Label("//dnfo/private:lock_runner.sh.tpl"),
            allow_single_file = True,
        ),
        "_runfiles_lib": attr.label(
            default = Label("@bazel_tools//tools/bash/runfiles"),
        ),
    },
    executable = True,
    toolchains = [
        Label(DNFO_TOOLCHAIN_TYPE),
        config_common.toolchain_type(Label(DNF5_TOOLCHAIN_TYPE), mandatory = False),
    ],
)
