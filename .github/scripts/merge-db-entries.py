#!/usr/bin/env python3
"""Copy package entries a published database has that ours does not.

    merge-db-entries.py <ours.db.tar.gz> <theirs.db.tar.gz>

Both builders seed their database from the release, spend an hour or more
building, then write it back. Anything the other one published in between is
absent from the copy being written, so publishing it silently un-indexes those
packages -- ilspy-git and llama.cpp-sycl-f32-git built, uploaded, were indexed
by heavy-build, and then vanished from the database when build-repo published a
snapshot older than they were. The assets survive (the prune keeps what the
database does not name), so only the index is wrong.

Merging entries rather than re-running repo-add keeps this to tar manipulation:
no package downloads, no container, and it can run on the runner just before
signing.

Only entries whose package NAME we do not have are copied. A name we do have is
ours to decide about -- we either rebuilt it, in which case ours is newer, or we
deliberately dropped it.
"""

import io
import os
import sys
import tarfile


def entries(path):
    """{directory-name: {member-name: bytes}} plus a name->dir index."""
    out, names = {}, {}
    if not os.path.exists(path):
        return out, names
    with tarfile.open(path, "r:*") as tf:
        for m in tf.getmembers():
            if not m.isfile():
                continue
            top = m.name.split("/")[0]
            data = tf.extractfile(m).read()
            out.setdefault(top, {})[m.name] = data
            if m.name.endswith("/desc"):
                text = data.decode("utf-8", "replace").splitlines()
                for i, line in enumerate(text):
                    if line.strip() == "%NAME%" and i + 1 < len(text):
                        names[text[i + 1].strip()] = top
                        break
    return out, names


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    ours_path, theirs_path = argv[1], argv[2]

    if not os.path.exists(ours_path):
        print("no local database at {}; nothing to merge into".format(ours_path))
        return 0
    if not os.path.exists(theirs_path):
        print("no published database to compare against; nothing to merge")
        return 0

    ours, our_names = entries(ours_path)
    theirs, their_names = entries(theirs_path)

    missing = sorted(set(their_names) - set(our_names))
    if not missing:
        print("database already indexes everything the release does")
        return 0

    print("re-indexing {} package(s) published while this build ran:".format(len(missing)))
    for name in missing:
        print("  {}".format(name))
        ours[their_names[name]] = theirs[their_names[name]]

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as dst:
        for top in sorted(ours):
            for member in sorted(ours[top]):
                data = ours[top][member]
                info = tarfile.TarInfo(member)
                info.size = len(data)
                info.mode = 0o644
                dst.addfile(info, io.BytesIO(data))
    with open(ours_path, "wb") as fh:
        fh.write(buf.getvalue())

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
