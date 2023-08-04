
#!/bin/sh
curl --form-string caption=@"`(date=$(date +%Y-%m-%d);input="/data/output/Camera1/$date";ls "$input"/*.mp4 -t | head -n1)`" -F video=@"`(date=$(date +%Y-%m-%d);input="/data/output/Camera1/$date";ls "$input"/*.mp4 -t | head -n1)`" https://api.telegram.org/bot${BOT_TOKEN}/sendVideo?chat_id=${CHAT_ID}
