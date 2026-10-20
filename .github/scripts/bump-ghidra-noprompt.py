#!/usr/bin/env python3
"""Point the ghidra-noprompt PKGBUILD at the newest xerootg/ghidra release.

Reads the release-metadata.json asset published by that fork's `Fork release`
workflow and rewrites the generated block in the PKGBUILD, plus the matching
fields in .SRCINFO, then restamps every Ghidra extension recipe next to it.
Exits 0 with "changed=false" on GITHUB_OUTPUT when nothing in git needs to
change, so the caller can skip the pull request.

Also emits "packages=", the pkgname-pkgver-pkgrel of everything the [ghidra]
repo should carry, so the caller can tell from the release assets whether any
of it still needs building.

The optional published database is the [ghidra] repo's current ghidra.db. It
keeps extension pkgrels moving forward even when the restamp from an earlier
Ghidra release has not reached main yet (see next_pkgrel).

Usage: bump-ghidra-noprompt.py <metadata.json> <pkgbuild-dir> [published.db]
"""

import glob
import json
import os
import re
import sys
import tarfile

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


def read_published(db_path):
    """Map pkgname -> (pkgver, pkgrel, ghidra-noprompt version it depends on).

    Read from a pacman sync database: a tarball of <name>-<ver>-<rel>/desc files.
    A missing database (first run) means nothing is published.
    """
    published = {}
    if not db_path or not os.path.exists(db_path):
        return published
    with tarfile.open(db_path) as db:
        for member in db.getmembers():
            if not member.name.endswith("/desc"):
                continue
            desc = db.extractfile(member).read().decode("utf-8")
            fields = {}
            for block in desc.strip().split("\n\n"):
                lines = block.split("\n")
                fields[lines[0].strip("%")] = lines[1:]
            name = fields["NAME"][0]
            ver, rel = fields["VERSION"][0].rsplit("-", 1)
            ghidra = next((d.split("=", 1)[1] for d in fields.get("DEPENDS", [])
                           if d.startswith("ghidra-noprompt=")), None)
            published[name] = (ver, rel, ghidra)
    return published


def pkg_id(text):
    """pkgname-pkgver-pkgrel of a PKGBUILD with plain assignments."""
    def get(name):
        m = re.search(rf"(?m)^{name}=['\"]?([^'\"\s]+)['\"]?\s*$", text)
        if not m:
            sys.exit(f"error: no plain {name}= assignment")
        return m.group(1)
    return f"{get('pkgname')}-{get('pkgver')}-{get('pkgrel')}"


def next_pkgrel(name, pkgver, pkgrel, ghidraver, published):
    """The pkgrel to build at, given what the [ghidra] repo already carries.

    The PKGBUILD in git can lag the published package: this job cannot push to
    main, so a restamp only lands when its pull request is merged. Restamping
    the stale recipe again on the next Ghidra release would arrive at the same
    pkgrel as the package already published for the previous one -- pacman
    would see no upgrade, keep the old extension and its exact dependency on
    the old Ghidra, and refuse `pacman -Syu`. So the published package sets the
    floor, and moving to a different Ghidra always goes strictly above it.
    """
    pub = published.get(name)
    if not pub or pub[0] != pkgver:
        return pkgrel
    pub_rel, pub_ghidra = int(pub[1]), pub[2]
    if pub_ghidra == ghidraver:
        return max(pkgrel, pub_rel)
    return max(pkgrel, pub_rel + 1)


