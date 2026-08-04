Builds some AURs and my libfprint package for my laptop, pushing the diff to [xerootg.github.io](http://xerootg.github.io)

Saves me time building AURs every time someone pushes.

Use these packages by adding this to your `pacman.conf`:
```ini
[custom]
Server = https://xerootg.github.io/archlinux
SigLevel = Optional TrustAll
```

## `[ghidra]` — the oversized-package repo

`ghidra-noprompt` is ~350 MB, and GitHub refuses any pushed file over 100 MB, so
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
