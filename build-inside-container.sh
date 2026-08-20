#!/usr/bin/env bash

set -e

# Container setup
pacman -Syu --disable-download-timeout --needed --noconfirm \
  archlinux-keyring \
  base-devel \
  git \
  gnupg \
  reflector \
  wget \
  rust \
  go \
  tree

# Update mirrors with retry (after reflector is installed)
echo "🔄 Updating mirror list..."
for i in {1..5}; do
  echo "  Attempt $i/5..."
  if reflector --latest 10 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    echo "✅ Mirror list updated successfully"
    break
  fi
  if [ $i -eq 5 ]; then
    echo "⚠️ Failed to update mirrors after 5 attempts, using existing mirrorlist"
  else
    sleep $((i * 5))
  fi
done

GID=$(id -g)

# git refuses to run if the files are not owned by the user running git
# needed for pkginfo VCS stamping in makepkg
chown -R $UID:$GID /workspace/yay
chown -R $UID:$GID /workspace/pacman-repo-builder
chown -R $UID:$GID /workspace/repo

# Build and install build-pacman-repo
cd /workspace/pacman-repo-builder
sed -i "s/alpm = \"[^\"]*\"/alpm = \"*\"/" Cargo.toml
cargo update -p alpm --aggressive
cargo build --release || (cargo fix --lib -p pacman-repo-builder && cargo build --release)
install -Dm755 target/release/build-pacman-repo /usr/local/bin/build-pacman-repo

# Patch makepkg
cd /workspace/repo
build-pacman-repo patch-makepkg --replace --unsafe-ignore-unknown-changes
# Keep --ultra -20. The 128 MiB window is doing real work here: these packages
# carry thousands of near-identical printer profiles and mesh resources, and
# dropping to level 19's 8 MiB window was measured at 3 MB -> 22 MB on
# orca-slicer-git-extras alone. Only the thread count is capped -- -T0 multiplied
# the per-thread window allocation by every core for no ratio benefit.
sed -i "s/COMPRESSZST=.*/COMPRESSZST=(zstd -c -T2 --ultra -20 -)/" /etc/makepkg.conf
sed -i "s/OPTIONS=.*/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)/" /etc/makepkg.conf

# Install yay as root
cd /workspace/yay
# Ensure .git is present for VCS stamping
if [ ! -d .git ]; then
  echo "ERROR: .git directory missing in /workspace/yay. VCS stamping will fail."
  exit 10
fi
makepkg -si --noconfirm

# Setup yay wrapper
cd /workspace/repo
chmod +x yay-noninteractive

# Materialise any member directory that is not already present.
#
# Most packages here are git submodules pointing at the AUR, but adding a
# submodule requires cloning it to record a commit, which is not always possible
# from wherever this repo is being edited. The members list in
# build-pacman-repo.yaml is the single source of truth for what gets built, so
# anything listed there without a directory is cloned straight from the AUR at
# build time. Existing submodules already have a directory and are left alone.
echo "📥 Checking for member directories that need cloning..."
python3 -c "
import re
text = open('build-pacman-repo.yaml').read()
block = text.split('members:', 1)[1] if 'members:' in text else ''
for line in block.splitlines():
    if line.lstrip().startswith('#'):
        continue
    m = re.match(r'\s*-?\s*directory:\s*(\S+)', line)
    if m:
        print(m.group(1))
" > /tmp/members.txt

NEED=()
while read -r member; do
  [ -n "$member" ] || continue
  if [ -d "pkgbuilds/$member" ] && [ -f "pkgbuilds/$member/PKGBUILD" ]; then
    continue
  fi
  NEED+=("$member")
done < /tmp/members.txt

