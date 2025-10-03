#!/bin/bash

# Usage: ./copy_album_media.sh "Album Name" /destination/folder

ALBUM_NAME="$1"
DEST_ROOT="$2"
DB_PATH="/mnt/iphone/PhotoData/Photos.sqlite"
MOUNT_PATH="/mnt/iphone"
LOG_FILE="/tmp/copy_errors.log"

# Check arguments
if [[ -z "$ALBUM_NAME" || -z "$DEST_ROOT" ]]; then
  echo "Usage: $0 \"Album Name\" /path/to/destination/folder"
  exit 1
fi

DEST_FOLDER="$DEST_ROOT/$ALBUM_NAME"
mkdir -p "$DEST_FOLDER"
> "$LOG_FILE"  # clear previous log

echo "Copying album '$ALBUM_NAME' to '$DEST_FOLDER' ..."

# Query SQLite DB and process files
sqlite3 -separator '|' "$DB_PATH" "
SELECT ZASSET.ZDIRECTORY, ZASSET.ZFILENAME
FROM ZASSET
JOIN Z_30ASSETS ON ZASSET.Z_PK = Z_30ASSETS.Z_3ASSETS
JOIN ZGENERICALBUM ON ZGENERICALBUM.Z_PK = Z_30ASSETS.Z_30ALBUMS
WHERE LOWER(TRIM(ZGENERICALBUM.ZTITLE)) LIKE '%' || LOWER(TRIM('$ALBUM_NAME')) || '%';
" | while IFS='|' read -r directory filename; do

    SRC="$MOUNT_PATH/$directory/$filename"
    DEST="$DEST_FOLDER/$filename"

    mkdir -p "$(dirname "$DEST")"

    if [[ ! -f "$SRC" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$ALBUM_NAME] File not found: $SRC" | tee -a "$LOG_FILE"
        continue
    fi

    if cp "$SRC" "$DEST"; then
        echo "Copied: $filename"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$ALBUM_NAME] Failed to copy: $SRC" | tee -a "$LOG_FILE"
    fi

done

echo "Finished copying album '$ALBUM_NAME'."

# Show summary if errors exist
if [[ -s "$LOG_FILE" ]]; then
  echo "Some files failed to copy. See log: $LOG_FILE"
else
  rm -f "$LOG_FILE"
fi

