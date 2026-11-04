"""Module extension fetching prebuilt dnfo distributions or building from source, and translating locks."""

load("//dnfo/private:platforms.bzl", "PLATFORMS")
load("//dnfo/private:repositories.bzl", "dnfo_dist_repository", "dnfo_toolchains_repository")
load("//dnfo/private:translate_lock.bzl", _translate_lock = "translate_lock")
load("//dnfo/private:versions.bzl", "INTEGRITY", "RELEASE_URL_TEMPLATE", "VERSION")

_toolchains = tag_class(
    doc = "Declares dnfo toolchains.",
    attrs = {
        "name": attr.string(
            default = "dnfo",
            doc = "Base name of generated repositories.",
        ),
        "from_source": attr.bool(
            default = False,
            doc = "Whether to build dnfo from source (opt-in). Requires rules_go.",
        ),
    },
)

_translate_lock_tag = tag_class(
    doc = "Translates a dnfo.lock.json lockfile into external RPM repositories.",
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the generated contents repository.",
        ),
        "lock": attr.label(
            mandatory = True,
            doc = "Label pointing to the dnfo.lock.json file.",
        ),
    },
)

def _dnfo_extension_impl(mctx):
    local_dir = mctx.getenv("DNFO_DIST_DIR")
    from_source = False
    name = "dnfo"

    # Process toolchain tags
    for mod in mctx.modules:
        for tag in mod.tags.toolchains:
            if tag.name:
                name = tag.name
            if mod.is_root and tag.from_source:
                from_source = True

        # Process translate_lock tags
        for tag in mod.tags.translate_lock:
            _translate_lock(
                name = tag.name,
                lock = tag.lock,
                target_name = tag.name,
            )

    if from_source:
        dnfo_toolchains_repository(
            name = name + "_toolchains",
            from_source = True,
            platforms = [],
            dist_repos = {},
        )
        return mctx.extension_metadata(reproducible = True)

    dist_repos = {}
    for platform in PLATFORMS:
        repo = "%s_%s" % (name, platform)
        if local_dir:
            urls = ["file://%s/dnfo-%s-%s.tar.gz" % (local_dir, VERSION, platform)]
            integrity = ""
        else:
            urls = [RELEASE_URL_TEMPLATE.format(
                version = VERSION,
                platform = platform,
            )]
            integrity = INTEGRITY.get(platform, "")
        dnfo_dist_repository(
            name = repo,
            urls = urls,
            integrity = integrity,
            version = VERSION,
        )
        dist_repos[platform] = repo

    dnfo_toolchains_repository(
        name = name + "_toolchains",
        dist_repos = dist_repos,
        platforms = PLATFORMS.keys(),
        from_source = False,
    )
    return mctx.extension_metadata(reproducible = not local_dir)

dnfo = module_extension(
    implementation = _dnfo_extension_impl,
    doc = "Configures dnfo toolchains and package lock translations.",
    tag_classes = {
        "toolchains": _toolchains,
        "translate_lock": _translate_lock_tag,
    },
    environ = ["DNFO_DIST_DIR"],
)
