#!/bin/bash
set -e

MOUNT_POINT="/mnt/iphone"
mkdir -p "$MOUNT_POINT"

echo "[*] Starting iPhone monitor in background..."

# Background loop to detect and mount iPhone
(
  while true; do
    if ideviceinfo &>/dev/null; then
        echo "[*] iPhone detected."

        # Pair the device if needed
        idevicepair pair 2>/dev/null || echo "[*] Already paired."

        # Mount only if not already mounted
        if ! mount | grep -q "$MOUNT_POINT"; then
            ifuse "$MOUNT_POINT"
            echo "[*] Mounted iPhone to $MOUNT_POINT"
        fi
    else
        echo "[*] No iPhone detected. Waiting..."
    fi
    sleep 5
  done
) &

# Keep container alive
tail -f /dev/null

