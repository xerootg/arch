Builds some AURs and my libfprint package for my laptop, pushing the diff to [xerootg.github.io](http://xerootg.github.io)

Saves me time building AURs every time someone pushes.

Use these packages by adding this to your `pacman.conf`:
```ini
[custom]
Server = https://xerootg.github.io/archlinux
SigLevel = Optional TrustAll
```

## `[ghidra]` — the oversized-package repo

`ghidra-noprompt` is ~500 MB, and GitHub refuses any pushed file over 100 MB, so
it cannot live in the Pages repo above. It gets its own pacman repo, served
directly out of a GitHub Release on this repository:

```ini
[ghidra]
Server = https://github.com/xerootg/arch/releases/download/pacman-repo
SigLevel = Optional TrustAll
```

Then `sudo pacman -Sy ghidra-noprompt`.

That is [stock Ghidra](https://github.com/NationalSecurityAgency/ghidra) from
the matching upstream stable release, with one change: opening a program that
has never been analyzed no longer prompts *"would you like to analyze it now?"*.
The prompt moves to a tool option (**Edit → Tool Options → Auto Analysis → Ask
To Analyze**) that ships disabled, so it can be turned back on without a
rebuild. The patch and the build that produced it live in
[xerootg/ghidra](https://github.com/xerootg/ghidra). The package
`provides`/`conflicts` with `ghidra`.

`.github/workflows/ghidra-noprompt.yml` checks that fork daily, repackages any
new release, refreshes the `ghidra.db` in the fixed `pacman-repo` release, and
drops the superseded package asset. The release tag never changes, so the
`Server` URL above is stable.

Its PKGBUILD lives in `release-pkgbuilds/`, not `pkgbuilds/`, so the
`build-pacman-repo` pipeline never sees it — that pipeline would otherwise try
to commit the package to the Pages repo and break the push for every other
package.

The job decides what to build from the release itself, not from the checked-in
`pkgver`, so it stays correct without needing to commit anything. It does try to
refresh the PKGBUILD afterwards, but the `main` ruleset requires a pull request
and `github-actions[bot]` cannot bypass it, so that push is best effort and
non-fatal — expect the checked-in recipe to lag a release behind unless the bot
is granted a bypass.

## `[orca]` — OrcaSlicer, for the same reason

`orca-slicer-git` compresses to ~164 MB, so it hits the same 100 MB wall. It gets
its own release-hosted repo:

```ini
[orca]
Server = https://github.com/xerootg/arch/releases/download/orca-repo
SigLevel = Optional TrustAll
```

Then `sudo pacman -Sy orca-slicer-git`.

Ships `orca-slicer-git` and `orca-slicer-git-extras` (calibration models, daily
tips, profile validator). The main package `provides`/`conflicts` with
`orca-slicer`.

`.github/workflows/orca-slicer.yml` computes upstream's `pkgver` the same way the
PKGBUILD does, skips the run if that revision is already published, and otherwise
does a full from-source build — around **2h45m** — before refreshing `orca.db` in
the fixed `orca-repo` release and deleting the superseded packages.

Two settings keep that build alive on a 16 GB runner, both in
[the PKGBUILD](https://github.com/xerootg/orca-slicer-git): `options=('!lto')` at
**pkgbase** level, and `ninja -j2` for the main build. The pkgbase part matters —
an `options=()` inside a `package_*()` function only affects packaging, and
makepkg resolves `lto` before `build()` runs, so a per-package array cannot
disable it. Without this the job is OOM-killed (exit 137) while compiling
libslic3r's precompiled header, and because that kill takes the whole container
down rather than returning a non-zero status, `allow-failure` does not contain
it — it stops every other package in the repo from updating too.
