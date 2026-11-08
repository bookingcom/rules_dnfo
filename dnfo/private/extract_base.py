#!/usr/bin/env python3
"""Extracts RPM database (rpmdb.sqlite) and repository configs (*.repo) from base container image layers."""

import argparse
import os
import sqlite3
import sys
import tarfile

def normalize_path(path):
    path = path.lstrip("/")
    if path.startswith("./"):
        path = path[2:]
    return path

def extract_from_layers(layer_paths, out_rpmdb_path, out_repos_path):
    latest_rpmdb = None
    repo_files = {}  # relative path -> bytes

    for layer_path in layer_paths:
        if not os.path.isfile(layer_path):
            continue

        try:
            with tarfile.open(layer_path, "r:*") as tar:
                for member in tar.getmembers():
                    norm = normalize_path(member.name)
                    dirname, basename = os.path.split(norm)

                    # Handle OCI/Docker whiteout files
                    if basename.startswith(".wh."):
                        wh_target = basename[4:]
                        if wh_target == "rpmdb.sqlite" and dirname in ("var/lib/rpm", "usr/lib/sysimage/rpm"):
                            latest_rpmdb = None
                        elif dirname in ("etc/yum.repos.d", "etc/yum/repos.d"):
                            repo_files.pop(os.path.join(dirname, wh_target), None)
                        continue

                    # Look for rpmdb.sqlite
                    if norm in ("var/lib/rpm/rpmdb.sqlite", "usr/lib/sysimage/rpm/rpmdb.sqlite"):
                        try:
                            if member.isreg():
                                f = tar.extractfile(member)
                                if f is not None:
                                    latest_rpmdb = f.read()
                            elif member.islnk() or member.issym():
                                link_target = normalize_path(member.linkname)
                                try:
                                    target_member = tar.getmember(link_target)
                                    f = tar.extractfile(target_member)
                                    if f is not None:
                                        latest_rpmdb = f.read()
                                except KeyError:
                                    pass
                        except Exception:
                            pass

                    # Look for *.repo configuration files
                    elif dirname in ("etc/yum.repos.d", "etc/yum/repos.d") and basename.endswith(".repo"):
                        f = tar.extractfile(member)
                        if f is not None:
                            repo_files[norm] = f.read()
        except Exception as e:
            # If a layer cannot be read as a tar, skip or log warning
            print(f"[dnfo_extract_base] Warning reading layer {layer_path}: {e}", file=sys.stderr)

    # 1. Write rpmdb.sqlite
    os.makedirs(os.path.dirname(os.path.abspath(out_rpmdb_path)), exist_ok=True)
    if latest_rpmdb is not None:
        with open(out_rpmdb_path, "wb") as f:
            f.write(latest_rpmdb)
    else:
        # Initialize an empty valid SQLite database file
        conn = sqlite3.connect(out_rpmdb_path)
        conn.commit()
        conn.close()

    # 2. Write combined base.repo
    os.makedirs(os.path.dirname(os.path.abspath(out_repos_path)), exist_ok=True)
    with open(out_repos_path, "wb") as f:
        if repo_files:
            f.write(b"# Repository configurations extracted from base image\n\n")
            for repo_path in sorted(repo_files.keys()):
                content = repo_files[repo_path].strip()
                f.write(content + b"\n\n")
        else:
            f.write(b"# No repository configurations found in base image\n")

def main():
    parser = argparse.ArgumentParser(description="Extract rpmdb and repo configs from container image layers")
    parser.add_argument("--layer", action="append", default=[], help="Path to layer tarball (ordered from bottom to top)")
    parser.add_argument("--output-rpmdb", required=True, help="Destination path for extracted rpmdb.sqlite")
    parser.add_argument("--output-repos", required=True, help="Destination path for extracted base.repo")
    args = parser.parse_args()

    extract_from_layers(args.layer, args.output_rpmdb, args.output_repos)

if __name__ == "__main__":
    main()
