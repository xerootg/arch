#!/usr/bin/env bash
# Sign every package and database file in a pacman repository directory.
#
#   sign-pacman-repo.sh <repo-dir> <db-basename>
#
# Needs only gpg and coreutils, so the same script runs inside the Arch build
# containers and directly on an Ubuntu runner for the backfill job.
#
# Reads from the environment:
#   GPG_SIGNING_KEY  ASCII-armoured secret key (the CI signing subkey)
#   GPG_PASSPHRASE   passphrase for that key
#
# With no key configured it prints a warning and exits 0 without touching
# anything. That is deliberate: these pipelines publish packages people
# actually install, and they must not start failing the moment signing is
# merged but before the secrets exist.
#
# Idempotent, and safe across a key rotation: an existing signature is kept
# only if it still verifies against the key currently loaded. A signature made
# by a revoked or superseded key fails that check and is replaced, so rotating
# the key is just "change the secret and re-run".

set -euo pipefail

REPO_DIR="${1:?usage: sign-pacman-repo.sh <repo-dir> <db-basename>}"
DB_NAME="${2:?usage: sign-pacman-repo.sh <repo-dir> <db-basename>}"

# Written so callers can decide whether there is anything new to publish.
SIGN_REPORT="${SIGN_REPORT:-}"

if [ -z "${GPG_SIGNING_KEY:-}" ]; then
  # Refuse to publish over an already-signed repo with no key. The database is
  # rewritten on every build, so its old .sig would no longer match it, and a
  # bad database signature is worse than an absent one -- pacman rejects the
  # repo outright and every client breaks at once. Fail here instead.
  if compgen -G "$REPO_DIR/*.sig" > /dev/null 2>&1; then
    echo "::error::GPG_SIGNING_KEY is not set but $REPO_DIR already contains" \
         "signatures. Publishing now would leave a stale database signature" \
         "that clients reject. Restore the signing secret, or delete the .sig" \
         "files deliberately to go back to an unsigned repo."
    exit 1
  fi
  echo "::warning::GPG_SIGNING_KEY is not set; publishing unsigned packages"
  [ -n "$SIGN_REPORT" ] && echo "signed=0" > "$SIGN_REPORT"
  exit 0
fi

command -v gpg >/dev/null 2>&1 || { echo "::error::gpg is not installed"; exit 1; }

# A private keyring in a temp dir, never the caller's. Removed on any exit.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() {
  gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf "$GNUPGHOME"
}
trap cleanup EXIT

printf '%s' "$GPG_SIGNING_KEY" | gpg --batch --quiet --import 2>/dev/null

# The passphrase goes in a 0600 file rather than on the command line, where
# every process on the box could read it out of ps.
printf '%s' "${GPG_PASSPHRASE:-}" > "$GNUPGHOME/passphrase"
chmod 600 "$GNUPGHOME/passphrase"

KEY_FPR="$(gpg --list-secret-keys --with-colons 2>/dev/null \
  | awk -F: '/^fpr:/ { print $10; exit }')"
if [ -z "$KEY_FPR" ]; then
  echo "::error::no secret key found after importing GPG_SIGNING_KEY"
  exit 1
fi
echo "Signing as $KEY_FPR"

# Trust our own key ultimately, so --verify below reports a clean status
# instead of warning about an unknown owner on every file.
echo "${KEY_FPR}:6:" | gpg --batch --quiet --import-ownertrust 2>/dev/null

# Publish the public half alongside the packages. Users have to import it
# before pacman will accept anything, and deriving it from the key that is
# actually signing means the two can never drift apart.
if [ -n "${PUBKEY_OUT:-}" ]; then
  gpg --armor --export "$KEY_FPR" > "$PUBKEY_OUT"
  chmod 644 "$PUBKEY_OUT"
  echo "Wrote the public key to $PUBKEY_OUT"
fi

gpg_sign() {
  gpg --batch --yes --quiet \
    --pinentry-mode loopback --passphrase-file "$GNUPGHOME/passphrase" \
    --local-user "$KEY_FPR" \
    --detach-sign --no-armor \
    --output "$1.sig" "$1"
}

# True when a usable signature is already present. `gpg --verify` fails on a
# signature from a key we no longer hold, which is exactly what should trigger
# a re-sign after a rotation.
already_signed() {
  [ -f "$1.sig" ] && gpg --batch --quiet --verify "$1.sig" "$1" >/dev/null 2>&1
}

cd "$REPO_DIR"

signed=0
kept=0

# --- packages ------------------------------------------------------------
shopt -s nullglob
for pkg in *.pkg.tar.zst *.pkg.tar.xz; do
  if already_signed "$pkg"; then
    kept=$((kept + 1))
    continue
  fi
  echo "  signing $pkg"
  gpg_sign "$pkg"
  signed=$((signed + 1))
done

# --- databases -----------------------------------------------------------
# pacman fetches `<name>.db` and `<name>.db.sig`; the `.tar.gz` twins are signed
# too so the directory stays internally consistent for anyone mirroring it.
# `.old` backups are never fetched and are left alone.
for db in "${DB_NAME}.db" "${DB_NAME}.files" \
          "${DB_NAME}.db.tar.gz" "${DB_NAME}.files.tar.gz"; do
  [ -f "$db" ] || continue
  # The database is rewritten on every build, so an existing signature is
  # usually stale. Verify rather than assume.
  if already_signed "$db"; then
    kept=$((kept + 1))
    continue
  fi
  echo "  signing $db"
  gpg_sign "$db"
  signed=$((signed + 1))
done

# --- orphans -------------------------------------------------------------
# A signature whose subject is gone would be served forever otherwise.
removed=0
for sig in *.sig; do
  subject="${sig%.sig}"
  if [ ! -f "$subject" ]; then
    echo "  removing orphaned $sig"
    rm -f "$sig"
    removed=$((removed + 1))
  fi
done
shopt -u nullglob

echo "Signatures: $signed new, $kept already valid, $removed orphaned removed."
if [ -n "$SIGN_REPORT" ]; then
  {
    echo "signed=$signed"
    echo "removed=$removed"
    echo "fingerprint=$KEY_FPR"
  } > "$SIGN_REPORT"
fi
