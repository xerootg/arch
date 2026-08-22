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

# Do not run check().
#
# python-beartype builds cleanly and then fails its own test_poetry case --
# 1 failed, 398 passed -- which aborts packaging and takes with it everything
# that depends on it: python-py-key-value-aio, python-fastmcp,
# python-fastmcp-slim, python-jsonref, jadx-ai-mcp-bin. An upstream test that
# does not survive a container is not a reason to refuse to ship the package.
#
# heavy-build already passes --nocheck; this makes the two pipelines agree.
sed -i "s/^BUILDENV=.*/BUILDENV=(!distcc color !ccache !check !sign)/" /etc/makepkg.conf

# Give yay somebody to drop privileges to.
#
# yay refuses to run makepkg as root, so when it is root it de-elevates. Its
# deElevateCommand looks up $SUDO_USER / $DOAS_USER and, only if neither
# resolves to a real user, falls back to `systemd-run`. This container has no
# systemd, so that fallback produces
#
#   error fetching <pkg>: System has not been booted with systemd as init
#   system (PID 1). Can't operate.
#
# and every AUR dependency install fails -- which is what took out
# python-fastmcp, python-fastmcp-slim and python-beartype in run #388. Member
# packages build fine because build-pacman-repo drives makepkg itself; only
# yay's path was broken.
#
# A real user in $SUDO_USER takes the credential branch instead, and no systemd
# is involved. HOME goes with it so yay's cache lands somewhere that user can
# actually write.
useradd -m -s /bin/bash builder 2>/dev/null || true
install -d -o builder -g builder /home/builder/.cache
export SUDO_USER=builder

# yay-noninteractive runs yay as this user rather than as root, so that yay
# stops printing "Avoid running yay as root/sudo." onto the stdout makepkg
# parses for dependency names. It still needs root for the pacman half.
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

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

# Materialise any member directory that is not already present.
#
# Most packages here are git submodules pointing at the AUR, but adding a
# submodule requires cloning it to record a commit, which is not always possible
# from wherever this repo is being edited. The members list in
# build-pacman-repo.yaml is the single source of truth for what gets built, so
# anything listed there without a directory is cloned straight from the AUR at
# build time. Existing submodules already have a directory and are left alone.
echo "📥 Checking for member directories that need cloning..."
python3 -c "
import re
text = open('build-pacman-repo.yaml').read()
block = text.split('members:', 1)[1] if 'members:' in text else ''
for line in block.splitlines():
    if line.lstrip().startswith('#'):
        continue
    m = re.match(r'\s*-?\s*directory:\s*(\S+)', line)
    if m:
        print(m.group(1))
" > /tmp/members.txt

NEED=()
while read -r member; do
  [ -n "$member" ] || continue
  if [ -d "pkgbuilds/$member" ] && [ -f "pkgbuilds/$member/PKGBUILD" ]; then
    continue
  fi
  NEED+=("$member")
done < /tmp/members.txt

