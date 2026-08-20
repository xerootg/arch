The main pacman repository, served straight from this release.

Add to `/etc/pacman.conf`:

```ini
[custom]
Server = https://github.com/xerootg/arch/releases/download/custom-repo
SigLevel = Required DatabaseOptional
```

Packages are signed. Import the key once before installing:

```bash
curl -fsSL https://xerootg.github.io/xerootg.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key "$(curl -fsSL https://xerootg.github.io/xerootg.asc \
  | gpg --show-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
```

Or run the enrolment script, which does both and fixes an existing `[custom]`
entry that still points at the old GitHub Pages URL:

```bash
curl -fsSL https://raw.githubusercontent.com/xerootg/arch/main/scripts/enroll.sh -o /tmp/enroll.sh
chmod +x /tmp/enroll.sh && sudo /tmp/enroll.sh client
```

**This replaces `https://xerootg.github.io/archlinux`.** That URL was a GitHub
Pages repository, and GitHub refuses any pushed file over 100 MB — which is why
large packages had to be split into separate repos, and why superseded packages
piled up forever (deleting one from git only adds a commit, it never reclaims
anything). Release assets may be 2 GB each and can actually be deleted, so the
database is the source of truth and anything it no longer names is pruned.

Everything in every repo is listed at [xerootg.github.io](https://xerootg.github.io/).
