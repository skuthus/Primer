#!/bin/sh
# Copy the Kindle's stock sleep screens (not the Amazon Kids ones) to /mnt/us/screensavers,
# where KOReader picks a random one each time the Kindle sleeps. Missing files only.
SRC=/usr/share/blanket/screensaver
DST=/mnt/us/screensavers
mkdir -p "$DST" || exit 1
for f in "$SRC"/bg_ss*.png; do
	[ -f "$f" ] || continue
	[ -f "$DST/${f##*/}" ] || cp "$f" "$DST/"
done
