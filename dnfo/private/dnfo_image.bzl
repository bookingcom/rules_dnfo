"""Public macro implementation for dnfo_image."""

load("@bazel_lib//lib:write_source_files.bzl", "write_source_file")
load("@dnf5-prebuilt//dnf5-prebuilt:defs.bzl", "dnf_config", "rpm_layer", "rpm_lock", "rpm_mark")
load(
    "@rules_img//img:base_images.bzl",
    "base_image_layer",
    "etc_passwd",
    "group_entry",
    "linux_skeleton",
    "passwd_entry",
)
load("@rules_img//img:image.bzl", "image_manifest")
load("@rules_img//img:layer.bzl", "layer_from_tar")
load("@rules_img//img:load.bzl", "image_load")
load("@rules_containers_util//containers:defs.bzl", "image_extract")

def _dnfo_repo_configs_impl(ctx):
    repositories = json.decode(ctx.attr.repositories_json)
    outs = []
    for i, r in enumerate(repositories):
        repo_id = r.get("id", "repo_%d" % i)
        repo_name = r.get("name", repo_id)
        lines = [
            "[%s]" % repo_id,
            "name=%s" % repo_name,
        ]
        if r.get("baseurl"):
            lines.append("baseurl=%s" % r["baseurl"])
        if r.get("metalink"):
            lines.append("metalink=%s" % r["metalink"])
        if r.get("mirrorlist"):
            lines.append("mirrorlist=%s" % r["mirrorlist"])
        if "gpgcheck" in r:
            lines.append("gpgcheck=%s" % r["gpgcheck"])
        elif r.get("gpgkey"):
            lines.append("gpgcheck=1")
        else:
            lines.append("gpgcheck=0")
        if r.get("gpgkey"):
            lines.append("gpgkey=%s" % r["gpgkey"])
        if "enabled" in r:
            lines.append("enabled=%s" % r["enabled"])
        else:
            lines.append("enabled=1")

        f = ctx.actions.declare_file("%s/%s.repo" % (ctx.label.name, repo_id))
        ctx.actions.write(f, "\n".join(lines) + "\n")
        outs.append(f)

    return [DefaultInfo(files = depset(outs))]

_dnfo_repo_configs = rule(
    implementation = _dnfo_repo_configs_impl,
    attrs = {
        "repositories_json": attr.string(
            mandatory = True,
            doc = "JSON-encoded list of repository definition dicts.",
        ),
    },
    doc = "Renders .repo configuration files from declarative repository dicts.",
)

