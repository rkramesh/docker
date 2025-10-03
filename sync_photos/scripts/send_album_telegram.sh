#!/bin/bash
# send_album_to_telegram.sh
# Usage: ./send_album_to_telegram.sh "Album Name"

set -euo pipefail

ALBUM_NAME="${1:-}"
DB_PATH="/mnt/iphone/PhotoData/Photos.sqlite"
MEDIA_ROOT="/mnt/iphone"
TMP_DIR="/tmp/album_convert"
FILESIZE_LIMIT=52428800  # 50MB
API="http://rkmotioneye:8085"
TAPI="https://api.telegram.org"
LOG_FILE="/tmp/rkeye.log"

[[ -z "$ALBUM_NAME" ]] && { echo "Please provide an album name."; exit 1; }

# Check dependencies
for cmd in sqlite3 convert curl stat; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd not found, install it."; exit 1; }
done

BOT_TOKEN="${BOT_TOKEN:?Set BOT_TOKEN}"
CHAT_ID="${CHAT_ID:?Set CHAT_ID}"

mkdir -p "$TMP_DIR"

# log to both stdout and file
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

send_media() {
  local file="$1"
  local size
  size=$(stat -c%s "$file")

  case "$file" in
    *.mp4|*.MOV|*.mov)
      if (( size > FILESIZE_LIMIT )); then
        log "Large video (>50MB), sending via local API: $file"
        curl -s -X POST "$API/bot$BOT_TOKEN/sendVideo" \
          -F chat_id="$CHAT_ID" \
          -F video=@"$file" \
          -F caption="$(basename "$file")" >> "$LOG_FILE"
      else
        log "Sending video via Telegram API: $file"
        curl -s -X POST "$TAPI/bot$BOT_TOKEN/sendVideo" \
          -F chat_id="$CHAT_ID" \
          -F video=@"$file" \
          -F caption="$(basename "$file")" >> "$LOG_FILE"
      fi
      ;;
    *.HEIC|*.heic)
      jpg_path="$TMP_DIR/$(basename "${file%.*}").jpg"
      log "Converting HEIC -> JPG (resized) with auto-rotation: $file -> $jpg_path"
      convert "$file" -auto-orient -resize 2048x2048\> "$jpg_path"
      send_media "$jpg_path"
      rm -f "$jpg_path"
      ;;
    *.jpg|*.jpeg|*.png)
      log "Sending photo: $file"
      curl -s -X POST "$TAPI/bot$BOT_TOKEN/sendPhoto" \
        -F chat_id="$CHAT_ID" \
        -F photo=@"$file" \
        -F caption="$(basename "$file")" >> "$LOG_FILE"
      ;;
    *)
      log "Unsupported file type: $file"
      ;;
  esac
}

log "Fetching files from album: $ALBUM_NAME"

sqlite3 -separator '|' "$DB_PATH" "
  SELECT ZASSET.ZDIRECTORY || '/' || ZASSET.ZFILENAME
  FROM ZASSET
  JOIN Z_30ASSETS ON ZASSET.Z_PK = Z_30ASSETS.Z_3ASSETS
  JOIN ZGENERICALBUM ON ZGENERICALBUM.Z_PK = Z_30ASSETS.Z_30ALBUMS
  WHERE ZGENERICALBUM.ZTITLE = '$ALBUM_NAME';
" | while IFS='|' read -r filepath; do
  full_path="$MEDIA_ROOT/$filepath"
  [[ -f "$full_path" ]] || { log "File not found: $full_path"; continue; }
  send_media "$full_path"
done

