#!/bin/bash
#
# One-command de-risk Test A: builds the injector, opens the probe page in Chrome,
# then injects a test sentence so you can confirm the page sees real, trusted,
# paste-free keystrokes. (Test B — the Google Docs canvas — is the same injector
# run with a blank Google Doc focused instead; see docs/test-instructions.md.)
#
# Your terminal app needs Accessibility: System Settings ▸ Privacy & Security ▸
# Accessibility ▸ enable Terminal (or iTerm). The injector prints whether the
# grant is present.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building injector…"
swift build --product InjectTest >/dev/null

PROBE="file://$(pwd)/docs/keyevent-probe.html"
echo "==> Opening probe page in Chrome…"
open -a "Google Chrome" "$PROBE" 2>/dev/null || open "$PROBE"
sleep 1

cat <<'MSG'

============================================================
 NEXT: click inside the big text box on the page in Chrome,
 then WAIT — a 7-second countdown is starting in this window
 and the injector will type into whatever field is focused.
 Keep the text box focused. Watch the page's verdict banner.
============================================================
MSG

exec "$(swift build --show-bin-path)/InjectTest"
