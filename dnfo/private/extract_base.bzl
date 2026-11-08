"""Rule to extract rpmdb.sqlite and repository configs from base container image layers."""

load("@rules_img//img:providers.bzl", "ImageIndexInfo", "ImageManifestInfo")

def _dnfo_extract_base_impl(ctx):
    out_rpmdb = ctx.outputs.out_rpmdb
    out_repos = ctx.outputs.out_repos

    # Collect layer blobs from image
    layers = []
    if ImageManifestInfo in ctx.attr.image:
        manifest_info = ctx.attr.image[ImageManifestInfo]
        for layer in manifest_info.layers:
            blob = getattr(layer, "blob", None) or getattr(layer, "generated_blob", None)
            if blob:
                layers.append(blob)
    elif ImageIndexInfo in ctx.attr.image:
        index_info = ctx.attr.image[ImageIndexInfo]
        target_manifest = None
        for m in index_info.manifests:
            if m.architecture == ctx.attr.architecture:
                target_manifest = m
                break
        if not target_manifest and len(index_info.manifests) > 0:
            target_manifest = index_info.manifests[0]
        if target_manifest:
            for layer in target_manifest.layers:
                blob = getattr(layer, "blob", None) or getattr(layer, "generated_blob", None)
                if blob:
                    layers.append(blob)
    else:
        # Fallback to files in DefaultInfo
        for f in ctx.attr.image[DefaultInfo].files.to_list():
            if f.extension in ("tar", "gz", "tgz", "zst", "cstream"):
                layers.append(f)

    args = ctx.actions.args()
    args.add("--output-rpmdb=" + out_rpmdb.path)
    args.add("--output-repos=" + out_repos.path)
    for layer in layers:
        args.add("--layer=" + layer.path)

    ctx.actions.run(
        inputs = depset(layers),
        outputs = [out_rpmdb, out_repos],
        executable = ctx.executable._tool,
        arguments = [args],
        mnemonic = "DnfoExtractBase",
        progress_message = "Extracting base rpmdb and repos from %{label}",
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(files = depset([out_rpmdb, out_repos])),
    ]

dnfo_extract_base = rule(
    implementation = _dnfo_extract_base_impl,
    attrs = {
        "image": attr.label(
            mandatory = True,
            doc = "The base container image target (rules_img or dnfo_image).",
        ),
        "out_rpmdb": attr.output(
            mandatory = True,
            doc = "Output file for extracted rpmdb.sqlite.",
        ),
        "out_repos": attr.output(
            mandatory = True,
            doc = "Output file for extracted base.repo.",
        ),
        "architecture": attr.string(
            default = "x86_64",
            doc = "Target architecture when resolving multi-platform image indexes.",
        ),
        "_tool": attr.label(
            default = Label("//dnfo/private:extract_base_bin"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Extracts rpmdb.sqlite and base.repo from a base container image.",
)
