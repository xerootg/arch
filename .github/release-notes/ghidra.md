A pacman repository served straight from this release, for packages too large
to live in the GitHub Pages repo (GitHub rejects any pushed file over 100 MB).

Add to `/etc/pacman.conf`:

```ini
[ghidra]
Server = https://github.com/xerootg/arch/releases/download/pacman-repo
SigLevel = Required DatabaseOptional
```

Packages here are signed. Import the key once before installing:

```bash
curl -fsSL https://xerootg.github.io/xerootg.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key "$(curl -fsSL https://xerootg.github.io/xerootg.asc \
  | gpg --show-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
```

Then `sudo pacman -Sy ghidra-noprompt`.

Contains **ghidra-noprompt**: stock Ghidra from the matching upstream release,
patched so opening a program that has never been analyzed does not prompt to
auto-analyze. The prompt moves to a tool option (**Edit → Tool Options → Auto
Analysis → Ask To Analyze**) that ships disabled, so stock behaviour can be
restored without a rebuild. See [xerootg/ghidra](https://github.com/xerootg/ghidra)
for the patch and the build that produced it. It `provides`/`conflicts` with
`ghidra`.

Assets here are replaced in place on every update; the tag is fixed so the
`Server` URL never changes. The current contents of every repo are listed at
[xerootg.github.io](https://xerootg.github.io/).
