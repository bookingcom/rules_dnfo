"""Rule to structurally verify that flattened images match unflattened image filesystems."""

load("@rules_img//img:providers.bzl", "ImageIndexInfo", "ImageManifestInfo")

def _collect_manifests(target):
    if ImageIndexInfo in target:
        return target[ImageIndexInfo].manifests
    if ImageManifestInfo in target:
        return [target[ImageManifestInfo]]
    fail("Target %s must provide ImageManifestInfo or ImageIndexInfo" % target.label)

def _image_structure_test_impl(ctx):
    flat_manifests = _collect_manifests(ctx.attr.flattened)
    unflat_manifests = _collect_manifests(ctx.attr.unflattened)

    unflat_by_platform = {}
    for m in unflat_manifests:
        plat = "%s/%s" % (m.os, m.architecture)
        unflat_by_platform[plat] = m

    all_inputs = []
    pairs = []

    for fm in flat_manifests:
        plat = "%s/%s" % (fm.os, fm.architecture)
        if plat not in unflat_by_platform:
            fail("Platform %s present in flattened target %s but missing from unflattened target %s" % (
                plat,
                ctx.attr.flattened.label,
                ctx.attr.unflattened.label,
            ))
        um = unflat_by_platform[plat]

        f_blobs = [l.blob for l in fm.layers if l.blob != None]
        u_blobs = [l.blob for l in um.layers if l.blob != None]

        all_inputs.extend(f_blobs)
        all_inputs.extend(u_blobs)

        pairs.append({
            "platform": plat,
            "flattened": [b.short_path for b in f_blobs],
            "unflattened": [b.short_path for b in u_blobs],
        })

    config_file = ctx.actions.declare_file(ctx.label.name + "_config.json")
    ctx.actions.write(
        output = config_file,
        content = json.encode_indent(pairs, indent = "  "),
    )
    all_inputs.append(config_file)

    test_script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = test_script,
        content = """#!/usr/bin/env bash
set -euo pipefail
exec "{tool}" --config "{config}"
""".format(
            tool = ctx.executable._comparator.short_path,
            config = config_file.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = all_inputs).merge(
        ctx.attr._comparator[DefaultInfo].default_runfiles,
    )

    return [
        DefaultInfo(
            executable = test_script,
            runfiles = runfiles,
        ),
    ]

image_structure_test = rule(
    implementation = _image_structure_test_impl,
    test = True,
    attrs = {
        "flattened": attr.label(
            mandatory = True,
            providers = [[ImageManifestInfo], [ImageIndexInfo]],
            doc = "Flattened container image (manifest or index).",
        ),
        "unflattened": attr.label(
            mandatory = True,
            providers = [[ImageManifestInfo], [ImageIndexInfo]],
            doc = "Unflattened container image (manifest or index).",
        ),
        "_comparator": attr.label(
            default = Label("//tests:compare_image_structure_bin"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Verifies that a flattened image has the exact same effective filesystem path structure as its unflattened counterpart.",
)
