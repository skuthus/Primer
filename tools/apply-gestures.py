#!/usr/bin/env python3
"""Clear the gestures listed in src/defaults/gestures.lua in a Kindle's koreader/settings/gestures.lua.

Each `name = {},` line in the defaults becomes an empty action list in both the file
browser and reader sections. Usage: tools/apply-gestures.py [/Volumes/Kindle]
"""
import pathlib, re, shutil, sys, time

root = pathlib.Path(__file__).resolve().parent.parent
kindle = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/Volumes/Kindle")
target = kindle / "koreader/settings/gestures.lua"
if not target.is_file():
    sys.exit(f"{target} not found (Kindle not mounted, or KOReader never saved gestures)")

names = re.findall(r"^\s*(\w+)\s*=\s*\{\}", (root / "src/defaults/gestures.lua").read_text(), re.M)
text = target.read_text()
backup = root / "backup" / f"gestures.lua.{time.strftime('%Y%m%d-%H%M%S')}"
backup.parent.mkdir(exist_ok=True)
shutil.copyfile(target, backup)

for name in names:
    # Replace an existing entry's action table (single-level) with {}.
    text, n = re.subn(r'(\["%s"\] = )\{[^{}]*\}' % re.escape(name), r"\1{}", text)
    print(f"{name}: {n} section(s) cleared" if n else f"{name}: not present (default applies)")
target.write_text(text)
print(f"Backup: {backup}")
