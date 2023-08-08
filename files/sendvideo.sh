#!/bin/bash
echo $1
API="http://rkmotioneye:8085"
URL="$API/bot$BOT_TOKEN/sendMessage"
VURL="$API/bot$BOT_TOKEN/sendVideo"

#curl -s -X POST $URL -d chat_id=$CHAT_ID -d text="$1 server successfully started at $(date +"%d.%m.%Y %H:%M:%S")"
curl -s _X POST $VURL --form-string caption="@$1" -F chat_id=${CHAT_ID} -F video="@$1" >> /var/log/rkeye.log

