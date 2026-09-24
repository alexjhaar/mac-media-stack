#!/bin/bash
# NAS Data Mount Helper
# Mounts the NFS share backing DATA_DIR (Downloads/Movies/TV Shows).
# Run manually before "docker compose up -d" if the mount isn't already
# active, or installed as a LaunchDaemon (see scripts/com.macmediastack.mount-nas.plist)
# to run automatically at boot, since macOS doesn't auto-remount NFS on its own.
# Usage: sudo bash scripts/mount-nas.sh

set -e

NAS_HOST="10.140.1.152"
NAS_EXPORT="/volume/53607296-e9a5-4d4c-9845-116e75db0392/.srv/.unifi-drive/Media/.data"
MOUNT_POINT="/Users/alexhaar/NAS-Media"
MAX_ATTEMPTS=30
RETRY_DELAY=10

if mount | grep -q "on ${MOUNT_POINT} "; then
    echo "Already mounted at ${MOUNT_POINT}."
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "This needs to run as root (mounting requires sudo)." >&2
    exit 1
fi

mkdir -p "$MOUNT_POINT"

# At boot, launchd can fire this before the network/NAS is actually reachable,
# so retry for a few minutes rather than failing once and staying unmounted
# for the rest of the session.
attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
    if mount -t nfs -o resvport,vers=3 "${NAS_HOST}:${NAS_EXPORT}" "$MOUNT_POINT" 2>/dev/null; then
        echo "Mounted ${NAS_HOST}:${NAS_EXPORT} at ${MOUNT_POINT} (attempt $attempt)."
        exit 0
    fi
    echo "Mount attempt $attempt/$MAX_ATTEMPTS failed, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    ((attempt++))
done

echo "Failed to mount ${NAS_HOST}:${NAS_EXPORT} after $MAX_ATTEMPTS attempts." >&2
exit 1
