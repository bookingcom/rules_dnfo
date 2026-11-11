"""Aspect Gazelle Orion extension for generating dnfo_image targets."""

aspect.gazelle_rule_kind("dnfo_image", {
    "From": "@rules_dnfo//dnfo:defs.bzl",
    "MergeableAttrs": [
        "lock_only",
        "packages",
        "repositories",
        "keyring",
        "entrypoint",
        "cmd",
        "workdir",
        "user",
        "stop_signal",
        "labels",
        "annotations",
        "env",
        "accounts",
        "architecture",
        "archs",
        "base",
        "base_rpmdb",
        "base_rpmdb_file",
        "base_repos",
        "base_repo_file",
        "include_skeleton",
        "files",
        "exclude_patterns",
        "exclude_paths",
        "exclude_docs",
        "exclude_man",
        "exclude_licenses",
        "exclude_build_id",
        "install_langs",
        "locale",
        "certificates",
    ],
})

_DNFO_GLOBS = [
    "*dnfo*.yaml",
    "*dnfo*.yml",
]

def _normalize_arch(arch):
    a = arch.lower().strip()
    if a in ("x86_64", "x86-64", "amd64"):
        return "x86_64"
    if a in ("aarch64", "arm64", "arm64v8"):
        return "aarch64"
    if a in ("armv7", "armv7l", "armv7hl", "armhfp"):
        return "armv7hl"
    if a in ("ppc64le", "powerpc64le"):
        return "ppc64le"
    if a in ("s390x",):
        return "s390x"
    if a in ("riscv64",):
        return "riscv64"
    return a

def _lockfile_for(config_name, arch = None):
    stem = config_name
    if stem.endswith(".yaml"):
        stem = stem[:-len(".yaml")]
    elif stem.endswith(".yml"):
        stem = stem[:-len(".yml")]
    if arch:
        return stem + "." + arch + ".lock.json"
    return stem + ".lock.json"

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

def _resolve_include_label(rel, inc):
    # If already a label
    if inc.startswith("//") or inc.startswith(":"):
        if not inc.endswith(".yaml") and not inc.endswith(".yml"):
            return inc
    # If it's a repo-absolute file path (e.g. //pkg:parent.dnfo.yaml or //pkg/parent.dnfo.yaml)
    if inc.startswith("//"):
        if ":" in inc:
            pkg, fname = inc[2:].split(":", 1)
        else:
            pkg, fname = inc[2:].rsplit("/", 1)
        target = _target_name(pkg, fname, 1)
        return "//" + pkg + ":" + target

    # Relative path within same package or sub/parent package
    parts = inc.split("/")
    fname = parts[-1]
    if len(parts) == 1:
        target = _target_name(rel, fname, 1)
        return ":" + target

    rel_dir_parts = [p for p in rel.split("/") if p] if rel else []
    for p in parts[:-1]:
        if p == "." or not p:
            continue
        elif p == "..":
            if rel_dir_parts:
                rel_dir_parts.pop()
        else:
            rel_dir_parts.append(p)
    target_pkg = "/".join(rel_dir_parts)
    target = _target_name(target_pkg, fname, 1)
    if target_pkg:
        return "//" + target_pkg + ":" + target
    else:
        return "//:" + target

