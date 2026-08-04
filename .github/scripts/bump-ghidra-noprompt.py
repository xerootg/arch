#!/usr/bin/env python3
"""Point the ghidra-noprompt PKGBUILD at the newest xerootg/ghidra release.

Reads the release-metadata.json asset published by that fork's `Fork release`
workflow and rewrites the generated block in the PKGBUILD, plus the matching
fields in .SRCINFO. Exits 0 with "changed=false" on GITHUB_OUTPUT when the
PKGBUILD already names that version, so the caller can skip the commit.

Usage: bump-ghidra-noprompt.py <metadata.json> <pkgbuild-dir>
"""

import json
import os
import re
import sys

FIELDS = ("version", "release_name", "java_min", "zip_sha256", "icon_sha256")


def emit(**kv):
    out = os.environ.get("GITHUB_OUTPUT")
    for key, value in kv.items():
        print(f"{key}={value}")
        if out:
            with open(out, "a", encoding="utf-8") as fh:
                fh.write(f"{key}={value}\n")


def set_var(text, name, value, count=1):
    """Replace a `name=...` assignment, erroring rather than silently no-oping."""
    pattern = re.compile(rf"(?m)^(\s*){re.escape(name)}\s*=.*$")
    new, found = pattern.subn(lambda m: f"{m.group(1)}{name}={value}", text, count=count)
    if found != count:
        sys.exit(f"error: expected {count} assignment(s) of {name!r}, found {found}")
    return new


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    meta_path, pkgdir = sys.argv[1], sys.argv[2]

    with open(meta_path, encoding="utf-8") as fh:
        meta = json.load(fh)
    missing = [f for f in FIELDS if not meta.get(f)]
    if missing:
        sys.exit(f"error: release metadata is missing {missing}")

    version = meta["version"]
    for name in ("zip_sha256", "icon_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", meta[name]):
            sys.exit(f"error: {name} is not a sha256 digest: {meta[name]!r}")

    pkgbuild_path = os.path.join(pkgdir, "PKGBUILD")
    with open(pkgbuild_path, encoding="utf-8") as fh:
        pkgbuild = fh.read()

    current = re.search(r"(?m)^pkgver=(.+)$", pkgbuild)
    if not current:
        sys.exit("error: PKGBUILD has no pkgver")
    if current.group(1).strip() == version:
        emit(changed="false", version=version)
        return

    start = pkgbuild.index("# >>> generated")
    end = pkgbuild.index("# <<< generated")
    block = pkgbuild[start:end]
    block = set_var(block, "pkgver", version)
    block = set_var(block, "_relname", meta["release_name"])
    block = set_var(block, "_javaver", meta["java_min"])
    block = set_var(block, "_zipsum", f"'{meta['zip_sha256']}'")
    block = set_var(block, "_iconsum", f"'{meta['icon_sha256']}'")
    pkgbuild = pkgbuild[:start] + block + pkgbuild[end:]

    # A new upstream version always restarts the package release counter.
    pkgbuild = set_var(pkgbuild, "pkgrel", "1")

    with open(pkgbuild_path, "w", encoding="utf-8") as fh:
        fh.write(pkgbuild)

    # Keep .SRCINFO in step. The build container regenerates it from the
    # PKGBUILD anyway, but the committed copy is what the outdated-package
    # check reads first, and a stale one hides the update.
    srcinfo_path = os.path.join(pkgdir, ".SRCINFO")
    if os.path.exists(srcinfo_path):
        with open(srcinfo_path, encoding="utf-8") as fh:
            srcinfo = fh.read()
        srcinfo = set_var(srcinfo, "pkgver", version)
        srcinfo = set_var(srcinfo, "pkgrel", "1")
        srcinfo = re.sub(r"(?m)^(\s*)depends = java-environment>=.*$",
                         rf"\g<1>depends = java-environment>={meta['java_min']}", srcinfo)
        srcinfo = re.sub(r"(?m)^(\s*)provides = ghidra=.*$",
                         rf"\g<1>provides = ghidra={version}", srcinfo)
        srcinfo = re.sub(r"(?m)^(\s*)source = .*\.zip.*$",
                         rf"\g<1>source = ghidra-noprompt-{version}.zip::"
                         rf"https://github.com/xerootg/ghidra/releases/download/"
                         rf"{meta['release_tag']}/{meta['zip_asset']}", srcinfo)
        srcinfo = re.sub(r"(?m)^(\s*)source = .*\.png.*$",
                         rf"\g<1>source = ghidra-noprompt-{version}.png::"
                         rf"https://github.com/xerootg/ghidra/releases/download/"
                         rf"{meta['release_tag']}/{meta['icon_asset']}", srcinfo)
        sums = [meta["zip_sha256"], meta["icon_sha256"]]
        srcinfo = re.sub(r"(?m)^(\s*)sha256sums = .*$",
                         lambda m, it=iter(sums): f"{m.group(1)}sha256sums = {next(it)}",
                         srcinfo)
        with open(srcinfo_path, "w", encoding="utf-8") as fh:
            fh.write(srcinfo)

    emit(changed="true", version=version, previous=current.group(1).strip())


if __name__ == "__main__":
    main()
