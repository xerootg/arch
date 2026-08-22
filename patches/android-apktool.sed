# android-apktool: build with the project's own gradle wrapper.
#
# The build fails against the gradle in the official repos:
#
#   Cannot find module 'gradle-public-api-legacy' in distribution directory
#   '/usr/share/java/gradle'
#   ==> ERROR: A failure occurred in build().
#
# That is gradle's own bootstrap reporting an incomplete distribution, so it is
# a mismatch between apktool and how gradle 9.7 is packaged rather than anything
# wrong with the recipe. apktool ships a gradlew wrapper, which fetches a gradle
# it is known to work with, and the build container has network.
#
# Written without being able to read the recipe -- the AUR is unreachable from
# where this was authored -- so it covers the usual spellings. If none matches,
# the no-op path prints the recipe's actual gradle lines and the next run can be
# exact rather than speculative.

# `gradle build` / `gradle assemble` ... at the start of a command
s/^\([[:space:]]*\)gradle[[:space:]]/\1.\/gradlew /

# after a && or | or ; separator
s/\([&|;][[:space:]]*\)gradle[[:space:]]/\1.\/gradlew /

# `$_gradle` style indirection is left alone deliberately: substituting into a
# variable assignment would change the meaning of every later use.

# Ask for the stacktrace.
#
# Switching to the wrapper got past "Cannot find module
# 'gradle-public-api-legacy'" -- the log now shows gradle 8.14.4 out of
# .gradle/wrapper/dists -- and the build fails later with an exception whose
# entire message is a bare version string:
#
#   * What went wrong:
#   26.0.2.1
#
# which says nothing about where it came from. Gradle's own advice is to rerun
# with --stacktrace, and the recipe is not readable from here, so ask it for the
# stacktrace rather than guessing at what wants that version.
/gradlew/ s/$/ --stacktrace/
/gradlew.*--stacktrace.*--stacktrace/ s/ --stacktrace\( --stacktrace\)*/ --stacktrace/
