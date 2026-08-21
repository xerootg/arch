# llama.cpp-sycl-f32-git: make package()'s cleanup removals tolerant.
#
# The build links cleanly now (lto: false in heavy-packages.yaml) and dies in
# package() instead:
#
#   rm: cannot remove '.../usr/include/ggml*': No such file or directory
#   ==> ERROR: A failure occurred in package().
#
# The recipe removes the ggml headers so it does not collide with the
# separately packaged ggml, but nothing installed them. Deleting a file that is
# already gone is exactly what the line wants.
#
# The first version of this rule matched a literal "$pkgdir" and changed
# nothing -- the build-one.sh no-op warning is what caught that. It now also
# matches ${pkgdir}, and handles rm carrying flags already.
#
# Scoped to lines mentioning pkgdir, so an rm elsewhere in the recipe is left
# alone. Both branches are idempotent: a line that already has -f is untouched
# because the -f alternative is matched first and rewritten to itself.

# rm with no flags:      rm "$pkgdir"/x   ->  rm -f "$pkgdir"/x
/pkgdir/ s/^\([[:space:]]*\)rm[[:space:]]\{1,\}\([^-[:space:]]\)/\1rm -f \2/

# rm with flags but no f: rm -r "$pkgdir"/x  ->  rm -fr "$pkgdir"/x
/pkgdir/ s/^\([[:space:]]*\)rm[[:space:]]\{1,\}-\([abcdeghijklmnopqrstuvwxyz]\{1,\}\)\([[:space:]]\)/\1rm -f\2\3/
