#!/bin/sh
# Lint, then copy Primer onto a Kindle that connects over MTP (2024 Paperwhite/Scribe/Colorsoft
# and other firmware 5.16.3+ devices) using gio. Usage: tools/deploy-mtp.sh [mtp://… storage URI]
# With no argument, the first mounted Kindle's "Internal Storage" is used.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -n "$1" ]; then
	KINDLE="${1%/}"
else
	ACT="$(gio mount -li 2>/dev/null | grep -oE 'activation_root=mtp://[^ ]+' | head -1 | cut -d= -f2)"
	[ -n "$ACT" ] || { echo "No MTP Kindle found (gio mount -l)"; exit 1; }
	gio mount "$ACT" >/dev/null 2>&1 || true
	KINDLE="${ACT%/}/Internal%20Storage"
fi
gio info "$KINDLE/koreader" >/dev/null 2>&1 || { echo "Kindle with KOReader not mounted at $KINDLE"; exit 1; }

"$ROOT/tools/lint/lint.sh" >/dev/null || { echo "Lint failed; not deploying"; "$ROOT/tools/lint/lint.sh"; exit 1; }

# Copy a local directory tree into $1 (MTP has no recursive copy; files are replaced one by one).
put_tree() { # put_tree <local dir> <remote dir URI>
	src="$1"; dst="$2"
	gio mkdir -p "$dst" >/dev/null 2>&1 || true
	find "$src" -mindepth 1 -type d | while read -r d; do
		gio mkdir -p "$dst/${d#"$src"/}" >/dev/null 2>&1 || true
	done
	find "$src" -type f ! -name '._*' ! -name '.DS_Store' | while read -r f; do
		rel="${f#"$src"/}"
		gio copy "$f" "$dst/$rel" 2>/dev/null \
			|| { gio remove "$dst/$rel" >/dev/null 2>&1 || true; gio copy "$f" "$dst/$rel"; }
	done
}

put_tree "$ROOT/src/plugins"      "$KINDLE/koreader/plugins"
put_tree "$ROOT/src/patches"      "$KINDLE/koreader/patches"
put_tree "$ROOT/src/extensions"   "$KINDLE/extensions"
put_tree "$ROOT/src/fonts"        "$KINDLE/koreader/fonts/primer"
put_tree "$ROOT/src/screensavers" "$KINDLE/koreader/screensavers/primer"
echo "Deployed to $KINDLE"
