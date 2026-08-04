#!/usr/bin/env bash
# Builds the ghidra-noprompt package and a standalone pacman database for it,
# inside an archlinux:base-devel container. Run from the repo root with the
# workspace mounted at /work.
#
# This package lives outside pkgbuilds/ on purpose: at ~350 MB it cannot be
# committed to the GitHub Pages repo (GitHub rejects any pushed file over
# 100 MB), so it is served from a GitHub Release instead and must not be
# touched by the build-pacman-repo pipeline.

set -euo pipefail

PKGDIR=/work/release-pkgbuilds/ghidra-noprompt
BUILDDIR=/work/.build
OUTDIR=/work/out
REPO_NAME="${REPO_NAME:-ghidra}"

pacman -Syu --noconfirm --needed --disable-download-timeout \
  archlinux-keyring base-devel curl

# The payload is a zip full of already-compressed jars. Level 20 spends many
# minutes to gain a percent or two over level 10.
sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -10 -)/' /etc/makepkg.conf
# Ghidra ships prebuilt native helpers; leave them as upstream built them.
sed -i 's/^OPTIONS=.*/OPTIONS=(!strip docs !libtool !staticlibs emptydirs zipman purge !debug)/' /etc/makepkg.conf

useradd -m builder
rm -rf "$BUILDDIR"
install -d -o builder -g builder "$BUILDDIR"
install -m644 -o builder -g builder "$PKGDIR/PKGBUILD" "$BUILDDIR/PKGBUILD"

# --nodeps: package() only unpacks a prebuilt distribution, so installing a JDK
# into the container would pull ~300 MB for nothing. The dependency is still
# recorded in the built package's metadata.
su builder -c "cd '$BUILDDIR' && makepkg --printsrcinfo > .SRCINFO"
su builder -c "cd '$BUILDDIR' && makepkg -f --noconfirm --nodeps --noprogressbar"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
cp "$BUILDDIR"/*.pkg.tar.zst "$OUTDIR/"
cp "$BUILDDIR/.SRCINFO" "$PKGDIR/.SRCINFO"

cd "$OUTDIR"
repo-add --new "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst

# repo-add leaves ghidra.db and ghidra.files as symlinks. GitHub release assets
# cannot be symlinks, and pacman asks for exactly those two names, so replace
# them with real copies.
for ext in db files; do
  rm -f "${REPO_NAME}.${ext}"
  cp "${REPO_NAME}.${ext}.tar.gz" "${REPO_NAME}.${ext}"
done

# Everything below runs as root inside the container, so the runner user cannot
# clean up after us. Drop the build tree here and leave the results writable.
rm -rf "$BUILDDIR"
chmod -R a+rwX "$OUTDIR" "$PKGDIR"
ls -lh "$OUTDIR"
