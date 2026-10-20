#!/usr/bin/env bash
# Builds the ghidra-noprompt package, every Ghidra extension recipe in
# release-pkgbuilds/ghidra-ext-*, and one pacman database holding all of them,
# inside an archlinux:base-devel container. Run from the repo root with the
# workspace mounted at /work.
#
# The extensions are built here rather than by build-pacman-repo because each
# pins an exact ghidra-noprompt version. Published separately, a new Ghidra
# would reach users before the extensions rebuilt against it, and `pacman -Syu`
# would refuse the transaction ("breaks dependency 'ghidra-noprompt=<old>'").
# Built together, either the new Ghidra and every extension land in one database
# or -- if any extension fails to build -- this script fails and nothing is
# published, leaving users on the previous, consistent set.
#
# This package lives outside pkgbuilds/ on purpose: at ~500 MB it cannot be
# committed to the GitHub Pages repo (GitHub rejects any pushed file over
# 100 MB), so it is served from a GitHub Release instead and must not be
# touched by the build-pacman-repo pipeline.

set -euo pipefail

PKGDIR=/work/release-pkgbuilds/ghidra-noprompt
BUILDDIR=/work/.build
OUTDIR=/work/out
REPO_NAME="${REPO_NAME:-ghidra}"

pacman -Syu --noconfirm --needed --disable-download-timeout \
  archlinux-keyring base-devel curl gnupg

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

# The extensions compile against the Ghidra just built, so install it. Unlike
# the repackaging above, these really need their dependencies: a JDK to run
# gradle, and ghidra-noprompt=<this version>, which pacman -U provides.
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder
shopt -s nullglob
extdirs=(/work/release-pkgbuilds/ghidra-ext-*/)
shopt -u nullglob
if [ ${#extdirs[@]} -gt 0 ]; then
  pacman -U --noconfirm "$OUTDIR"/ghidra-noprompt-*.pkg.tar.zst
fi
for extdir in "${extdirs[@]}"; do
  ext="$(basename "$extdir")"
  echo "::group::$ext"
  extbuild="$BUILDDIR/$ext"
  install -d -o builder -g builder "$extbuild"
  install -m644 -o builder -g builder "$extdir/PKGBUILD" "$extbuild/PKGBUILD"
  su builder -c "cd '$extbuild' && makepkg --printsrcinfo > .SRCINFO"
  su builder -c "cd '$extbuild' && makepkg -f -s --noconfirm --noprogressbar"
  cp "$extbuild"/*.pkg.tar.zst "$OUTDIR/"
  cp "$extbuild/.SRCINFO" "$extdir/.SRCINFO"
  echo "::endgroup::"
done

cd "$OUTDIR"
repo-add --new "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst

# repo-add leaves ghidra.db and ghidra.files as symlinks. GitHub release assets
# cannot be symlinks, and pacman asks for exactly those two names, so replace
# them with real copies.
for ext in db files; do
  rm -f "${REPO_NAME}.${ext}"
  cp "${REPO_NAME}.${ext}.tar.gz" "${REPO_NAME}.${ext}"
done

# Sign the package and the database. Must come after the symlinks above are
# replaced with real files, so the .sig covers the bytes pacman downloads.
export SIGN_REPORT=/work/.sign-report
export PUBKEY_OUT="$OUTDIR/xerootg.asc"
bash /work/.github/scripts/sign-pacman-repo.sh "$OUTDIR" "$REPO_NAME"

# Everything below runs as root inside the container, so the runner user cannot
# clean up after us. Drop the build tree here and leave the results writable.
rm -rf "$BUILDDIR"
chmod -R a+rwX "$OUTDIR" "$PKGDIR" "${extdirs[@]}"
ls -lh "$OUTDIR"
