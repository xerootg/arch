#!/usr/bin/env bash
# Build exactly one AUR package, in its own container, and leave the results in
# /work/out. Signing and publishing happen outside.
#
#   build-one.sh <pkgname>
#
# Reads from the environment:
#   MAKE_JOBS   cap on make/ninja parallelism (default 2)
#   USE_CCACHE  "true" to compile through ccache
#   SKIP_IF     a filename already published; if this build would produce it,
#               exit 0 without building
#
# Deliberately plain makepkg, not build-pacman-repo. The packages routed here
# are the ones that tool cannot or should not handle -- including one whose
# split packages it considers a dependency cycle.

set -euo pipefail

PKG="${1:?usage: build-one.sh <pkgname>}"
OUT=/work/out
SRCDEST=/work/cache/src
CCACHE_DIR=/work/cache/ccache
mkdir -p "$OUT" "$SRCDEST" "$CCACHE_DIR"

pacman -Syu --noconfirm --needed --disable-download-timeout \
  archlinux-keyring base-devel git curl jq gnupg >/dev/null

# Same packaging rules as the main pipeline, so a package built here is
# indistinguishable from one built there.
sed -i 's/^OPTIONS=.*/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)/' /etc/makepkg.conf
sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T2 --ultra -20 -)/' /etc/makepkg.conf
# Reuse downloaded sources across runs. makepkg checksums everything it reuses,
# so a poisoned cache cannot silently change what gets built.
sed -i "s|^#\?SRCDEST=.*|SRCDEST=$SRCDEST|" /etc/makepkg.conf
grep -q '^SRCDEST=' /etc/makepkg.conf || echo "SRCDEST=$SRCDEST" >> /etc/makepkg.conf

echo "MAKEFLAGS=\"-j${MAKE_JOBS:-2}\"" >> /etc/makepkg.conf
echo "NINJAFLAGS=\"-j${MAKE_JOBS:-2}\"" >> /etc/makepkg.conf

if [ "${USE_CCACHE:-false}" = "true" ]; then
  pacman -S --noconfirm --needed ccache >/dev/null
  sed -i 's/^BUILDENV=.*/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf
  export CCACHE_DIR
  ccache --max-size=4G >/dev/null 2>&1 || true
  echo "ccache enabled ($(ccache --show-stats 2>/dev/null | head -3 | tr '\n' ' '))"
fi

useradd -m builder 2>/dev/null || true
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
chown -R builder:builder "$SRCDEST" "$CCACHE_DIR"

# AUR repositories are named by pkgbase, not pkgname.
base="$(curl -fsSL --globoff "https://aur.archlinux.org/rpc/v5/info?arg[]=${PKG}" \
        | jq -r '.results[0].PackageBase // empty')"
[ -n "$base" ] || { echo "::error::$PKG is not in the AUR"; exit 3; }
[ "$base" != "$PKG" ] && echo "pkgbase: $base"

d=/work/build
rm -rf "$d"
install -d -o builder -g builder "$d"
su builder -c "git clone -q --depth=1 https://aur.archlinux.org/${base}.git '$d/src'"

# validpgpkeys over hkps -- a bare hostname uses hkp on 11371, which CI blocks.
su builder -c "cd '$d/src' && makepkg --printsrcinfo" > "$d/.SRCINFO" 2>/dev/null || true
while read -r key; do
  [ -n "$key" ] || continue
  for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
    su builder -c "timeout 60 gpg --batch --quiet --keyserver $ks --recv-keys $key" 2>/dev/null \
      && { echo "imported validpgpkey $key"; break; }
  done
done < <(sed -n 's/^[[:space:]]*validpgpkeys = //p' "$d/.SRCINFO" | tr -d '[:space:]')

# A -git package's version is only known after the sources are fetched, so
# resolve it before deciding whether there is anything to do.
if grep -q '^pkgver()' "$d/src/PKGBUILD"; then
  echo "Resolving pkgver from sources..."
  su builder -c "cd '$d/src' && makepkg -od --nobuild --noconfirm --skippgpcheck" >/dev/null 2>&1 || true
  su builder -c "cd '$d/src' && makepkg --printsrcinfo" > "$d/.SRCINFO" 2>/dev/null || true
fi
version="$(sed -n 's/^[[:space:]]*pkgver = //p' "$d/.SRCINFO" | head -1)"
release="$(sed -n 's/^[[:space:]]*pkgrel = //p' "$d/.SRCINFO" | head -1)"
echo "version: ${version}-${release}"

# The release is the build cache. If this exact version is already published
# there is nothing to build, and that costs no cache quota at all.
if [ -n "${SKIP_IF:-}" ] && [ -n "$version" ]; then
  if grep -q -- "-${version}-${release}-" <<<"$SKIP_IF"; then
    echo "Already published at ${version}-${release}; nothing to do."
    echo "skipped=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
fi

set +e
su builder -c "cd '$d/src' && makepkg -s --noconfirm --noprogressbar --nocheck" 2>&1 \
  | grep --line-buffered -vE '^-- (Installing|Up-to-date): '
rc=${PIPESTATUS[0]}
set -e

if [ "$USE_CCACHE" = "true" ]; then
  ccache --show-stats 2>/dev/null | head -6 || true
fi

[ "$rc" -eq 0 ] || { echo "::error::makepkg exited $rc for $PKG"; exit "$rc"; }

cp "$d/src"/*.pkg.tar.zst "$OUT/"
chmod -R a+rwX "$OUT" "$SRCDEST" "$CCACHE_DIR"
echo "Built:"
ls -lh "$OUT"
