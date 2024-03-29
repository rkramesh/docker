#!/bin/bash
API="http://rkmotioneye:8085"
TAPI="https://api.telegram.org"
URL="$API/bot$BOT_TOKEN/sendMessage"
VURL="$API/bot$BOT_TOKEN/sendVideo"

#curl -s -X POST $URL -d chat_id=$CHAT_ID -d text="$1 server successfully started at $(date +"%d.%m.%Y %H:%M:%S")"
#curl -s _X POST $VURL --form-string caption="@$1" -F chat_id=${CHAT_ID} -F video="@$1" >> /var/log/rkeye.log

#if [[ -f "$file_path" && $(stat -c%s "$file_path") -gt 52428800 ]]
if [[ -f "$1" && $(stat -c%s "$1") -gt 52428800 ]]
then
  curl -s _X POST "$API/bot$BOT_TOKEN/sendVideo"  --form-string caption="$1" -F chat_id=${CHAT_ID} -F video="@$1" >> /var/log/rkeye.log
  curl -s -X POST "$API/bot$BOT_TOKEN/sendMessage" -d chat_id=$CHAT_ID -d text="$API"

else
  curl -s _X POST "$TAPI/bot$BOT_TOKEN/sendVideo" --form-string caption=${1##*/Camera1/}_T -F chat_id=${CHAT_ID} -F video="@$1" >> /var/log/rkeye.log
  curl -s -X POST "$TAPI/bot$BOT_TOKEN/sendMessage" -d chat_id=$CHAT_ID -d text="$TAPI"
fi


rm -rf $1
