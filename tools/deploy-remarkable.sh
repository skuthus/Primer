#!/bin/sh
# Lint, then copy Primer into KOReader on a reMarkable over SSH (USB networking, 10.11.99.1).
# Needs key login as root: an SSH config entry named "remarkable" (or pass another host).
# Usage: tools/deploy-remarkable.sh [host]
set -e
HOST="${1:-remarkable}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/lint/lint.sh" >/dev/null || { echo "Lint failed; not deploying"; "$ROOT/tools/lint/lint.sh"; exit 1; }

# KOReader's folder: AppLoad (XOVI), Toltec, or a manual install.
KO=$(ssh -o BatchMode=yes "$HOST" 'for d in /home/root/xovi/exthome/appload/koreader /opt/koreader /home/root/koreader; do [ -f "$d/reader.lua" ] && { echo "$d"; break; }; done')
[ -n "$KO" ] || { echo "KOReader not found on $HOST"; exit 1; }

# Keep a copy of KOReader's settings from before Primer's first run.
ssh -o BatchMode=yes "$HOST" "[ -f '$KO/settings.reader.lua.pre-primer' ] || cp '$KO/settings.reader.lua' '$KO/settings.reader.lua.pre-primer' 2>/dev/null || true"

# Stage what goes into KOReader's folder (no Kindle extension), then send it as one tar stream.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/plugins" "$STAGE/patches" "$STAGE/fonts/primer" "$STAGE/screensavers/primer"
cp -R "$ROOT/src/plugins/." "$STAGE/plugins/"
cp "$ROOT"/src/patches/*.lua "$STAGE/patches/"
cp "$ROOT"/src/fonts/* "$STAGE/fonts/primer/"
cp -R "$ROOT/src/screensavers/." "$STAGE/screensavers/primer/"
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete
COPYFILE_DISABLE=1 tar -C "$STAGE" -cf - . | ssh -o BatchMode=yes "$HOST" "tar -C '$KO' -xf -"
echo "Deployed to $HOST:$KO"
