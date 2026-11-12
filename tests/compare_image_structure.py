#!/usr/bin/env python3
"""Compares the effective filesystem structure between unflattened and flattened container layers.

Resolves directory symlinks and respects OCI whiteout files to verify that
flattening does not lose or alter any filesystem paths across architectures.
"""

import argparse
import json
import os
import sys
import tarfile


def find_file(path: str) -> str:
    """Locates a file within Bazel runfiles or current directory."""
    if os.path.isabs(path) and os.path.exists(path):
        return path

    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "_main")

    if test_srcdir:
        candidates = [
            os.path.join(test_srcdir, test_workspace, path),
            os.path.join(test_srcdir, path),
            os.path.join(test_srcdir, "rules_dnfo", path),
            os.path.join(test_srcdir, "_main", path),
        ]
        for c in candidates:
            if os.path.exists(c):
                return c

    if os.path.exists(path):
        return path

    # Search in current directory and parents
    for root, _, files in os.walk("."):
        if os.path.basename(path) in files:
            full = os.path.join(root, os.path.basename(path))
            if path in full:
                return full

    raise FileNotFoundError(f"Cannot find file: {path} (TEST_SRCDIR={test_srcdir})")


def _resolve_dir_symlinks(dir_path: str, symlinks: dict) -> str:
    """Canonicalizes a directory path by dereferencing any known parent directory symlinks."""
    if not dir_path or dir_path == ".":
        return ""
    parts = dir_path.split("/")
    curr = []
    for p in parts:
        curr.append(p)
        cur_str = "/".join(curr)
        if cur_str in symlinks:
            target = symlinks[cur_str]
            curr = target.split("/") if target else []
    return "/".join(curr)


def compute_effective_filesystem(tar_paths: list) -> dict:
    """Computes the effective filesystem paths and types from ordered image layer tarballs.

    Applies directory symlink canonicalization and OCI whiteout handling.
    """
    symlinks = {}  # canonical_dir -> resolved_target_dir
    fs = {}        # canonical_path -> member_type ('dir', 'symlink', 'file')

    for tp in tar_paths:
        resolved_tp = find_file(tp)
        with tarfile.open(resolved_tp, "r:*") as t:
            for member in t.getmembers():
                name = member.name.strip("/")
                if not name or name == ".":
                    continue

                basename = os.path.basename(name)
                dirname = os.path.dirname(name)
                resolved_dir = _resolve_dir_symlinks(dirname, symlinks)

                # OCI Whiteouts
                if basename == ".wh..wh..opq":
                    # Opaque whiteout: hide all previous entries under resolved_dir
                    prefix = (resolved_dir + "/") if resolved_dir else ""
                    keys_to_del = [k for k in fs if k.startswith(prefix) and k != resolved_dir]
                    for k in keys_to_del:
                        del fs[k]
                    continue
                elif basename.startswith(".wh."):
                    # Explicit entry whiteout
                    target_name = basename[4:]
                    del_path = (resolved_dir + "/" + target_name) if resolved_dir else target_name
                    if del_path in fs:
                        del fs[del_path]
                    continue

                canonical_name = (resolved_dir + "/" + basename) if resolved_dir else basename

                if member.isdir():
                    fs[canonical_name] = "dir"
                elif member.issym():
                    fs[canonical_name] = "symlink"
                    target = member.linkname
                    if target.startswith("/"):
                        resolved_target = target.lstrip("/")
                    else:
                        resolved_target = os.path.normpath(
                            (resolved_dir + "/" + target) if resolved_dir else target
                        ).lstrip("/")
                    symlinks[canonical_name] = resolved_target
                else:
                    fs[canonical_name] = "file"

    return fs


def compare_structures(platform: str, flattened_tars: list, unflattened_tars: list) -> bool:
    """Compares the filesystem structure of flattened vs unflattened layer tarballs."""
    flat_fs = compute_effective_filesystem(flattened_tars)
    unflat_fs = compute_effective_filesystem(unflattened_tars)

    flat_keys = set(flat_fs.keys())
    unflat_keys = set(unflat_fs.keys())

    missing_in_flat = unflat_keys - flat_keys
    extra_in_flat = flat_keys - unflat_keys

    if missing_in_flat or extra_in_flat:
        print(f"FAILED: Filesystem structure mismatch on platform [{platform}]!")
        if missing_in_flat:
            print(f"  Missing in flattened image ({len(missing_in_flat)} entries):")
            for item in sorted(list(missing_in_flat))[:20]:
                print(f"    - {item} ({unflat_fs[item]})")
            if len(missing_in_flat) > 20:
                print(f"    ... and {len(missing_in_flat) - 20} more")
        if extra_in_flat:
            print(f"  Extraneous in flattened image ({len(extra_in_flat)} entries):")
            for item in sorted(list(extra_in_flat))[:20]:
                print(f"    + {item} ({flat_fs[item]})")
            if len(extra_in_flat) > 20:
                print(f"    ... and {len(extra_in_flat) - 20} more")
        return False

    print(f"[PASS] Platform [{platform}]: {len(flat_keys)} filesystem entries match perfectly.")
    return True


def main():
    parser = argparse.ArgumentParser(description="Compare flattened vs unflattened image filesystem structure.")
    parser.add_argument("--config", help="Path to JSON configuration file describing comparisons.")
    parser.add_argument("--platform", default="unknown", help="Platform name when running in CLI mode.")
    parser.add_argument("--flattened", nargs="*", help="List of flattened layer tarballs.")
    parser.add_argument("--unflattened", nargs="*", help="List of unflattened layer tarballs.")

    args = parser.parse_args()

    pairs = []
    if args.config:
        cfg_path = find_file(args.config)
        with open(cfg_path, "r") as f:
            pairs = json.load(f)
    elif args.flattened and args.unflattened:
        pairs = [{
            "platform": args.platform,
            "flattened": args.flattened,
            "unflattened": args.unflattened,
        }]
    else:
        parser.error("Either --config or both --flattened and --unflattened must be provided.")

    all_passed = True
    for item in pairs:
        plat = item.get("platform", "unknown")
        flat = item.get("flattened", [])
        unflat = item.get("unflattened", [])
        if not compare_structures(plat, flat, unflat):
            all_passed = False

    if not all_passed:
        sys.exit(1)

    print("All image structure comparisons PASSED successfully.")


if __name__ == "__main__":
    main()
