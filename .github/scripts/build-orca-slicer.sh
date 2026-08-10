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

# Pin OPTIONS to exactly what build-inside-container.sh uses. Leaving it to
# whatever the container image happens to ship is an uncontrolled variable in a
# build that is already memory-bound, and !debug is the part that matters:
# makepkg resolves `debug` from the pkgbase options array, falling back to this
# file. The PKGBUILD's pkgbase array is options=('!lto') and says nothing about
# debug -- the !debug in its package_*() functions only governs packaging -- so
# a stock `debug` here puts -g on every translation unit in the tree.
sed -i 's/^OPTIONS=.*/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)/' /etc/makepkg.conf

echo "--- effective makepkg.conf ---"
grep -E '^(OPTIONS|COMPRESSZST|CFLAGS|CXXFLAGS|DEBUG_CFLAGS|MAKEFLAGS)=' /etc/makepkg.conf

# Sample to a FILE, not just stdout. The previous attempt only echoed, and the
# samples were then unreadable: cmake emits thousands of "-- Installing:" lines
# per second during the dependency install, the log API only serves the tail,
# and every useful line was buried under OpenCASCADE headers. The file is
# uploaded as an artifact by the workflow, so it survives a clean failure even
# when the tail is worthless.
RESOURCE_LOG="${RESOURCE_LOG:-/work/resources.log}"
: > "$RESOURCE_LOG"
chmod a+rw "$RESOURCE_LOG"
( while sleep 30; do
    printf '%s mem=%s swap=%s disk_work=%s disk_root=%s load=%s\n' \
      "$(date -u +%H:%M:%S)" \
      "$(free -m | awk '/^Mem:/{print $3"/"$2"MB"}')" \
      "$(free -m | awk '/^Swap:/{print $3"/"$2"MB"}')" \
      "$(df -m /work | awk 'NR==2{print $4"MB"}')" \
      "$(df -m / | awk 'NR==2{print $4"MB"}')" \
      "$(cut -d' ' -f1-3 /proc/loadavg)" >> "$RESOURCE_LOG"
  done ) &
_sampler=$!
trap 'kill "$_sampler" 2>/dev/null || true' EXIT

# Echo a copy into the stream too, but rarely enough to survive the flood.
( while sleep 300; do tail -1 "$RESOURCE_LOG" | sed 's/^/[resources] /'; done ) &
_echoer=$!
trap 'kill "$_sampler" "$_echoer" 2>/dev/null || true' EXIT

useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

rm -rf "$BUILDDIR"
install -d -o builder -g builder "$BUILDDIR"
# The PKGBUILD's source array references orca-slicer-wrapper.sh alongside it.
install -m644 -o builder -g builder "$PKGDIR"/PKGBUILD "$BUILDDIR/PKGBUILD"
install -m644 -o builder -g builder "$PKGDIR"/orca-slicer-wrapper.sh "$BUILDDIR/orca-slicer-wrapper.sh"

# makepkg -s is not enough here. This PKGBUILD is a split package and declares
# its depends inside package_orca-slicer-git(), where makepkg cannot see them
# when it resolves dependencies -- only the pkgbase makedepends get installed.
# The build genuinely needs the runtime ones too: deps/CMakeLists.txt is patched
# to build wxWidgets against system GTK3, so a missing gtk3 fails the configure
# step with "Could NOT find GTK3" about five minutes in.
#
# Take the union from .SRCINFO instead, which flattens every package section's
# arrays, and strip any version constraints before handing them to pacman. This
# is what build-pacman-repo was doing via yay before this package moved out.
su builder -c "cd '$BUILDDIR' && makepkg --printsrcinfo > .SRCINFO"
mapfile -t DEPS < <(
  sed -n 's/^[[:space:]]*\(make\)\?depends = //p' "$BUILDDIR/.SRCINFO" \
    | sed 's/[<>=].*$//' \
    | sort -u
)
if [ ${#DEPS[@]} -eq 0 ]; then
  echo "::error::no dependencies parsed from .SRCINFO"
  exit 1
fi

# Some depends come from xerootg's own repo rather than the official ones --
# ttf-nanum, for instance. pacman aborts the whole transaction on an unknown
# target, so drop those here. They are runtime fonts and data, not build inputs;
# the built package still records the dependency and pacman resolves it from
# [custom] at install time.
AVAILABLE=(); SKIPPED=()
for dep in "${DEPS[@]}"; do
  if pacman -Si "$dep" >/dev/null 2>&1; then
    AVAILABLE+=("$dep")
  else
    SKIPPED+=("$dep")
  fi
done
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "Not in the official repos, skipping: ${SKIPPED[*]}"
fi
echo "Installing ${#AVAILABLE[@]} dependencies: ${AVAILABLE[*]}"
pacman -S --needed --noconfirm --disable-download-timeout "${AVAILABLE[@]}"

# Fail loudly rather than five minutes into a cmake configure.
for probe in gtk3 webkit2gtk-4.1 glew; do
  pacman -Qi "$probe" >/dev/null 2>&1 || { echo "::error::$probe missing after dependency install"; exit 1; }
done

# Filter cmake's install chatter. It is thousands of lines per second and zero
# information, and it is what made the last two failures undiagnosable: the log
# API serves only the tail, so the flood pushed every useful line out of reach.
# PIPESTATUS keeps makepkg's real exit code, which a bare pipe would discard.
set +e
su builder -c "cd '$BUILDDIR' && makepkg -f --noconfirm --noprogressbar --nocheck" 2>&1 \
  | grep --line-buffered -vE '^-- (Installing|Up-to-date): '
_rc=${PIPESTATUS[0]}
set -e
if [ "$_rc" -ne 0 ]; then
  echo "::error::makepkg exited $_rc"
  echo "--- final resource samples ---"
  tail -20 "$RESOURCE_LOG" || true
  exit "$_rc"
fi

echo "--- resource samples (build complete) ---"
tail -5 "$RESOURCE_LOG" || true

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
