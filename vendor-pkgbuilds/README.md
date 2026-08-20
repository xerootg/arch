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