def _resolve_file_label(rel, src):
    if not src:
        return src

    # If already a label
    if src.startswith("@") or src.startswith("//") or src.startswith(":"):
        return src

    if src.startswith("./"):
        src = src[2:]

    # If it has path traversal ../
    if src.startswith("../") or "/../" in src:
        parts = src.split("/")
        fname = parts[-1]
        rel_dir_parts = [p for p in rel.split("/") if p] if rel else []
        for p in parts[:-1]:
            if p == "." or not p:
                continue
            elif p == "..":
                if rel_dir_parts:
                    rel_dir_parts.pop()
            else:
                rel_dir_parts.append(p)
        target_pkg = "/".join(rel_dir_parts)
        if target_pkg:
            return "//" + target_pkg + ":" + fname
        else:
            return "//:" + fname

    # Simple file or subpath within current package
    return ":" + src

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
        name = _target_name(ctx.rel, config_name, total_files)

        attrs = {
            "config": config_name,
        }

        # Apko-style file inheritance (include: <path>)
        include = data.get("include")
        if include:
            inc_list = include if type(include) == "list" else [include]
            for inc in inc_list:
                if type(inc) != "string":
                    continue
                parent_target = _resolve_include_label(ctx.rel, inc)
                attrs["base"] = parent_target
                attrs["base_rpmdb"] = parent_target + "_rpmdb"
                attrs["base_repos"] = parent_target + "_repos"

        # Contents: packages and repositories
        pkgs = None
        contents = data.get("contents")
        if contents and type(contents) == "dict":
            pkgs = contents.get("packages")
            if pkgs and type(pkgs) == "list":
                attrs["packages"] = pkgs
            repos = contents.get("repositories")
            if repos and type(repos) == "list":
                attrs["repositories"] = repos
            kr = contents.get("keyring")
            if kr and type(kr) == "list":
                attrs["keyring"] = kr

        # Architectures
        raw_archs = data.get("archs")
        if not raw_archs:
            raw_archs = data.get("architectures")

        norm_archs = []
        if raw_archs:
            if type(raw_archs) == "list":
                for a in raw_archs:
                    na = _normalize_arch(str(a))
                    if na not in norm_archs:
                        norm_archs.append(na)
            elif type(raw_archs) == "string":
                norm_archs.append(_normalize_arch(str(raw_archs)))

        if norm_archs:
            attrs["archs"] = norm_archs

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

        # User (process execution user)
        user = data.get("user")
        if user == None:
            user = data.get("run-as", data.get("run_as"))
        if user == None and acc:
            user = acc.get("run-as", acc.get("run_as", acc.get("user")))
        if user != None:
            attrs["user"] = str(user)

        # Stop Signal
        stop_sig = data.get("stop-signal", data.get("stop_signal"))
        if stop_sig and type(stop_sig) == "string":
            attrs["stop_signal"] = stop_sig

        # Labels
        lbls = data.get("labels")
        if lbls and type(lbls) == "dict":
            attrs["labels"] = lbls

        # Annotations
        annos = data.get("annotations")
        if annos and type(annos) == "dict":
            attrs["annotations"] = annos

        # Base image
        base = data.get("base")
        if base and type(base) == "string":
            if base.startswith("//") or base.startswith(":"):
                attrs["base"] = base
            elif base.startswith("@"):
                attrs["base"] = base
            elif "/" in base or ":" in base:
                fail(
                    ("Base image '%s' in %s is invalid. " % (base, s.path)) +
                    "External base images must be pulled via rules_img in MODULE.bazel. " +
                    "Please pull the image in MODULE.bazel using rules_img (e.g. images.pull(name = \"%s\", ...)) " % base.split("/")[0] +
                    "and reference it here using base: <image_name>."
                )
            else:
                attrs["base"] = "@" + base + "//:image"
                pkg_prefix = "//" + ctx.rel if ctx.rel else "//"
                print(
                    "\n[gazelle-dnfo] External base image '%s' declared for %s:%s.\n" % (base, pkg_prefix, name) +
                    "Ensure it is pulled via rules_img in your MODULE.bazel:\n\n" +
                    'images = use_extension("@rules_img//img:extensions.bzl", "images")\n' +
                    'images.pull(\n' +
                    '    name = "%s",\n' % base +
                    '    digest = "...",\n' +
                    '    repository = "...",\n' +
                    ')\n' +
                    'use_repo(images, "%s")\n' % base,
                )

        base_rpmdb = data.get("base_rpmdb", data.get("base-rpmdb"))
        if base_rpmdb and type(base_rpmdb) == "string":
            attrs["base_rpmdb"] = base_rpmdb

        base_rpmdb_file = data.get("base_rpmdb_file", data.get("base-rpmdb-file"))
        if base_rpmdb_file and type(base_rpmdb_file) == "string":
            attrs["base_rpmdb_file"] = base_rpmdb_file

        base_repos = data.get("base_repos", data.get("base-repos"))
        if base_repos and type(base_repos) == "string":
            attrs["base_repos"] = base_repos

        base_repo_file = data.get("base_repo_file", data.get("base-repo-file"))
        if base_repo_file and type(base_repo_file) == "string":
            attrs["base_repo_file"] = base_repo_file

        # Include skeleton override
        inc_skel = data.get("include_skeleton", data.get("include-skeleton"))
        if inc_skel != None and type(inc_skel) == "bool":
            attrs["include_skeleton"] = inc_skel

        # Exclude patterns and paths
        raw_excludes = []
        for k in ["exclude_patterns", "exclude-patterns", "exclude_paths", "exclude-paths", "exclude", "excludes"]:
            v = data.get(k)
            if not v and contents and type(contents) == "dict":
                v = contents.get(k)
            if v:
                if type(v) == "list":
                    for item in v:
                        if item not in raw_excludes:
                            raw_excludes.append(item)
                elif type(v) == "string":
                    if v not in raw_excludes:
                        raw_excludes.append(v)

        if raw_excludes:
            attrs["exclude_patterns"] = raw_excludes

        # Exclude boolean flags
        for flag in ["exclude_docs", "exclude_man", "exclude_licenses", "exclude_build_id"]:
            k_kebab = flag.replace("_", "-")
            val = data.get(flag, data.get(k_kebab))
            if val == None and contents and type(contents) == "dict":
                val = contents.get(flag, contents.get(k_kebab))
            if val != None and type(val) == "bool":
                attrs[flag] = val

        # Locale and language configuration
        loc = data.get("locale", data.get("locales"))
        if not loc:
            loc = data.get("install_langs", data.get("install-langs"))
        if not loc and contents and type(contents) == "dict":
            loc = contents.get("locale", contents.get("locales"))
            if not loc:
                loc = contents.get("install_langs", contents.get("install-langs"))

        if loc:
            attrs["locale"] = loc

        # Files installation support
        files_data = data.get("files", data.get("install"))
        if not files_data and contents and type(contents) == "dict":
            files_data = contents.get("files", contents.get("install"))

        if files_data:
            if type(files_data) == "dict":
                has_metadata = False
                for v in files_data.values():
                    if type(v) == "dict":
                        has_metadata = True
                        break

                if not has_metadata:
                    files_dict = {}
                    for path, src in files_data.items():
                        if type(src) == "string":
                            p = path if path.startswith("/") else ("/" + path)
                            files_dict[p] = _resolve_file_label(ctx.rel, src)
                    if files_dict:
                        attrs["files"] = files_dict
                else:
                    files_dict = {}
                    for path, item in files_data.items():
                        p = path if path.startswith("/") else ("/" + path)
                        if type(item) == "string":
                            files_dict[p] = _resolve_file_label(ctx.rel, item)
                        elif type(item) == "dict":
                            src = item.get("source", item.get("src"))
                            entry = {"source": _resolve_file_label(ctx.rel, src)}
                            for k in ["mode", "uid", "gid", "uname", "gname", "mtime", "permissions"]:
                                if k in item:
                                    entry[k] = item[k]
                            files_dict[p] = entry
                    if files_dict:
                        attrs["files"] = files_dict

            elif type(files_data) == "list":
                has_metadata = False
                for item in files_data:
                    if type(item) == "dict":
                        for k in ["mode", "uid", "gid", "uname", "gname", "mtime", "permissions"]:
                            if k in item:
                                has_metadata = True
                                break

                if not has_metadata:
                    files_dict = {}
                    for item in files_data:
                        if type(item) == "dict":
                            dest = item.get("path", item.get("destination", item.get("dest")))
                            src = item.get("source", item.get("src"))
                            if dest and src:
                                p = dest if dest.startswith("/") else ("/" + dest)
                                files_dict[p] = _resolve_file_label(ctx.rel, src)
                    if files_dict:
                        attrs["files"] = files_dict
                else:
                    files_list = []
                    for item in files_data:
                        if type(item) == "dict":
                            dest = item.get("path", item.get("destination", item.get("dest")))
                            src = item.get("source", item.get("src"))
                            if dest and src:
                                p = dest if dest.startswith("/") else ("/" + dest)
                                entry = {
                                    "path": p,
                                    "source": _resolve_file_label(ctx.rel, src),
                                }
                                for k in ["mode", "uid", "gid", "uname", "gname", "mtime", "permissions"]:
                                    if k in item:
                                        entry[k] = item[k]
                                files_list.append(entry)
                    if files_list:
                        attrs["files"] = files_list

        # Certificates support
        certs_data = data.get("certificates")
        if certs_data != None:
            if type(certs_data) == "dict":
                certs_dict = dict(certs_data)
                if "additional" in certs_dict and type(certs_dict["additional"]) == "list":
                    new_additional = []
                    for item in certs_dict["additional"]:
                        if type(item) == "dict":
                            new_item = dict(item)
                            src = new_item.get("source", new_item.get("src"))
                            if src:
                                new_item["source"] = _resolve_file_label(ctx.rel, src)
                                if "src" in new_item:
                                    new_item.pop("src")
                            new_additional.append(new_item)
                        elif type(item) == "string":
                            new_additional.append({"source": _resolve_file_label(ctx.rel, item)})
                    certs_dict["additional"] = new_additional
                attrs["certificates"] = certs_dict
            elif type(certs_data) == "list":
                attrs["certificates"] = certs_data

        # Lockfile check
        has_lock = False
        if not pkgs:
            has_lock = True
        elif norm_archs and len(norm_archs) > 1:
            all_exist = True
            for a in norm_archs:
                lf = _lockfile_for(config_name, a)
                if not ctx.has_file(lf):
                    all_exist = False
                    break
            has_lock = all_exist
        else:
            lockfile_name = _lockfile_for(config_name)
            has_lock = ctx.has_file(lockfile_name)

        if not pkgs:
            attrs["lock_only"] = False
        elif has_lock:
            attrs["lock_only"] = False
            pkg_prefix = "//" + ctx.rel if ctx.rel else "//"
            if norm_archs and len(norm_archs) > 1:
                lock_lines = []
                repo_names = []
                for a in norm_archs:
                    rname = "%s_%s_packages" % (name, a)
                    lf = _lockfile_for(config_name, a)
                    repo_names.append('"%s"' % rname)
                    lock_lines.append(
                        'dnfo.lock(\n    name = "%s",\n    lockfile = "%s:%s",\n)' % (rname, pkg_prefix, lf)
                    )
                if ctx.properties["dnfo_lock_hint"]:
                    print(
                        ("\n[gazelle-dnfo] Multi-arch lockfiles found for %s:%s.\n" % (pkg_prefix, name)) +
                        "Ensure the following is present in your MODULE.bazel:\n\n" +
                        'dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")\n' +
                        "\n".join(lock_lines) + "\n" +
                        ("use_repo(dnfo, %s)\n" % ", ".join(repo_names))
                    )
            else:
                lf = _lockfile_for(config_name)
                repo_name = name + "_packages"
                if ctx.properties["dnfo_lock_hint"]:
                    print(
                        "\n[gazelle-dnfo] Lockfile found for %s:%s (%s/%s).\n" % (pkg_prefix, name, ctx.rel or ".", lf) +
                        "Ensure the following is present in your MODULE.bazel:\n\n" +
                        'dnfo = use_extension("@rules_dnfo//dnfo:extensions.bzl", "dnfo")\n' +
                        "dnfo.lock(\n" +
                        '    name = "%s",\n' % repo_name +
                        '    lockfile = "%s:%s",\n' % (pkg_prefix, lf) +
                        ")\n" +
                        'use_repo(dnfo, "%s")\n' % repo_name,
                    )
        else:
            attrs["lock_only"] = True
            pkg_prefix = "//" + ctx.rel if ctx.rel else "//"
            print(
                "\n[gazelle-dnfo] Lockfile(s) missing for %s:%s.\n" % (pkg_prefix, name) +
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
    properties = {
        "dnfo_lock_hint": aspect.Property(type = "bool", default = True),
    },
)
