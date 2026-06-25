#!/bin/bash
#
# Build Typer+ and assemble a signed, double-clickable "Typer+.app".
#
# For a stable Accessibility / Post-Events grant that SURVIVES rebuilds, create a
# persistent self-signed code-signing certificate once (Keychain Access ->
# Certificate Assistant -> Create a Certificate -> Self Signed Root -> Code
# Signing, e.g. named "TyperPlus Self"), then run:
#
#     TYPERPLUS_SIGN_IDENTITY="TyperPlus Self" ./scripts/build_app.sh
#
# Without it the app is ad-hoc signed and macOS forgets the permission grant on
# every rebuild (re-grant in System Settings, or run:
#     tccutil reset Accessibility com.aus.typerplus ).

set -euo pipefail
cd "$(dirname "$0")/.."

APP="Typer+.app"
EXE="TyperPlus"
BUNDLE_ID="com.aus.typerplus"
IDENTITY="${TYPERPLUS_SIGN_IDENTITY:-}"

# Auto-use the stable self-signed identity if it's installed.
if [[ -z "${IDENTITY}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "TyperPlus Self"; then
    IDENTITY="TyperPlus Self"
fi

echo "==> Building (release)"
swift build -c release --product "${EXE}"

BIN="$(swift build -c release --show-bin-path)/${EXE}"
if [[ ! -f "${BIN}" ]]; then
    echo "build product not found at ${BIN}"
    exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${EXE}"
cp "SupportFiles/Info.plist" "${APP}/Contents/Info.plist"
if [[ -f "SupportFiles/AppIcon.icns" ]]; then
    cp "SupportFiles/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

# Bundle Inter fonts where Bundle.main can find them in the hand-assembled .app.
FONT_SRC="Sources/TyperPlus/Resources/Fonts"
if [[ -d "${FONT_SRC}" ]]; then
    mkdir -p "${APP}/Contents/Resources/Fonts"
    cp "${FONT_SRC}"/*.ttf "${APP}/Contents/Resources/Fonts/" 2>/dev/null || true
fi

if [[ -n "${IDENTITY}" ]]; then
    echo "==> Codesigning with stable identity: ${IDENTITY}"
    codesign --force --identifier "${BUNDLE_ID}" --sign "${IDENTITY}" "${APP}"
else
    echo "==> Codesigning ad-hoc (grant resets each rebuild; install 'TyperPlus Self' to avoid)"
    codesign --force --identifier "${BUNDLE_ID}" --sign - "${APP}"
fi

codesign --verify --strict --verbose=2 "${APP}" || true

# Kill any running copy so the binary can be replaced AND the user always sees THIS build
# (single-instance launch would otherwise just re-activate a stale running copy).
pkill -9 -f "Typer\+.app/Contents/MacOS/TyperPlus" 2>/dev/null && { echo "==> Quit running Typer+"; sleep 1; } || true

INSTALL_DIR="${TYPERPLUS_INSTALL_DIR:-$HOME/Desktop}"
DEST="${INSTALL_DIR}/${APP}"
if [[ -d "${INSTALL_DIR}" && -w "${INSTALL_DIR}" ]]; then
    rm -rf "${DEST}"
    cp -R "${APP}" "${DEST}"
    rm -rf "${APP}"
    echo ""
    echo "==> Installed: ${DEST}"
    if [[ "${TYPERPLUS_LAUNCH:-1}" == "1" ]]; then
        open "${DEST}" && echo "==> Launched ${DEST}"
    else
        echo "    Launch with:  open \"${DEST}\"   (or Spotlight: Typer+)"
    fi
else
    echo ""
    echo "==> Built: $(pwd)/${APP}  (couldn't write ${INSTALL_DIR}; left it here)"
    echo "    Launch with:  open \"${APP}\""
fi
echo "    (Always launch the .app bundle, never the bare binary.)"
