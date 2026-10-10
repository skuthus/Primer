#!/bin/sh
# Install, remove, or report the start-at-boot job. From KUAL (Primer menu), or from Primer's
# own Settings / welcome screen with "quiet" as the second argument (no on-screen message).

JOB_SRC="/mnt/us/extensions/primer/koreader-autostart.conf"
JOB_DST="/etc/upstart/koreader-autostart.conf"

QUIET="$2"

say() {
	[ "$QUIET" = "quiet" ] && return
	if [ -x /mnt/us/koreader/fbink ]; then
		/mnt/us/koreader/fbink -qpm -y -6 "$1"
	else
		eips 1 38 "$1"
	fi
}

rootfs_rw() { mntroot rw >/dev/null 2>&1 || mount -o rw,remount /; }
rootfs_ro() { mntroot ro >/dev/null 2>&1 || mount -o ro,remount /; }

same() { [ "$(md5sum < "$1")" = "$(md5sum < "$2" 2>/dev/null)" ]; }

case "$1" in
	enable)
		[ -f "$JOB_SRC" ] || { say "Primer: job file missing"; exit 1; }
		rootfs_rw
		cp -f "$JOB_SRC" "$JOB_DST" && chmod 644 "$JOB_DST"
		sync
		rootfs_ro
		if same "$JOB_SRC" "$JOB_DST"; then
			say "Primer will start at boot"
		else
			say "Primer: install FAILED"
		fi
		;;
	disable)
		rootfs_rw
		rm -f "$JOB_DST"
		sync
		rootfs_ro
		if [ -e "$JOB_DST" ]; then
			say "Primer: remove FAILED"
		else
			say "Kindle UI will start at boot"
		fi
		;;
	status)
		if [ ! -e "$JOB_DST" ]; then
			say "Autostart: OFF"
		elif [ -e /mnt/us/NO_KOREADER ]; then
			say "Autostart: ON, paused by NO_KOREADER"
		elif same "$JOB_SRC" "$JOB_DST"; then
			say "Autostart: ON"
		else
			say "Autostart: ON (outdated, tap Enable)"
		fi
		;;
esac
