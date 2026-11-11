"""Rule to extract and filter CA certificates from PKI directories or bundles."""

def _p11_kit_extract_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".pem")

    args = ctx.actions.args()
    args.add("--output", out.path)
    args.add("--purpose", ctx.attr.purpose)
    for src in ctx.files.srcs:
        args.add("--input", src.path)

    ctx.actions.run(
        mnemonic = "P11KitExtract",
        progress_message = "Extracting CA certificates for %s (%s)" % (ctx.label, ctx.attr.purpose),
        executable = ctx.executable._extractor_tool,
        arguments = [args],
        inputs = ctx.files.srcs,
        outputs = [out],
    )
    return [DefaultInfo(files = depset([out]))]

p11_kit_extract = rule(
    implementation = _p11_kit_extract_impl,
    doc = "Extracts CA certificates from extracted directories or bundle files filtered by purpose.",
    attrs = {
        "purpose": attr.string(
            default = "server-auth",
            doc = "Certificate purpose filter ('server-auth', 'email', 'code-signing').",
        ),
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Extracted PKI directories or bundle files to extract CA certificates from.",
        ),
        "_extractor_tool": attr.label(
            default = Label("//dnfo/private:p11_kit_extract_bin"),
            executable = True,
            cfg = "exec",
        ),
    },
)