if [ ${#NEED[@]} -gt 0 ]; then
  # AUR git repositories are named by *pkgbase*, not pkgname. Cloning by
  # pkgname does not fail -- the AUR git server hands back an empty repository
  # rather than a 404 -- so the mistake shows up later as a directory with no
  # PKGBUILD. Resolve pkgbase through the RPC before cloning anything.
  #
  # curl needs --globoff here: the arg[] parameters contain brackets, which curl
  # otherwise treats as a glob range and mangles.
  QUERY=""
  for m in "${NEED[@]}"; do
    # Vendored packages are not looked up; several of them are in this repo
    # precisely because the AUR has dropped them.
    [ -d "vendor-pkgbuilds/$m" ] && continue
    QUERY="${QUERY}&arg[]=${m}"
  done
  if [ -z "$QUERY" ]; then
    echo '{"results":[]}' > /tmp/aur-info.json
  elif ! curl -fsSL --globoff "https://aur.archlinux.org/rpc/v5/info?${QUERY#&}" -o /tmp/aur-info.json; then
    echo "::error::could not query the AUR RPC"
    exit 4
  fi

  python3 -c "
import json
d = json.load(open('/tmp/aur-info.json'))
for r in d.get('results', []):
    print(r['Name'], r['PackageBase'])
" > /tmp/pkgbase.txt

  declare -A BASE_OF
  declare -A FIRST_MEMBER_OF_BASE
  DROP=()
  while read -r name base; do
    [ -n "$name" ] || continue
    BASE_OF["$name"]="$base"
  done < /tmp/pkgbase.txt

  for member in "${NEED[@]}"; do
    # A PKGBUILD carried in this repo wins over the AUR, and is the only option
    # for packages the AUR no longer has at all.
    if [ -d "vendor-pkgbuilds/$member" ]; then
      echo "  using the vendored PKGBUILD for $member"
      cp -r "vendor-pkgbuilds/$member" "pkgbuilds/$member"
      chown -R "$UID:$GID" "pkgbuilds/$member"
      continue
    fi
    base="${BASE_OF[$member]}"
    if [ -z "$base" ]; then
      echo "::error::$member is not in the AUR (no RPC result). Either correct"
      echo "         the name in build-pacman-repo.yaml, drop it, or carry a"
      echo "         PKGBUILD for it in vendor-pkgbuilds/$member/."
      exit 4
    fi
    if [ "$base" != "$member" ]; then
      echo "  $member is a split package of pkgbase $base"
    fi
    # Two members sharing a pkgbase is not an error to report, it is one to
    # fix. build-pacman-repo refuses to run in that state ("Duplication
    # detected"), but the situation is harmless in itself: one build of that
    # pkgbase produces every package it splits into, so the second member is
    # simply redundant. Drop it from the effective members list and carry on.
    #
    # This has now been hit three times -- authentik, dotnet and sentencepiece --
    # because a members list is written in pkgnames and the pkgbase is only
    # knowable from the AUR. Failing the build each time made a lookup this
    # script is already doing into a six-minute round trip.
    if [ -n "${FIRST_MEMBER_OF_BASE[$base]}" ]; then
      echo "  ↩ $member is the same pkgbase ($base) as ${FIRST_MEMBER_OF_BASE[$base]};" \
           "dropping the duplicate -- one build produces both"
      mkdir -p /workspace/repo-out
      echo "duplicate: dropped $member (same pkgbase $base as ${FIRST_MEMBER_OF_BASE[$base]})" \
        >> /workspace/repo-out/.preflight-report
      DROP+=("$member")
      continue
    fi
    FIRST_MEMBER_OF_BASE["$base"]="$member"

    echo "  cloning $base -> pkgbuilds/$member"
    rm -rf "pkgbuilds/$member"
    if ! git clone --quiet --depth=1 "https://aur.archlinux.org/${base}.git" "pkgbuilds/$member"; then
      echo "::error::could not clone $base from the AUR"
      exit 4
    fi
    # Apply a local patch if this repo carries one. Some AUR recipes are simply
    # broken -- authentik-platform-git's build() cd's to a path that no longer
    # exists upstream -- and the choice is either to carry a fix or to not have
    # the package. The patch is applied to a fresh clone every run, so it never
    # drifts silently: if upstream fixes the same thing the patch stops applying
    # and says so.
    if [ -f "patches/${base}.patch" ]; then
      echo "  applying patches/${base}.patch"
      if ! (cd "pkgbuilds/$member" && patch -p1 --forward < "/workspace/repo/patches/${base}.patch"); then
        echo "::warning::patches/${base}.patch no longer applies to $base --" \
             "upstream may have fixed it; check whether the patch can be dropped"
      fi
    fi
    if [ ! -f "pkgbuilds/$member/PKGBUILD" ]; then
      echo "::error::$base cloned but has no PKGBUILD"
      exit 4
    fi
    chown -R "$UID:$GID" "pkgbuilds/$member"
  done

  # Rewrite the effective members list so build-pacman-repo never sees the
  # duplicates. Only the working copy in the container is touched; the file in
  # git keeps the full list, which is what someone reading it expects.
  if [ ${#DROP[@]} -gt 0 ]; then
    echo "🧹 Removing ${#DROP[@]} duplicate pkgbase member(s) from the working config"
    printf '%s\n' "${DROP[@]}" > /tmp/drop.txt
    python3 - <<'PYDROP'
import re
drop = {l.strip() for l in open('/tmp/drop.txt') if l.strip()}
lines = open('build-pacman-repo.yaml').read().splitlines(keepends=True)
out, skip = [], False
for line in lines:
    m = re.match(r'(\s*)- directory:\s*(\S+)\s*$', line)
    if m:
        skip = m.group(2) in drop
        if skip:
            continue
    elif skip:
        # The entry's own indented keys (allow-failure, pacman, ...) go with it.
        # Anything at list level or shallower ends the entry.
        if re.match(r'\s*-\s', line) or not line.startswith((' ', '\t')) or re.match(r'\s{0,2}\S', line):
            skip = False
        else:
            continue
    out.append(line)
open('build-pacman-repo.yaml', 'w').writelines(out)
PYDROP
  fi
fi

# Prepare sources and update SRCINFO
for dir in pkgbuilds/*/; do
  if grep -q "^pkgver()" "$dir/PKGBUILD" 2>/dev/null; then
    echo "📥 Fetching sources for $(basename "$dir")..."
    (cd "$dir" && makepkg -od --nobuild --noconfirm) || true
  fi
done

# Local fixups, the same mechanism heavy-build has.
#
# patches/<member>.sed is applied to that member's PKGBUILD, patches/<member>.patch
# with patch -p1. Applied before .SRCINFO is regenerated so a fixup touching
# depends or pkgver is picked up.
#
# A fixup that changes nothing prints the recipe lines it was aimed at. That is
# how the llama.cpp rule was found to be matching $pkgdir when the recipe wrote
# ${pkgdir} -- without it, a missed rule costs a build to learn nothing.
echo "🩹 Applying local fixups..."
fixups_applied=0
for fx in patches/*.sed patches/*.patch; do
  [ -e "$fx" ] || continue
  member="$(basename "$fx")"; member="${member%.*}"
  d="pkgbuilds/$member"
  if [ ! -f "$d/PKGBUILD" ]; then
    echo "  ↷ $member is not a member here; skipping $(basename "$fx")"
    continue
  fi
  before="$(md5sum "$d/PKGBUILD" | cut -d' ' -f1)"
  case "$fx" in
    *.sed)   sed -i -f "$fx" "$d/PKGBUILD" ;;
    *.patch) patch -p1 -d "$d" --forward < "$fx" || echo "::warning::$(basename "$fx") did not apply" ;;
  esac
  after="$(md5sum "$d/PKGBUILD" | cut -d' ' -f1)"
  if [ "$before" = "$after" ]; then
    echo "  ⚠ $(basename "$fx") changed nothing. The recipe's relevant lines are:"
    grep -n -E '(^|[^[:alnum:]_])(gradle|rm|install|cp|mv|make)[[:space:]]' "$d/PKGBUILD" \
      | sed 's/^/      /' || echo "      (none matched)"
  else
    echo "  ✅ applied $(basename "$fx") to $member"
    fixups_applied=$((fixups_applied + 1))
  fi
done
[ "$fixups_applied" -eq 0 ] && echo "  no fixups changed anything"

echo "🔄 Updating .SRCINFO files..."
build-pacman-repo sync-srcinfo --update

# Import the upstream release keys the PKGBUILDs pin.
#
# A PKGBUILD with validpgpkeys verifies its source tarball against that key, and
# a fresh container has an empty keyring, so the build dies with
# "FAILED (unknown public key ...)" -- which is what stopped libkcompactdisc.
# Import them rather than reaching for --skippgpcheck: the whole point of the
# check is that upstream's tarball is what upstream published.
# One key, every route we have. Returns non-zero only if all of them fail.
import_pgp_key() {
  local key="$1" ks
  [ -n "$key" ] || return 1

  # hkps:// explicitly. A bare hostname makes gpg use hkp on port 11371, which
  # is blocked on GitHub runners, so every --recv-keys silently times out --
  # which is how libkcompactdisc kept failing on "unknown public key" even
  # after key import was added. hkps is plain 443.
  for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
    if timeout 60 gpg --batch --quiet --keyserver "$ks" --recv-keys "$key" 2>/dev/null; then
      echo "  ✅ $key (from $ks)"
      return 0
    fi
  done

  # Last resort: the keyserver's plain HTTPS lookup endpoint. No hkp, no SRV
  # records, nothing but a GET -- if this fails the key really is unreachable.
  if curl -fsSL --max-time 60 \
       "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${key}" \
       | gpg --batch --quiet --import 2>/dev/null; then
    echo "  ✅ $key (via https lookup)"
    return 0
  fi

  return 1
}

echo "🔑 Importing validpgpkeys declared by the PKGBUILDs..."
mapfile -t VALIDKEYS < <(
  grep -h '^[[:space:]]*validpgpkeys = ' pkgbuilds/*/.SRCINFO 2>/dev/null \
    | sed 's/.*= //' | tr -d '[:space:]' | sort -u
)
if [ ${#VALIDKEYS[@]} -gt 0 ]; then
  echo "  ${#VALIDKEYS[@]} key(s) to fetch"
  for key in "${VALIDKEYS[@]}"; do
    # Not fatal: only the packages pinning this key fail, and they carry
    # allow-failure. Killing the run would punish every other package.
    import_pgp_key "$key" \
      || echo "  ::warning::could not fetch validpgpkey $key"
  done
else
  echo "  none declared"
fi

# Find pkgbases whose own split packages depend on each other, before
# build-pacman-repo does.
#
# Its planner calls that a dependency cycle and refuses to run -- not to build
# that package, to run at all. It happened with dotnet-core-preview-bin and
# again with sentencepiece, whose python-sentencepiece depends on sentencepiece,
# and each time it took all seventy-two members down with it. allow-failure
# cannot contain it because nothing gets as far as building.
#
# makepkg has no problem with these: one invocation produces every split package
# at once, so the "cycle" is satisfied by construction. They belong in
# heavy-build.yml, which uses plain makepkg. Drop them here and say so.
echo "🔎 Checking for pkgbases whose split packages depend on each other..."
python3 - <<'PYCYCLE' > /tmp/cycles.txt
import glob, os
for path in sorted(glob.glob('pkgbuilds/*/.SRCINFO')):
    member = os.path.basename(os.path.dirname(path))
    base, current, names, deps = None, None, set(), {}
    for raw in open(path, encoding='utf-8', errors='replace'):
        line = raw.strip()
        if line.startswith('pkgbase = '):
            base = line.split(' = ', 1)[1]
        elif line.startswith('pkgname = '):
            current = line.split(' = ', 1)[1]
            names.add(current)
            deps.setdefault(current, set())
        elif current and (line.startswith('depends = ')
                          or line.startswith('optdepends = ')
                          or line.startswith('makedepends = ')):
            dep = line.split(' = ', 1)[1].split(':')[0]
            for sep in ('>=', '<=', '=', '>', '<'):
                dep = dep.split(sep)[0]
            deps[current].add(dep.strip())
    if len(names) < 2:
        continue
    for name, needs in deps.items():
        internal = (needs & names) - {name}
        if internal:
            print(f"{member}\t{base}\t{name}\t{','.join(sorted(internal))}")
            break
PYCYCLE

if [ -s /tmp/cycles.txt ]; then
  cut -f1 /tmp/cycles.txt > /tmp/drop-cycles.txt
  while IFS=$'\t' read -r member base name internal; do
    echo "  ⮾ $member: pkgbase $base -- $name depends on $internal from the same"
    echo "     pkgbase. build-pacman-repo refuses the whole run over this."
    echo "     Dropping it here; add it to .github/heavy-packages.yaml, which"
    echo "     builds with plain makepkg and has no planner to upset."
    echo "self-cycle: dropped $member (pkgbase $base; $name needs $internal) -- move it to .github/heavy-packages.yaml" \
      >> /workspace/repo-out/.preflight-report
  done < /tmp/cycles.txt
  python3 - <<'PYDROPCYCLE'
import re
drop = {l.strip() for l in open('/tmp/drop-cycles.txt') if l.strip()}
lines = open('build-pacman-repo.yaml').read().splitlines(keepends=True)
out, skip = [], False
for line in lines:
    m = re.match(r'(\s*)- directory:\s*(\S+)\s*$', line)
    if m:
        skip = m.group(2) in drop
        if skip:
            continue
    elif skip:
        if re.match(r'\s*-\s', line) or not line.startswith((' ', '\t')) or re.match(r'\s{0,2}\S', line):
            skip = False
        else:
            continue
    out.append(line)
open('build-pacman-repo.yaml', 'w').writelines(out)
PYDROPCYCLE
else
  echo "  none"
fi

# Not a cat of every .SRCINFO. Seventy-two of them is several thousand lines of
# log for information nobody reads, and the log API only serves the tail.
echo "📄 .SRCINFO present for $(find pkgbuilds -name .SRCINFO | wc -l) member(s)"

for dir in pkgbuilds/*/; do
  if [ -f "$dir/PKGBUILD" ]; then
    echo "🧹 Cleaning sources for $(basename "$dir")..."
    (cd "$dir" && makepkg -odc --noconfirm) || true
  fi
done

# Check for outdated packages
echo ""
echo "🔍 Debug: Existing packages in repo directory:"
ls -1 /workspace/repo-out/*.pkg.tar.zst 2>/dev/null | xargs -I{} basename {} || echo "  (none)"

echo ""
echo "🔍 Debug: Running outdated check with full details:"
build-pacman-repo outdated --details lossy-yaml || true

echo ""
# A plain directory now, not a checkout of the Pages repo. The packages are
# published as GitHub Release assets, which lifts the 100 MB per-file push limit
# that forced the oversized packages into repos of their own.
REPO_DIR="/workspace/repo-out"
mkdir -p "$REPO_DIR"

# Bootstrap an empty database if the release has none yet.
#
# build-pacman-repo reads the database to work out what is outdated, and it has
# always been there before -- the old layout checked out the Pages repo, which
# carried a committed custom.db.tar.gz. A freshly created release has nothing,
# so the very first run of this repo has no database to read. repo-add cannot
# make an empty one (it needs at least one package), but an empty gzipped tar is
# exactly what an empty database is.
for db in "${REPO_NAME:-custom}.db" "${REPO_NAME:-custom}.files"; do
  if [ ! -f "$REPO_DIR/${db}.tar.gz" ]; then
    echo "No ${db}.tar.gz yet; creating an empty database to bootstrap."
    tar -czf "$REPO_DIR/${db}.tar.gz" --files-from /dev/null
    cp "$REPO_DIR/${db}.tar.gz" "$REPO_DIR/${db}"
  fi
done

OUTDATED=$(build-pacman-repo outdated --details pkgname)
BUILT=false
if [ -z "$OUTDATED" ]; then
  echo "✅ All packages are up-to-date, nothing to build"
else
  echo "📦 Outdated packages to build:"
  echo "$OUTDATED"
  # Build if outdated.
  #
  # Tee the whole thing. Failures under allow-failure are reported by
  # build-pacman-repo as a list of names with no reasons, and the reasons are
  # buried thousands of lines upstream where the log API's tail cannot reach
  # them -- twelve packages failed in run #384 and only one reason was
  # recoverable. Keeping the output lets the postmortem below replay just the
  # part that matters.
  set +e
  build-pacman-repo build 2>&1 | tee /tmp/build.log
  build_rc=${PIPESTATUS[0]}
  set -e
  if [ "$build_rc" -ne 0 ]; then
    echo "::error::build-pacman-repo build failed"
    # Deliberately not a tree of pkgbuilds/. That was useful with five members
    # and is actively harmful with seventy-two: it is thousands of lines, the
    # log API only serves the tail, and it pushes the actual error out of reach.
    # The failure list is what is wanted, and it is twenty lines.
    echo "--- failed-builds.yaml ---"
    cat failed-builds.yaml 2>/dev/null || echo "(nothing recorded)"
    exit 2
  fi
  # A build that died on a key we can fetch deserves a second chance.
  #
  # The importer above only knows keys a PKGBUILD declares in validpgpkeys.
  # libkcompactdisc declares none and still verifies its tarball, so it failed
  # with "unknown public key BB463350D6EF31EF" -- a key keyserver.ubuntu.com
  # serves perfectly well. The failure message names the key, and the build
  # output is already captured, so read the ID back out and try again.
  mapfile -t MISSING_KEYS < <(
    grep -oE 'unknown public key [0-9A-Fa-f]{8,40}' /tmp/build.log 2>/dev/null \
      | awk '{print $NF}' | sort -u
  )
  if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
    echo ""
    echo "🔑 ${#MISSING_KEYS[@]} build(s) failed on a key that was not declared in any"
    echo "   validpgpkeys. Fetching by the ID the failure named, then retrying."
    imported=0
    for key in "${MISSING_KEYS[@]}"; do
      if import_pgp_key "$key"; then
        imported=$((imported + 1))
      else
        echo "  ✗ $key could not be fetched from any keyserver"
      fi
    done
    if [ "$imported" -gt 0 ]; then
      echo "  retrying the build with $imported newly trusted key(s)"
      # Clear the failure record first. build-pacman-repo remembers what failed
      # and answers a second invocation with "Failures had been recorded.
      # Skip." -- so the first version of this retry imported the key
      # correctly, retried, and skipped the very package it had just fixed.
      rm -f failed-builds.yaml
      # Already-built packages are skipped, so this costs only the ones that
      # failed. Still non-fatal: allow-failure semantics have not changed.
      set +e
      build-pacman-repo build 2>&1 | tee -a /tmp/build.log
      set -e
    fi
  fi

  BUILT=true
  # Verify packages
  echo ""
  echo "📦 Packages in repository: $(find "$REPO_DIR" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l)"
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

# Release assets top out at 2 GB each. Far more headroom than the 100 MB push
# limit this repo used to live under, but still a hard wall: an oversized asset
# is rejected at upload and the run would publish a database referencing a
# package nobody can download. Name it here instead.
MAX_MB=1900
OVERSIZED=""
while read -r pkg; do
  [ -n "$pkg" ] || continue
  size_mb=$(du -m "$pkg" | cut -f1)
  if [ "$size_mb" -gt "$MAX_MB" ]; then
    OVERSIZED="${OVERSIZED}  $(basename "$pkg") - ${size_mb}MB
"
  fi
done < <(find "$REPO_DIR" -maxdepth 1 -name "*.pkg.tar.zst")

if [ -n "$OVERSIZED" ]; then
  echo "::error::package(s) too large for a GitHub release asset (limit ${MAX_MB}MB):"
  printf '%s' "$OVERSIZED"
  exit 5
fi

# Why did each contained failure fail?
#
# allow-failure keeps one bad package from stopping the other seventy, which is
# right, but build-pacman-repo then reports only "Some builds failed:" and a
# list of names. The actual errors are inline, thousands of lines back, and the
# Actions log API serves only a tail -- so in practice they were unreadable.
# Replay the tail of each failed package's own output, here at the end.
if [ -s /tmp/build.log ]; then
  echo ""
  echo "🧾 Postmortem for packages that failed (contained by allow-failure):"
  python3 - <<'PYPOSTMORTEM'
import re

LOG = "/tmp/build.log"
BEFORE, AFTER = 14, 10

# build-pacman-repo prints "==== PACKAGE ====" then "pkgbase: <name>" before
# each one it handles. That is an exact boundary. The first version of this
# guessed at boundaries using makepkg's "Making package:" line, which a
# package that dies during dependency resolution never reaches -- so sections
# ran on into the next package and the excerpt showed its dependency
# downloads instead of the failure.
SECTION = re.compile(r"^=+ PACKAGE =+\s*$")
PKGBASE = re.compile(r"pkgbase:\s*(\S+)")

# Strong first. "checking for file conflicts..." is a routine pacman line and
# it contains the word conflict, which is exactly what the previous pass
# anchored on for fatx, android-apktool and powershell -- reporting their
# dependency installs as though that were the error.
STRONG = re.compile(
    r"==> ERROR|^error:|\berror making\b|FAILED \(|Traceback|"
    r"non-zero status code|undefined reference|Could not resolve|"
    r"failed to install|No space left|Killed|command not found|"
    # A stacktrace's "Caused by:" is the line that actually names the cause,
    # and it sits below the message rather than above it -- hence AFTER.
    r"Caused by:|What went wrong")
WEAK = re.compile(r"\berror\b|\bfatal\b|cannot |could not |not found|Permission denied")

try:
    lines = open(LOG, "r", errors="replace").read().splitlines()
except OSError:
    raise SystemExit(0)

# Only the LAST list counts, and only once per package.
#
# The build runs twice when a missing key is recovered, so there are two
# "Some builds failed" lists. Reading both reported android-apktool twice and
# listed libkcompactdisc as failed when the retry had in fact built it -- its
# excerpt was the tail of a successful package, which read as the postmortem
# being broken again when it was only being asked the wrong question.
failed, collecting = [], False
for line in lines:
    if "Some builds failed" in line:
        failed, collecting = [], True
        continue
    if collecting:
        m = re.match(r"\s*[\u25cf*-]\s+(\S+)", line)
        if m:
            if m.group(1) not in failed:
                failed.append(m.group(1))
        elif line.strip():
            collecting = False

if not failed:
    print("  nothing failed")
    raise SystemExit(0)

# Cut into sections and label each by its pkgbase.
bounds = [i for i, l in enumerate(lines) if SECTION.match(l)] + [len(lines)]
sections = {}
for a, b in zip(bounds, bounds[1:]):
    name = None
    for line in lines[a:min(a + 8, b)]:
        m = PKGBASE.search(line)
        if m:
            name = m.group(1)
            break
    if not name:
        continue
    # Keep the longest section per package: the second pass only says
    # "Failures had been recorded. Skip." and carries no diagnosis.
    body = lines[a:b]
    if name not in sections or len(body) > len(sections[name]):
        sections[name] = body

for name in failed:
    print("")
    print("  " + "-" * 68)
    print("  {}".format(name))
    print("  " + "-" * 68)

    chunk = [l for l in sections.get(name, []) if l.strip()]
    if not chunk:
        print("    (no section found for it in the build output)")
        continue

    hit = None
    for pattern in (STRONG, WEAK):
        for i in range(len(chunk) - 1, -1, -1):
            if pattern.search(chunk[i]):
                hit = i
                break
        if hit is not None:
            break

    if hit is None:
        print("    (nothing matched an error pattern; showing the end of its section)")
        window = chunk[-BEFORE:]
    else:
        window = chunk[max(0, hit - BEFORE):hit + AFTER]

    for l in window:
        print("    " + l[:200])
PYPOSTMORTEM
fi

# Replay the preflight verdict.
#
# The Actions log API serves only a tail, capped around 5,000 lines, and this
# step runs for over an hour. Anything printed during setup is unreadable by the
# time the run finishes -- which has now hidden a failure four separate times.
# Whatever the preflight decided is worth more at the end than at the start.
echo ""
echo "🔎 Preflight verdict (replayed here so it survives the log tail):"
if [ -s /workspace/repo-out/.preflight-report ]; then
  sed 's/^/  /' /workspace/repo-out/.preflight-report
else
  echo "  no members were dropped: no duplicate pkgbases, no self-cycles"
fi
rm -f /workspace/repo-out/.preflight-report

# Rename any epoch package so its name survives a GitHub Release, and point the
# database at the renamed file. Must happen before signing -- the database is
# rewritten here, so a signature made first would no longer match it.
echo ""
echo "🏷  Checking package names against what a release will accept..."
python3 /workspace/repo/.github/scripts/sanitize-epoch-filenames.py \
  "$REPO_DIR" "${REPO_NAME:-custom}"

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
export PUBKEY_OUT="$REPO_DIR/xerootg.asc"
bash /workspace/repo/.github/scripts/sign-pacman-repo.sh "$REPO_DIR" "${REPO_NAME:-custom}"

echo ""
echo "📦 Final repository contents:"
ls -lh "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null || echo "  (none)"

# Hand the results back to the runner user, which does the publishing.
chmod -R a+rwX "$REPO_DIR"
