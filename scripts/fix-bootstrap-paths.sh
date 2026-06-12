#!/usr/bin/env bash
set -e -o pipefail

ARCH="${1:-aarch64}"
SCRIPTDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPTDIR"

OLD_PREFIX="/data/data/com.termux"
NEW_PREFIX="/data/data/com.einkbot"
BOOTSTRAP_URL="https://github.com/termux/termux-packages/releases/download/bootstrap-2026.06.07-r1%2Bapt.android-7/bootstrap-${ARCH}.zip"
ZIP_NAME="bootstrap-einkbot-${ARCH}.zip"

command -v patchelf >/dev/null 2>&1 || sudo apt-get install -y patchelf
command -v zip >/dev/null 2>&1 || sudo apt-get install -y zip

TMPDIR=$(mktemp -d)
echo "Working in $TMPDIR"

echo "::group::Downloading upstream bootstrap for $ARCH"
curl -fL -o "$TMPDIR/bootstrap.zip" "$BOOTSTRAP_URL"
echo "::endgroup::"

echo "::group::Extracting bootstrap"
unzip -q "$TMPDIR/bootstrap.zip" -d "$TMPDIR/rootfs"
cd "$TMPDIR/rootfs"
echo "::endgroup::"

echo "::group::Fixing paths in text files"
find . -type f ! -name '*.gz' ! -name '*.xz' ! -name '*.bz2' ! -name '*.zip' \
    ! -name '*.png' ! -name '*.jpg' ! -name '*.so.?' ! -name '*.o' ! -name '*.a' \
    -exec grep -l "$OLD_PREFIX" {} \; 2>/dev/null | while IFS= read -r f; do
    if file "$f" | grep -q "text"; then
        sed -i "s|$OLD_PREFIX|$NEW_PREFIX|g" "$f"
    fi
done
echo "::endgroup::"

echo "::group::Fixing ELF binaries (RPATH/RUNPATH)"
find . -type f -name '*.so*' -o -type f -name '*.so' -o -type f -executable | \
    while IFS= read -r f; do
    if file "$f" 2>/dev/null | grep -q ELF; then
        rpath=$(patchelf --print-rpath "$f" 2>/dev/null || true)
        if [ -n "$rpath" ] && echo "$rpath" | grep -q "$OLD_PREFIX"; then
            new_rpath="${rpath//$OLD_PREFIX/$NEW_PREFIX}"
            echo "  RPATH: $f"
            patchelf --set-rpath "$new_rpath" "$f"
        fi
    fi
done
echo "::endgroup::"

echo "::group::Fixing SYMLINKS.txt"
if [ -f SYMLINKS.txt ]; then
    sed -i "s|$OLD_PREFIX|$NEW_PREFIX|g" SYMLINKS.txt
fi
echo "::endgroup::"

echo "::group::Fixing dpkg metadata paths"
find var/lib/dpkg -type f 2>/dev/null | while IFS= read -r f; do
    sed -i "s|$OLD_PREFIX|$NEW_PREFIX|g" "$f"
done
echo "::endgroup::"

echo "::group::Creating bootstrap zip"
zip -r -9 "${SCRIPTDIR}/${ZIP_NAME}" . -x "*/\.*" 2>/dev/null
ZIP_SIZE=$(ls -lh "${SCRIPTDIR}/${ZIP_NAME}" | awk '{print $5}')
echo "Created: ${ZIP_NAME} (${ZIP_SIZE})"
echo "::endgroup::"

rm -rf "$TMPDIR"
echo "Done! ${ZIP_NAME} ready."
