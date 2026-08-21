#!/usr/bin/env bash
# Add to a local pacman database any package the release has and it does not.
#
#   reindex-orphans.sh <dir> <repo-name> <release-tag>
#
# Prints "REINDEXED=1" to $GITHUB_OUTPUT (and stdout) when it changed the
# database, so the caller knows to re-sign.
#
# The release is the ground truth for what exists; the database is only an
# index of it. Two builders share this release, each seeds a database copy,
# spends up to two hours building, and writes it back -- so whatever the other
# one published in between is missing from the copy being written.
#
# The first attempt at this merged entries from the *published* database, which
# fails exactly when it matters: once a build-repo run has written back a
# database without ilspy-git and llama.cpp-sycl-f32-git, the published copy no
# longer names them either, so there is nothing to merge and the packages stay
# invisible while their assets sit on the release. Comparing against the assets
# is the only comparison that recovers from that state.
#
# Needs gh and docker, so it runs on the runner rather than in the build
# container, which has no credentials.

set -euo pipefail

DIR="${1:?usage: reindex-orphans.sh <dir> <repo-name> <tag>}"
REPO_NAME="${2:?}"
TAG="${3:?}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$DIR"

mapfile -t INDEXED < <(python3 "$SCRIPT_DIR/db-entries.py" "$REPO_NAME")
indexed=$'\n'
for f in "${INDEXED[@]}"; do indexed+="${f}"$'\n'; done

orphans=()
while read -r asset; do
  case "$asset" in *.pkg.tar.zst|*.pkg.tar.xz) ;; *) continue ;; esac
  grep -qxF "$asset" <<<"$indexed" && continue
  orphans+=( "$asset" )
done < <(gh release view "$TAG" --json assets --jq '.assets[].name')

if [ ${#orphans[@]} -eq 0 ]; then
  echo "The database indexes every package on the release."
  exit 0
fi

echo "${#orphans[@]} published package(s) are missing from the database:"
printf '  %s\n' "${orphans[@]}"

# repo-add reads the metadata out of the package itself, so the file has to be
# here. Only the orphans are fetched, not the whole repo.
got=()
for f in "${orphans[@]}"; do
  if gh release download "$TAG" --pattern "$f" --clobber; then
    got+=( "$f" )
  else
    echo "::warning::could not download $f to re-index it"
  fi
done

if [ ${#got[@]} -eq 0 ]; then
  echo "::warning::none of the orphans could be downloaded; database unchanged"
  exit 0
fi

docker run --rm -v "$PWD:/w" -w /w archlinux:base-devel bash -c '
  set -e
  repo-add --quiet --nocolor "'"${REPO_NAME}"'.db.tar.gz" '"${got[*]}"'
  for ext in db files; do
    rm -f "'"${REPO_NAME}"'.$ext"
    cp "'"${REPO_NAME}"'.$ext.tar.gz" "'"${REPO_NAME}"'.$ext"
  done
  chmod -R a+rwX .
'

# Do not leave the downloaded packages behind: publish-release-repo.sh uploads
# what the database names and these are already on the release, so re-uploading
# them is wasted transfer.
for f in "${got[@]}"; do rm -f "$f"; done

echo "Re-indexed ${#got[@]} package(s)."
echo "REINDEXED=1" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "REINDEXED=1"
