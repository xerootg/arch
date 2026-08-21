#!/usr/bin/env python3
"""Print one field per package from a pacman database.

    db-entries.py <repo-name> [%FILENAME%|%NAME%] [dir]

Reads <repo-name>.db.tar.gz and prints the requested field for every package
in it, one per line. Missing database prints nothing and exits 0 -- a repo
that has never published is empty, not broken.

This exists because three callers needed the same six lines of tar-walking and
one of them had to embed it in a YAML block scalar, where the indentation rules
for a heredoc body are their own small trap.
"""

import os
import sys
import tarfile


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    repo = argv[1]
    field = argv[2] if len(argv) > 2 else "%FILENAME%"
    directory = argv[3] if len(argv) > 3 else "."

    path = os.path.join(directory, repo + ".db.tar.gz")
    if not os.path.exists(path):
        return 0

    with tarfile.open(path, "r:*") as tf:
        for m in tf.getmembers():
            if not m.isfile():
                continue
            data = tf.extractfile(m).read().decode("utf-8", "replace").splitlines()
            for i, line in enumerate(data):
                if line.strip() == field and i + 1 < len(data):
                    print(data[i + 1].strip())
                    break
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
