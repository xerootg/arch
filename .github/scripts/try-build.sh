#!/usr/bin/env bash
# Build one or more AUR packages on their own and report exactly why each fails.
#
#   try-build.sh <pkgname> [pkgname...]
#
# The full pipeline takes 45 minutes and buries per-package errors in a log the
# API will only serve the tail of, so a package that fails under allow-failure
# is effectively undiagnosable from the run. This builds only what is named,
# keeps each package's output in its own file, and prints the tail of the ones
# that failed.
#
# Read-only with respect to the published repos: it builds, it never publishes.

set -uo pipefail   # deliberately not -e: a failing build is the subject here

LOGDIR="${LOGDIR:-/work/try-build-logs}"
mkdir -p "$LOGDIR"

pacman -Syu --noconfirm --needed --disable-download-timeout \
  archlinux-keyring base-devel git curl jq >/dev/null

sed -i 's/^OPTIONS=.*/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)/' /etc/makepkg.conf

# Same repo set the real pipeline has. Without [custom] this reports "target
# not found" for dependencies this project publishes -- a verdict that says
# more about the probe than about the package, which is the opposite of what
# this script is for.
. "$(dirname "${BASH_SOURCE[0]}")/enable-custom-repo.sh"

useradd -m builder 2>/dev/null || true
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

if ! command -v yay >/dev/null 2>&1; then
  install -d -o builder -g builder /tmp/yay-build
  su builder -c 'git clone -q https://aur.archlinux.org/yay-bin.git /tmp/yay-build/yay-bin'
  su builder -c 'cd /tmp/yay-build/yay-bin && makepkg -si --noconfirm --noprogressbar' >/dev/null 2>&1
fi

declare -a OK=() BAD=()

for pkg in "$@"; do
  echo "==================================================================="
  echo "  $pkg"
  echo "==================================================================="

  # AUR repos are named by pkgbase, not pkgname.
  base="$(curl -fsSL --globoff "https://aur.archlinux.org/rpc/v5/info?arg[]=${pkg}" \
          | jq -r '.results[0].PackageBase // empty')"
  if [ -z "$base" ]; then
    echo "  not in the AUR"
    BAD+=("$pkg (not in the AUR)")
    continue
  fi
  [ "$base" != "$pkg" ] && echo "  pkgbase: $base"

  d="/tmp/tb-$pkg"
  rm -rf "$d"
  install -d -o builder -g builder "$d"
  if ! su builder -c "git clone -q --depth=1 https://aur.archlinux.org/${base}.git '$d/src'"; then
    BAD+=("$pkg (clone failed)")
    continue
  fi

  # Same key import the pipeline does, so a failure here means the same thing
  # there. Without it this reports "unknown public key" for packages the real
  # build handles fine.
  su builder -c "cd '$d/src' && makepkg --printsrcinfo" > "$d/.SRCINFO" 2>/dev/null || true
  while read -r key; do
    [ -n "$key" ] || continue
    for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
      su builder -c "timeout 60 gpg --batch --quiet --keyserver $ks --recv-keys $key" 2>/dev/null \
        && { echo "  imported validpgpkey $key"; break; }
    done
  done < <(sed -n 's/^[[:space:]]*validpgpkeys = //p' "$d/.SRCINFO" 2>/dev/null | tr -d '[:space:]')

  log="$LOGDIR/${pkg}.log"
  # -s installs missing dependencies; most failures here are a dependency that
  # cannot be satisfied rather than the package's own source.
  su builder -c "cd '$d/src' && makepkg -s --noconfirm --noprogressbar --nocheck" \
    > "$log" 2>&1
  rc=$?

  if [ $rc -eq 0 ]; then
    echo "  BUILT ok"
    OK+=("$pkg")
  else
    echo "  FAILED (exit $rc). Last 45 lines:"
    echo "  ---------------------------------------------------------------"
    tail -45 "$log" | sed 's/^/  | /'
    echo "  ---------------------------------------------------------------"
    BAD+=("$pkg (exit $rc)")
  fi
  rm -rf "$d"
done

echo
echo "==================================================================="
echo "  summary"
echo "==================================================================="
echo "  built:  ${#OK[@]}  ${OK[*]:-}"
echo "  failed: ${#BAD[@]}"
for b in "${BAD[@]:-}"; do [ -n "$b" ] && echo "    - $b"; done

chmod -R a+rwX "$LOGDIR"
[ ${#BAD[@]} -eq 0 ]
