# Vendored PKGBUILDs

A directory here, named for the member, is copied into `pkgbuilds/` instead of
cloning from the AUR. It takes priority over the AUR, and it is the only way to
build something the AUR no longer carries.

Known cases from `pacman -Qmq` on the laptop:

| package | why |
|---|---|
| `extract-xiso` | dropped from the AUR |
| `ktailctl` | dropped from the AUR |
| `pipxu` | dropped from the AUR |
| `claude-desktop-bin` | never in the AUR |
| `intel-oneapi-mkl-sycl-shim` | dropped from the AUR |
| `python-androguard` | dropped from the AUR |
| `python-pkg_resources` | dropped; `python-setuptools` provides it |

A vendored PKGBUILD is a maintenance commitment: nothing upstream will update it,
and nothing will tell you when it breaks. Prefer an AUR package that still exists,
or a `-bin` variant, and vendor only when neither is available.

## Resolved by substitution instead of vendoring

A dependency walk over plausible alternative names found real AUR packages for
three of these, which is strictly better than carrying a PKGBUILD nobody
upstream maintains:

| was | now | why it matters |
|---|---|---|
| `electron37` | `electron37-bin` | the source build is Chromium: hours on four cores, real OOM risk, and it needs `gn`, `clang`, `gperf`. The `-bin` variant needs `alsa-lib`, `gtk3`, `nss` and is a download and a repack. It `provides` `electron37`. |
| `claude-desktop-bin` | `claude-desktop` | the `-bin` name is not in the AUR; the plain one is |
| `extract-xiso` | `extract-xiso-git` | the release package was dropped; the `-git` one remains |

## Still needing a decision

| package | state |
|---|---|
| `python-pkg_resources` | **needs nothing.** `python-setuptools` provides it; the installed copy is a leftover and can be removed |
| `ktailctl` | gone from the AUR, and `ktailctl-git` does not exist either |
| `pipxu` | gone; no `-git` variant |
| `python-androguard` | gone; no `-git` variant |
| `intel-oneapi-mkl-sycl-shim` | gone |

For these four, the options are to vendor a PKGBUILD here (a standing
maintenance commitment, since nothing upstream will update it or tell you when
it breaks), to find the package under a name not yet tried, or to drop it. None
of them can be built from the AUR as things stand.
