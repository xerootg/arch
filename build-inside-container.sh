#!/usr/bin/env bash

set -e

# Container setup
pacman -Syu --disable-download-timeout --needed --noconfirm \
  archlinux-keyring \
  base-devel \
  git \
  reflector \
  wget \
  rust \
  tree

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
sed -i "s/COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/" /etc/makepkg.conf
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
OUTDATED=$(build-pacman-repo outdated --details pkgname)
if [ -z "$OUTDATED" ]; then
  echo "✅ All packages are up-to-date, nothing to build"
  echo "has_outdated=false" >> /workspace/.github-output
else
  echo "📦 Outdated packages to build:"
  echo "$OUTDATED"
  echo "has_outdated=true" >> /workspace/.github-output
  # Convert newline-separated package names to comma-separated list for commit message
  PACKAGE_LIST=$(echo "$OUTDATED" | tr '\n' ',' | sed 's/,$//')
  echo "packages=$PACKAGE_LIST" >> /workspace/.github-output
  chmod ugo+r /workspace/.github-output
  # Build if outdated
  # Retry reflector up to 5 times with backoff
  for i in {1..5}; do
    echo "🔄 Attempting to fetch mirrors (attempt $i/5)..."
    if reflector --latest 10 --protocol http,https --sort rate --save /etc/pacman.d/mirrorlist; then
      echo "✅ Mirror list updated successfully"
      break
    fi
    if [ $i -eq 5 ]; then
      echo "⚠️ Failed to update mirrors after 5 attempts, using existing mirrorlist"
    else
      echo "⚠️ Reflector failed, retrying in $((i * 5)) seconds..."
      sleep $((i * 5))
    fi
  done
  test -d /workspace/github-pages/archlinux || (echo "cannot find the gh pages repo, exiting" && exit 1)
  build-pacman-repo build || (echo "build-pacman-repo failed" && tree -lah pkgbuilds/ -I "src|pkg|.git|.cache" && exit 2)
  # Verify packages
  REPO_DIR="/workspace/github-pages/archlinux"
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
