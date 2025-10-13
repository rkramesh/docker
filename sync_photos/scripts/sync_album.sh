#!/bin/bash

# === Configuration ===
#
# Set these via environment variables (in your shell, .env, or docker-compose).
# Key options:
# - BOT_TOKEN, CHAT_ID (required): Telegram bot token and destination chat id.
# - API_SERVER: Local Bot API server base URL; used automatically for large videos (> MAX_TELEGRAM_SIZE)
# - TELEGRAM_API: Cloud Bot API base URL (defaults to official).
# - LOG_DIR: Directory for logs (default /tmp). Mount this in Docker to view logs on host.
#
# Batching and sizes:
# - BATCH_SIZE: Photos per media group (Telegram limit is 10).
# - MAX_TELEGRAM_SIZE: Per-video threshold in bytes (default 50MB). Videos above this go via API_SERVER.
# - VIDEO_GROUPING: 1 to enable small-video batching, 0 to send videos individually (default 0).
# - VIDEO_GROUP_MAX_ITEMS: Max videos per video group (Telegram limit is 10).
# - VIDEO_GROUP_MAX_TOTAL: Max combined size (bytes) of a small-video group. Tune to avoid 413.
# - VIDEO_GROUP_VIA_API: 1 to send video groups via API_SERVER (safer for larger totals), 0 for Telegram.
#
# Reliability and mode:
# - RETRY_FAILED: 1 to process only files listed in failed_<ALBUM>.txt; successes are removed from that list.
# - INFO_BOT_TOKEN: Optional token for sending minimal start/batch/final notifications to the same CHAT_ID.
API_SERVER="${API_SERVER:-http://rkmotioneye:8085}"
TELEGRAM_API="${TELEGRAM_API:-https://api.telegram.org}"
BATCH_SIZE=${BATCH_SIZE:-10}  # Telegram media group limit is 10
MAX_TELEGRAM_SIZE=${MAX_TELEGRAM_SIZE:-$((50*1024*1024))} # 50 MB
INFO_BOT_TOKEN="${INFO_BOT_TOKEN:-}"
RETRY_FAILED=${RETRY_FAILED:-0}

# Helper: escape regex metacharacters for grep -E (portable)
regex_escape() {
    local s="$1"
    # Escape: ] [ \ . ^ $ * + ? ( ) { } | < > -
    printf '%s' "$s" | sed -e 's/[][\\.^$*+?(){}|<>-]/\\&/g'
}

# Helper: normalize path to collapse multiple slashes
norm_path() {
    printf '%s' "$1" | sed 's#\/+#/#g'
}

# Helper: add to SENT_TRACK once (dedup) with normalization and HEIC mapping
add_to_sent() {
    local p="$1"
    local src
    src="$(resolve_original_path "$p")"
    src="$(norm_path "$src")"
    # Dedup exact-line
    if ! grep -qxF -- "$src" "$SENT_TRACK" 2>/dev/null; then
        echo "$src" >> "$SENT_TRACK"
    fi
    remove_from_failed "$src"
}

