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

# SEED_TIME, if set, is when the database being published here was read from the
# release. Assets uploaded after that moment cannot possibly be named by it --
# another pipeline put them there -- so they are not superseded and must not be
# pruned.
#
# heavy-build makes this concrete rather than theoretical. It uploads each
# package as its job finishes but only rewrites the database once the whole
# matrix is done, which can be five hours later. For that entire window the
# release holds packages the database does not name, and pruning by the database
# alone would delete work that just succeeded.
SEED_TIME="${SEED_TIME:-}"

cd "$DIR"

# What the database says should exist. That, plus signatures and the public key,
# is exactly the set of assets this release should hold.
mapfile -t WANTED < <(
  python3 - "$REPO_NAME" %FILENAME% <<'PYEOF'
import sys, tarfile
name, key = sys.argv[1], sys.argv[2]
with tarfile.open(f"{name}.db.tar.gz", "r:*") as tf:
    for m in tf.getmembers():
        if not m.isfile():
            continue
        data = tf.extractfile(m).read().decode("utf-8", "replace").splitlines()
        for i, line in enumerate(data):
            if line.strip() == key and i + 1 < len(data):
                print(data[i + 1].strip())
                break
PYEOF
)

# Every package NAME the database knows, which is a different question from
# every filename it names. The prune below needs both.
mapfile -t KNOWN_NAMES < <(
  python3 - "$REPO_NAME" %NAME% <<'PYEOF'
import sys, tarfile
name, key = sys.argv[1], sys.argv[2]
with tarfile.open(f"{name}.db.tar.gz", "r:*") as tf:
    for m in tf.getmembers():
        if not m.isfile():
            continue
        data = tf.extractfile(m).read().decode("utf-8", "replace").splitlines()
        for i, line in enumerate(data):
            if line.strip() == key and i + 1 < len(data):
                print(data[i + 1].strip())
                break
PYEOF
)
known=$'\n'
for n in "${KNOWN_NAMES[@]}"; do known+="${n}"$'\n'; done
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

# Verify before pruning. GitHub rewrites some characters in asset names on
# upload -- ':' becomes '.', which broke every package with an epoch until
# sanitize-epoch-filenames.py started applying the substitution up front. If
# some other character ever gets the same treatment the symptom is silent: the
# database names a file the release does not have, pacman 404s on it, and the
# prune below deletes the package for not matching. Catch it here instead.
mapfile -t ON_RELEASE < <(gh release view "$TAG" --json assets --jq '.assets[].name')
missing=()
for f in "${WANTED[@]}"; do
  printf '%s\n' "${ON_RELEASE[@]}" | grep -qxF "$f" || missing+=( "$f" )
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "::error::the database names ${#missing[@]} file(s) the release does not have."
  echo "::error::pacman would 404 on these, and the prune would delete them:"
  printf '::error::  %s\n' "${missing[@]}"
  echo "::error::if a name differs only by punctuation, GitHub rewrote it on upload"
  echo "::error::and sanitize-epoch-filenames.py needs to learn that substitution."
  exit 1
fi
echo "All ${#WANTED[@]} database entries have a matching asset."

echo "Pruning superseded assets..."
[ -n "$SEED_TIME" ] && echo "Keeping anything uploaded after $SEED_TIME."
pruned=0
kept_newer=0
kept_foreign=0
while IFS=$'\t' read -r asset updated; do
  [ -n "$asset" ] || continue
  case "$asset" in
    *.pkg.tar.zst|*.pkg.tar.zst.sig|*.pkg.tar.xz|*.pkg.tar.xz.sig) ;;
    *) continue ;;   # never touch databases or the key
  esac
  grep -qxF "$asset" <<<"$keep" && continue

  # Only prune a package this database actually knows about.
  #
  # "Not named by the database" is not the same as "superseded". heavy-build
  # publishes packages this pipeline has never heard of, and adds them to the
  # database hours later when its matrix finishes -- so for that window they
  # look exactly like stale assets. Run #384 deleted all ten of them on that
  # reasoning. If the database has no entry for the package name at all, it is
  # not our stale copy to delete; only a different version of a package we do
  # know is.
  #
  # A pacman filename is <name>-<pkgver>-<pkgrel>-<arch>.pkg.tar.<ext>, so
  # dropping the last three dash-separated fields leaves the name.
  base="${asset%.sig}"
  base="${base%.pkg.tar.*}"
  pkgname="${base%-*-*-*}"
  if ! grep -qxF "$pkgname" <<<"$known"; then
    echo "  keeping $asset (this database has no $pkgname; not ours to prune)"
    kept_foreign=$((kept_foreign + 1))
    continue
  fi

  # Both are RFC 3339 in UTC, so a string comparison is a time comparison.
  if [ -n "$SEED_TIME" ] && [[ "$updated" > "$SEED_TIME" ]]; then
    echo "  keeping $asset (uploaded $updated, after this database was read)"
    kept_newer=$((kept_newer + 1))
    continue
  fi

  echo "  removing $asset"
  gh release delete-asset "$TAG" "$asset" --yes
  pruned=$((pruned + 1))
done < <(gh release view "$TAG" --json assets \
           --jq '.assets[] | "\(.name)\t\(.updatedAt)"')
echo "Pruned $pruned superseded asset(s); kept $kept_newer newer than this run"
echo "and $kept_foreign belonging to packages this database does not track."
