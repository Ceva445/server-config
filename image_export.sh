#!/bin/bash
# image_export.sh <device>        e.g.  image_export.sh sdb1
#
# Triggered by udev when a USB partition is plugged in (via image-export@.service).
# If the drive has a marker file `image_export.yml` at its root, ALL project
# images are copied onto it. Otherwise the script does nothing.
#
# NEVER deletes anything: rsync runs WITHOUT --delete, so existing files on the
# drive stay, and only missing/changed files are added (incremental). The server
# media is only read, never modified.
set -u

DEV="/dev/$1"
MARKER="image_export.yml"
MOUNT="/mnt/image-export"
APPS="/home/piatek/Desktop/apps"
PROJECTS="delivery_plus recive-stock"

log() { logger -t image-export "$*"; }

# 1) Never touch the dedicated backup stick
LABEL="$(blkid -o value -s LABEL "$DEV" 2>/dev/null)"
[ "$LABEL" = "bkp_pendr" ] && exit 0

# 2) Wait for the device node to appear (udev fires early)
for _ in $(seq 1 10); do [ -b "$DEV" ] && break; sleep 1; done
[ -b "$DEV" ] || { log "no block device $DEV"; exit 0; }

# 3) Use an existing mount if the drive was auto-mounted, else mount ourselves
OWN_MOUNT=0
TARGET="$(findmnt -n -o TARGET --source "$DEV" 2>/dev/null | head -1)"
if [ -z "$TARGET" ]; then
    mkdir -p "$MOUNT"
    for _ in $(seq 1 5); do
        mount "$DEV" "$MOUNT" 2>/dev/null && { TARGET="$MOUNT"; OWN_MOUNT=1; break; }
        sleep 1
    done
fi
[ -n "$TARGET" ] || { log "cannot mount $DEV"; exit 0; }

cleanup() { [ "$OWN_MOUNT" = 1 ] && umount "$MOUNT" 2>/dev/null; }

# 4) Only act if the marker file is present (opt-in)
if [ ! -f "$TARGET/$MARKER" ]; then
    cleanup
    exit 0
fi

DEST="$TARGET/image_export"
LOGFILE="$TARGET/image_export.log"
mkdir -p "$DEST"

log "export drive detected ($DEV) — copying images"
echo "$(date '+%F %T') START image export from $(hostname) -> $DEV" >> "$LOGFILE"

for p in $PROJECTS; do
    SRC="$APPS/$p/media"
    [ -d "$SRC" ] || continue
    log "copying $p ..."
    echo "$(date '+%F %T') copying $p ..." >> "$LOGFILE"
    # archive mode, NO --delete -> nothing on the drive is ever removed
    rsync -a --info=stats2 "$SRC/" "$DEST/$p/" >> "$LOGFILE" 2>&1
    echo "$(date '+%F %T') $p done" >> "$LOGFILE"
done

sync
echo "$(date '+%F %T') FINISHED — bezpiecznie wyjmij pendrive" >> "$LOGFILE"
log "image export FINISHED to $DEV"
cleanup
exit 0
