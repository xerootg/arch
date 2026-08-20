#!/usr/bin/env bash
# Build exactly one AUR package, in its own container, and leave the results in
# /work/out. Signing and publishing happen outside.
#
#   build-one.sh <pkgname>
#
# Reads from the environment:
#   MAKE_JOBS   cap on make/ninja parallelism (default 2)
#   USE_CCACHE  "true" to compile through ccache
#   USE_LTO     "false" to build without link-time optimisation (default true)
#   SKIP_IF     a filename already published; if this build would produce it,
#               exit 0 without building
#   GH_REPO     owner/repo the [custom] release lives on (default xerootg/arch)
#   RELEASE_TAG the release tag holding [custom] (default custom-repo)
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
  archlinux-keyring base-devel git curl jq gnupg python >/dev/null

# Same packaging rules as the main pipeline, so a package built here is
# indistinguishable from one built there.
#
# LTO is the one that is not always safe. ggml-sycl-f32-git links its examples
# against symbols from a static common library, and under LTO with icpx those
# come back as undefined references out of ld-temp.o -- the same class of
# problem that forced options=('!lto') on orca-slicer. USE_LTO=false turns it
# off for a single package rather than for everything.
if [ "${USE_LTO:-true}" = "false" ]; then
  lto_opt='!lto'
  echo "LTO disabled for this package."
else
  lto_opt='lto'
fi
sed -i "s/^OPTIONS=.*/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug $lto_opt)/" /etc/makepkg.conf
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

# Make everything already published available as a build dependency.
#
# These packages depend on other AUR packages, and the container only knows the
# stock Arch repos -- so ilspy-git asked for dotnet-sdk-preview-bin and
# powershell, llama.cpp-sycl-f32-git asked for ggml-sycl-f32-git, and pacman
# said "target not found" for all three despite this project building every one
# of them. [custom] is where they live, so point the builder at it.
#
# This is also what makes an incremental multi-pipeline build work at all: a
# dependency built by build-repo, or by an earlier run of this workflow, is
# picked up from the release rather than rebuilt from source here.
CUSTOM_URL="https://github.com/${GH_REPO:-xerootg/arch}/releases/download/${RELEASE_TAG:-custom-repo}"

if curl -fsSL "$CUSTOM_URL/xerootg.asc" -o /tmp/xerootg.asc; then
  pacman-key --init >/dev/null 2>&1 || true
  pacman-key --populate archlinux >/dev/null 2>&1 || true
  pacman-key --add /tmp/xerootg.asc >/dev/null
  # --lsign-key wants the PRIMARY fingerprint. A signature names the signing
  # subkey, so reading it off the key itself is the only thing that works.
  fpr="$(gpg --show-keys --with-colons /tmp/xerootg.asc | awk -F: '/^fpr:/{print $10; exit}')"
  pacman-key --lsign-key "$fpr" >/dev/null
  echo "trusting [custom] signing key $fpr"
  siglevel="Required DatabaseOptional"
else
  # No key published yet. Still usable, just unverified -- and worth saying so
  # out loud rather than silently downgrading.
  echo "::warning::could not fetch the [custom] signing key; using SigLevel = Optional TrustAll"
  siglevel="Optional TrustAll"
fi

cat >> /etc/pacman.conf <<PACEOF

[custom]
Server = $CUSTOM_URL
SigLevel = $siglevel
PACEOF

# Not fatal: a first run has no database published, and every dependency that
# happens to be in the stock repos still resolves.
pacman -Sy --noconfirm >/dev/null 2>&1 \
  || echo "::warning::could not refresh [custom]; only the stock repos are available"

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

# A package with an epoch has a colon in its filename, and GitHub rewrites that
# to a dot on upload. Do it here instead, so the name the manifest records, the
# name the index job re-downloads, and the name the release ends up holding are
# all the same string. No database exists in this directory, so this only
# renames files.
python3 /work/.github/scripts/sanitize-epoch-filenames.py "$OUT"

chmod -R a+rwX "$OUT" "$SRCDEST" "$CCACHE_DIR"
echo "Built:"
ls -lh "$OUT"
