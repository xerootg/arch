#!/usr/bin/env bash
# Walks the AUR dependency closure of the packages named on the command line,
# inside an archlinux:base-devel container, using yay for AUR lookups.
#
# The question this answers is "what would this repo have to build?". Anything
# the official repositories can satisfy is a leaf: pacman resolves it at install
# time and it never needs packaging here. Only AUR packages are recursed into,
# because only they have to be built.
#
# Writes a markdown report to ${REPORT:-/work/dep-report.md}.

set -euo pipefail

REPORT="${REPORT:-/work/dep-report.md}"
: > "$REPORT"

pacman -Syu --noconfirm --needed --disable-download-timeout \
  archlinux-keyring base-devel git curl >/dev/null

if ! command -v yay >/dev/null 2>&1; then
  echo "Building yay..."
  useradd -m builder 2>/dev/null || true
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
  install -d -o builder -g builder /tmp/yay-build
  su builder -c 'git clone -q https://aur.archlinux.org/yay-bin.git /tmp/yay-build/yay-bin'
  su builder -c 'cd /tmp/yay-build/yay-bin && makepkg -si --noconfirm --noprogressbar' >/dev/null
fi
yay --version | head -1

# strip version constraints, descriptions and alternation from a dep atom
clean_dep() {
  sed -e 's/[<>=].*$//' -e 's/:.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$1"
}

declare -A KIND      # pkg -> official | aur | unresolved
declare -A REQUIRES  # pkg -> space separated deps (aur only)
declare -A ROOTOF    # pkg -> first root that pulled it in

queue=(); roots=()
for p in "$@"; do
  p="$(clean_dep "$p")"
  [ -n "$p" ] || continue
  roots+=("$p"); queue+=("$p"); ROOTOF["$p"]="$p"
done

while [ ${#queue[@]} -gt 0 ]; do
  pkg="${queue[0]}"; queue=("${queue[@]:1}")
  [ -n "${KIND[$pkg]+x}" ] && continue

  # -Sp resolves plain names and provides alike, so this catches things like
  # java-environment that no single package is literally named after.
  if pacman -Sp --noconfirm --print-format '%r/%n' "$pkg" >/dev/null 2>&1; then
    KIND["$pkg"]=official
    continue
  fi

  info="$(yay -Si "$pkg" 2>/dev/null || true)"
  if [ -z "$info" ]; then
    KIND["$pkg"]=unresolved
    continue
  fi
  KIND["$pkg"]=aur

  deps="$(awk -F': *' '
      /^Depends On/ || /^Make Deps/ || /^Check Deps/ { print $2 }
    ' <<<"$info" | tr ' ' '\n' | grep -v '^None$' | grep -v '^$' || true)"

  kept=""
  while read -r d; do
    [ -n "$d" ] || continue
    d="$(clean_dep "$d")"
    [ -n "$d" ] || continue
    kept+="$d "
    if [ -z "${KIND[$d]+x}" ]; then
      queue+=("$d")
      [ -n "${ROOTOF[$d]+x}" ] || ROOTOF["$d"]="${ROOTOF[$pkg]:-$pkg}"
    fi
  done <<<"$deps"
  REQUIRES["$pkg"]="$kept"
done

aur=(); official=(); unresolved=()
for p in "${!KIND[@]}"; do
  case "${KIND[$p]}" in
    aur)        aur+=("$p") ;;
    official)   official+=("$p") ;;
    unresolved) unresolved+=("$p") ;;
  esac
done

{
  echo "## AUR dependency walk"
  echo
  echo "Roots: \`${roots[*]}\`"
  echo
  echo "### Must be built by this repo (AUR): ${#aur[@]}"
  echo
  if [ ${#aur[@]} -gt 0 ]; then
    echo '| package | pulled in by | its AUR/other deps |'
    echo '|---|---|---|'
    while read -r p; do
      echo "| \`$p\` | ${ROOTOF[$p]:-} | ${REQUIRES[$p]:-—} |"
    done < <(printf '%s\n' "${aur[@]}" | sort)
  else
    echo "_none_"
  fi
  echo
  echo "### Satisfied by the official repos, nothing to do: ${#official[@]}"
  echo
  printf '%s\n' "${official[@]}" | sort | tr '\n' ' ' | fold -sw 100
  echo
  if [ ${#unresolved[@]} -gt 0 ]; then
    echo
    echo "### Not found in AUR or the official repos: ${#unresolved[@]}"
    echo
    echo "These are usually virtual names, dropped packages, or locally built"
    echo "ones. Each needs a human decision."
    echo
    printf '%s\n' "${unresolved[@]}" | sort | sed 's/^/- `/;s/$/`/'
  fi
} >> "$REPORT"

cat "$REPORT"
chmod a+rw "$REPORT"
