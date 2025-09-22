#!/bin/bash
set -e

echo "[*] Waiting for iPhone to be connected..."

while ! ideviceinfo &>/dev/null; do
  sleep 2
done

echo "[*] iPhone detected."

idevicepair pair || echo "[*] Already paired."

mkdir -p /mnt/iphone

ifuse /mnt/iphone

echo "[*] Mounted iPhone to /mnt/iphone"

# Keep container alive, no copying here
tail -f /dev/null

