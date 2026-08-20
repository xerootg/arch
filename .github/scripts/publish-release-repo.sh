#!/usr/bin/env bash
# Publish a pacman repo directory to a GitHub Release, and prune what the
# database no longer references.
#
#   publish-release-repo.sh <dir> <repo-name> <release-tag>
#
# Runs on the runner, not in the Arch container: it needs gh, and the container
# has no credentials.
#
# Release assets are the right home for a pacman repo. GitHub refuses any pushed
# file over 100 MB, which is why the oversized packages had to be split into
# their own repos, but a release asset may be 2 GB. The download URL 302s to
# release-assets.githubusercontent.com and pacman follows that natively -- the
# same mechanism [ghidra] and [orca] have been using all along.
#
# It also fixes pruning. Packages pushed into the Pages repo accumulated
# forever, because deleting one only adds a commit and never reclaims anything;
# imhex had three versions live at once. Assets can simply be deleted, so the
# database is the source of truth and anything it does not name goes.

set -euo pipefail

DIR="${1:?usage: publish-release-repo.sh <dir> <repo-name> <tag>}"
REPO_NAME="${2:?}"
TAG="${3:?}"

cd "$DIR"

# What the database says should exist. That, plus signatures and the public key,
# is exactly the set of assets this release should hold.
mapfile -t WANTED < <(
  python3 - "$REPO_NAME" <<'PYEOF'
import sys, tarfile
name = sys.argv[1]
with tarfile.open(f"{name}.db.tar.gz", "r:*") as tf:
    for m in tf.getmembers():
        if not m.isfile():
            continue
        data = tf.extractfile(m).read().decode("utf-8", "replace").splitlines()
        for i, line in enumerate(data):
            if line.strip() == "%FILENAME%" and i + 1 < len(data):
                print(data[i + 1].strip())
                break
PYEOF
)
if [ ${#WANTED[@]} -eq 0 ]; then
  echo "::error::no %FILENAME% entries in ${REPO_NAME}.db.tar.gz; refusing to publish"
  exit 1
fi
echo "Database references ${#WANTED[@]} package(s)."

# Metadata that always ships alongside.
EXTRA=( "${REPO_NAME}.db" "${REPO_NAME}.files"
        "${REPO_NAME}.db.tar.gz" "${REPO_NAME}.files.tar.gz" )
[ -f xerootg.asc ] && EXTRA+=( xerootg.asc )

uploads=()
for f in "${WANTED[@]}" "${EXTRA[@]}"; do
  [ -f "$f" ] && uploads+=( "$f" )
  [ -f "$f.sig" ] && uploads+=( "$f.sig" )
done

if [ ${#uploads[@]} -eq 0 ]; then
  echo "Nothing local to upload."
else
  echo "Uploading ${#uploads[@]} file(s)."
  # --clobber so a rebuilt package or a re-signed database replaces the old one.
  gh release upload "$TAG" "${uploads[@]}" --clobber
fi

# Anything the database does not reference is superseded. Build the keep-set
# from the database rather than from what happens to be on disk: a package that
# was not rebuilt this run is absent locally but still perfectly current.
keep=$'\n'
for f in "${WANTED[@]}" "${EXTRA[@]}"; do
  keep+="${f}"$'\n'"${f}.sig"$'\n'
done

echo "Pruning superseded assets..."
pruned=0
while read -r asset; do
  [ -n "$asset" ] || continue
  case "$asset" in
    *.pkg.tar.zst|*.pkg.tar.zst.sig|*.pkg.tar.xz|*.pkg.tar.xz.sig) ;;
    *) continue ;;   # never touch databases or the key
  esac
  if ! grep -qxF "$asset" <<<"$keep"; then
    echo "  removing $asset"
    gh release delete-asset "$TAG" "$asset" --yes
    pruned=$((pruned + 1))
  fi
done < <(gh release view "$TAG" --json assets --jq '.assets[].name')
echo "Pruned $pruned superseded asset(s)."
