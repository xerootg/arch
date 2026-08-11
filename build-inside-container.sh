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

# Prepare sources and update SRCINFO
for dir in pkgbuilds/*/; do
  if grep -q "^pkgver()" "$dir/PKGBUILD" 2>/dev/null; then
    echo "📥 Fetching sources for $(basename "$dir")..."
    (cd "$dir" && makepkg -od --nobuild --noconfirm) || true
  fi
done

echo "🔄 Updating .SRCINFO files..."
build-pacman-repo sync-srcinfo --update

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
ls -1 /workspace/github-pages/archlinux/*.pkg.tar.zst 2>/dev/null | xargs -I{} basename {} || echo "  (none)"

echo ""
echo "🔍 Debug: Running outdated check with full details:"
build-pacman-repo outdated --details lossy-yaml || true

echo ""
REPO_DIR="/workspace/github-pages/archlinux"
test -d "$REPO_DIR" || { echo "cannot find the gh pages repo, exiting"; exit 1; }

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
export PUBKEY_OUT=/workspace/github-pages/xerootg.asc
bash /workspace/repo/.github/scripts/sign-pacman-repo.sh "$REPO_DIR" custom

SIGNED=$(sed -n 's/^signed=//p' "$SIGN_REPORT" 2>/dev/null || true)
REMOVED=$(sed -n 's/^removed=//p' "$SIGN_REPORT" 2>/dev/null || true)
SIGNED=${SIGNED:-0}
REMOVED=${REMOVED:-0}

# The Pages repo is worth pushing if packages changed *or* signatures did.
if [ "$BUILT" = true ]; then
  PACKAGE_LIST=$(echo "$OUTDATED" | tr '\n' ',' | sed 's/,$//')
  echo "has_outdated=true" >> /workspace/.github-output
  echo "packages=$PACKAGE_LIST" >> /workspace/.github-output
elif [ "$SIGNED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
  echo "has_outdated=true" >> /workspace/.github-output
  echo "packages=signatures ($SIGNED signed, $REMOVED removed)" >> /workspace/.github-output
else
  echo "has_outdated=false" >> /workspace/.github-output
fi
chmod ugo+r /workspace/.github-output
