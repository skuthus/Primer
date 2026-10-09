#!/bin/sh
# KUAL > Voyage: collect places the Kindle may store its user-set device name.
OUT=/mnt/us/voyage-devicename.txt
{
	echo "== $(date)"
	echo "== /var/local/java/prefs"
	ls -la /var/local/java/prefs 2>&1
	for f in /var/local/java/prefs/reginfo /var/local/java/prefs/com.amazon.ebook.framework/prefs; do
		[ -f "$f" ] && { echo "== $f"; grep -i -E 'name|nick' "$f" 2>&1 | head -40; }
	done
	echo "== files mentioning device name"
	grep -rIl -i -E 'device_?name|devicename|user_device' /var/local 2>/dev/null | head -40
	echo "== lipc properties with 'name'"
	for svc in $(lipc-probe -l 2>/dev/null); do
		lipc-probe -v "$svc" 2>/dev/null | grep -i 'name' | sed "s|^|$svc: |"
	done
	for p in "com.lab126.amazonRegistrationService deviceName" "com.lab126.amazonRegistrationService userName" "com.lab126.system deviceName"; do
		set -- $p
		echo "== lipc-get-prop $1 $2: $(lipc-get-prop -s "$1" "$2" 2>&1)"
	done
} > "$OUT" 2>&1
sync
if [ -x /mnt/us/koreader/fbink ]; then
	/mnt/us/koreader/fbink -qpm -y -6 "Saved voyage-devicename.txt"
else
	eips 1 38 "Saved voyage-devicename.txt"
fi
