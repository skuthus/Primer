#!/bin/sh
# Build a release zip whose folders go straight onto a Kindle (or another KOReader device):
#   dist/Primer-<version>.zip  =  koreader/{plugins,patches,fonts/primer}  +  extensions/primer
# Options:
#   --koreader <koreader-kindle*.zip>  also include KOReader itself (one zip installs both)
#   A StarDict dictionary folder in vendor/dict/ is included in koreader/data/dict/.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
KOREADER_ZIP=""
while [ $# -gt 0 ]; do
	case "$1" in
		--koreader) KOREADER_ZIP="$2"; shift 2 ;;
		*) echo "Unknown option: $1"; exit 1 ;;
	esac
done

"$ROOT/tools/lint/lint.sh" >/dev/null || { echo "Lint failed; not packaging"; "$ROOT/tools/lint/lint.sh"; exit 1; }

NAME="Primer-$VERSION"
[ -n "$KOREADER_ZIP" ] && NAME="$NAME-with-KOReader"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ -n "$KOREADER_ZIP" ]; then
	[ -f "$KOREADER_ZIP" ] || { echo "No such file: $KOREADER_ZIP"; exit 1; }
	unzip -q "$KOREADER_ZIP" -d "$STAGE"
	[ -d "$STAGE/koreader" ] || { echo "$KOREADER_ZIP doesn't look like a KOReader release (no koreader/ folder)"; exit 1; }
fi

mkdir -p "$STAGE/koreader/plugins" "$STAGE/koreader/patches" "$STAGE/koreader/fonts/primer" "$STAGE/extensions"
cp -R "$ROOT/src/plugins/." "$STAGE/koreader/plugins/"
cp "$ROOT"/src/patches/*.lua "$STAGE/koreader/patches/"
cp "$ROOT"/src/fonts/* "$STAGE/koreader/fonts/primer/"
cp -R "$ROOT/src/extensions/." "$STAGE/extensions/"
if [ -d "$ROOT/vendor/dict" ] && [ -n "$(ls -A "$ROOT/vendor/dict")" ]; then
	mkdir -p "$STAGE/koreader/data/dict"
	cp -R "$ROOT/vendor/dict/." "$STAGE/koreader/data/dict/"
fi
cp "$ROOT/INSTALL.txt" "$STAGE/Primer - Install.txt"
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete

mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/$NAME.zip"
(cd "$STAGE" && zip -qr -X "$ROOT/dist/$NAME.zip" .)
echo "Built dist/$NAME.zip"
