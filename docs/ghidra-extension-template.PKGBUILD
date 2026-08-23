# Template: a Ghidra extension as a pacman package.
#
# Copy to pkgbuilds/<pkgname>/PKGBUILD, fill in the marked fields, and add the
# directory to build-pacman-repo.yaml. Committed recipes are used as-is; only
# members without a directory get cloned from the AUR.
#
# ---------------------------------------------------------------------------
# The one thing that makes Ghidra extensions different from ordinary packages
# ---------------------------------------------------------------------------
# An extension is compiled against a specific Ghidra release and records that
# version in its extension.properties. Ghidra refuses to load an extension
# whose recorded version does not match the running one -- silently, in the
# log, which is a miserable way to find out. So the package pins an exact
# dependency, and _ghidraver below is rewritten by the same bump script that
# updates ghidra-noprompt. When Ghidra moves, these rebuild.

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
	export JAVA_HOME="/usr/lib/jvm/java-${_javaver}-openjdk"

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
