#!/bin/bash
# NAS Data Mount Helper
# Mounts the NFS share backing DATA_DIR (Downloads/Movies/TV Shows).
# Run this before "docker compose up -d" if the mount isn't already active
# (e.g. after a reboot, since macOS doesn't auto-remount NFS on its own).
# Usage: sudo bash scripts/mount-nas.sh

set -e

NAS_HOST="10.140.1.152"
NAS_EXPORT="/volume/53607296-e9a5-4d4c-9845-116e75db0392/.srv/.unifi-drive/Media/.data"
MOUNT_POINT="/Users/alexhaar/NAS-Media"

if mount | grep -q "on ${MOUNT_POINT} "; then
    echo "Already mounted at ${MOUNT_POINT}."
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "This needs to run as root (mounting requires sudo)." >&2
    exit 1
fi

mkdir -p "$MOUNT_POINT"
mount -t nfs -o resvport,vers=3 "${NAS_HOST}:${NAS_EXPORT}" "$MOUNT_POINT"
echo "Mounted ${NAS_HOST}:${NAS_EXPORT} at ${MOUNT_POINT}."
