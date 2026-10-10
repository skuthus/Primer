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
find "$KINDLE/koreader/plugins" "$KINDLE/koreader/patches" "$KINDLE/extensions" -name '._*' -delete
sync
echo "Deployed to $KINDLE"