def stamp_extensions(version, javaver, published):
    """Point every Ghidra extension recipe at the new Ghidra, and bump its pkgrel.

    An extension is compiled against one Ghidra release and records that version
    in extension.properties; Ghidra then refuses to load an extension whose
    recorded version does not match, silently, in the log. So the packages carry
    an exact `ghidra-noprompt=<version>` dependency, and this rewrites it when
    Ghidra moves.

    pkgrel has to move too. The extension's own pkgver has not changed, so
    without a pkgrel bump pacman would not see the rebuilt package as an
    upgrade and would keep the one that pins the old Ghidra.

    Returns (restamped extension names, their pkgname-pkgver-pkgrel ids).
    """
    stamped, ids = [], []
    for pkgbuild in sorted(glob.glob("release-pkgbuilds/ghidra-ext-*/PKGBUILD")):
        with open(pkgbuild, encoding="utf-8") as fh:
            text = fh.read()
        if "_ghidraver" not in text:
            sys.exit(f"error: {pkgbuild} has no _ghidraver to stamp; it would "
                     "be published pinned to a Ghidra that is not")

        updated = set_var(text, "_ghidraver", version)
        if javaver:
            # Optional: an extension may pin java independently of Ghidra.
            try:
                updated = set_var(updated, "_javaver", str(javaver))
            except SystemExit:
                pass

        m = re.search(r"(?m)^pkgrel=(\d+)$", updated)
        if not m:
            sys.exit(f"error: {pkgbuild} has no plain pkgrel to bump")
        pkgrel = int(m.group(1))
        if updated != text:
            pkgrel += 1
        name, pkgver, _ = pkg_id(updated).rsplit("-", 2)
        pkgrel = next_pkgrel(name, pkgver, pkgrel, version, published)
        updated = set_var(updated, "pkgrel", str(pkgrel))

        ids.append(pkg_id(updated))
        if updated == text:
            continue
        with open(pkgbuild, "w", encoding="utf-8") as fh:
            fh.write(updated)
        stamped.append(os.path.basename(os.path.dirname(pkgbuild)))
        print(f"{pkgbuild}: stamped Ghidra {version}, pkgrel {pkgrel}")

    return stamped, ids


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    meta_path, pkgdir = sys.argv[1], sys.argv[2]
    published = read_published(sys.argv[3] if len(sys.argv) == 4 else None)

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
    previous = current.group(1).strip()

    # Always rewrite the block and compare the result, rather than short
    # circuiting on the version alone. A hand-seeded PKGBUILD carries
    # placeholder checksums at the right version, and a version-only check
    # would leave those placeholders in place forever.
    start = pkgbuild.index("# >>> generated")
    end = pkgbuild.index("# <<< generated")
    block = pkgbuild[start:end]
    block = set_var(block, "pkgver", version)
    block = set_var(block, "_relname", meta["release_name"])
    block = set_var(block, "_javaver", meta["java_min"])
    block = set_var(block, "_zipsum", f"'{meta['zip_sha256']}'")
    block = set_var(block, "_iconsum", f"'{meta['icon_sha256']}'")
    updated = pkgbuild[:start] + block + pkgbuild[end:]

    # A new upstream version restarts the package release counter; a checksum
    # correction at the same version must not.
    if previous != version:
        updated = set_var(updated, "pkgrel", "1")

    # The extensions are restamped whether or not ghidra-noprompt itself moved:
    # a recipe added or edited by hand may name an older Ghidra.
    stamped, ext_ids = stamp_extensions(version, meta["java_min"], published)
    packages = " ".join([pkg_id(updated)] + ext_ids)

    if updated == pkgbuild:
        emit(changed="true" if stamped else "false", version=version,
             previous=previous, packages=packages,
             extensions_restamped=" ".join(stamped))
        return

    with open(pkgbuild_path, "w", encoding="utf-8") as fh:
        fh.write(updated)

    # Keep .SRCINFO in step. The build container regenerates it from the
    # PKGBUILD anyway, but the committed copy is what the outdated-package
    # check reads first, and a stale one hides the update.
    srcinfo_path = os.path.join(pkgdir, ".SRCINFO")
    if os.path.exists(srcinfo_path):
        with open(srcinfo_path, encoding="utf-8") as fh:
            srcinfo = fh.read()
        srcinfo = set_var(srcinfo, "pkgver", version)
        if previous != version:
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

    emit(changed="true", version=version, previous=previous, packages=packages,
         extensions_restamped=" ".join(stamped))


if __name__ == "__main__":
    main()
