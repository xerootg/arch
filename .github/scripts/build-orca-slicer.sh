#!/usr/bin/env bash
# Builds orca-slicer-git (and its -extras split package) plus a standalone
# pacman database, inside an archlinux:base-devel container. Run from the repo
# root with the workspace mounted at /work.
#
# This package lives outside pkgbuilds/ on purpose. It compresses to ~164 MB,
# and GitHub rejects any pushed file over 100 MB, so it cannot go through
# build-pacman-repo into the GitHub Pages repo -- that push is refused outright
# and takes every other package's update down with it. It is served from a
# GitHub Release instead.
#
# Unlike the ghidra-noprompt script this one really compiles: expect ~2h45m.
# The memory settings that keep it alive on a 16 GB runner live in the PKGBUILD
# itself (options=('!lto') at pkgbase level, and ninja -j2 for the main build).

set -euo pipefail

PKGDIR=/work/release-pkgbuilds/orca-slicer-git
BUILDDIR=/work/.orca-build
OUTDIR=/work/orca-out
REPO_NAME="${REPO_NAME:-orca}"

pacman -Syu --noconfirm --needed --disable-download-timeout \
  archlinux-keyring base-devel git curl

# Keep the large window: these packages carry thousands of near-identical
# printer profiles and mesh resources, and level 19's 8 MiB window was measured
# at 3 MB -> 22 MB on the -extras package alone. Cap threads instead.
sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T2 --ultra -20 -)/' /etc/makepkg.conf

useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

rm -rf "$BUILDDIR"
install -d -o builder -g builder "$BUILDDIR"
# The PKGBUILD's source array references orca-slicer-wrapper.sh alongside it.
install -m644 -o builder -g builder "$PKGDIR"/PKGBUILD "$BUILDDIR/PKGBUILD"
install -m644 -o builder -g builder "$PKGDIR"/orca-slicer-wrapper.sh "$BUILDDIR/orca-slicer-wrapper.sh"

# -s installs the makedepends (cmake, ninja, ...) via sudo as builder. This one
# genuinely needs them; it is a from-source build, not a repack.
su builder -c "cd '$BUILDDIR' && makepkg -s --noconfirm --noprogressbar --nocheck"
su builder -c "cd '$BUILDDIR' && makepkg --printsrcinfo > .SRCINFO"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
cp "$BUILDDIR"/*.pkg.tar.zst "$OUTDIR/"
cp "$BUILDDIR/.SRCINFO" "$PKGDIR/.SRCINFO"

cd "$OUTDIR"
repo-add --new "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst

# repo-add leaves the plain names as symlinks. GitHub release assets cannot be
# symlinks, and pacman asks for exactly those names.
for ext in db files; do
  rm -f "${REPO_NAME}.${ext}"
  cp "${REPO_NAME}.${ext}.tar.gz" "${REPO_NAME}.${ext}"
done

# Everything above ran as root; hand the results back to the runner user and
# drop the build tree it cannot remove itself.
rm -rf "$BUILDDIR"
chmod -R a+rwX "$OUTDIR" "$PKGDIR"
ls -lh "$OUTDIR"
