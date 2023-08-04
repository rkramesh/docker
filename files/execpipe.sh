#!/bin/bash
. $HOME/.bashrc
URL="https://api.telegram.org/bot$BOT_TOKEN/sendMessage"
curl -s -X POST $URL -d chat_id=$CHAT_ID -d text="$(hostname) server successfully started at $(date +"%d.%m.%Y %H:%M:%S")"
while true; do eval "$(cat /media/rkpipe)" &> /media/pipe-output.txt;done
