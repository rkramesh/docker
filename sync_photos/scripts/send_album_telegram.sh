#!/bin/bash

# Usage: ./send_album_to_telegram.sh "Album Name"

ALBUM_NAME="$1"
DB_PATH="/mnt/iphone/PhotoData/Photos.sqlite"
MEDIA_ROOT="/mnt/iphone"  # root folder where photos are stored
TMP_DIR="/tmp/album_convert"  # temporary folder for converted images

if [ -z "$ALBUM_NAME" ]; then
  echo "Please provide an album name."
  exit 1
fi

if ! command -v sqlite3 &> /dev/null; then
  echo "sqlite3 not found, please install it."
  exit 1
fi

if ! command -v heif-convert &> /dev/null; then
  echo "heif-convert not found, please install it."
  exit 1
fi

# Telegram bot env vars
BOT_TOKEN="${BOT_TOKEN:?Need to set BOT_TOKEN env var}"
CHAT_ID="${CHAT_ID:?Need to set CHAT_ID env var}"

mkdir -p "$TMP_DIR"

send_file_to_telegram() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    echo "File not found: $file_path"
    return
  fi

  local filesize=$(stat -c%s "$file_path")

  if [[ $filesize -gt 52428800 ]]; then
    echo "Sending large video via API: $file_path"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendVideo" \
      --form-string caption="$(basename "$file_path")" \
      -F chat_id="$CHAT_ID" \
      -F video=@"$file_path" >> /var/log/rkeye.log
  else
    echo "Sending video/photo via API: $file_path"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendVideo" \
      --form-string caption="$(basename "$file_path")" \
      -F chat_id="$CHAT_ID" \
      -F video=@"$file_path" >> /var/log/rkeye.log
  fi
}

echo "Fetching files from album: $ALBUM_NAME"

sqlite3 "$DB_PATH" <<EOF | while IFS='|' read -r filepath; do
SELECT ZASSET.ZDIRECTORY || '/' || ZASSET.ZFILENAME
FROM ZASSET
JOIN Z_30ASSETS ON ZASSET.Z_PK = Z_30ASSETS.Z_3ASSETS
JOIN ZGENERICALBUM ON ZGENERICALBUM.Z_PK = Z_30ASSETS.Z_30ALBUMS
WHERE ZGENERICALBUM.ZTITLE = '$ALBUM_NAME';
EOF

  full_path="$MEDIA_ROOT/$filepath"

  # If HEIC, convert to JPG before sending
  if [[ "$full_path" == *.HEIC || "$full_path" == *.heic ]]; then
    jpg_path="$TMP_DIR/$(basename "${full_path%.*}").jpg"
    echo "Converting $full_path to $jpg_path"
    heif-convert "$full_path" "$jpg_path"
    send_file_to_telegram "$jpg_path"
    # Optionally remove the converted jpg after sending:
    # rm "$jpg_path"
  else
    send_file_to_telegram "$full_path"
  fi
done

