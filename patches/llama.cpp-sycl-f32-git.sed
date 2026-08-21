# llama.cpp-sycl-f32-git: make package()'s cleanup removals tolerant.
#
# The build now links cleanly (see lto: false in heavy-packages.yaml) and dies
# in package() instead:
#
#   rm: cannot remove '.../usr/include/ggml*': No such file or directory
#   ==> ERROR: A failure occurred in package().
#
# The recipe removes the ggml headers so it does not conflict with the
# separately packaged ggml, but nothing installed them, so a bare rm fails and
# takes the whole package down. Deleting a file that is already absent is
# exactly the outcome the line wants.
#
# Scoped deliberately: only lines that mention $pkgdir, and only where rm has
# no flag yet, so an existing `rm -rf` is left alone.
/\$pkgdir/ s/^\([[:space:]]*\)rm \([^-]\)/\1rm -f \2/
