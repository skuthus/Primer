#!/bin/sh
# Primer USB handoff. KOReader has exited so the Kindle can lend its drive to the computer.
# Wait for USB drive mode to start and finish, then bring KOReader back.
# Runs from /tmp (copied there first): /mnt/us is unusable while the drive is lent out.

LOG=/tmp/voyage-usb-handoff.log
GADGET=/sys/devices/platform/fsl-usb2-udc/gadget
KOREADER=/mnt/us/koreader/koreader.sh

log() { echo "$(date +%T) $*" >> "$LOG"; }
computer() { [ "$(cat "$GADGET/connected" 2>/dev/null)" = "1" ]; }
# The gadget's LUN names the partition while it's lent to the computer, and is empty otherwise.
lent() { [ -n "$(cat "$GADGET/gadget-lun0/file" 2>/dev/null)" ]; }
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
	exec /bin/sh "$KOREADER" --framework_stop >/dev/null 2>&1
else
	log "Primer not reachable, giving up"
fi
cp "$LOG" /mnt/us/voyage-usb-handoff.log 2>/dev/null
