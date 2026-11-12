"""Public macro implementation for dnfo_image."""

load("@bazel_lib//lib:expand_template.bzl", "expand_template")
load("@bazel_lib//lib:write_source_files.bzl", "write_source_file")
load("@dnf5-prebuilt//dnf5-prebuilt:defs.bzl", "dnf_config", "rpm_extract", "rpm_layer", "rpm_lock", "rpm_mark")
load(
    "@rules_img//img:base_images.bzl",
    "base_image_layer",
    "etc_passwd",
    "group_entry",
    "linux_skeleton",
    "passwd_entry",
    "trust_store",
)
load("@rules_img//img:convert.bzl", "image_flatten")
load("@rules_img//img:image.bzl", "image_index", "image_manifest")
load("@rules_img//img:layer.bzl", "image_layer", "layer_from_tar")
load("@rules_img//img:load.bzl", "image_load")
load("@rules_img//img:providers.bzl", "ImageManifestInfo", "LayersInfo")
load("@rules_containers_util//containers:defs.bzl", "image_extract")
load("@rules_multirun//:defs.bzl", "multirun")
load("//dnfo/private:p11_kit_extract.bzl", "p11_kit_extract")

def _dnfo_image_to_layer_impl(ctx):
    manifest_info = ctx.attr.image[ImageManifestInfo]
    return [
        LayersInfo(layers = manifest_info.layers),
        DefaultInfo(files = depset([l.blob for l in manifest_info.layers if l.blob != None])),
    ]

_dnfo_image_to_layer = rule(
    implementation = _dnfo_image_to_layer_impl,
    attrs = {
        "image": attr.label(
            mandatory = True,
            providers = [ImageManifestInfo],
            doc = "Image manifest target whose layers are extracted into LayersInfo.",
        ),
    },
    doc = "Converts an ImageManifestInfo target into LayersInfo for use as layers in image_manifest.",
)

def _create_image_manifest(
        target_name,
        layers,
        base = None,
        flatten_all_layers = False,
        flatten_dnfo_layers = False,
        entrypoint = None,
        cmd = None,
        working_dir = None,
        env = None,
        platform = None,
        user = None,
        stop_signal = None,
        labels = None,
        annotations = None,
        visibility = ["//visibility:public"]):
    """Helper to assemble an image manifest with optional layer flattening.

    Handles full layer flattening (flatten_all_layers) and dnfo-only layer flattening
    (flatten_dnfo_layers) on top of an optional base image.
    """
    manifest_kwargs = {}
    if platform:
        manifest_kwargs["platform"] = platform
    if user != None:
        manifest_kwargs["user"] = str(user)
    if stop_signal != None:
        manifest_kwargs["stop_signal"] = stop_signal
    if labels:
        manifest_kwargs["labels"] = labels
    if annotations:
        manifest_kwargs["annotations"] = annotations

    if flatten_all_layers or (flatten_dnfo_layers and not base):
        if base:
            manifest_kwargs["base"] = base
        image_manifest(
            name = target_name + "_unflattened",
            layers = layers,
            entrypoint = entrypoint,
            cmd = cmd,
            working_dir = working_dir,
            env = env,
            visibility = ["//visibility:private"],
            **manifest_kwargs
        )
        image_flatten(
            name = target_name,
            image = ":" + target_name + "_unflattened",
            visibility = visibility,
        )
    elif flatten_dnfo_layers and base:
        final_layers = layers
        if len(layers) > 1:
            intermediate_kwargs = {}
            if platform:
                intermediate_kwargs["platform"] = platform
            image_manifest(
                name = target_name + "_dnfo_unflattened",
                layers = layers,
                visibility = ["//visibility:private"],
                **intermediate_kwargs
            )
            image_flatten(
                name = target_name + "_dnfo_flattened",
                image = ":" + target_name + "_dnfo_unflattened",
                visibility = ["//visibility:private"],
            )
            _dnfo_image_to_layer(
                name = target_name + "_dnfo_layer",
                image = ":" + target_name + "_dnfo_flattened",
                visibility = ["//visibility:private"],
            )
            final_layers = [":" + target_name + "_dnfo_layer"]

        manifest_kwargs["base"] = base
        image_manifest(
            name = target_name,
            layers = final_layers,
            entrypoint = entrypoint,
            cmd = cmd,
            working_dir = working_dir,
            env = env,
            visibility = visibility,
            **manifest_kwargs
        )
    else:
        if base:
            manifest_kwargs["base"] = base
        image_manifest(
            name = target_name,
            layers = layers,
            entrypoint = entrypoint,
            cmd = cmd,
            working_dir = working_dir,
            env = env,
            visibility = visibility,
            **manifest_kwargs
        )

