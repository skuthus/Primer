#!/bin/sh
# Primer USB handoff. KOReader has exited so the Kindle can lend itself to the computer (USB
# drive mode on i.MX Kindles, MTP on MediaTek ones). Wait for the connection to start and end,
# then bring KOReader back.
# Runs from /tmp (copied there first): /mnt/us is unusable while the drive is lent out.

LOG=/tmp/voyage-usb-handoff.log
GADGET=/sys/devices/platform/fsl-usb2-udc/gadget   # i.MX Kindles: USB drive mode
UDC=$(ls -d /sys/class/udc/* 2>/dev/null | head -n 1)  # MediaTek Kindles: MTP gadget
KOREADER=/mnt/us/koreader/koreader.sh

log() { echo "$(date +%T) $*" >> "$LOG"; }
# A computer on the cable: the i.MX gadget says so; on MediaTek the charger driver reports a
# computer's port as SDP/CDP (a wall charger is DCP).
computer() {
	if [ -e "$GADGET/connected" ]; then
		[ "$(cat "$GADGET/connected" 2>/dev/null)" = "1" ]
		return
	fi
	for p in /sys/class/power_supply/*; do
		t=$(sed -n 's/.*\[\([A-Za-z_]*\)\].*/\1/p' "$p/usb_type" 2>/dev/null)
		[ -z "$t" ] && t=$(cat "$p/type" 2>/dev/null)
		case "$t" in
			USB_SDP|USB_CDP|SDP|CDP) [ "$(cat "$p/online" 2>/dev/null)" != "0" ] && return 0 ;;
		esac
	done
	return 1
}
# Lent to the computer: on i.MX the gadget's LUN names the partition while it's exported;
# on MediaTek the MTP gadget is "configured" by the host for as long as the cable is in.
lent() {
	if [ -e "$GADGET/gadget-lun0/file" ]; then
		[ -n "$(cat "$GADGET/gadget-lun0/file" 2>/dev/null)" ]
		return
	fi
	[ -n "$UDC" ] && [ "$(cat "$UDC/state" 2>/dev/null)" = "configured" ]
}
reachable() { [ -f "$KOREADER" ] && ! lent; }
state() { echo "computer=$(computer && echo y || echo n) lent=$(lent && echo y || echo n) reachable=$(reachable && echo y || echo n) mounts=$(grep -c ' /mnt/us\| /mnt/base-us' /proc/mounts)"; }

echo "---" >> "$LOG"
log "handoff: start, $(state)"

# Up to 60 s for the Kindle to lend the drive.
i=0
while ! lent && computer && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
if lent; then
	log "drive lent after ${i}s, waiting for eject/unplug"
	while lent; do sleep 1; done
	log "drive returned, $(state)"
else
	log "drive never lent (${i}s), $(state)"
fi

# Wait (up to 2 min) for KOReader's files to be reachable again, then let the Kindle UI settle.
i=0
while ! reachable && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done
sleep 4
log "after settle, $(state)"
cp "$LOG" /mnt/us/voyage-usb-handoff.log 2>/dev/null

if [ -e /mnt/us/NO_KOREADER ]; then
	log "NO_KOREADER present, staying in Kindle UI"
elif reachable; then
	log "relaunching Primer"
	cp "$LOG" /mnt/us/voyage-usb-handoff.log 2>/dev/null
	cd /
	# Same choice as the boot job: on firmware 5.16.3+ (KPM present) restarting the framework on
	# exit leaves the Kindle without its home screen, so run over it like KPM's launcher does.
	if [ -d /var/local/kmc ]; then
		exec /bin/sh "$KOREADER" --asap >/dev/null 2>&1
	fi
	exec /bin/sh "$KOREADER" --framework_stop >/dev/null 2>&1
else
	log "Primer not reachable, giving up"
fi
cp "$LOG" /mnt/us/voyage-usb-handoff.log 2>/dev/null
