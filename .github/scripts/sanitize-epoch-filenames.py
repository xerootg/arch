#!/usr/bin/env python3
"""Make package filenames survive a GitHub Release.

GitHub rewrites ':' to '.' in release asset names, silently and with no way to
opt out. A pacman package whose version carries an epoch has a colon in its
filename -- dotnet-sdk-preview-bin-1:11.0.0...pkg.tar.zst -- so the asset lands
as ...-1.11.0.0...pkg.tar.zst while the database still says the name has a
colon in it. Nothing then lines up:

  * pacman asks the Server for the name in %FILENAME% and gets a 404, so every
    epoch package in the repo is undownloadable
  * publish-release-repo.sh builds its keep-set from %FILENAME%, does not find
    a matching asset, and prunes the package it just uploaded
  * heavy-build's index job re-downloads by %FILENAME% and dies on the first one

So apply GitHub's substitution ourselves, before anything records the name:
rename the files and rewrite %FILENAME% in the databases to match. The version
inside the package is untouched -- repo-add reads %VERSION% from .PKGINFO, not
from the filename -- so pacman still sees the epoch and still orders upgrades
correctly. Only the download URL changes.

    sanitize-epoch-filenames.py <dir> [repo-name]

With a repo-name it also rewrites <name>.db.tar.gz and <name>.files.tar.gz
(and their uncompressed copies). Without one it only renames files, which is
what a build directory holding no database needs.
"""

import io
import os
import shutil
import sys
import tarfile


def sanitize(name):
    """GitHub's asset-name substitution. Only ':' is affected -- '+' and '~'
    are preserved, verified against the names actually stored on the release."""
    return name.replace(":", ".")


def rename_packages(directory):
    renamed = {}
    for entry in sorted(os.listdir(directory)):
        if ":" not in entry:
            continue
        if ".pkg.tar" not in entry:
            continue
        new = sanitize(entry)
        src = os.path.join(directory, entry)
        dst = os.path.join(directory, new)
        if os.path.exists(dst) and not os.path.samefile(src, dst):
            os.remove(dst)
        os.rename(src, dst)
        renamed[entry] = new
        print("  renamed {} -> {}".format(entry, new))
    return renamed


def rewrite_db(path):
    """Rewrite %FILENAME% inside a pacman database tarball.

    Read fully into memory first: these are a few hundred kilobytes of text,
    and rewriting a tar in place is not a thing.
    """
    if not os.path.exists(path):
        return 0

    changed = 0
    buf = io.BytesIO()
    with tarfile.open(path, "r:*") as src:
        members = src.getmembers()
        with tarfile.open(fileobj=buf, mode="w:gz") as dst:
            for m in members:
                if not m.isfile():
                    dst.addfile(m)
                    continue
                data = src.extractfile(m).read()
                text = data.decode("utf-8", "surrogateescape")
                lines = text.split("\n")
                for i, line in enumerate(lines):
                    if line.strip() == "%FILENAME%" and i + 1 < len(lines):
                        if ":" in lines[i + 1]:
                            lines[i + 1] = sanitize(lines[i + 1])
                            changed += 1
                        break
                data = "\n".join(lines).encode("utf-8", "surrogateescape")
                m.size = len(data)
                dst.addfile(m, io.BytesIO(data))

    if changed:
        with open(path, "wb") as fh:
            fh.write(buf.getvalue())
    return changed


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    directory = argv[1]
    repo_name = argv[2] if len(argv) > 2 else None

    print("Sanitizing epoch colons in {}".format(directory))
    renamed = rename_packages(directory)

    total = 0
    if repo_name:
        for ext in ("db", "files"):
            archive = os.path.join(directory, "{}.{}.tar.gz".format(repo_name, ext))
            n = rewrite_db(archive)
            total += n
            if n:
                print("  rewrote {} %FILENAME% entr{} in {}.{}.tar.gz".format(
                    n, "y" if n == 1 else "ies", repo_name, ext))
            # The bare <name>.db is the copy pacman actually downloads; keep it
            # identical to the tarball rather than rewriting it separately.
            plain = os.path.join(directory, "{}.{}".format(repo_name, ext))
            if os.path.exists(archive) and os.path.exists(plain):
                shutil.copyfile(archive, plain)

    if not renamed and not total:
        print("  nothing to do -- no epoch in any filename")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
