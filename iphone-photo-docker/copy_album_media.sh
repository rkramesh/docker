#!/bin/bash

# Usage: ./copy_album_media.sh "Album Name" /destination/folder

ALBUM_NAME="$1"
DEST_FOLDER="$2"
DB_PATH="/mnt/iphone/PhotoData/Photos.sqlite"
MOUNT_PATH="/mnt/iphone"

if [[ -z "$ALBUM_NAME" || -z "$DEST_FOLDER" ]]; then
  echo "Usage: $0 \"Album Name\" /path/to/destination/folder"
  exit 1
fi

mkdir -p "$DEST_FOLDER"

# Query SQLite DB for file paths
echo "Fetching files from album: $ALBUM_NAME"

sqlite3 "$DB_PATH" <<EOF | while IFS='|' read -r directory filename; do
SELECT
  ZASSET.ZDIRECTORY,
  ZASSET.ZFILENAME
FROM
  ZASSET
JOIN
  Z_30ASSETS ON ZASSET.Z_PK = Z_30ASSETS.Z_3ASSETS
JOIN
  ZGENERICALBUM ON ZGENERICALBUM.Z_PK = Z_30ASSETS.Z_30ALBUMS
WHERE
  ZGENERICALBUM.ZTITLE = '$ALBUM_NAME';
EOF

  # Construct source and destination paths
  SRC="$MOUNT_PATH/$directory/$filename"
  DEST="$DEST_FOLDER/$filename"

  if [[ -f "$SRC" ]]; then
    echo "Copying $SRC to $DEST"
    cp "$SRC" "$DEST"
  else
    echo "File not found: $SRC"
  fi
done

