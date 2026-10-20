# Template: a Ghidra extension as a pacman package.
#
# Copy to release-pkgbuilds/ghidra-ext-<name>/PKGBUILD and fill in the marked
# fields. That is all: ghidra-noprompt.yml builds every release-pkgbuilds/
# ghidra-ext-* in the same run as ghidra-noprompt and publishes them together
# to [ghidra]. Do not add it to build-pacman-repo.yaml.
#
# ---------------------------------------------------------------------------
# The one thing that makes Ghidra extensions different from ordinary packages
# ---------------------------------------------------------------------------
# An extension is compiled against a specific Ghidra release and records that
# version in its extension.properties. Ghidra refuses to load an extension
# whose recorded version does not match the running one -- silently, in the
# log, which is a miserable way to find out. So the package pins an exact
# dependency, and _ghidraver below is rewritten by the same bump script that
# updates ghidra-noprompt. When Ghidra moves, these rebuild in the same run and
# land in the same database, so `pacman -Syu` always sees a matching pair. An
# extension that fails to build holds the new Ghidra back for everyone, so fix
# it or remove it from release-pkgbuilds/ promptly.

pkgname=ghidra-ext-CHANGEME
pkgver=0.0.0
pkgrel=1

# >>> generated: do not hand-edit >>>
# Stamped by .github/scripts/bump-ghidra-noprompt.py when the fork releases.
_ghidraver=12.1.2
_javaver=21
# <<< generated <<<

# The directory name Ghidra will see under Ghidra/Extensions/. Must match the
# name inside the built zip, which is the gradle project name.
_extname=CHANGEME

pkgdesc="CHANGEME (Ghidra ${_ghidraver} extension)"
arch=('x86_64')
url='CHANGEME'
license=('Apache-2.0')

# Exact version, deliberately. A range would let pacman pair this with a Ghidra
# that will not load it, and the failure mode is a missing menu entry rather
# than an error anyone notices.
depends=("ghidra-noprompt=${_ghidraver}")
makedepends=('gradle' "java-environment>=${_javaver}" 'git')

source=("CHANGEME")
sha256sums=('SKIP')

# Extensions are jars plus resources; there is nothing to strip and the
# prebuilt native helpers belong to Ghidra itself.
options=('!strip')

build() {
	cd "${srcdir}/CHANGEME"

	# Ghidra's own build plugin wants this either as a property or in the
	# environment; give it both, since extensions disagree about which they read.
	export GHIDRA_INSTALL_DIR="/opt/ghidra-noprompt"
	# No JAVA_HOME. java-environment>=${_javaver} is satisfied by whichever JDK
	# pacman picks -- non-interactively that is jdk-openjdk, the newest -- so a
	# path naming JDK ${_javaver} may not exist, and gradle refuses to start when
	# JAVA_HOME points nowhere. Ghidra's buildExtension.gradle sets source and
	# target compatibility to Ghidra's own Java release, so a newer JDK is fine.

	# --offline is not an option here: Ghidra extensions resolve dependencies
	# from Maven Central at build time. The build container has network.
	gradle -PGHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR}" --no-daemon buildExtension
}

package() {
	cd "${srcdir}/CHANGEME"

	# buildExtension writes dist/ghidra_<ver>_<rel>_<date>_<name>.zip. Match on
	# the extension name rather than the whole filename, which carries a build
	# date nothing else knows.
	local _zip
	_zip="$(find dist -maxdepth 1 -name "*_${_extname}.zip" -print -quit)"
	if [ -z "${_zip}" ]; then
		echo "no built extension zip in dist/ -- did buildExtension run?" >&2
		return 1
	fi

	# Extensions live inside the Ghidra tree. Two packages writing into one
	# directory is fine for pacman, which tracks files rather than directories,
	# as long as they do not claim the same paths.
	install -dm755 "${pkgdir}/opt/ghidra-noprompt/Ghidra/Extensions"
	bsdtar -xf "${_zip}" -C "${pkgdir}/opt/ghidra-noprompt/Ghidra/Extensions"

	install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE" 2>/dev/null || true
}
