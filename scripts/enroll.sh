#!/usr/bin/env bash
# Enrolment for xerootg's Arch package repos.
#
#   ./enroll.sh client   set this machine up to trust and use the repos
#   ./enroll.sh ci       install the signing secrets into GitHub Actions
#
# With no argument it picks the mode that fits the machine: anything with
# /etc/pacman.conf gets client mode.
#
# Both modes are idempotent -- re-running changes nothing that is already right,
# so it is safe on a half-finished setup.

set -euo pipefail

KEY_URL="https://xerootg.github.io/xerootg.asc"
REPO="xerootg/arch"

REPOS=(
  "custom|https://xerootg.github.io/archlinux"
  "ghidra|https://github.com/xerootg/arch/releases/download/pacman-repo"
  "orca|https://github.com/xerootg/arch/releases/download/orca-repo"
)

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { red "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# client
# ---------------------------------------------------------------------------

enroll_client() {
  bold "Enrolling this machine"
  [ -f /etc/pacman.conf ] || die "no /etc/pacman.conf -- this is not an Arch system"
  command -v pacman-key >/dev/null || die "pacman-key not found"
  [ "$(id -u)" -eq 0 ] || die "run this with sudo"

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  echo "Fetching the signing key..."
  curl -fsSL "$KEY_URL" -o "$tmp/key.asc" || die "could not fetch $KEY_URL"

  # Read the fingerprint out of the key itself rather than hardcoding it here,
  # so this script keeps working across a key rotation.
  local fpr
  fpr="$(gpg --show-keys --with-colons "$tmp/key.asc" \
          | awk -F: '/^fpr:/{print $10; exit}')"
  [ -n "$fpr" ] || die "could not read a fingerprint from the downloaded key"
  echo "  key fingerprint: $fpr"

  pacman-key --add "$tmp/key.asc" >/dev/null
  # The step everyone misses. --add only imports; until the key is locally
  # signed pacman still rejects every package as untrusted.
  pacman-key --lsign-key "$fpr" >/dev/null 2>&1 \
    || die "pacman-key --lsign-key $fpr failed"
  grn "  key imported and locally signed"

  local added=0 present=0
  for entry in "${REPOS[@]}"; do
    local name="${entry%%|*}" server="${entry##*|}"
    if grep -qE "^\[${name}\]" /etc/pacman.conf; then
      present=$((present + 1))
      echo "  [$name] already in pacman.conf, leaving it alone"
      continue
    fi
    # Appended at the end on purpose: pacman resolves repos in file order, and
    # a third-party repo above [core]/[extra] would shadow official packages.
    {
      echo ""
      echo "[$name]"
      echo "Server = $server"
      echo "SigLevel = Required DatabaseOptional"
    } >> /etc/pacman.conf
    added=$((added + 1))
    grn "  [$name] added"
  done

  echo
  echo "Refreshing package lists..."
  pacman -Sy

  echo
  grn "Done. $added repo(s) added, $present already present."
  echo "Browse what is available at https://xerootg.github.io/"
}

# ---------------------------------------------------------------------------
# ci
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# key generation
# ---------------------------------------------------------------------------

KEY_UID='xerootg <4009802+xerootg@users.noreply.github.com>'

# Generate the signing key on this machine.
#
# Deliberately not shipped in this script and not stored in the repository: a
# private signing key in a public repo lets anyone sign packages as you, which
# is worse than not signing at all. Generating it here also gives it the best
# provenance available -- it is created on your machine and never travels.
#
# Two keys, not one. The primary only certifies; it is what users trust and what
# pacman-key --lsign-key refers to. Only the signing subkey is exported to CI,
# so a compromised runner costs a subkey you can revoke, not the identity every
# user has already trusted.
generate_key() {
  local outdir="$1"
  command -v gpg >/dev/null || die "gpg is required to generate a key"

  mkdir -p "$outdir"
  chmod 700 "$outdir"

  # An isolated keyring: this key has no business in your personal one, and a
  # throwaway home means nothing is left behind. mktemp gives a short path,
  # which matters because gpg-agent's socket lives inside GNUPGHOME and unix
  # sockets cap out around 108 bytes.
  local ghome; ghome="$(mktemp -d)"
  chmod 700 "$ghome"
  export GNUPGHOME="$ghome"

  local old_umask; old_umask="$(umask)"
  umask 077

  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40 > "$outdir/GPG_PASSPHRASE.txt"

  echo "  generating a 4096-bit primary key (this takes a moment)..."
  gpg --batch --quiet --pinentry-mode loopback \
      --passphrase-file "$outdir/GPG_PASSPHRASE.txt" \
      --quick-generate-key "$KEY_UID" rsa4096 cert never

  local fpr
  fpr="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
  [ -n "$fpr" ] || die "key generation failed"

  echo "  adding the signing subkey..."
  gpg --batch --quiet --pinentry-mode loopback \
      --passphrase-file "$outdir/GPG_PASSPHRASE.txt" \
      --quick-add-key "$fpr" rsa4096 sign never

  gpg --batch --yes --pinentry-mode loopback \
      --passphrase-file "$outdir/GPG_PASSPHRASE.txt" \
      --armor --export-secret-subkeys "$fpr" > "$outdir/GPG_SIGNING_KEY.txt"
  gpg --batch --yes --pinentry-mode loopback \
      --passphrase-file "$outdir/GPG_PASSPHRASE.txt" \
      --armor --export-secret-keys "$fpr" > "$outdir/PRIMARY-KEY-BACKUP.asc"
  gpg --armor --export "$fpr" > "$outdir/xerootg.asc"
  # gpg 2.1+ writes a revocation certificate at creation; keep it.
  [ -f "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" ] \
    && cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$outdir/REVOCATION-CERTIFICATE.asc"

  chmod 600 "$outdir"/*
  umask "$old_umask"
  gpgconf --kill all >/dev/null 2>&1 || true
  unset GNUPGHOME
  rm -rf "$ghome"

  GENERATED_FPR="$fpr"
  grn "  key generated: $fpr"
}

enroll_ci() {
  # This mode needs no root at all -- it talks to the GitHub API, not the
  # system. Running it under sudo is the natural thing to try after client
  # mode demanded sudo, but root has its own empty gh config, so a session
  # authenticated as your user is invisible here. Step back down rather than
  # making that your problem.
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    ylw "ci mode does not need root; re-running as $SUDO_USER so your gh login is visible."
    exec sudo -u "$SUDO_USER" -H -- "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" ci
  fi
  if [ "$(id -u)" -eq 0 ]; then
    die "ci mode must not run as root -- gh is authenticated per user, and root
       has no session. Re-run it as your normal user, without sudo."
  fi

  bold "Installing signing secrets into $REPO"

  command -v gh >/dev/null \
    || die "the GitHub CLI (gh) is required. Install it, or paste the values by hand at
       https://github.com/$REPO/settings/secrets/actions"

  gh auth status >/dev/null 2>&1 || die "not logged in. Run: gh auth login"

  # Look next to the script first, then the working directory, so this works
  # whether the key files were unpacked beside it or downloaded separately.
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local keyfile="" passfile=""
  for d in "$here" "$PWD" "$here/signing-key" "$PWD/signing-key"; do
    [ -z "$keyfile"  ] && [ -f "$d/GPG_SIGNING_KEY.txt" ] && keyfile="$d/GPG_SIGNING_KEY.txt"
    [ -z "$passfile" ] && [ -f "$d/GPG_PASSPHRASE.txt"  ] && passfile="$d/GPG_PASSPHRASE.txt"
  done
  if [ -z "$keyfile" ] || [ -z "$passfile" ]; then
    local outdir="$HOME/xerootg-signing-key"

    # Refuse to quietly mint a second key over a repo that is already signing.
    # Every signature already published was made by the old key, and replacing
    # the secret without re-signing leaves clients rejecting the repo.
    if gh secret list --repo "$REPO" 2>/dev/null | grep -q '^GPG_SIGNING_KEY'; then
      if [ "${ROTATE:-0}" != "1" ]; then
        die "$REPO already has GPG_SIGNING_KEY set, and no key files were found
       next to this script. Generating a new key now would invalidate every
       signature already published.

       If you meant to rotate the key, re-run as:  ROTATE=1 $0 ci
       and afterwards run the sign-backfill workflow to re-sign everything.

       If you have the existing key files, put them beside this script instead."
      fi
      ylw "ROTATE=1 set -- generating a replacement key."
      ylw "Run the sign-backfill workflow afterwards or clients will reject the repo."
    fi

    bold "No key files found. Generating a signing key on this machine."
    echo "  output directory: $outdir"
    generate_key "$outdir"
    keyfile="$outdir/GPG_SIGNING_KEY.txt"
    passfile="$outdir/GPG_PASSPHRASE.txt"
    NEWLY_GENERATED="$outdir"
  fi

  grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$keyfile" \
    || die "$keyfile does not look like an armoured private key"

  # Confirm the export really is subkey-only before it goes anywhere. If the
  # certifying primary were in here, a compromised runner would take the whole
  # identity with it instead of a revocable subkey.
  if command -v gpg >/dev/null; then
    if gpg --show-keys --with-colons "$keyfile" 2>/dev/null | grep -q '^sec:'; then
      ylw "  warning: this export appears to contain the primary secret key."
      ylw "  Expected a subkey-only export. Continuing, but that is not the intended setup."
    fi
    local fpr
    fpr="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')"
    [ -n "$fpr" ] && echo "  key fingerprint: $fpr"
  fi

  echo "Setting GPG_SIGNING_KEY..."
  gh secret set GPG_SIGNING_KEY --repo "$REPO" < "$keyfile"
  echo "Setting GPG_PASSPHRASE..."
  # printf, not cat: a trailing newline in the file would become part of the
  # passphrase and every signing run would fail with a bad passphrase.
  printf '%s' "$(cat "$passfile")" | gh secret set GPG_PASSPHRASE --repo "$REPO"

  echo
  grn "Both secrets installed."
  gh secret list --repo "$REPO" | sed 's/^/  /'

  if [ -n "${NEWLY_GENERATED:-}" ]; then
    echo
    bold "Keep these safe, off this machine"
    cat <<EOF
  $NEWLY_GENERATED/
    PRIMARY-KEY-BACKUP.asc      full secret key. Needed to issue a new signing
                                subkey, or to recover if GitHub loses the secret.
    REVOCATION-CERTIFICATE.asc  publish this if the key is ever compromised.
    GPG_PASSPHRASE.txt          also unlocks the backup above, so store it with them.
    xerootg.asc                 public key. Not secret; CI republishes it anyway.

  A password manager entry or an encrypted USB stick is fine. The two secrets
  are already in GitHub, so nothing here is needed day to day -- but without
  PRIMARY-KEY-BACKUP.asc you cannot ever rotate the subkey without asking every
  user to trust a new fingerprint.
EOF
  fi

  echo
  bold "Next: build and publish the signatures"
  cat <<EOF
  gh workflow run build-repo.yml    --repo $REPO   # signs [custom]
  gh workflow run sign-backfill.yml --repo $REPO   # signs published [ghidra] and [orca]
  gh workflow run repo-index.yml    --repo $REPO   # regenerates the site

  Run them in that order and let each finish. Or just say the word and I
  will trigger them.
EOF
}

# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 [client|ci]

  client   Import the signing key into pacman's keyring, locally sign it, and
           add the three repos to /etc/pacman.conf. Needs root.

  ci       Install GPG_SIGNING_KEY and GPG_PASSPHRASE as Actions secrets on
           $REPO. Needs the GitHub CLI, logged in. Uses the key files
           beside this script if they are there, and otherwise generates a
           fresh signing key on this machine first. Do not run it with sudo.

With no argument, client mode is chosen on a system that has /etc/pacman.conf.
EOF
}

mode="${1:-}"
if [ -z "$mode" ]; then
  if [ -f /etc/pacman.conf ]; then
    mode=client
  else
    usage; exit 1
  fi
fi

case "$mode" in
  client) enroll_client ;;
  ci)     enroll_ci ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
