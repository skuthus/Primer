#!/bin/sh
# Lint, then copy Primer onto a USB-mounted Kindle. Usage: tools/deploy.sh [/Volumes/Kindle]
set -e
KINDLE="${1:-/Volumes/Kindle}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$KINDLE/koreader" ] || { echo "Kindle with KOReader not mounted at $KINDLE"; exit 1; }
"$ROOT/tools/lint/lint.sh" >/dev/null || { echo "Lint failed; not deploying"; "$ROOT/tools/lint/lint.sh"; exit 1; }
cp -RX "$ROOT/src/plugins/." "$KINDLE/koreader/plugins/"
mkdir -p "$KINDLE/koreader/patches" && cp -X "$ROOT"/src/patches/*.lua "$KINDLE/koreader/patches/"
cp -RX "$ROOT/src/extensions/." "$KINDLE/extensions/"
rm -rf "$KINDLE/extensions/voyage" # the KUAL extension's old name
# Bundled open fonts (used when the Kindle's own fonts aren't there).
mkdir -p "$KINDLE/koreader/fonts/primer" && cp -X "$ROOT"/src/fonts/* "$KINDLE/koreader/fonts/primer/"
# Sleep screen collections (public domain; see src/screensavers/CREDITS.md).
mkdir -p "$KINDLE/koreader/screensavers/primer" && cp -RX "$ROOT/src/screensavers/." "$KINDLE/koreader/screensavers/primer/"
find "$KINDLE/koreader/plugins" "$KINDLE/koreader/patches" "$KINDLE/extensions" "$KINDLE/koreader/fonts/primer" "$KINDLE/koreader/screensavers/primer" -name '._*' -delete
sync
echo "Deployed to $KINDLE"
