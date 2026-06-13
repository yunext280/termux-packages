#!/usr/bin/env bash
set -e -o pipefail

ARCH="${1:-aarch64}"

SCRIPTDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPTDIR"

command -v zip >/dev/null 2>&1 || sudo apt-get install -y zip

. ./scripts/properties.sh

BOOTSTRAP_PACKAGES=(
    apt bash libbz2 command-not-found coreutils libcurl dash diffutils findutils
    gawk grep gzip less procps psmisc sed tar termux-core termux-exec
    termux-keyring termux-tools util-linux liblzma ed debianutils dos2unix
    inetutils lsof nano net-tools patch unzip
)

echo "::group::Building bootstrap packages for $ARCH"
echo "Building ${#BOOTSTRAP_PACKAGES[@]} packages..."
./build-package.sh -F -C -a "$ARCH" "${BOOTSTRAP_PACKAGES[@]}"
echo "::endgroup::"

cd "$SCRIPTDIR"
DEB_FILES=(./output/*.deb)
if [ ${#DEB_FILES[@]} -eq 0 ]; then
    echo "ERROR: no .deb files found in output/"
    exit 1
fi
echo "Found ${#DEB_FILES[@]} .deb files"

TMPDIR=$(mktemp -d)
ROOTFS="$TMPDIR/rootfs"
mkdir -p "$ROOTFS"

PREFIX="${TERMUX_PREFIX}"
DPKG_DIR="$ROOTFS/${PREFIX}/var/lib/dpkg"
INFO_DIR="$DPKG_DIR/info"
mkdir -p "$INFO_DIR"
: > "$DPKG_DIR/status"

echo "::group::Extracting packages into rootfs"
for deb in "${DEB_FILES[@]}"; do
    echo "  Processing $(basename "$deb")..."
    CTRL=$(mktemp -d)

    dpkg-deb -e "$deb" "$CTRL" || { echo "WARNING: dpkg-deb -e failed for $(basename "$deb"), skipping"; rm -rf "$CTRL"; continue; }
    dpkg-deb -x "$deb" "$ROOTFS" || { echo "WARNING: dpkg-deb -x failed for $(basename "$deb"), skipping"; rm -rf "$CTRL"; continue; }

    PKG_NAME=$(grep -E "^Package:" "$CTRL/control" | awk '{print $2}')
    [ -z "$PKG_NAME" ] && { rm -rf "$CTRL"; continue; }

    dpkg-deb --fsys-tarfile "$deb" | tar -t --no-recursion --exclude='*/' \
        2>/dev/null | sort | sed "s|^\.||" > "$INFO_DIR/${PKG_NAME}.list" || true

    cd "$ROOTFS"
    : > "$INFO_DIR/${PKG_NAME}.md5sums"
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f ".${f}" ] && md5sum ".${f}" | sed "s| \\./| |" \
            >> "$INFO_DIR/${PKG_NAME}.md5sums" 2>/dev/null || true
    done < "$INFO_DIR/${PKG_NAME}.list"

    for field in Package Version Architecture Installed-Size Depends Provides \
                 Replaces Conflicts Description Homepage Essential; do
        grep "^${field}:" "$CTRL/control" >> "$DPKG_DIR/status" 2>/dev/null || true
    done
    echo "Status: install ok installed" >> "$DPKG_DIR/status"
    echo "" >> "$DPKG_DIR/status"

    [ -f "$CTRL/conffiles" ] && cp "$CTRL/conffiles" "$INFO_DIR/${PKG_NAME}.conffiles"
    for s in preinst postinst prerm postrm; do
        [ -f "$CTRL/$s" ] && cp "$CTRL/$s" "$INFO_DIR/${PKG_NAME}.$s"
    done

    rm -rf "$CTRL"
    cd "$SCRIPTDIR"
done
echo "::endgroup::"

mkdir -p "$ROOTFS/${PREFIX}/tmp"
mkdir -p "$ROOTFS/${PREFIX}/share/termux"

echo "::group::Installing second-stage bootstrap"
BS_DIR="./scripts/bootstrap"

sed \
    -e "s%@TERMUX_PREFIX@%${TERMUX_PREFIX}%g" \
    -e "s%@TERMUX_PACKAGE_MANAGER@%${TERMUX_PACKAGE_MANAGER}%g" \
    -e "s%@TERMUX_PACKAGE_MANAGER_ALT@%${TERMUX_PACKAGE_MANAGER_ALT}%g" \
    -e "s%@TERMUX_PACKAGE_MANAGER_ALT_FALLBACK@%${TERMUX_PACKAGE_MANAGER_ALT_FALLBACK}%g" \
    -e "s%@TERMUX_PACKAGE_MANAGER_ALT_FALLBACK_ALT@%${TERMUX_PACKAGE_MANAGER_ALT_FALLBACK_ALT}%g" \
    -e "s%@TERMUX_APP_PACKAGE@%${TERMUX_APP_PACKAGE}%g" \
    -e "s%@TERMUX_HOME@%${TERMUX_HOME}%g" \
    -e "s%@TERMUX_APP_NAME@%${TERMUX_APP_NAME}%g" \
    "$BS_DIR/termux-bootstrap-second-stage.sh" \
    > "$ROOTFS/${PREFIX}/share/termux/termux-bootstrap-second-stage.sh"

sed \
    -e "s%@TERMUX_PREFIX@%${TERMUX_PREFIX}%g" \
    "$BS_DIR/01-termux-bootstrap-second-stage-fallback.sh" \
    > "$ROOTFS/${PREFIX}/share/termux/01-termux-bootstrap-second-stage-fallback.sh"

chmod +x "$ROOTFS/${PREFIX}/share/termux/termux-bootstrap-second-stage.sh"
echo "::endgroup::"

echo "::group::Creating bootstrap zip"
ZIP_NAME="bootstrap-einkbot-${ARCH}.zip"
cd "$ROOTFS"
zip -r -9 "${SCRIPTDIR}/${ZIP_NAME}" . -x "*/\.*" 2>/dev/null
ZIP_SIZE=$(ls -lh "${SCRIPTDIR}/${ZIP_NAME}" | awk '{print $5}')
echo "Created: ${ZIP_NAME} (${ZIP_SIZE})"
echo "::endgroup::"

rm -rf "$TMPDIR"
echo "Done! ${ZIP_NAME} ready."