# Resolve original source path for a converted image (e.g., TMP_DIR/*.jpg -> ALBUM_DIR/*.HEIC if exists)
resolve_original_path() {
    local p="$1"
    local ext="${p##*.}"; ext="${ext,,}"
    # If this is a converted JPG in TMP_DIR, map back to original HEIC if present
    if [[ "$p" == "$TMP_DIR"/* && "$ext" == "jpg" ]]; then
        local base_noext
        base_noext="$(basename "${p%.*}")"
        if [[ -f "$ALBUM_DIR/${base_noext}.HEIC" ]]; then
            echo "$ALBUM_DIR/${base_noext}.HEIC"
            return 0
        fi
        if [[ -f "$ALBUM_DIR/${base_noext}.heic" ]]; then
            echo "$ALBUM_DIR/${base_noext}.heic"
            return 0
        fi
    fi
    # Default: return the same path
    echo "$p"
}

# Check if file has already been sent
is_already_sent() {
    local f="$1"
    f="$(norm_path "$f")"
    [[ -f "$SENT_TRACK" ]] || return 1
    # Exact path match
    if grep -qxF -- "$f" "$SENT_TRACK" 2>/dev/null; then
        return 0
    fi
    # If HEIC, also match legacy TMP jpg entries by basename
    local bn ext
    bn="$(basename "$f")"
    ext="${bn##*.}"; ext="${ext,,}"
    local base_noext="${bn%.*}"
    if [[ "$ext" == "heic" ]]; then
        # Basename-only matching, ignore path prefixes and double slashes
        local esc_base
        esc_base="$(regex_escape "$base_noext")"
        if grep -qE "(^|/)$esc_base\.jpg$"  "$SENT_TRACK" 2>/dev/null; then return 0; fi
        if grep -qE "(^|/)$esc_base\.heic$" "$SENT_TRACK" 2>/dev/null; then return 0; fi
        if grep -qE "(^|/)$esc_base\.HEIC$" "$SENT_TRACK" 2>/dev/null; then return 0; fi
    fi
    return 1
}

VIDEO_GROUPING=${VIDEO_GROUPING:-0}
VIDEO_GROUP_MAX_TOTAL=${VIDEO_GROUP_MAX_TOTAL:-$((45*1024*1024))}
VIDEO_GROUP_MAX_ITEMS=${VIDEO_GROUP_MAX_ITEMS:-10}
VIDEO_GROUP_VIA_API=${VIDEO_GROUP_VIA_API:-0}
LOG_DIR="${LOG_DIR:-/tmp}"

# Ensure required env variables
: "${BOT_TOKEN:?Need to set BOT_TOKEN env variable}"
: "${CHAT_ID:?Need to set CHAT_ID env variable}"

# === Album setup ===
ALBUM_DIR="$1"
# Normalize: remove any trailing slashes so tracker paths are consistent across runs
ALBUM_DIR="${ALBUM_DIR%/}"
ALBUM_NAME="$(basename "$ALBUM_DIR")"
TMP_DIR="/tmp/album_convert_$ALBUM_NAME"
PERSISTENT_DIR="/tmp/album_state"  # Persistent across runs
LOG_FILE="$LOG_DIR/sync_album_${ALBUM_NAME}.log"
ERR_LOG="$LOG_DIR/sync_album_${ALBUM_NAME}.error.log"
SENT_TRACK="$PERSISTENT_DIR/sent_${ALBUM_NAME}.txt"
FAILED_TRACK="$PERSISTENT_DIR/failed_${ALBUM_NAME}.txt"
SKIP_TRACK="$PERSISTENT_DIR/skip_${ALBUM_NAME}.txt"

mkdir -p "$TMP_DIR" "$PERSISTENT_DIR" "$LOG_DIR"
touch "$LOG_FILE" "$ERR_LOG" "$SENT_TRACK" "$FAILED_TRACK" "$SKIP_TRACK"

# Helper: file size in bytes (prefer stat, fallback to wc)
get_file_size() {
    local f="$1"
    # Try GNU/coreutils stat
    if stat -c%s "$f" >/dev/null 2>&1; then
        stat -c%s "$f"
        return
    fi
    # Try BSD/mac-like (not expected inside RPi Docker, but harmless)
    if stat -f %z "$f" >/dev/null 2>&1; then
        stat -f %z "$f"
        return
    fi
    # Fallback
    wc -c < "$f" 2>/dev/null | tr -d ' '
}

# Minimal notifier to the main Telegram chat (CHAT_ID). Uses INFO_BOT_TOKEN if provided, else BOT_TOKEN.
tg_notify() {
    local text="$1"
    # Use INFO_BOT_TOKEN if provided; otherwise, default to main BOT_TOKEN
    local token="${INFO_BOT_TOKEN:-$BOT_TOKEN}"
    curl -s -o /dev/null -X POST "$TELEGRAM_API/bot$token/sendMessage" \
         -d chat_id="$CHAT_ID" \
         --data-urlencode text="$text" \
         -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

# === Helpers to update trackers ===
remove_from_failed() {
    local f="$1"
    [[ ! -f "$FAILED_TRACK" ]] && return 0
    grep -vxF -- "$f" "$FAILED_TRACK" > "$FAILED_TRACK.tmp" 2>/dev/null || true
    mv -f "$FAILED_TRACK.tmp" "$FAILED_TRACK" 2>/dev/null || true
}

# Resume info
sent_count=$(wc -l < "$SENT_TRACK" 2>/dev/null || echo "0")
failed_count=$(wc -l < "$FAILED_TRACK" 2>/dev/null || echo "0")
skipped_count=$(wc -l < "$SKIP_TRACK" 2>/dev/null || echo "0")

if (( sent_count > 0 || failed_count > 0 || skipped_count > 0 )); then
    echo "$(date) [RESUME] 🔄 RESUMING: $sent_count sent, $failed_count failed, $skipped_count skipped" | tee -a "$LOG_FILE"
fi

echo "$(date) [START] 🚀 Starting offline sync for album: $ALBUM_DIR" | tee -a "$LOG_FILE"

# Build file list and totals
file_counter=0
media_batch=()  # Changed to handle both photos and videos
# Human-friendly batch sequencing per album
BATCH_SEQ=0
RUN_ALREADY=0  # Count of files detected as already sent during this run

FILE_LIST=()
if [[ "$RETRY_FAILED" == "1" ]]; then
    # Retry-only mode: process only files previously failed
    if [[ -f "$FAILED_TRACK" ]]; then
        mapfile -t FILE_LIST < "$FAILED_TRACK"
    fi
    total_files=${#FILE_LIST[@]}
else
    # Normal mode: count supported files at top level of album dir (consistent with iteration below)
    total_files=$(find "$ALBUM_DIR" -maxdepth 1 -type f \
        \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mov' -o -iname '*.mp4' \) | wc -l)
fi

# Notify start (minimal) to LOG_CHAT_ID if set
tg_notify "START 📁 album=$ALBUM_NAME total=$total_files resume: sent=$sent_count failed=$failed_count skipped=$skipped_count"

# === Smart media group sender (photos + videos) ===
send_media_batch_bg() {
    local batch_files=("$@")
    local batch_id=$(date +%s%N | cut -b1-13)
    BATCH_SEQ=$((BATCH_SEQ+1))
    local batch_name="${ALBUM_NAME}-b${BATCH_SEQ}"
    local photo_items=()
    local video_items=()
    local item ext
    for item in "${batch_files[@]}"; do
        ext="${item##*.}"; ext="${ext,,}"
        case "$ext" in
            jpg|jpeg|png|heic) photo_items+=("$item");;
            mp4|mov) video_items+=("$item");;
        esac
    done

    local photo_count=${#photo_items[@]}
    local video_count=${#video_items[@]}

    echo "$(date) [BATCH] 📤 Queued batch $batch_name (id=$batch_id) photos=$photo_count videos=$video_count total=${#batch_files[@]}" | tee -a "$LOG_FILE"

    # First: send photos as a media group (2-10). If 1 photo, send singly.
    if (( photo_count > 0 )); then
        if (( photo_count == 1 )); then
            send_single_media "${photo_items[0]}"
        else
            local media_json="["
            local file_args=()
            local first=true
            local ph
            for ph in "${photo_items[@]}"; do
                local base
                base=$(basename "$ph")
                $first && first=false || media_json+="," 
                media_json+="{\"type\":\"photo\",\"media\":\"attach://$base\"}"
                file_args+=("-F" "$base=@$ph")
            done
            media_json+="]"

            (
                echo "$(date) [BATCH] 📊 Batch $batch_name (id=$batch_id): $photo_count photos (videos will be sent individually)" | tee -a "$LOG_FILE"

                local retries=3
                while [ $retries -gt 0 ]; do
                    resp=$(curl -s -w "%{http_code}" -o "$TMP_DIR/resp_$batch_id.json" \
                        --connect-timeout 10 --max-time 60 --retry 2 \
                        -X POST "$TELEGRAM_API/bot$BOT_TOKEN/sendMediaGroup" \
                        -F chat_id="$CHAT_ID" \
                        -F media="$media_json" \
                        "${file_args[@]}" 2>/dev/null || echo "000")

                    if [[ "$resp" == "200" ]] && grep -q '"ok":true' "$TMP_DIR/resp_$batch_id.json" 2>/dev/null; then
                        echo "$(date) [SUCCESS] ✅ Photo group $batch_name sent (id=$batch_id)" | tee -a "$LOG_FILE"
                        tg_notify "BATCH_OK ✅ album=$ALBUM_NAME batch=$batch_name items=$photo_count photos=$photo_count videos=0"
                        local img
                        for img in "${photo_items[@]}"; do
                            add_to_sent "$img"
                            [[ "$img" == "$TMP_DIR"* ]] && rm -f "$img" 2>/dev/null || true
                        done
                        rm -f "$TMP_DIR/resp_$batch_id.json" 2>/dev/null || true
                        break
                    elif [[ "$resp" == "000" ]]; then
                        echo "$(date) [ERROR] ❌ Photo group $batch_name connection failed (id=$batch_id)" | tee -a "$ERR_LOG"
                        tg_notify "BATCH_FAIL ❌ album=$ALBUM_NAME batch=$batch_name http=000 connection_error=true items=$photo_count"
                    else
                        echo "$(date) [ERROR] ❌ Photo group $batch_name failed (HTTP $resp) (id=$batch_id)" | tee -a "$ERR_LOG"
                        tg_notify "BATCH_FAIL ❌ album=$ALBUM_NAME batch=$batch_name http=$resp items=$photo_count"
                        echo "$(date) [ERROR] 🔍 Failed photos in group $batch_id:" | tee -a "$ERR_LOG"
                        for img in "${photo_items[@]}"; do echo "  - $(basename "$img")" | tee -a "$ERR_LOG"; done
                        cat "$TMP_DIR/resp_$batch_id.json" >> "$ERR_LOG" 2>/dev/null || true
                    fi

                    ((retries--))
                    if [ $retries -gt 0 ]; then
                        echo "$(date) [RETRY] 🔄 Retrying photo group $batch_name (id=$batch_id)..." | tee -a "$LOG_FILE"
                        sleep 3
                    fi
                done
                sleep 1
            ) &
        fi
    fi

    # Then: send videos.
    if (( video_count > 0 )); then
        if [[ "$VIDEO_GROUPING" == "1" ]]; then
            # Build a safe video group subject to count and total-size caps, only direct-to-Telegram sized videos
            local group_videos=()
            local group_total=0
            local v size
            for v in "${video_items[@]}"; do
                size=$(stat -c%s "$v" 2>/dev/null || echo 0)
                # Skip videos that must go via API due to size
                if (( size > MAX_TELEGRAM_SIZE )); then
                    continue
                fi
                # Respect item and total-size caps
                if (( ${#group_videos[@]} < VIDEO_GROUP_MAX_ITEMS )) && (( group_total + size <= VIDEO_GROUP_MAX_TOTAL )); then
                    group_videos+=("$v")
                    group_total=$((group_total + size))
                fi
            done

            # Send grouped small videos if we have at least 2
            if (( ${#group_videos[@]} >= 2 )); then
                local vg_batch_id=$(date +%s%N | cut -b1-13)
                local vg_name="${batch_name}-videos"
                local media_json="["
                local file_args=()
                local first=true
                local vv base
                for vv in "${group_videos[@]}"; do
                    base=$(basename "$vv")
                    $first && first=false || media_json+="," 
                    media_json+="{\"type\":\"video\",\"media\":\"attach://$base\"}"
                    file_args+=("-F" "$base=@$vv")
                done
                media_json+="]"

                (
                    echo "$(date) [BATCH] 📊 Video group $vg_name (id=$vg_batch_id): ${#group_videos[@]} small videos (≤ $(($MAX_TELEGRAM_SIZE/1024/1024))MB each, total=$(($group_total/1024/1024))MB)" | tee -a "$LOG_FILE"
                    local retries=3
                    while [ $retries -gt 0 ]; do
                        # Select endpoint: Telegram (default) or API server if VIDEO_GROUP_VIA_API=1
                        local vg_base="$TELEGRAM_API"
                        if [[ "$VIDEO_GROUP_VIA_API" == "1" ]]; then vg_base="$API_SERVER"; fi
                        resp=$(curl -s -w "%{http_code}" -o "$TMP_DIR/resp_$vg_batch_id.json" \
                            --connect-timeout 15 --max-time 120 --retry 2 \
                            -X POST "$vg_base/bot$BOT_TOKEN/sendMediaGroup" \
                            -F chat_id="$CHAT_ID" \
                            -F media="$media_json" \
                            "${file_args[@]}" 2>/dev/null || echo "000")

                        if [[ "$resp" == "200" ]] && grep -q '"ok":true' "$TMP_DIR/resp_$vg_batch_id.json" 2>/dev/null; then
                            echo "$(date) [SUCCESS] ✅ Video group $vg_name sent (id=$vg_batch_id)" | tee -a "$LOG_FILE"
                            tg_notify "BATCH_OK ✅ album=$ALBUM_NAME batch=$vg_name items=${#group_videos[@]} photos=0 videos=${#group_videos[@]}"
                            for vv in "${group_videos[@]}"; do
                                add_to_sent "$vv"
                            done
                            rm -f "$TMP_DIR/resp_$vg_batch_id.json" 2>/dev/null || true
                            break
                        elif [[ "$resp" == "000" ]]; then
                            echo "$(date) [ERROR] ❌ Video group $vg_name connection failed (id=$vg_batch_id)" | tee -a "$ERR_LOG"
                            tg_notify "BATCH_FAIL ❌ album=$ALBUM_NAME batch=$vg_name http=000 connection_error=true items=${#group_videos[@]}"
                        else
                            echo "$(date) [ERROR] ❌ Video group $vg_name failed (HTTP $resp) (id=$vg_batch_id)" | tee -a "$ERR_LOG"
                            tg_notify "BATCH_FAIL ❌ album=$ALBUM_NAME batch=$vg_name http=$resp items=${#group_videos[@]}"
                            echo "$(date) [ERROR] 🔍 Failed videos in group $vg_batch_id:" | tee -a "$ERR_LOG"
                            for vv in "${group_videos[@]}"; do echo "  - $(basename "$vv")" | tee -a "$ERR_LOG"; done
                            cat "$TMP_DIR/resp_$vg_batch_id.json" >> "$ERR_LOG" 2>/dev/null || true
                        fi

                        ((retries--))
                        if [ $retries -gt 0 ]; then
                            echo "$(date) [RETRY] 🔄 Retrying video group $vg_name (id=$vg_batch_id)..." | tee -a "$LOG_FILE"
                            sleep 3
                        fi
                    done
                    sleep 1
                ) &

                # Remove grouped videos from the to-send list; send remaining individually below
                local remaining_videos=()
                local in_group
                for v in "${video_items[@]}"; do
                    in_group=0
                    for vv in "${group_videos[@]}"; do [[ "$v" == "$vv" ]] && in_group=1 && break; done
                    if [[ $in_group -eq 0 ]]; then remaining_videos+=("$v"); fi
                done
                video_items=("${remaining_videos[@]}")
            fi
        fi

        # Send any remaining videos individually (small or large)
        local v
        for v in "${video_items[@]}"; do
            ( send_single_media "$v" ) &
        done
    fi

}

# === Send a single media item (photo or video) ===
send_single_media() {
    local item="$1"
    local name="$(basename "$item")"
    local ext="${item##*.}"
    ext="${ext,,}"

    case "$ext" in
        jpg|jpeg|png|heic)
            echo "$(date) [PHOTO] 🖼️ Sending single photo: $name" | tee -a "$LOG_FILE"
            local resp
            resp=$(curl -s -w "%{http_code}" -o "$TMP_DIR/resp_single.json" \
                --connect-timeout 15 --max-time 90 \
                -X POST "$TELEGRAM_API/bot$BOT_TOKEN/sendPhoto" \
                -F chat_id="$CHAT_ID" \
                -F photo="@$item")
            if [[ "$resp" == "200" ]] && grep -q '"ok":true' "$TMP_DIR/resp_single.json" 2>/dev/null; then
                echo "$(date) [SUCCESS] ✅ Photo sent: $name" | tee -a "$LOG_FILE"
                add_to_sent "$item"
            else
                echo "$(date) [ERROR] ❌ Photo failed (HTTP $resp): $name" | tee -a "$ERR_LOG"
                echo "$item" >> "$FAILED_TRACK"
                cat "$TMP_DIR/resp_single.json" >> "$ERR_LOG" 2>/dev/null || true
            fi
            rm -f "$TMP_DIR/resp_single.json" 2>/dev/null || true
            ;;
        mp4|mov)
            local size
            size=$(get_file_size "$item")
            if (( size > MAX_TELEGRAM_SIZE )); then
                echo "$(date) [VIDEO] 🎬 Single video is large; sending via proxy: $name" | tee -a "$LOG_FILE"
                send_large_video "$item"
                return
            fi
            echo "$(date) [VIDEO] 🎥 Sending single video: $name" | tee -a "$LOG_FILE"
            local resp
            resp=$(curl -s -w "%{http_code}" -o "$TMP_DIR/resp_single.json" \
                --connect-timeout 30 --max-time 180 \
                -X POST "$TELEGRAM_API/bot$BOT_TOKEN/sendVideo" \
                -F chat_id="$CHAT_ID" \
                -F video="@$item")
            if [[ "$resp" == "200" ]] && grep -q '"ok":true' "$TMP_DIR/resp_single.json" 2>/dev/null; then
                echo "$(date) [SUCCESS] ✅ Video sent: $name" | tee -a "$LOG_FILE"
                add_to_sent "$item"
            else
                echo "$(date) [ERROR] ❌ Video failed (HTTP $resp): $name" | tee -a "$ERR_LOG"
                echo "$item" >> "$FAILED_TRACK"
                cat "$TMP_DIR/resp_single.json" >> "$ERR_LOG" 2>/dev/null || true
            fi
            rm -f "$TMP_DIR/resp_single.json" 2>/dev/null || true
            ;;
        *)
            echo "$(date) [SKIP] ⚠️  Unsupported single item type: $name" | tee -a "$ERR_LOG"
            echo "$item" >> "$SKIP_TRACK"
            ;;
    esac
}

# === Send large video individually ===
send_large_video() {
    local video_file="$1"
    local video_name="$(basename "$video_file")"
    local size=$(get_file_size "$video_file")

    echo "$(date) [VIDEO] 🎥 Sending large video: $video_name (size: $((size/1024)) KB)" | tee -a "$LOG_FILE"

    local url="$API_SERVER/bot$BOT_TOKEN/sendVideo"

    resp=$(curl -s -w "%{http_code}" -o "$TMP_DIR/resp_video.json" \
        --connect-timeout 30 --max-time 300 \
        -X POST "$url" \
        -F chat_id="$CHAT_ID" \
        -F video="@$video_file")

    if [[ "$resp" == "200" ]]; then
        # Verify API response is actually successful
        if grep -q '"ok":true' "$TMP_DIR/resp_video.json" 2>/dev/null; then
            echo "$(date) [SUCCESS] ✅ Video sent: $video_name" | tee -a "$LOG_FILE"
            add_to_sent "$video_file"
            rm -f "$TMP_DIR/resp_video.json" 2>/dev/null || true
        else
            echo "$(date) [ERROR] ❌ Video API error: $video_name" | tee -a "$ERR_LOG"
            cat "$TMP_DIR/resp_video.json" >> "$ERR_LOG" 2>/dev/null || true
        fi
    else
        echo "$(date) [ERROR] ❌ Video failed (HTTP $resp): $video_name" | tee -a "$ERR_LOG"
        cat "$TMP_DIR/resp_video.json" >> "$ERR_LOG" 2>/dev/null || true
    fi
}

# === Resource monitoring ===
check_resources() {
    local mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "500000")
    local bg_jobs=$(jobs -r | wc -l)
    local temp_files=$(find "$TMP_DIR" -type f | wc -l)

    if [ "$mem_available" -lt 150000 ]; then
        echo "$(date) [RESOURCE] 🧠 Low memory ($((mem_available/1024))MB), pausing..." | tee -a "$LOG_FILE"
        sleep 3
    fi

    if [ "$bg_jobs" -gt 5 ]; then
        echo "$(date) [RESOURCE] ⏳ Throttling ($bg_jobs background jobs)..." | tee -a "$LOG_FILE"
        sleep 1
    fi

    if [ "$temp_files" -gt 20 ]; then
        echo "$(date) [CLEANUP] 🧹 Cleaning old temp files..." | tee -a "$LOG_FILE"
        find "$TMP_DIR" -name "*.jpg" -mmin +10 -delete 2>/dev/null || true
    fi
}

# === Main processing loop ===
if [[ "$RETRY_FAILED" == "1" ]]; then
  # Iterate over previously failed entries
  for f in "${FILE_LIST[@]}"; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    # ensure file is within this album
    case "$f" in "$ALBUM_DIR"/*) ;; *) continue ;; esac

    ((file_counter++))

    # Skip files that are already processed (robust check for HEIC with legacy JPG entries)
    if is_already_sent "$f"; then
        RUN_ALREADY=$((RUN_ALREADY+1))
        echo "$(date) [SKIP] [$file_counter/$total_files] ✅ Already sent: $(basename "$f")" | tee -a "$LOG_FILE"
        # In retry-only mode, clean up FAILED_TRACK entries for already-sent files
        if [[ "$RETRY_FAILED" == "1" ]]; then
            remove_from_failed "$f"
        fi
        continue
    fi

    # In normal mode, skip items known to have failed earlier; in retry mode, we will process them
    # In retry mode, we explicitly process failed ones, so no skip here

    if grep -qxF "$f" "$SKIP_TRACK" 2>/dev/null; then
        echo "[$file_counter/$total_files] ⏭️  Previously skipped: $(basename "$f")"
        continue
    fi

    # Resource check every 3 files
    [ $((file_counter % 3)) -eq 0 ] && check_resources

    echo "$(date) [PROCESS] [$file_counter/$total_files] 🔄 Processing: $(basename "$f")"

    ext="${f##*.}"
    ext="${ext,,}"   # lowercase extension

    case "$ext" in
        heic)
            jpg_path="$TMP_DIR/$(basename "${f%.*}").jpg"
            echo "$(date) [HEIC] 🔄 Converting HEIC: $(basename "$f")" | tee -a "$LOG_FILE"

            # Sequential conversion for RPi3 stability with better error handling
            if [[ ! -f "$f" ]]; then
                echo "$(date) [ERROR] ❌ Source file not found: $(basename "$f")" | tee -a "$ERR_LOG"
                continue
            fi

            # Try conversion with memory limit and error capture
            convert_error=$(convert "$f" -limit memory 256MB -limit disk 1GB \
                -auto-orient -resize 2048x2048\> -quality 92 -strip "$jpg_path" 2>&1)

            if [[ $? -eq 0 && -f "$jpg_path" && -s "$jpg_path" ]]; then
                echo "$(date) [HEIC] ✅ HEIC converted: $(basename "$f")" | tee -a "$LOG_FILE"
                media_batch+=("$jpg_path")
            else
                echo "$(date) [ERROR] ❌ HEIC conversion failed: $(basename "$f")" | tee -a "$ERR_LOG"
                echo "$(date) [ERROR] 🔍 Error: $convert_error" | tee -a "$ERR_LOG"
                echo "$f" >> "$FAILED_TRACK"  # Track as failed
                rm -f "$jpg_path" 2>/dev/null || true
            fi
            ;;
        jpg|jpeg|png)
            echo "$(date) [PHOTO] 📷 Adding photo: $(basename "$f")" | tee -a "$LOG_FILE"
            media_batch+=("$f")
            ;;
        mp4|mov)
            size=$(get_file_size "$f")

            # If video is too large for media group, send separately
            if (( size > MAX_TELEGRAM_SIZE )); then
                # Send current batch first if any
                if (( ${#media_batch[@]} > 0 )); then
                    wait  # Wait for conversions
                    send_media_batch_bg "${media_batch[@]}"
                    media_batch=()
                fi

                echo "$(date) [VIDEO] 🎬 Large video detected: $(basename "$f")" | tee -a "$LOG_FILE"
                (send_large_video "$f") &
            else
                echo "$(date) [VIDEO] 🎥 Adding video: $(basename "$f")" | tee -a "$LOG_FILE"
                media_batch+=("$f")
            fi
            ;;
        *)
            echo "$(date) [SKIP] ⚠️  Skipping unknown format: $(basename "$f")" | tee -a "$ERR_LOG"
            echo "$f" >> "$SKIP_TRACK"  # Track as skipped
            continue
            ;;
    esac

    # Send batch when full
    if (( ${#media_batch[@]} >= BATCH_SIZE )); then
        wait
        send_media_batch_bg "${media_batch[@]}"
        media_batch=()
        echo "$(date) [BATCH] 🚀 Batch queued, continuing processing..." | tee -a "$LOG_FILE"
    fi
  done
else
  # Normal mode: safe streaming of files at top level (no recursion), handle spaces/newlines
  while IFS= read -r -d '' f; do
    [[ ! -f "$f" ]] && continue

    ((file_counter++))

    # Skip files that are already processed (robust check for HEIC with legacy JPG entries)
    if is_already_sent "$f"; then
        RUN_ALREADY=$((RUN_ALREADY+1))
        echo "$(date) [SKIP] [$file_counter/$total_files] ✅ Already sent: $(basename "$f")" | tee -a "$LOG_FILE"
        continue
    fi

    # Skip items known to have failed earlier in normal mode
    if grep -qxF "$f" "$FAILED_TRACK" 2>/dev/null; then
        echo "[$file_counter/$total_files] ❌ Previously failed, skipping: $(basename "$f")"
        continue
    fi

    if grep -qxF "$f" "$SKIP_TRACK" 2>/dev/null; then
        echo "[$file_counter/$total_files] ⏭️  Previously skipped: $(basename "$f")"
        continue
    fi

    # Resource check every 3 files
    [ $((file_counter % 3)) -eq 0 ] && check_resources

    echo "$(date) [PROCESS] [$file_counter/$total_files] 🔄 Processing: $(basename "$f")"

    ext="${f##*.}"
    ext="${ext,,}"

    case "$ext" in
        heic)
            jpg_path="$TMP_DIR/$(basename "${f%.*}").jpg"
            echo "$(date) [HEIC] 🔄 Converting HEIC: $(basename "$f")" | tee -a "$LOG_FILE"

            if [[ ! -f "$f" ]]; then
                echo "$(date) [ERROR] ❌ Source file not found: $(basename "$f")" | tee -a "$ERR_LOG"
                continue
            fi

            convert_error=$(convert "$f" -limit memory 256MB -limit disk 1GB \
                -auto-orient -resize 2048x2048\> -quality 92 -strip "$jpg_path" 2>&1)

            if [[ $? -eq 0 && -f "$jpg_path" && -s "$jpg_path" ]]; then
                echo "$(date) [HEIC] ✅ HEIC converted: $(basename "$f")" | tee -a "$LOG_FILE"
                media_batch+=("$jpg_path")
            else
                echo "$(date) [ERROR] ❌ HEIC conversion failed: $(basename "$f")" | tee -a "$ERR_LOG"
                echo "$(date) [ERROR] 🔍 Error: $convert_error" | tee -a "$ERR_LOG"
                echo "$f" >> "$FAILED_TRACK"
                rm -f "$jpg_path" 2>/dev/null || true
            fi
            ;;
        jpg|jpeg|png)
            echo "$(date) [PHOTO] 📷 Adding photo: $(basename "$f")" | tee -a "$LOG_FILE"
            media_batch+=("$f")
            ;;
        mp4|mov)
            size=$(get_file_size "$f")

            if (( size > MAX_TELEGRAM_SIZE )); then
                if (( ${#media_batch[@]} > 0 )); then
                    wait
                    send_media_batch_bg "${media_batch[@]}"
                    media_batch=()
                fi

                echo "$(date) [VIDEO] 🎬 Large video detected: $(basename "$f")" | tee -a "$LOG_FILE"
                (send_large_video "$f") &
            else
                echo "$(date) [VIDEO] 🎥 Adding video: $(basename "$f")" | tee -a "$LOG_FILE"
                media_batch+=("$f")
            fi
            ;;
        *)
            echo "$(date) [SKIP] ⚠️  Skipping unknown format: $(basename "$f")" | tee -a "$ERR_LOG"
            echo "$f" >> "$SKIP_TRACK"
            continue
            ;;
    esac

    if (( ${#media_batch[@]} >= BATCH_SIZE )); then
        wait
        send_media_batch_bg "${media_batch[@]}"
        media_batch=()
        echo "$(date) [BATCH] 🚀 Batch queued, continuing processing..." | tee -a "$LOG_FILE"
    fi
  done < <(find "$ALBUM_DIR" -maxdepth 1 -type f \
      \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mov' -o -iname '*.mp4' \) -print0)
fi

# === Finalization ===
echo "$(date) [SUMMARY] 🏁 Processing complete, finalizing..." | tee -a "$LOG_FILE"

# Wait for all conversions to finish
wait

# Send final batch if any
if (( ${#media_batch[@]} > 0 )); then
    echo "$(date) [BATCH] 📤 Sending final batch of ${#media_batch[@]} files..." | tee -a "$LOG_FILE"
    send_media_batch_bg "${media_batch[@]}"
fi

echo "$(date) [WAIT] ⏳ Waiting for all uploads to complete..." | tee -a "$LOG_FILE"
wait

# Final statistics
sent_files=$(wc -l < "$SENT_TRACK" 2>/dev/null || echo "0")
error_count=$(grep -c "❌" "$ERR_LOG" 2>/dev/null || echo "0")

echo "$(date) [SUCCESS] ✅ SYNC COMPLETE!" | tee -a "$LOG_FILE"
echo "$(date) [SUMMARY] 📊 Files processed: $sent_files/$total_files" | tee -a "$LOG_FILE"
echo "$(date) [SUMMARY] ♻️ Already present this run: $RUN_ALREADY files" | tee -a "$LOG_FILE"
echo "$(date) [SUMMARY] ⚠️  Errors: $error_count" | tee -a "$LOG_FILE"

if (( error_count > 0 )); then
    echo "$(date) [SUMMARY] 🔍 Check error log: $ERR_LOG" | tee -a "$LOG_FILE"
fi

echo "$(date) [CLEANUP] 🧹 Cleaning up temporary files..." | tee -a "$LOG_FILE"
rm -rf "$TMP_DIR" 2>/dev/null || true

# Final tracking summary
final_sent=$(wc -l < "$SENT_TRACK" 2>/dev/null || echo "0")
final_failed=$(wc -l < "$FAILED_TRACK" 2>/dev/null || echo "0")
final_skipped=$(wc -l < "$SKIP_TRACK" 2>/dev/null || echo "0")

echo "$(date) [SUMMARY] 📋 FINAL SUMMARY:" | tee -a "$LOG_FILE"
echo "$(date) [SUMMARY] ✅ Successfully sent: $final_sent files" | tee -a "$LOG_FILE"
echo "$(date) [SUMMARY] ❌ Failed: $final_failed files" | tee -a "$LOG_FILE"
echo "$(date) [SUMMARY] ⏭️  Skipped: $final_skipped files" | tee -a "$LOG_FILE"

echo "$(date) [STATE] 💾 State saved to: $PERSISTENT_DIR" | tee -a "$LOG_FILE"
echo "$(date) [STATE] 🔄 Next run will resume from where it left off" | tee -a "$LOG_FILE"
echo "$(date) [SUCCESS] 🎉 Album sync completed successfully!" | tee -a "$LOG_FILE"

# Final minimal notification
status_msg="OK"
if (( error_count > 0 )); then status_msg="ERRORS:$error_count"; fi
tg_notify "DONE ✅ album=$ALBUM_NAME sent=$final_sent failed=$final_failed skipped=$final_skipped already=$RUN_ALREADY total=$total_files status=$status_msg"
