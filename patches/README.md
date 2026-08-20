# PKGBUILD patches

A patch here is applied to a fresh AUR clone of the matching **pkgbase**, every
run, right after cloning: `patches/<pkgbase>.patch`.

Carrying a patch is a real cost — it has to be kept working as upstream moves —
so it is worth it only when the alternative is not having the package. The case
that forced it was `authentik-platform-git`, whose `build()` does

```sh
cd "$srcdir/platform/cmd/agent_system"
```

against a tree where that path no longer exists.

Patches are applied with `--forward`, and a patch that no longer applies emits a
warning rather than failing the build. That is deliberate: the usual reason a
patch stops applying is that upstream fixed the same thing, and the right
response is to delete the patch, not to break every other package's update in
the meantime.