def dnfo_image(
        name,
        config = "dnfo.yaml",
        packages = [],
        repositories = [],
        releasever = "10",
        install_weak_deps = False,
        contents = None,
        architecture = "x86_64",
        lock_only = False,
        tag = "",
        entrypoint = None,
        cmd = None,
        workdir = None,
        env = {},
        accounts = {},
        gpgcheck = True,
        keyring = [],
        base = None,
        base_rpmdb = None,
        base_rpmdb_file = None,
        base_repos = None,
        base_repo_file = None,
        include_skeleton = None,
        **kwargs):
    """Builds an OCI container image from RPM packages declared in a dnfo YAML specification.

    1. Renders .repo configuration files and a dnf_config, then creates a companion locking target
       (<name>.lock) and diff test (<name>.lock_test) via rpm_lock and write_source_file.
    2. When lock_only = True (Phase 1, before the lockfile exists on disk), stops after creating
       the lock targets so that `bazel run //<pkg>:<name>.lock` can generate the initial lockfile.
    3. When lock_only = False (Phase 3, once the lockfile exists), initializes rpmdb with rpm_mark
       and assembles RPM packages into a deduplicated layer tarball with rpmdb injected via rpm_layer
       (which also performs GPG signature verification when keyring is provided).
    4. Conditionally creates base image layer (linux_skeleton and etc_passwd) unless a base image
       is provided or 'filesystem' RPM is included (can be overridden via include_skeleton).
    5. Sets entrypoint, cmd, workdir, env using rules_img.
    6. Creates a target to load into local Docker (<name>_load and alias 'load') with canonical tags.

    Args:
      name: Target name for the generated container image.
      config: YAML configuration file (dnfo.yaml).
      packages: List of RPM package names to install.
      repositories: List of repository dicts.
      releasever: OS release version (default "10").
      install_weak_deps: Whether to install weak dependencies (default False).
      contents: Optional label to pre-resolved packages repo.
      architecture: Target CPU architecture (default "x86_64").
      lock_only: Phase 1 flag; if True, only generates locking targets.
      tag: Image tag (default "<name>:latest").
      entrypoint: List of entrypoint command arguments.
      cmd: List of default command arguments.
      workdir: Working directory inside the container.
      env: Environment variable dictionary.
      accounts: User and group account definitions.
      gpgcheck: Whether to verify package GPG signatures.
      keyring: GPG key URLs or labels.
      base: Optional base container image target to inherit layers and configs from.
      base_rpmdb: Optional base rpmdb.sqlite file/target to mark packages on top of and solve against.
      base_repos: Optional base repository configs target(s) inherited from parent or base image.
      include_skeleton: Optional boolean to explicitly force or omit the linux_skeleton
          directory layer. When None (default), skeleton is automatically omitted if base
          is provided or if 'filesystem' is in packages.
      **kwargs: Additional arguments forwarded to rules_img.
    """
    visibility = kwargs.get("visibility", ["//visibility:public"])

    # 1. Base image extraction (using rules_containers_util image_extract for base images)
    extracted_repos = None
    if base and not base_rpmdb:
        extract_rpmdb_name = name + "_base_rpmdb"
        platform_str = "linux/amd64" if architecture == "x86_64" else ("linux/arm64" if architecture == "aarch64" else None)
        image_extract(
            name = extract_rpmdb_name,
            file = base_rpmdb_file or "/usr/lib/sysimage/rpm/rpmdb.sqlite",
            image = base,
            out = name + "_base_rpmdb.sqlite",
            platform = platform_str,
            visibility = ["//visibility:private"],
        )
        base_rpmdb = ":" + extract_rpmdb_name

    if base and base_repo_file:
        extract_repo_name = name + "_base_repo"
        platform_str = "linux/amd64" if architecture == "x86_64" else ("linux/arm64" if architecture == "aarch64" else None)
        image_extract(
            name = extract_repo_name,
            file = base_repo_file,
            image = base,
            out = name + "_base.repo",
            platform = platform_str,
            visibility = ["//visibility:private"],
        )
        extracted_repos = ":" + extract_repo_name

    # 2. Repository configs, dnf_config, and rpm_lock generation via dnf5-prebuilt
    lockfile_name = config.rsplit(".", 1)[0] + ".lock.json" if "." in config else (config + ".lock.json")
    arch_list = [architecture, "noarch"] if architecture != "noarch" else ["noarch"]

    all_keyrings = list(keyring)
    repo_configs = []
    dict_repos = []
    if type(repositories) == "list":
        for r in repositories:
            if type(r) == "string":
                repo_configs.append(r)
            elif type(r) == "dict":
                dict_repos.append(r)
                k = r.get("gpgkey")
                if k and (k.startswith("@") or k.startswith("//") or k.startswith(":")):
                    if k not in all_keyrings:
                        all_keyrings.append(k)

    if dict_repos:
        _dnfo_repo_configs(
            name = name + "_repos",
            repositories_json = json.encode(dict_repos),
            visibility = visibility,
        )
        repo_configs.append(":" + name + "_repos")

    if base_repos:
        if type(base_repos) == "list":
            repo_configs.extend(base_repos)
        else:
            repo_configs.append(base_repos)

    if extracted_repos:
        repo_configs.append(extracted_repos)

    if repo_configs and packages:
        dnf_config(
            name = name + "_dnf_config",
            arch = arch_list,
            install_weak_deps = install_weak_deps,
            releasever = releasever,
            repo_configs = repo_configs,
            visibility = ["//visibility:private"],
        )

        rpm_lock(
            name = name + "_generated_lock",
            arch = arch_list,
            base_rpmdb = base_rpmdb,
            config = ":" + name + "_dnf_config",
            packages = packages,
            tags = ["no-remote-cache", "no-remote-exec", "requires-network"],
            visibility = ["//visibility:private"],
        )

        write_source_file(
            name = name + ".lock",
            in_file = ":" + name + "_generated_lock",
            out_file = lockfile_name,
            tags = ["no-remote-cache", "no-remote-exec", "requires-network"],
            visibility = visibility,
        )

    if lock_only:
        return

    # 3. RPMDB and RPMs layer via dnf5-prebuilt
    rpms_label = contents if contents else ("@" + name + "_packages//:rpms")
    rpm_mark(
        name = name + "_rpmdb",
        base_rpmdb = base_rpmdb,
        rpms = [rpms_label],
        visibility = visibility,
    )

    rpm_layer(
        name = name + "_rpms_tar",
        rpms = [rpms_label],
        rpmdb = ":" + name + "_rpmdb",
        gpgcheck = gpgcheck and bool(all_keyrings),
        gpgkeys = all_keyrings,
        visibility = ["//visibility:private"],
    )

    layer_from_tar(
        name = name + "_rpms_layer",
        src = ":" + name + "_rpms_tar",
        visibility = ["//visibility:private"],
    )

    # 3. Base image layer with accounts (conditionally generated)
    has_filesystem = ("filesystem" in packages) if packages else False
    need_skeleton = include_skeleton if include_skeleton != None else (not bool(base) and not has_filesystem)
    need_accounts = bool(accounts) or (need_skeleton and not bool(base))

    base_layer_srcs = []
    if need_skeleton:
        linux_skeleton(
            name = name + "_skeleton",
            visibility = ["//visibility:private"],
        )
        base_layer_srcs.append(":" + name + "_skeleton")

    if need_accounts:
        user_entries = [
            passwd_entry(username = "root", uid = 0, gid = 0, home = "/root", shell = "/bin/bash"),
        ]
        group_entries = [
            group_entry(name = "root", gid = 0),
        ]

        users_list = accounts.get("users", []) if accounts else []
        for u in users_list:
            uname = u.get("username", "")
            if uname and uname != "root":
                uid = u.get("uid", 1000)
                gid = u.get("gid", 1000)
                home = u.get("home", "/home/" + uname)
                shell = u.get("shell", "/bin/bash")
                user_entries.append(passwd_entry(username = uname, uid = uid, gid = gid, home = home, shell = shell))

        groups_list = accounts.get("groups", []) if accounts else []
        for g in groups_list:
            gname = g.get("groupname", g.get("name", ""))
            if gname and gname != "root":
                gid = g.get("gid", 1000)
                group_entries.append(group_entry(name = gname, gid = gid))

        etc_passwd(
            name = name + "_passwd",
            users = user_entries,
            groups = group_entries,
            visibility = ["//visibility:private"],
        )
        base_layer_srcs.append(":" + name + "_passwd")

    layers = [":" + name + "_rpms_layer"]
    if base_layer_srcs:
        base_image_layer(
            name = name + "_base_layer",
            srcs = base_layer_srcs,
            visibility = ["//visibility:private"],
        )
        layers.append(":" + name + "_base_layer")

    # 4. Container image manifest
    ep = entrypoint if entrypoint != None else ["/bin/bash"]
    c = cmd if cmd != None else ["-l"]
    wd = workdir if workdir != None else "/home"

    manifest_kwargs = {}
    if base:
        manifest_kwargs["base"] = base

    image_manifest(
        name = name,
        layers = layers,
        entrypoint = ep,
        cmd = c,
        working_dir = wd,
        env = env,
        visibility = visibility,
        **manifest_kwargs
    )

    # 5. Local Docker load target
    load_tag = tag if tag else (name + ":latest")
    image_load(
        name = name + "_load",
        image = ":" + name,
        tag_list = [
            load_tag,
            "docker.io/library/" + load_tag,
        ],
        visibility = visibility,
    )
