#!/usr/bin/env bash
# Add [custom] and [ghidra] to this container's pacman.conf, so packages this
# project has already published are installable as build dependencies.
#
# Source it, do not execute it -- it edits /etc/pacman.conf in the caller's
# container and is a no-op worth repeating.
#
#   . enable-custom-repo.sh
#
# Reads GH_REPO (default xerootg/arch), RELEASE_TAG (default custom-repo) and
# GHIDRA_RELEASE_TAG (default pacman-repo).

# Make everything already published available as a build dependency.
#
# These packages depend on other AUR packages, and the container only knows the
# stock Arch repos -- so ilspy-git asked for dotnet-sdk-preview-bin and
# powershell, llama.cpp-sycl-f32-git asked for ggml-sycl-f32-git, and pacman
# said "target not found" for all three despite this project building every one
# of them. [custom] is where they live, so point the builder at it.
#
# This is also what makes an incremental multi-pipeline build work at all: a
# dependency built by build-repo, or by an earlier run of this workflow, is
# picked up from the release rather than rebuilt from source here.
CUSTOM_URL="https://github.com/${GH_REPO:-xerootg/arch}/releases/download/${RELEASE_TAG:-custom-repo}"

if curl -fsSL "$CUSTOM_URL/xerootg.asc" -o /tmp/xerootg.asc; then
  pacman-key --init >/dev/null 2>&1 || true
  pacman-key --populate archlinux >/dev/null 2>&1 || true
  pacman-key --add /tmp/xerootg.asc >/dev/null
  # --lsign-key wants the PRIMARY fingerprint. A signature names the signing
  # subkey, so reading it off the key itself is the only thing that works.
  fpr="$(gpg --show-keys --with-colons /tmp/xerootg.asc | awk -F: '/^fpr:/{print $10; exit}')"
  pacman-key --lsign-key "$fpr" >/dev/null
  echo "trusting [custom] signing key $fpr"
  siglevel="Required DatabaseOptional"
else
  # No key published yet. Still usable, just unverified -- and worth saying so
  # out loud rather than silently downgrading.
  echo "::warning::could not fetch the [custom] signing key; using SigLevel = Optional TrustAll"
  siglevel="Optional TrustAll"
fi

cat >> /etc/pacman.conf <<PACEOF

[custom]
Server = $CUSTOM_URL
SigLevel = $siglevel
PACEOF

# [ghidra] as well, for anything that builds against Ghidra.
#
# A Ghidra extension is compiled against a specific Ghidra release and needs
# that release present at build time, so ghidra-noprompt is a makedepend --
# and it lives in its own repo because it is far too large to have been pushed
# anywhere before releases were used. Same GitHub repo, same signing key,
# different release tag.
#
# Adding it costs nothing when nothing needs it: pacman fetches one small
# database and no packages.
GHIDRA_URL="https://github.com/${GH_REPO:-xerootg/arch}/releases/download/${GHIDRA_RELEASE_TAG:-pacman-repo}"
cat >> /etc/pacman.conf <<PACEOF

[ghidra]
Server = $GHIDRA_URL
SigLevel = $siglevel
PACEOF

# Not fatal: a first run has no database published, and every dependency that
# happens to be in the stock repos still resolves.
pacman -Sy --noconfirm >/dev/null 2>&1 \
  || echo "::warning::could not refresh [custom]; only the stock repos are available"
