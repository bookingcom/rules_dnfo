"""Aspect Gazelle Orion extension for generating dnfo_image targets."""

aspect.gazelle_rule_kind("dnfo_image", {
    "From": "@rules_dnfo//dnfo:defs.bzl",
    "MergeableAttrs": [
        "lock_only",
        "packages",
        "repositories",
        "entrypoint",
        "cmd",
        "workdir",
        "env",
        "accounts",
        "architecture",
        "base",
        "include_skeleton",
    ],
})

_DNFO_GLOBS = [
    "*dnfo*.yaml",
    "*dnfo*.yml",
]

def _lockfile_for(config_name):
    if config_name.endswith(".yaml"):
        return config_name[:-len(".yaml")] + ".lock.json"
    if config_name.endswith(".yml"):
        return config_name[:-len(".yml")] + ".lock.json"
    return config_name + ".lock.json"

def _target_name(rel, config_name, total_files):
    base = rel.split("/")[-1] if rel else "image"
    if total_files <= 1 and config_name in ("dnfo.yaml", "dnfo.yml"):
        return base
    stem = config_name
    if stem.endswith(".yaml"):
        stem = stem[:-len(".yaml")]
    elif stem.endswith(".yml"):
        stem = stem[:-len(".yml")]
    if stem == "dnfo":
        return base
    return stem.replace(".", "_").replace("-", "_")

def _prepare(cfg):
    return aspect.PrepareResult(
        sources = [aspect.SourceGlobs(*_DNFO_GLOBS)],
        queries = {
            "dnfo_yaml": aspect.YamlQuery(
                query = ".",
                filter = _DNFO_GLOBS,
            ),
        },
    )

def _declare(ctx):
    if not ctx.sources:
        return
    total_files = len(ctx.sources)
    for s in ctx.sources:
        results = s.query_results["dnfo_yaml"]
        if not results:
            continue
        data = results[0]
        if type(data) != "dict":
            continue

        config_name = s.path.split("/")[-1] if "/" in s.path else s.path
        lockfile_name = _lockfile_for(config_name)
        has_lock = ctx.has_file(lockfile_name)
        name = _target_name(ctx.rel, config_name, total_files)

        attrs = {
            "config": config_name,
        }

        # Contents: packages and repositories
        contents = data.get("contents")
        if contents and type(contents) == "dict":
            pkgs = contents.get("packages")
            if pkgs and type(pkgs) == "list":
                attrs["packages"] = pkgs
            repos = contents.get("repositories")
            if repos and type(repos) == "list":
                attrs["repositories"] = repos

        # Architectures
        archs = data.get("archs")
        if archs and type(archs) == "list" and len(archs) > 0:
            if archs[0] != "x86_64":
                attrs["architecture"] = archs[0]

        # Entrypoint
        ep = data.get("entrypoint")
        if ep:
            if type(ep) == "dict" and "command" in ep:
                ep_list = [ep["command"]]
                if "args" in ep and type(ep["args"]) == "list":
                    ep_list.extend(ep["args"])
                attrs["entrypoint"] = ep_list
            elif type(ep) == "list":
                attrs["entrypoint"] = ep
            elif type(ep) == "string":
                attrs["entrypoint"] = [ep]

        # Cmd
        cmd = data.get("cmd")
        if cmd:
            if type(cmd) == "list":
                attrs["cmd"] = cmd
            elif type(cmd) == "string":
                attrs["cmd"] = [cmd]

        # WorkDir
        wd = data.get("work-dir")
        if wd:
            attrs["workdir"] = wd

        # Environment
        env = data.get("environment")
        if env and type(env) == "dict":
            attrs["env"] = env

        # Accounts
        acc = data.get("accounts")
        if acc and type(acc) == "dict":
            attrs["accounts"] = acc

        # Base image
        base = data.get("base")
        if base and type(base) == "string":
            attrs["base"] = base

        # Include skeleton override
        inc_skel = data.get("include_skeleton", data.get("include-skeleton"))
        if inc_skel != None and type(inc_skel) == "bool":
            attrs["include_skeleton"] = inc_skel

        if has_lock:
            attrs["lock_only"] = False
            pkg_prefix = "//" + ctx.rel if ctx.rel else "//"
            repo_name = name + "_packages"
            print(
                "\n[gazelle-dnfo] Lockfile found for %s:%s (%s/%s).\n" % (pkg_prefix, name, ctx.rel or ".", lockfile_name) +
                "Ensure the following is present in your MODULE.bazel:\n\n" +
                'dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")\n' +
                "dnfo.lock(\n" +
                '    name = "%s",\n' % repo_name +
                '    lockfile = "%s:%s",\n' % (pkg_prefix, lockfile_name) +
                ")\n" +
                'use_repo(dnfo, "%s")\n' % repo_name,
            )
        else:
            attrs["lock_only"] = True
            pkg_prefix = "//" + ctx.rel if ctx.rel else "//"
            print(
                "\n[gazelle-dnfo] No lockfile found for %s:%s (expected %s).\n" % (pkg_prefix, name, lockfile_name) +
                "Generated skeleton with lock_only = True.\n" +
                "Next steps:\n" +
                "  Step 2: bazel run %s:%s.lock\n" % (pkg_prefix, name) +
                "  Step 3: bazel run //:gazelle\n",
            )

        ctx.targets.add(
            kind = "dnfo_image",
            name = name,
            attrs = attrs,
        )

aspect.orion_extension(
    id = "gazelle-dnfo",
    prepare = _prepare,
    declare = _declare,
)
