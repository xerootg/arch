A pacman repository served straight from this release.

`orca-slicer-git` compresses to around 164 MB, and GitHub refuses any pushed
file over 100 MB, so it cannot live in the GitHub Pages repo that serves
`[custom]`. Release assets have a 2 GB limit, so it lives here instead.

Add to `/etc/pacman.conf`:

```ini
[orca]
Server = https://github.com/xerootg/arch/releases/download/orca-repo
SigLevel = Required DatabaseOptional
```

Packages here are signed. Import the key once before installing:

```bash
curl -fsSL https://xerootg.github.io/xerootg.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key "$(curl -fsSL https://xerootg.github.io/xerootg.asc \
  | gpg --show-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
```

Then `sudo pacman -Sy orca-slicer-git`.

Provides `orca-slicer-git` and `orca-slicer-git-extras` (calibration models,
daily tips and the profile validator). The main package `provides`/`conflicts`
with `orca-slicer`.

Assets are replaced in place on every update and superseded builds are deleted,
so this release holds one revision at a time. The tag is fixed, so the `Server`
URL never changes. The current contents of every repo are listed at
[xerootg.github.io](https://xerootg.github.io/).