if [ ${#NEED[@]} -gt 0 ]; then
  # AUR git repositories are named by *pkgbase*, not pkgname. Cloning by
  # pkgname does not fail -- the AUR git server hands back an empty repository
  # rather than a 404 -- so the mistake shows up later as a directory with no
  # PKGBUILD. Resolve pkgbase through the RPC before cloning anything.
  #
  # curl needs --globoff here: the arg[] parameters contain brackets, which curl
  # otherwise treats as a glob range and mangles.
  QUERY=""
  for m in "${NEED[@]}"; do QUERY="${QUERY}&arg[]=${m}"; done
  if ! curl -fsSL --globoff "https://aur.archlinux.org/rpc/v5/info?${QUERY#&}" -o /tmp/aur-info.json; then
    echo "::error::could not query the AUR RPC"
    exit 4
  fi

  python3 -c "
import json
d = json.load(open('/tmp/aur-info.json'))
for r in d.get('results', []):
    print(r['Name'], r['PackageBase'])
" > /tmp/pkgbase.txt

  declare -A BASE_OF
  declare -A FIRST_MEMBER_OF_BASE
  while read -r name base; do
    [ -n "$name" ] || continue
    BASE_OF["$name"]="$base"
  done < /tmp/pkgbase.txt

  for member in "${NEED[@]}"; do
    base="${BASE_OF[$member]}"
    if [ -z "$base" ]; then
      echo "::error::$member is not in the AUR (no RPC result). Remove it from"
      echo "         build-pacman-repo.yaml, or correct the name."
      exit 4
    fi
    if [ "$base" != "$member" ]; then
      echo "  $member is a split package of pkgbase $base"
    fi
    # build-pacman-repo refuses to run when two member directories carry the
    # same pkgbase ("Duplication detected"), so this is fatal rather than a
    # warning. One entry per pkgbase builds every split package it produces.
    # Caught here in seconds instead of after cloning everything.
    if [ -n "${FIRST_MEMBER_OF_BASE[$base]}" ]; then
      echo "::error::$member and ${FIRST_MEMBER_OF_BASE[$base]} are both split packages"
      echo "         of pkgbase $base. build-pacman-repo rejects duplicate pkgbases."
      echo "         Keep one of them in build-pacman-repo.yaml and drop the other --"
      echo "         the single build produces both packages."
      exit 4
    fi
    FIRST_MEMBER_OF_BASE["$base"]="$member"

    echo "  cloning $base -> pkgbuilds/$member"
    rm -rf "pkgbuilds/$member"
    if ! git clone --quiet --depth=1 "https://aur.archlinux.org/${base}.git" "pkgbuilds/$member"; then
      echo "::error::could not clone $base from the AUR"
      exit 4
    fi
    if [ ! -f "pkgbuilds/$member/PKGBUILD" ]; then
      echo "::error::$base cloned but has no PKGBUILD"
      exit 4
    fi
    chown -R "$UID:$GID" "pkgbuilds/$member"
  done
fi

# Prepare sources and update SRCINFO
for dir in pkgbuilds/*/; do
  if grep -q "^pkgver()" "$dir/PKGBUILD" 2>/dev/null; then
    echo "📥 Fetching sources for $(basename "$dir")..."
    (cd "$dir" && makepkg -od --nobuild --noconfirm) || true
  fi
done

echo "🔄 Updating .SRCINFO files..."
build-pacman-repo sync-srcinfo --update

# Import the upstream release keys the PKGBUILDs pin.
#
# A PKGBUILD with validpgpkeys verifies its source tarball against that key, and
# a fresh container has an empty keyring, so the build dies with
# "FAILED (unknown public key ...)" -- which is what stopped libkcompactdisc.
# Import them rather than reaching for --skippgpcheck: the whole point of the
# check is that upstream's tarball is what upstream published.
echo "🔑 Importing validpgpkeys declared by the PKGBUILDs..."
mapfile -t VALIDKEYS < <(
  grep -h '^[[:space:]]*validpgpkeys = ' pkgbuilds/*/.SRCINFO 2>/dev/null \
    | sed 's/.*= //' | tr -d '[:space:]' | sort -u
)
if [ ${#VALIDKEYS[@]} -gt 0 ]; then
  echo "  ${#VALIDKEYS[@]} key(s) to fetch"
  for key in "${VALIDKEYS[@]}"; do
    [ -n "$key" ] || continue
    got=0
    # hkps:// explicitly. A bare hostname makes gpg use hkp on port 11371, which
    # is blocked on GitHub runners, so every --recv-keys silently times out --
    # which is how libkcompactdisc kept failing on "unknown public key" even
    # after key import was added. hkps is plain 443.
    for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
      if timeout 60 gpg --batch --quiet --keyserver "$ks" --recv-keys "$key" 2>/dev/null; then
        echo "  ✅ $key (from $ks)"
        got=1
        break
      fi
    done
    # Last resort: the keyserver's plain HTTPS lookup endpoint. No hkp, no SRV
    # records, nothing but a GET -- if this fails the key really is unreachable.
    if [ "$got" -eq 0 ]; then
      if curl -fsSL --max-time 60 \
           "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${key}" \
           | gpg --batch --quiet --import 2>/dev/null; then
        echo "  ✅ $key (via https lookup)"
        got=1
      fi
    fi
    # Not fatal: only the packages pinning this key fail, and they carry
    # allow-failure. Killing the run would punish every other package.
    [ "$got" -eq 1 ] || echo "  ::warning::could not fetch validpgpkey $key"
  done
else
  echo "  none declared"
fi

echo "📄 Current .SRCINFO files:"
find pkgbuilds -name ".SRCINFO" -exec cat {} \;

for dir in pkgbuilds/*/; do
  if [ -f "$dir/PKGBUILD" ]; then
    echo "🧹 Cleaning sources for $(basename "$dir")..."
    (cd "$dir" && makepkg -odc --noconfirm) || true
  fi
done

# Check for outdated packages
echo ""
echo "🔍 Debug: Existing packages in repo directory:"
ls -1 /workspace/repo-out/*.pkg.tar.zst 2>/dev/null | xargs -I{} basename {} || echo "  (none)"

echo ""
echo "🔍 Debug: Running outdated check with full details:"
build-pacman-repo outdated --details lossy-yaml || true

echo ""
# A plain directory now, not a checkout of the Pages repo. The packages are
# published as GitHub Release assets, which lifts the 100 MB per-file push limit
# that forced the oversized packages into repos of their own.
REPO_DIR="/workspace/repo-out"
mkdir -p "$REPO_DIR"

# Bootstrap an empty database if the release has none yet.
#
# build-pacman-repo reads the database to work out what is outdated, and it has
# always been there before -- the old layout checked out the Pages repo, which
# carried a committed custom.db.tar.gz. A freshly created release has nothing,
# so the very first run of this repo has no database to read. repo-add cannot
# make an empty one (it needs at least one package), but an empty gzipped tar is
# exactly what an empty database is.
for db in "${REPO_NAME:-custom}.db" "${REPO_NAME:-custom}.files"; do
  if [ ! -f "$REPO_DIR/${db}.tar.gz" ]; then
    echo "No ${db}.tar.gz yet; creating an empty database to bootstrap."
    tar -czf "$REPO_DIR/${db}.tar.gz" --files-from /dev/null
    cp "$REPO_DIR/${db}.tar.gz" "$REPO_DIR/${db}"
  fi
done

OUTDATED=$(build-pacman-repo outdated --details pkgname)
BUILT=false
if [ -z "$OUTDATED" ]; then
  echo "✅ All packages are up-to-date, nothing to build"
else
  echo "📦 Outdated packages to build:"
  echo "$OUTDATED"
  # Build if outdated
  build-pacman-repo build || (echo "build-pacman-repo failed" && tree -lah pkgbuilds/ -I "src|pkg|.git|.cache" && exit 2)
  BUILT=true
  # Verify packages
  echo ""
  echo ""
  echo "📦 Packages in repository:"
  ls -lah "$REPO_DIR/"*.pkg.tar.zst 2>/dev/null || echo "  (none found)"
  PKG_COUNT=$(find "$REPO_DIR" -maxdepth 1 -name "*.pkg.tar.zst" | wc -l)
  if [ "$PKG_COUNT" -eq 0 ]; then
    echo "ERROR: No packages found in repository"
    exit 3
  fi
  echo "✅ Found $PKG_COUNT package(s):"
  find "$REPO_DIR" -maxdepth 1 -name "*.pkg.tar.zst" | while read -r pkg; do
    size_mb=$(du -m "$pkg" | cut -f1)
    echo "$(basename "$pkg") - ${size_mb}MB"
  done
fi

# Release assets top out at 2 GB each. Far more headroom than the 100 MB push
# limit this repo used to live under, but still a hard wall: an oversized asset
# is rejected at upload and the run would publish a database referencing a
# package nobody can download. Name it here instead.
MAX_MB=1900
OVERSIZED=""
while read -r pkg; do
  [ -n "$pkg" ] || continue
  size_mb=$(du -m "$pkg" | cut -f1)
  if [ "$size_mb" -gt "$MAX_MB" ]; then
    OVERSIZED="${OVERSIZED}  $(basename "$pkg") - ${size_mb}MB
"
  fi
done < <(find "$REPO_DIR" -maxdepth 1 -name "*.pkg.tar.zst")

if [ -n "$OVERSIZED" ]; then
  echo "::error::package(s) too large for a GitHub release asset (limit ${MAX_MB}MB):"
  printf '%s' "$OVERSIZED"
  exit 5
fi

# Sign unconditionally, whether or not anything was rebuilt.
#
# build-pacman-repo cannot do this itself: it calls `repo-add --quiet --nocolor`
# with no way to pass --sign, and it knows nothing about GPG. Signing here also
# covers the packages that were already in the repo and were not rebuilt this
# run -- pacman wants a .sig beside every package once SigLevel is Required,
# and an untouched package would otherwise never get one.
echo ""
echo "🔏 Signing the repository..."
export SIGN_REPORT=/workspace/.sign-report
export PUBKEY_OUT="$REPO_DIR/xerootg.asc"
bash /workspace/repo/.github/scripts/sign-pacman-repo.sh "$REPO_DIR" "${REPO_NAME:-custom}"

echo ""
echo "📦 Final repository contents:"
ls -lh "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null || echo "  (none)"

# Hand the results back to the runner user, which does the publishing.
chmod -R a+rwX "$REPO_DIR"
