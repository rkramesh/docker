#!/bin/bash
echo $1
API="http://rkmotioneye:8085"
URL="$API/bot$BOT_TOKEN/sendMessage"
VURL="$API/bot$BOT_TOKEN/sendVideo"

curl -s -X POST $URL -d chat_id=$CHAT_ID -d text="test message" $(date +"%d.%m.%Y %H:%M:%S")
# curl -s _X POST $VURL --form-string caption="@$1" -F chat_id=${CHAT_ID} -F video="@$1" > /var/log/rkeye.log
# curl --form-string caption=@"`(date=$(date +%Y-%m-%d);input="/data/output/Camera1/$date";ls "$input"/*.mp4 -t | head -n1)`" -F video=@"`(date=$(date +%Y-%m-%d);input="/data/output/Camera1/$date";ls "$input"/*.mp4 -t | head -n1)`" https://api.telegram.org/bot${BOT_TOKEN}/sendVideo?chat_id=${CHAT_ID}
