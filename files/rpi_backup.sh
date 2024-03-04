#!/bin/bash
source /root/.bashrc 

# Directory to backup
backup_dir="/var/lib/rpimonitor"

# Directory to store backups
backup_dest="/media"

# Telegram Bot Token
telegram_token="$BOT_TOKEN"

# Telegram Chat ID
chat_id="$CHAT_ID"

# Create a timestamp for the backup file
timestamp=$(date +"%Y%m%d_%H%M%S")

# Compressed backup filename
backup_filename="rpimonitor_backup_$timestamp.tar.gz"

# Backup the directory
tar -zcvf "$backup_dest/$backup_filename" "$backup_dir"

# Send the backup file to Telegram
curl -F "chat_id=$chat_id" -F document=@"$backup_dest/$backup_filename" https://api.telegram.org/bot$telegram_token/sendDocument

