#!/bin/bash
#
# Turn any square-ish PNG into the app icon (SupportFiles/AppIcon.icns), then the
# next ./scripts/build_app.sh picks it up automatically.
#
#   ./scripts/make_icon.sh /path/to/logo.png
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "usage: ./scripts/make_icon.sh /path/to/logo.png"
    echo "  (a square PNG, ideally 1024x1024)"
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz       "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png"   >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
mkdir -p SupportFiles
iconutil -c icns "$ICONSET" -o SupportFiles/AppIcon.icns
echo "==> Wrote SupportFiles/AppIcon.icns"
echo "    Now run ./scripts/build_app.sh to rebuild Typer+.app with the new icon."