def _process_certificates(name, certificates, packages, user_file_paths):
    """Processes certificates attribute configuration.

    mode (default '0444') applies to all outputs generated by trust_store,
    including the bundle, directory hashes, and Java cacerts keystore.
    """
    if certificates == None:
        return None

    if type(certificates) == "list":
        certs_cfg = {"providers": certificates}
    elif type(certificates) == "dict":
        certs_cfg = dict(certificates)
    else:
        fail("Unexpected type '%s' for 'certificates' in %s" % (type(certificates), name))

    raw_providers = certs_cfg.get("providers")
    if raw_providers != None:
        if type(raw_providers) != "list":
            fail("certificates.providers in %s must be a list" % name)
        providers = raw_providers
    else:
        providers = []

    for p in providers:
        if p not in packages:
            fail("Certificate provider '%s' in %s must be listed in 'packages'" % (p, name))

    raw_additional = certs_cfg.get("additional", [])
    if type(raw_additional) != "list":
        fail("certificates.additional in %s must be a list" % name)

    if not providers and not raw_additional:
        fail("certificates block in %s requires at least one provider in 'providers' or certificate in 'additional'" % name)

    purpose = certs_cfg.get("purpose", "server-auth")
    if purpose not in ("server-auth", "email", "code-signing"):
        fail("Invalid certificates.purpose '%s' in %s. Supported: 'server-auth', 'email', 'code-signing'" % (purpose, name))

    bundle = certs_cfg.get("bundle", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
    if bundle == False or bundle == None or bundle == "":
        bundle_enabled = False
        bundle_path = "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
    else:
        bundle_enabled = True
        bundle_path = str(bundle) if type(bundle) == "string" else "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"

    directory = certs_cfg.get("directory", "/etc/pki/ca-trust/extracted/pem/directory-hash")
    if directory == False or directory == None or directory == "":
        exploded_enabled = False
        exploded_dir = "/etc/pki/ca-trust/extracted/pem/directory-hash"
    else:
        exploded_enabled = True
        exploded_dir = str(directory) if type(directory) == "string" else "/etc/pki/ca-trust/extracted/pem/directory-hash"

    java_keystore = certs_cfg.get("java-keystore", certs_cfg.get("java_keystore", False))
    if not java_keystore:
        java_keystore_enabled = False
        java_keystore_path = "/etc/pki/ca-trust/extracted/java/cacerts"
    else:
        java_keystore_enabled = True
        java_keystore_path = java_keystore if type(java_keystore) == "string" else "/etc/pki/ca-trust/extracted/java/cacerts"

    # Mode applies to all trust_store outputs (bundle, directory hash, java keystore)
    mode = certs_cfg.get("mode", "0444")

    cert_labels = []
    anchor_files = {}
    anchor_symlinks = {}

    for idx, item in enumerate(raw_additional):
        if type(item) == "string":
            item = {"source": item}
        elif type(item) != "dict":
            fail("certificates.additional item %d in %s must be a string or dict" % (idx, name))

        src = item.get("source", item.get("src"))
        content = item.get("content")

        if not src and not content:
            fail("certificates.additional item %d in %s must specify 'source' or 'content'" % (idx, name))

        if content:
            cert_target = "%s_cert_%d" % (name, idx)
            content_lines = content[:-1].split("\n") if content.endswith("\n") else content.split("\n")
            expand_template(
                name = cert_target,
                out = cert_target + ".crt",
                template = content_lines,
                visibility = ["//visibility:private"],
            )
            cert_label = ":" + cert_target
            raw_name = item.get("name", "anchor-%d.crt" % idx)
        else:
            cert_label = src
            clean_src = src.rsplit(":", 1)[-1].rsplit("/", 1)[-1]
            raw_name = item.get("name", clean_src)

        anchor_name = raw_name
        if "/" in anchor_name or ".." in anchor_name:
            fail("Anchor name '%s' in %s certificates.additional must not contain '/' or '..'" % (anchor_name, name))
        if not (anchor_name.endswith(".crt") or anchor_name.endswith(".pem")):
            anchor_name = anchor_name + ".crt"

        cert_labels.append(cert_label)

        dest_path = item.get("path")
        if dest_path:
            dest_path = dest_path if dest_path.startswith("/") else ("/" + dest_path)

        is_anchor = item.get("anchor", False)
        anchor_dest = "/etc/pki/ca-trust/source/anchors/" + anchor_name

        if dest_path and is_anchor:
            anchor_files[dest_path] = {
                "source": cert_label,
                "mode": str(item.get("mode", "0644")),
            }
            anchor_symlinks[anchor_dest] = dest_path
        elif dest_path:
            anchor_files[dest_path] = {
                "source": cert_label,
                "mode": str(item.get("mode", "0644")),
            }
        elif is_anchor:
            anchor_files[anchor_dest] = {
                "source": cert_label,
                "mode": str(item.get("mode", "0644")),
            }

    # Collision checks against user files
    for p in anchor_files:
        if p in user_file_paths:
            fail("Certificate file path '%s' in %s collides with user-defined 'files'" % (p, name))
    for s in anchor_symlinks:
        if s in user_file_paths:
            fail("Certificate anchor symlink path '%s' in %s collides with user-defined 'files'" % (s, name))

    return {
        "providers": providers,
        "purpose": purpose,
        "bundle_enabled": bundle_enabled,
        "bundle_path": bundle_path,
        "exploded_enabled": exploded_enabled,
        "exploded_dir": exploded_dir,
        "java_keystore_enabled": java_keystore_enabled,
        "java_keystore_path": java_keystore_path,
        "mode": str(mode),
        "cert_labels": cert_labels,
        "anchor_files": anchor_files,
        "anchor_symlinks": anchor_symlinks,
    }

def _normalize_arch(arch):
    a = str(arch).lower().strip()
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
    if a == "noarch":
        return "noarch"
    return a

def _layers_for_arch(extra_layers, arch):
    """Returns the list of extra layers applicable to architecture `arch`.

    `extra_layers` is a list of dicts, where each dict has:
      - 'layer': Label of the layer target.
      - 'arch' (optional): Target architecture (e.g. 'x86_64', 'aarch64').
        If omitted, the layer applies to all architectures.
    The list is iterated in the exact order specified.
    """
    if not extra_layers:
        return []

    if type(extra_layers) != "list":
        fail("extra_layers must be a list of layer entries (dicts or labels), got %s" % type(extra_layers))

    norm_target_arch = _normalize_arch(arch)
    result = []

    for item in extra_layers:
        if type(item) == "string":
            result.append(item)
        elif type(item) == "dict":
            layer = item.get("layer")
            if not layer:
                fail("extra_layers entry dict must contain a 'layer' key, got: %s" % item)
            item_arch = item.get("arch")
            if not item_arch or item_arch == "noarch":
                result.append(layer)
            elif _normalize_arch(item_arch) == norm_target_arch:
                result.append(layer)
        else:
            fail("extra_layers items must be dicts with 'layer' and optional 'arch', got: %s" % type(item))

    return result

def _platform_for_arch(arch):
    if arch == "x86_64":
        return ("@rules_dnfo//dnfo/platforms:linux_x86_64", "linux/amd64")
    if arch == "aarch64":
        return ("@rules_dnfo//dnfo/platforms:linux_aarch64", "linux/arm64")
    if arch == "armv7hl":
        return ("@rules_dnfo//dnfo/platforms:linux_armv7hl", "linux/arm/v7")
    if arch == "ppc64le":
        return ("@rules_dnfo//dnfo/platforms:linux_ppc64le", "linux/ppc64le")
    if arch == "s390x":
        return ("@rules_dnfo//dnfo/platforms:linux_s390x", "linux/s390x")
    if arch == "riscv64":
        return ("@rules_dnfo//dnfo/platforms:linux_riscv64", "linux/riscv64")
    fail("Unsupported architecture '%s'. Supported architectures are: %s" % (
        arch,
        ", ".join(["x86_64", "aarch64", "armv7hl", "ppc64le", "s390x", "riscv64"]),
    ))

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

def _normalize_exclude_pattern(pattern):
    pats = [pattern]
    if pattern.startswith("/"):
        stripped = pattern.lstrip("/")
        if stripped not in pats:
            pats.append(stripped)
        if not pattern.startswith("*/"):
            wildcard_prefix = "*" + pattern
            if wildcard_prefix not in pats:
                pats.append(wildcard_prefix)
    elif not pattern.startswith("*"):
        wildcard_prefix = "*/" + pattern
        if wildcard_prefix not in pats:
            pats.append(wildcard_prefix)

    res = list(pats)
    for p in pats:
        if "*" not in p and "?" not in p:
            entry_wildcard = p.rstrip("/") + "/*"
            if entry_wildcard not in res:
                res.append(entry_wildcard)
            dir_wildcard = p.rstrip("/")
            if dir_wildcard not in res:
                res.append(dir_wildcard)
    return res

def dnfo_image(
        name,
        config = "dnfo.yaml",
        packages = [],
        repositories = [],
        releasever = "10",
        install_weak_deps = False,
        contents = None,
        architecture = "x86_64",
        archs = [],
        lock_only = False,
        tag = "",
        entrypoint = None,
        cmd = None,
        workdir = None,
        user = None,
        stop_signal = None,
        labels = {},
        annotations = {},
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
        files = {},
        exclude_patterns = [],
        exclude_paths = [],
        exclude_docs = None,
        exclude_man = None,
        exclude_licenses = None,
        exclude_build_id = None,
        install_langs = None,
        locale = None,
        certificates = None,
        extra_layers = None,
        flatten_all_layers = False,
        flatten_dnfo_layers = False,
        **kwargs):
    """Builds an OCI container image or multi-arch image index from RPM packages declared in dnfo YAML.

    1. Renders .repo configuration files and dnf_config, then creates companion locking targets
       (<name>.lock or per-arch <name>.<arch>.lock) via rpm_lock and write_source_file.
       For multi-arch configurations, an alias through rules_multirun (<name>.lock) is created so
       a single lockfile run updates both/all lockfiles.
    2. When lock_only = True (Phase 1, before lockfiles exist on disk), stops after creating
       the lock targets so that `bazel run //<pkg>:<name>.lock` generates the lockfiles.
    3. When lock_only = False (Phase 3, once lockfiles exist), initializes rpmdb with rpm_mark
       and assembles RPM packages into deduplicated layer tarballs with rpmdb injected via rpm_layer.
    4. Conditionally creates base image layer (linux_skeleton and etc_passwd) unless a base image
       is provided or 'filesystem' RPM is included (can be overridden via include_skeleton).
    5. Sets entrypoint, cmd, workdir, user, stop_signal, labels, annotations, env using rules_img.
    6. For multi-arch images, composes an image_index under <name> containing all platform manifests.
    7. Creates a target to load into local Docker (<name>_load and alias 'load') with canonical tags.

    Args:
      name: Target name for the generated container image or image index.
      config: YAML configuration file (dnfo.yaml).
      packages: List of RPM package names to install.
      repositories: List of repository dicts.
      releasever: OS release version (default "10").
      install_weak_deps: Whether to install weak dependencies (default False).
      contents: Optional label or dict mapping arch to pre-resolved packages repo.
      architecture: Target CPU architecture (default "x86_64", used when archs is not specified).
      archs: List of CPU architectures or aliases (e.g. ["x86_64", "aarch64"] or ["amd64", "arm64"]).
      lock_only: Phase 1 flag; if True, only generates locking targets.
      tag: Image tag (default "<name>:latest").
      entrypoint: List of entrypoint command arguments.
      cmd: List of default command arguments.
      workdir: Working directory inside the container.
      user: User name or UID for container process execution.
      stop_signal: System call signal sent to container to exit (e.g. "SIGTERM").
      labels: Dictionary of image labels.
      annotations: Dictionary of image annotations.
      env: Environment variable dictionary.
      accounts: User and group account definitions.
      gpgcheck: Whether to verify package GPG signatures.
      keyring: GPG key URLs or labels.
      base: Optional base container image target to inherit layers and configs from.
      base_rpmdb: Optional base rpmdb.sqlite file/target to mark packages on top of and solve against.
      base_repos: Optional base repository configs target(s) inherited from parent or base image.
      include_skeleton: Optional boolean to explicitly force or omit the linux_skeleton directory layer.
      files: Dictionary or list of files to install into the image from repository or pulled by Bazel.
      exclude_patterns: Optional list of glob patterns to exclude from RPM layers.
      exclude_paths: Optional list of directory or file paths to exclude from RPM layers.
      exclude_docs: Optional boolean flag to exclude documentation and info files.
      exclude_man: Optional boolean flag to exclude manual pages.
      exclude_licenses: Optional boolean flag to exclude license files.
      exclude_build_id: Optional boolean flag to exclude .build-id debug links.
      install_langs: Optional language locales to keep.
      locale: Optional locale alias for install_langs; also sets default LANG in image manifest.
      certificates: Optional SSL/TLS CA certificate configuration.
      extra_layers: Optional list of dicts with 'layer' and optional 'arch' to inject into the image.
      flatten_all_layers: Whether to squash all layers (including base image) into a single layer.
      flatten_dnfo_layers: Whether to squash layers defined in this dnfo target into a single layer on top of base image.
      **kwargs: Additional arguments forwarded to rules_img.
    """
    visibility = kwargs.get("visibility", ["//visibility:public"])

    if extra_layers != None and type(extra_layers) != "list":
        fail("extra_layers in %s must be a list of layer entries (dicts or labels), got %s" % (name, type(extra_layers)))

    # Resolve architectures
    raw_archs = []
    if archs:
        if type(archs) == "list":
            raw_archs.extend(archs)
        elif type(archs) == "string":
            raw_archs.append(archs)
    elif architecture:
        raw_archs.append(architecture)
    else:
        raw_archs.append("x86_64")

    resolved_archs = []
    for a in raw_archs:
        na = _normalize_arch(a)
        if na not in resolved_archs:
            resolved_archs.append(na)

    is_multi_arch = len(resolved_archs) > 1

    # Resolve install_langs and locale
    install_langs_val = install_langs if install_langs != None else locale
    install_langs_str = ""
    primary_locale = None
    if install_langs_val:
        if type(install_langs_val) == "list":
            install_langs_str = ":".join(install_langs_val)
            primary_locale = install_langs_val[0] if install_langs_val else None
        else:
            install_langs_str = str(install_langs_val)
            primary_locale = install_langs_str.replace(",", ":").split(":")[0]

    # Resolve exclude patterns and paths
    raw_patterns = []
    if type(exclude_patterns) == "list":
        raw_patterns.extend(exclude_patterns)
    elif type(exclude_patterns) == "string":
        raw_patterns.append(exclude_patterns)

    if type(exclude_paths) == "list":
        raw_patterns.extend(exclude_paths)
    elif type(exclude_paths) == "string":
        raw_patterns.append(exclude_paths)

    all_exclude_patterns = []
    for pat in raw_patterns:
        for norm_pat in _normalize_exclude_pattern(pat):
            if norm_pat not in all_exclude_patterns:
                all_exclude_patterns.append(norm_pat)

    # Resolve repository configs
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

    config_stem = config.rsplit(".", 1)[0] if "." in config else config
    dnf_config_kwargs = {}
    if install_langs_str:
        dnf_config_kwargs["install_langs"] = install_langs_str

    valid_keyrings = [
        k
        for k in all_keyrings
        if k.startswith("@") or k.startswith("//") or k.startswith(":")
    ]

    rpm_layer_kwargs = {}
    if all_exclude_patterns:
        rpm_layer_kwargs["exclude_patterns"] = all_exclude_patterns
    if install_langs_str:
        rpm_layer_kwargs["install_langs"] = install_langs_str
    if exclude_docs != None:
        rpm_layer_kwargs["exclude_docs"] = exclude_docs
    if exclude_man != None:
        rpm_layer_kwargs["exclude_man"] = exclude_man
    if exclude_licenses != None:
        rpm_layer_kwargs["exclude_licenses"] = exclude_licenses
    if exclude_build_id != None:
        rpm_layer_kwargs["exclude_build_id"] = exclude_build_id

    # --- Phase 1: Lockfile Generation ---
    if is_multi_arch:
        arch_lock_targets = []
        for a in resolved_archs:
            arch_target_platform, arch_extract_platform = _platform_for_arch(a)
            arch_base_rpmdb = base_rpmdb
            if base and not base_rpmdb:
                extract_rpmdb_name = name + "_" + a + "_base_rpmdb"
                image_extract(
                    name = extract_rpmdb_name,
                    file = base_rpmdb_file or "/usr/lib/sysimage/rpm/rpmdb.sqlite",
                    image = base,
                    out = name + "_" + a + "_base_rpmdb.sqlite",
                    platform = arch_extract_platform,
                    visibility = ["//visibility:private"],
                )
                arch_base_rpmdb = ":" + extract_rpmdb_name

            arch_extracted_repos = None
            if base and base_repo_file:
                extract_repo_name = name + "_" + a + "_base_repo"
                image_extract(
                    name = extract_repo_name,
                    file = base_repo_file,
                    image = base,
                    out = name + "_" + a + "_base.repo",
                    platform = arch_extract_platform,
                    visibility = ["//visibility:private"],
                )
                arch_extracted_repos = ":" + extract_repo_name

            arch_repo_configs = list(repo_configs)
            if arch_extracted_repos:
                arch_repo_configs.append(arch_extracted_repos)

            arch_list = [a, "noarch"] if a != "noarch" else ["noarch"]
            arch_lockfile_name = config_stem + "." + a + ".lock.json"

            if arch_repo_configs and packages:
                dnf_config(
                    name = name + "_" + a + "_dnf_config",
                    arch = arch_list,
                    install_weak_deps = install_weak_deps,
                    releasever = releasever,
                    repo_configs = arch_repo_configs,
                    visibility = ["//visibility:private"],
                    **dnf_config_kwargs
                )

                rpm_lock(
                    name = name + "_" + a + "_generated_lock",
                    arch = arch_list,
                    base_rpmdb = arch_base_rpmdb,
                    config = ":" + name + "_" + a + "_dnf_config",
                    packages = packages,
                    tags = ["no-remote-cache", "no-remote-exec", "requires-network"],
                    visibility = ["//visibility:private"],
                )

                write_source_file(
                    name = name + "." + a + ".lock",
                    in_file = ":" + name + "_" + a + "_generated_lock",
                    out_file = arch_lockfile_name,
                    tags = ["no-remote-cache", "no-remote-exec", "requires-network"],
                    visibility = visibility,
                )
                arch_lock_targets.append(":" + name + "." + a + ".lock")

        # Alias through rules_multirun to update both/all lockfiles with a single invocation
        if arch_lock_targets:
            multirun(
                name = name + ".lock",
                commands = arch_lock_targets,
                visibility = visibility,
            )

        if lock_only:
            return
    else:
        # Single-arch lockfile generation
        arch = resolved_archs[0]
        arch_list = [arch, "noarch"] if arch != "noarch" else ["noarch"]
        target_platform, extract_platform = _platform_for_arch(arch)

        extracted_repos = None
        if base and not base_rpmdb:
            extract_rpmdb_name = name + "_base_rpmdb"
            image_extract(
                name = extract_rpmdb_name,
                file = base_rpmdb_file or "/usr/lib/sysimage/rpm/rpmdb.sqlite",
                image = base,
                out = name + "_base_rpmdb.sqlite",
                platform = extract_platform,
                visibility = ["//visibility:private"],
            )
            base_rpmdb = ":" + extract_rpmdb_name

        if base and base_repo_file:
            extract_repo_name = name + "_base_repo"
            image_extract(
                name = extract_repo_name,
                file = base_repo_file,
                image = base,
                out = name + "_base.repo",
                platform = extract_platform,
                visibility = ["//visibility:private"],
            )
            extracted_repos = ":" + extract_repo_name

        single_repo_configs = list(repo_configs)
        if extracted_repos:
            single_repo_configs.append(extracted_repos)

        lockfile_name = config_stem + ".lock.json"
        if single_repo_configs and packages:
            dnf_config(
                name = name + "_dnf_config",
                arch = arch_list,
                install_weak_deps = install_weak_deps,
                releasever = releasever,
                repo_configs = single_repo_configs,
                visibility = ["//visibility:private"],
                **dnf_config_kwargs
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

    # --- Phase 3: Image Assembly ---
    ep = entrypoint if entrypoint != None else ["/bin/bash"]
    c = cmd if cmd != None else ["-l"]
    wd = workdir if workdir != None else "/home"

    merged_env = dict(env) if env else {}
    if primary_locale and "LANG" not in merged_env:
        merged_env["LANG"] = primary_locale

    # Extract user-defined file destination paths for collision checking
    user_file_paths = []
    if files:
        if type(files) == "dict":
            for dest in files.keys():
                user_file_paths.append(dest if dest.startswith("/") else ("/" + dest))
        elif type(files) == "list":
            for item in files:
                if type(item) == "dict":
                    dest = item.get("path", item.get("destination", item.get("dest")))
                    if dest:
                        user_file_paths.append(dest if dest.startswith("/") else ("/" + dest))

    parsed_certs = _process_certificates(name, certificates, packages, user_file_paths)

    # Base skeleton and account entries
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

    # Architecture-independent Trust Store (built ONCE)
    if parsed_certs:
        store_certs = list(parsed_certs["cert_labels"])
        if parsed_certs["providers"]:
            ref_arch = resolved_archs[0]
            prov_repo = ("@" + name + "_" + ref_arch + "_packages//:") if is_multi_arch else ("@" + name + "_packages//:")
            prov_rpms = [prov_repo + p for p in parsed_certs["providers"]]
            rpm_extract(
                name = name + "_extracted_pki",
                dirs = ["usr/share/pki/ca-trust-source"],
                rpms = prov_rpms,
                visibility = ["//visibility:private"],
            )
            p11_kit_extract(
                name = name + "_ca_extracted",
                srcs = [":" + name + "_extracted_pki"],
                purpose = parsed_certs["purpose"],
                visibility = ["//visibility:private"],
            )
            store_certs.append(":" + name + "_ca_extracted")

        trust_store_kwargs = {}
        if parsed_certs["mode"]:
            trust_store_kwargs["mode"] = parsed_certs["mode"]

        trust_store(
            name = name + "_trust_store",
            certs = store_certs,
            bundle = parsed_certs["bundle_enabled"],
            bundle_path = parsed_certs["bundle_path"],
            exploded = parsed_certs["exploded_enabled"],
            exploded_dir = parsed_certs["exploded_dir"],
            java_keystore = parsed_certs["java_keystore_enabled"],
            java_keystore_path = parsed_certs["java_keystore_path"],
            visibility = ["//visibility:private"],
            **trust_store_kwargs
        )
        base_layer_srcs.append(":" + name + "_trust_store")

    base_layer_label = None
    if base_layer_srcs:
        base_image_layer(
            name = name + "_base_layer",
            srcs = base_layer_srcs,
            visibility = ["//visibility:private"],
        )
        base_layer_label = ":" + name + "_base_layer"

    # Files layer: combine user-defined files and certificate anchors/symlinks
    files_srcs = {}
    files_metadata = {}
    files_symlinks = {}

    if files:
        if type(files) == "dict":
            for dest, item in files.items():
                dest_path = dest if dest.startswith("/") else ("/" + dest)
                if type(item) == "string":
                    files_srcs[dest_path] = item
                elif type(item) == "dict":
                    src = item.get("source", item.get("src"))
                    if not src:
                        fail("File entry for '%s' in %s must specify 'source' or 'src'" % (dest, name))
                    files_srcs[dest_path] = src
                    meta = {}
                    for k in ["mode", "uid", "gid", "uname", "gname", "mtime"]:
                        if k in item:
                            meta[k] = item[k]
                    if "permissions" in item and "mode" not in meta:
                        meta["mode"] = str(item["permissions"])
                    if meta:
                        files_metadata[dest_path] = json.encode(meta)
                else:
                    fail("Unexpected file entry type '%s' for '%s' in 'files' attribute for %s" % (type(item), dest, name))
        elif type(files) == "list":
            for item in files:
                if type(item) == "dict":
                    dest = item.get("path", item.get("destination", item.get("dest")))
                    if not dest:
                        fail("File item in %s 'files' must specify 'path' or 'destination'" % name)
                    dest_path = dest if dest.startswith("/") else ("/" + dest)
                    src = item.get("source", item.get("src"))
                    if not src:
                        fail("File item for '%s' in %s must specify 'source' or 'src'" % (dest, name))
                    files_srcs[dest_path] = src
                    meta = {}
                    for k in ["mode", "uid", "gid", "uname", "gname", "mtime"]:
                        if k in item:
                            meta[k] = item[k]
                    if "permissions" in item and "mode" not in meta:
                        meta["mode"] = str(item["permissions"])
                    if meta:
                        files_metadata[dest_path] = json.encode(meta)
                else:
                    fail("Unexpected file entry type '%s' in 'files' attribute for %s" % (type(item), name))

    if parsed_certs:
        for p_dest, p_val in parsed_certs["anchor_files"].items():
            files_srcs[p_dest] = p_val["source"]
            files_metadata[p_dest] = json.encode({"mode": p_val["mode"]})
        for s_dest, s_target in parsed_certs["anchor_symlinks"].items():
            files_symlinks[s_dest] = s_target

    files_layer_label = None
    if files_srcs or files_symlinks:
        image_layer_kwargs = {}
        if files_symlinks:
            image_layer_kwargs["symlinks"] = files_symlinks
        image_layer(
            name = name + "_files_layer",
            srcs = files_srcs,
            file_metadata = files_metadata,
            visibility = ["//visibility:private"],
            **image_layer_kwargs
        )
        files_layer_label = ":" + name + "_files_layer"

    if is_multi_arch:
        manifest_labels = []
        for a in resolved_archs:
            arch_target_platform, _ = _platform_for_arch(a)
            arch_base_rpmdb = base_rpmdb
            if base and not base_rpmdb:
                arch_base_rpmdb = ":" + name + "_" + a + "_base_rpmdb"

            arch_layers = []
            if packages or contents:
                rpms_label = None
                if contents:
                    if type(contents) == "dict":
                        rpms_label = contents.get(a)
                    elif type(contents) == "string":
                        rpms_label = contents
                if not rpms_label:
                    rpms_label = "@" + name + "_" + a + "_packages//:rpms"

                rpm_mark(
                    name = name + "_" + a + "_rpmdb",
                    base_rpmdb = arch_base_rpmdb,
                    rpms = [rpms_label],
                    visibility = visibility,
                )

                rpm_layer(
                    name = name + "_" + a + "_rpms_tar",
                    rpms = [rpms_label],
                    rpmdb = ":" + name + "_" + a + "_rpmdb",
                    gpgcheck = gpgcheck and bool(valid_keyrings),
                    gpgkeys = valid_keyrings,
                    visibility = ["//visibility:private"],
                    **rpm_layer_kwargs
                )

                layer_from_tar(
                    name = name + "_" + a + "_rpms_layer",
                    src = ":" + name + "_" + a + "_rpms_tar",
                    visibility = ["//visibility:private"],
                )
                arch_layers.append(":" + name + "_" + a + "_rpms_layer")

            if base_layer_label:
                arch_layers.append(base_layer_label)
            if files_layer_label:
                arch_layers.append(files_layer_label)

            arch_extra = _layers_for_arch(extra_layers, a)
            if arch_extra:
                arch_layers.extend(arch_extra)

            target_name = name + "_" + a
            _create_image_manifest(
                target_name = target_name,
                layers = arch_layers,
                base = base,
                flatten_all_layers = flatten_all_layers,
                flatten_dnfo_layers = flatten_dnfo_layers,
                entrypoint = ep,
                cmd = c,
                working_dir = wd,
                env = merged_env,
                platform = arch_target_platform,
                user = user,
                stop_signal = stop_signal,
                labels = labels,
                annotations = annotations,
                visibility = visibility,
            )
            manifest_labels.append(":" + target_name)

        # Multi-platform image index
        index_kwargs = {}
        if annotations:
            index_kwargs["annotations"] = annotations

        image_index(
            name = name,
            manifests = manifest_labels,
            visibility = visibility,
            **index_kwargs
        )

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
        return

    # Single-arch manifest
    layers = []
    if packages or contents:
        rpms_label = contents.get(arch) if type(contents) == "dict" else contents
        if not rpms_label:
            rpms_label = "@" + name + "_packages//:rpms"
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
            gpgcheck = gpgcheck and bool(valid_keyrings),
            gpgkeys = valid_keyrings,
            visibility = ["//visibility:private"],
            **rpm_layer_kwargs
        )

        layer_from_tar(
            name = name + "_rpms_layer",
            src = ":" + name + "_rpms_tar",
            visibility = ["//visibility:private"],
        )
        layers.append(":" + name + "_rpms_layer")

    if base_layer_label:
        layers.append(base_layer_label)
    if files_layer_label:
        layers.append(files_layer_label)

    single_extra = _layers_for_arch(extra_layers, arch)
    if single_extra:
        layers.extend(single_extra)

    _create_image_manifest(
        target_name = name,
        layers = layers,
        base = base,
        flatten_all_layers = flatten_all_layers,
        flatten_dnfo_layers = flatten_dnfo_layers,
        entrypoint = ep,
        cmd = c,
        working_dir = wd,
        env = merged_env,
        platform = target_platform,
        user = user,
        stop_signal = stop_signal,
        labels = labels,
        annotations = annotations,
        visibility = visibility,
    )

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
