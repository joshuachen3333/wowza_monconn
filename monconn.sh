#!/usr/bin/env bash
###############################################################################
# monconn7x29.sh
#
# VERSION=7x29
#
# CHANGES from monconn7x28.sh:
#   1. If the same key (IP-ClientID) already exists with a connect event,
#      we IGNORE the new connect and keep the oldest one. (原先 7x28 的主要改動)
#   2. Updated references to "7x29".
#   3. 新增檢查：對於同一個 key，如果該 key 已經有一個 video 名稱，
#      後續任何帶有 video 的事件 (如 create, seek, stop, destroy) 都必須
#      檢查該 video 是否相同；若不同，必須在 debug.log 明顯顯示。
#
# USAGE:
#   ./monconn7x29.sh [options]
#     -c, --connect_width <width>   Set the width of the "connect" column (default: 15)
#     -t, --target                  Enable target mode (display truncated video name
#                                   in the "connect" column)
#     -d, --debug                   Enable debug mode (write logs to debug.log and
#                                   detailed.log)
#     -h, --help                    Display usage/help.
###############################################################################

VERSION=7x29

###############################################################################
# 1. Parse command-line arguments
###############################################################################
TARGET_MODE=false
DEBUG_MODE=false
CONNECT_WIDTH=15  # Default value

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--connect_width)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]]; then
                CONNECT_WIDTH="$2"
                shift 2
            else
                echo "Error: --connect_width requires a positive integer argument."
                exit 1
            fi
            ;;
        -t|--target)
            TARGET_MODE=true
            shift
            ;;
        -d|--debug)
            DEBUG_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "  -c, --connect_width <width>   Set the width of the \"connect\" column (default: 15)"
            echo "  -t, --target                  Enable target mode (show truncated video name instead of client-id)"
            echo "  -d, --debug                   Enable debug mode (write logs to debug.log and detailed.log)"
            echo "  -h, --help                    Display this help message"
            exit 0
            ;;
        *)
            echo "Warning: Unknown option $1"
            shift
            ;;
    esac
done

###############################################################################
# 2. Setup logging based on DEBUG_MODE
###############################################################################
if $DEBUG_MODE; then
    # Remove old logs if they exist
    [ -f debug.log ] && rm debug.log
    [ -f detailed.log ] && rm detailed.log

    # We'll also remove IP_TABLE.txt and ADDR.txt for a fresh start
    [ -f IP_TABLE.txt ] && rm IP_TABLE.txt
    [ -f ADDR.txt ] && rm ADDR.txt
fi

# Debug log helper
function debug_log() {
    if $DEBUG_MODE; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - [${VERSION}] - $@" >> debug.log
    fi
}

# Detailed log helper
function detailed_log() {
    if $DEBUG_MODE; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - [${VERSION}] - $@" >> detailed.log
    fi
}

###############################################################################
# 3. Declare associative arrays
###############################################################################
declare -A IP_TABLE
declare -A LAST_ACTIVE
declare -A final_duration
declare -A IP_COLORS  # Map IPs to their assigned colors

###############################################################################
# 4. Timeout and other settings
###############################################################################
IDLE_TIME=14400     # 4 hours in seconds
UPDATE_INTERVAL=1
DISCONNECT_TIME=60  # 1 minute

# Decimal places for durations
DECIMAL_PLACES=1
if (( DECIMAL_PLACES < 1 )); then
    debug_log "DECIMAL_PLACES cannot be less than 1. Setting to 1."
    DECIMAL_PLACES=1
fi

# IPs to ignore
IGNORE_IPLIST=" \
137.135.108.237 \
20.194.188.192 \
52.187.110.61 \
"

###############################################################################
# 5. Column widths and dynamic formatting strings
###############################################################################
IP_WIDTH=15
# CONNECT_WIDTH is now set via command-line argument or defaulted to 15

BASE_DURATION_WIDTHS=(5 4 6 6 6 6)  # creat, play, seek, stop, destry, discnt

ADJUSTED_DURATION_WIDTHS=()
for base_width in "${BASE_DURATION_WIDTHS[@]}"; do
    adjusted_width=$(( base_width + DECIMAL_PLACES - 1 ))
    ADJUSTED_DURATION_WIDTHS+=("$adjusted_width")
done

PRINTF_FORMAT="%-${IP_WIDTH}s | %-${CONNECT_WIDTH}s"
for width in "${ADJUSTED_DURATION_WIDTHS[@]}"; do
    PRINTF_FORMAT+=" | %-${width}s"
done
PRINTF_FORMAT+="\n"

###############################################################################
# 6. Generate separator line matching PRINTF_FORMAT
###############################################################################
function generate_separator_line() {
    local format="${PRINTF_FORMAT%\\n}"
    local separator_line=""
    local regex='%-?([0-9]+)s'

    while [[ "$format" != "" ]]; do
        if [[ "$format" =~ ^$regex ]]; then
            local width="${BASH_REMATCH[1]}"
            local dashes
            dashes=$(printf '%*s' "$width" '' | tr ' ' '-')
            separator_line+="$dashes"
            format="${format#${BASH_REMATCH[0]}}"
        else
            local sep="${format:0:1}"
            # Replace spaces with '-', '|' with '+'
            if [[ "$sep" == " " ]]; then
                sep='-'
            elif [[ "$sep" == "|" ]]; then
                sep='+'
            fi
            separator_line+="$sep"
            format="${format:1}"
        fi
    done

    echo "$separator_line"
}

###############################################################################
# 7. Parse field widths (for aligning decimals)
###############################################################################
function parse_field_widths() {
    local format="${PRINTF_FORMAT%\\n}"
    local regex='%-?([0-9]+)s'
    FIELD_WIDTHS=()

    while [[ "$format" != "" ]]; do
        if [[ "$format" =~ ^$regex ]]; then
            FIELD_WIDTHS+=("${BASH_REMATCH[1]}")
            format="${format#${BASH_REMATCH[0]}}"
        else
            format="${format#?}"
        fi
    done
}
parse_field_widths

###############################################################################
# 8. Align durations at the decimal point
###############################################################################
function format_duration_aligned() {
    local duration="$1"
    local field_index="$2"
    if [[ -n "$duration" ]]; then
        local total_width="${FIELD_WIDTHS[$field_index]}"
        local int_width=$(( total_width - DECIMAL_PLACES - 1 ))
        (( int_width < 1 )) && int_width=1

        # If duration is numeric, format it. Otherwise, show '?' to indicate an error
        if [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            local formatted
            formatted=$(printf "%.${DECIMAL_PLACES}f" "$duration")
            local integer_part="${formatted%.*}"
            local fractional_part="${formatted#*.}"
            local padded_integer
            padded_integer=$(printf "%${int_width}s" "$integer_part")
            echo "$padded_integer.$fractional_part"
        else
            # Not numeric, so indicate an error
            printf "%${FIELD_WIDTHS[$field_index]}s" "?"
        fi
    else
        printf "%${FIELD_WIDTHS[$field_index]}s" ""
    fi
}

###############################################################################
# 9. Helper functions
###############################################################################
function convert_to_readable() {
    date -d "@$1" +"%Y-%m-%d-%H-%M-%S"
}

function contains_element() {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

function validate_key() {
    local key="$1"
    if [[ ! "$key" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}-[0-9]{5,10}$ ]]; then
        if $DEBUG_MODE; then
            echo "" >> detailed.log
            echo "!!!!!!!!!!!!!!!!!!!!!$key not valid, removed" >> detailed.log
        fi
        # Extract IP from key
        local ip="${key%%-*}"
        # Remove color assignment if IP is invalid
        unset IP_COLORS["$ip"]
        unset IP_TABLE["$key"]
        unset LAST_ACTIVE["$key"]
        clear
        print_header
    fi
}

###############################################################################
# 10. Define Color Groups with Prioritized Bright Colors
###############################################################################
COLOR_CODES=(
    "\e[92m"  # Bright Green (Group 0)
    "\e[93m"  # Bright Yellow (Group 1)
    "\e[94m"  # Bright Blue (Group 2)
    "\e[95m"  # Bright Magenta (Group 3)
    "\e[96m"  # Bright Cyan (Group 4)
    "\e[91m"  # Bright Red (Group 5)
    "\e[32m"  # Green (Group 6)
    "\e[33m"  # Yellow (Group 7)
    "\e[34m"  # Blue (Group 8)
    "\e[35m"  # Magenta (Group 9)
    "\e[31m"  # Red (Group 10)
)

NUM_COLORS=${#COLOR_CODES[@]}
COLOR_INDEX=0  # Tracks the next color to assign

###############################################################################
# 11. Print header function
###############################################################################
function print_header() {
    printf "$PRINTF_FORMAT" \
           "IP x29" "connect" "creat" "play" "seek" "stop" "destry" "discnt"
    local separator_line
    separator_line=$(generate_separator_line)
    echo "$separator_line"
}

# Initialize display
clear
echo -en "\e[H"
print_header

###############################################################################
# 12. Process each line from the Wowza log
###############################################################################
function process_line() {
    local line="$1"

    # Extra debug for raw line
    debug_log "Raw line: $line"

    EVENT=$(echo "$line" | awk '{print $4}')
    if [[ "$EVENT" == "comment" ]]; then
        debug_log "Skipping 'comment' line"
        return
    fi

    IP=$(echo "$line" | awk '{print $17}')
    if contains_element "$IP" $IGNORE_IPLIST; then
        debug_log "Ignored IP: $IP"
        return
    fi

    # Log the event, IP for debug
    debug_log "Parsed EVENT='$EVENT', IP='$IP'"

    detailed_log "EVENT=$EVENT"
    detailed_log "IP=$IP"

    # Extract client ID from column 22 if valid
    local CLIENT_ID_TMP
    CLIENT_ID_TMP=$(echo "$line" | awk '{print $22}')
    if [[ "$CLIENT_ID_TMP" =~ ^[0-9]{5,10}$ ]]; then
        CLIENT_ID="$CLIENT_ID_TMP"
        debug_log "CLIENT_ID extracted from column 22 => '$CLIENT_ID'"
    else
        CLIENT_ID=$(awk '{
            if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $2 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
                for(i=3;i<=NF;i++) {
                    if ($i ~ /^[0-9]{5,10}$/) {
                        print $i;
                        exit;
                    }
                }
            }
        }' <<< "$line")

        debug_log "CLIENT_ID extracted via fallback => '$CLIENT_ID'"
    fi

    NOW=$(date +%s)
    local VIDEO_NAME=""
    # Only parse col 8 if not connect/disconnect
    if [[ "$EVENT" != "connect" && "$EVENT" != "disconnect" ]]; then
        local VIDEO_FIELD
        VIDEO_FIELD=$(echo "$line" | awk '{print $8}')
        if [[ -n "$VIDEO_FIELD" && "$VIDEO_FIELD" == vod/* ]]; then
            VIDEO_FIELD="${VIDEO_FIELD#vod/}"
            VIDEO_NAME=$(echo "$VIDEO_FIELD" | awk -F'/' '{if(NF>=2) {print $1"/"$2} else {print $1}}')
            if (( ${#VIDEO_NAME} > CONNECT_WIDTH )); then
                debug_log "Truncating VIDEO_NAME from '$VIDEO_NAME' to CONNECT_WIDTH=$CONNECT_WIDTH"
                VIDEO_NAME="${VIDEO_NAME:0:${CONNECT_WIDTH}}"
            fi
        fi
    fi

    local KEY="$IP-$CLIENT_ID"
    debug_log "KEY=$KEY, VIDEO_NAME=$VIDEO_NAME"

    local DURATION=""

    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # 7x29: IGNORE new connect if the key already exists with a connect
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    if [[ "$EVENT" == "connect" ]]; then
        if [[ -n "${IP_TABLE["$KEY"]}" && "${IP_TABLE["$KEY"]}" =~ connect: ]]; then
            debug_log "7x29: Found existing connect for $KEY => IGNORING new connect event"
            return  # do nothing else, leave old connect in place
        fi
        # No existing connect => proceed
        DURATION=$NOW
        debug_log "connect => DURATION=$DURATION (timestamp)"

    elif [[ "$EVENT" == "disconnect" ]]; then
        # Attempt to parse "connect:" from IP_TABLE
        if [[ ${IP_TABLE["$KEY"]} =~ "connect:" ]]; then
            local CONNECT_MOMENT
            CONNECT_MOMENT=$(echo "${IP_TABLE["$KEY"]}" \
                | awk -F ',' '{for(i=1;i<=NF;i++) if($i ~ /connect:/) print $i}' \
                | cut -d':' -f2)

            debug_log "disconnect => CONNECT_MOMENT raw='$CONNECT_MOMENT' NOW=$NOW"
            detailed_log "disconnect => CONNECT_MOMENT=$CONNECT_MOMENT, NOW=$NOW"

            if [[ "$CONNECT_MOMENT" =~ ^[0-9]+$ ]]; then
                DURATION=$(( NOW - CONNECT_MOMENT )) 2>> debug.log
                debug_log "DISCONNECT DURATION=$DURATION"
            else
                debug_log "7x29: CONNECT_MOMENT not purely numeric => '$CONNECT_MOMENT'"
                # Just default to 0
                DURATION="0"
            fi
        else
            if [[ ${IP_TABLE["$KEY"]} =~ "disconnect:" ]]; then
                local NEAREST_EVENT
                NEAREST_EVENT=$(echo "${IP_TABLE["$KEY"]}" \
                    | awk -F ',' '{n=split($0,a,","); print a[n-1]}' \
                    | cut -d':' -f2)
                DURATION="$NEAREST_EVENT"
                debug_log "disconnect => found existing disconnect:$DURATION"
            else
                local LAST_ITEM
                LAST_ITEM=$(echo "${IP_TABLE["$KEY"]}" | awk -F ',' '{print $NF}')
                DURATION="${LAST_ITEM#*:}"
                debug_log "disconnect => using last event's duration:$DURATION"
            fi
        fi

        # Update final_duration if numeric
        if [[ ${final_duration["$KEY"]} ]]; then
            IFS=":" read -r OLD_DURATION LAST_TS <<< "${final_duration["$KEY"]}"
            if [[ "$OLD_DURATION" =~ ^[0-9]+(\.[0-9]+)?$ && "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                DURATION=$(echo "$DURATION + $OLD_DURATION" | bc)
                debug_log "Updated DURATION w/final_duration => $DURATION"
            else
                debug_log "WARNING: final_duration not numeric => OLD_DURATION='$OLD_DURATION', new='$DURATION'"
            fi
        fi
        final_duration["$KEY"]="$DURATION:$NOW"

    else
        # For other events, read numeric from col 13
        local numericCheck
        numericCheck=$(echo "$line" | awk '{print $13}')
        debug_log "EVENT=$EVENT => raw col13='$numericCheck'"

        if [[ "$numericCheck" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            DURATION="$numericCheck"
            debug_log "EVENT=$EVENT => numeric DURATION=$DURATION"
        else
            debug_log "WARNING: col13 not numeric => '$numericCheck'"
            DURATION="0"
        fi
    fi

    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # 7x29: 檢查同一個 key 的 video 是否一致
    # 若 IP_TABLE[$KEY] 裡面已有 video:XXX，現在又偵測到新的 VIDEO_NAME 就要比較
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # 以下邏輯：任何時候只要我們解析到 VIDEO_NAME，就與 IP_TABLE 既有的 video 進行比對
    # （包含 create, seek, stop, destroy 等事件）
    local old_video=""
    if [[ "${IP_TABLE["$KEY"]}" =~ (video:[^,]+) ]]; then
        old_video="${BASH_REMATCH[1]#video:}"
    fi

    if [[ -n "$VIDEO_NAME" ]]; then
        if [[ -n "$old_video" ]]; then
            if [[ "$VIDEO_NAME" != "$old_video" ]]; then
                # video 不一致
                debug_log "******************video mismatch for KEY=$KEY => old='$old_video', new='$VIDEO_NAME'"
            else
                # video 相同
                debug_log "******************video same for KEY=$KEY => video='$VIDEO_NAME'"
            fi
        else
            # IP_TABLE 裡還沒有 video, 剛好這次帶進來
            debug_log "******************video newly assigned for KEY=$KEY => video='$VIDEO_NAME'"
        fi
    fi

    # Store last active & validate
    LAST_ACTIVE["$KEY"]=$NOW
    validate_key "$KEY"

    # ~~~~~~~~~~~~~~ Update IP_TABLE ~~~~~~~~~~~~~~
    local previous_data="${IP_TABLE[$KEY]}"
    local event_duration_string="$EVENT:$DURATION"

    local existing_video_entry=""
    if [[ "$previous_data" =~ (video:[^,]+) ]]; then
        existing_video_entry="${BASH_REMATCH[1]}"
    fi

    local new_video_entry=""
    if [[ -n "$VIDEO_NAME" ]]; then
        new_video_entry="video:$VIDEO_NAME"
    fi

    if [[ -z "$previous_data" ]]; then
        if [[ -n "$new_video_entry" ]]; then
            IP_TABLE[$KEY]="$event_duration_string,$new_video_entry"
        else
            IP_TABLE[$KEY]="$event_duration_string"
        fi
    else
        local updated_data="$previous_data,$event_duration_string"
        if [[ -z "$existing_video_entry" && -n "$new_video_entry" ]]; then
            updated_data="$updated_data,$new_video_entry"
        fi
        IP_TABLE[$KEY]="$updated_data"
    fi

    debug_log "IP_TABLE[$KEY] => ${IP_TABLE[$KEY]}"

    # If debug, write IP_TABLE to file
    if $DEBUG_MODE; then
        {
            for k in "${!IP_TABLE[@]}"; do
                echo "$k: ${IP_TABLE[$k]}"
            done
        } > IP_TABLE.txt
    fi
}

###############################################################################
# 13. Safe increment function
###############################################################################
function safe_increment_ip_count() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        debug_log "7x29: ERROR A DETECTED: Empty IP, skipping increment."
        return 1
    fi

    (( ip_count["$ip"]++ ))
    return 0
}

###############################################################################
# 14. Main loop: tail the log, update, display
###############################################################################
tail -F /usr/local/WowzaStreamingEngine/logs/wowzastreamingengine_access.log |
while read -r line; do
    process_line "$line"
    NOW=$(date +%s)

    # Remove idle or disconnected
    for k in "${!LAST_ACTIVE[@]}"; do
        if (( NOW - LAST_ACTIVE[$k] > IDLE_TIME )); then
            local IDLED_TIME=$(( NOW - LAST_ACTIVE[$k] ))
            debug_log "Removing $k (IDLED $IDLED_TIME seconds)"
            local ip="${k%%-*}"
            unset IP_TABLE["$k"]
            unset LAST_ACTIVE["$k"]
            unset IP_COLORS["$ip"]
            clear
            print_header

        elif [[ $EVENT == "disconnect" ]] && (( NOW - LAST_ACTIVE[$k] > DISCONNECT_TIME )); then
            local STOPPED_TIME=$(( NOW - LAST_ACTIVE[$k] ))
            debug_log "Removing $k (disconnect, $STOPPED_TIME seconds idle)"
            local ip="${k%%-*}"
            unset IP_TABLE["$k"]
            unset LAST_ACTIVE["$k"]
            unset IP_COLORS["$ip"]
            clear
            print_header
        fi
    done

    # Sort by IP
    sorted_keys=( $(printf '%s\n' "${!IP_TABLE[@]}" | sort) )

    unset ip_count
    declare -A ip_count

    # Count how many unique client IDs per IP
    for entry_key in "${sorted_keys[@]}"; do
        ip="${entry_key%%-*}"

        if ! safe_increment_ip_count "$ip"; then
            continue
        fi
    done

    # Show results
    echo -en "\e[3;1H"

    for entry_key in "${sorted_keys[@]}"; do
        if $DEBUG_MODE; then
            echo "$entry_key: ${IP_TABLE[$entry_key]}" >> ADDR.txt
        fi

        IFS=',' read -ra parts <<< "${IP_TABLE[$entry_key]}"
        DISPLAY_IP="${entry_key%%-*}"
        CLIENT_ID="${entry_key##*-}"

        # Reset placeholders
        CREATE="" PLAY="" SEEK="" STOP="" DESTROY="" DISCONNECT="" VIDEO_NAME=""

        # Gather
        for val in "${parts[@]}"; do
            EVENT_TYPE="${val%%:*}"
            THIS_VALUE="${val#*:}"
            case "$EVENT_TYPE" in
                connect|create|play|seek|stop|destroy|disconnect)
                    case "$EVENT_TYPE" in
                        create)     CREATE="$THIS_VALUE";;
                        play)       PLAY="$THIS_VALUE";;
                        seek)       SEEK="$THIS_VALUE";;
                        stop)       STOP="$THIS_VALUE";;
                        destroy)    DESTROY="$THIS_VALUE";;
                        disconnect) DISCONNECT="$THIS_VALUE";;
                    esac
                    ;;
                video)
                    VIDEO_NAME="$THIS_VALUE"
                    ;;
            esac
        done

        CREATE=$(format_duration_aligned "$CREATE" 2)
        PLAY=$(format_duration_aligned "$PLAY" 3)
        SEEK=$(format_duration_aligned "$SEEK" 4)
        STOP=$(format_duration_aligned "$STOP" 5)
        DESTROY=$(format_duration_aligned "$DESTROY" 6)
        DISCONNECT=$(format_duration_aligned "$DISCONNECT" 7)

        if $TARGET_MODE && [[ -n "$VIDEO_NAME" ]]; then
            CONNECT_FIELD="$VIDEO_NAME"
        else
            CONNECT_FIELD="$CLIENT_ID"
        fi
        CONNECT_FIELD=$(printf "%-${CONNECT_WIDTH}s" "$CONNECT_FIELD")

        connection_count="${ip_count[$DISPLAY_IP]}"

        # If connection_count>1 => grouped IP => color
        if (( connection_count > 1 )); then
            # Assign color if not assigned
            if [[ -z "${IP_COLORS[$DISPLAY_IP]}" ]]; then
                IP_COLORS[$DISPLAY_IP]="${COLOR_CODES[$(( COLOR_INDEX % NUM_COLORS ))]}"
                debug_log "Assigned Color: ${IP_COLORS[$DISPLAY_IP]} to IP: $DISPLAY_IP"
                (( COLOR_INDEX++ ))
            fi
            COLOR="${IP_COLORS[$DISPLAY_IP]}"
            RESET_COLOR="\e[0m"
        else
            COLOR=""
            RESET_COLOR=""
        fi

        debug_log "Processing entry: $entry_key"
        debug_log "DISPLAY_IP: $DISPLAY_IP, Connection Count: $connection_count, Color: ${COLOR:-Default White}"

        if (( connection_count > 1 )); then
            debug_log "Applying Color: ${COLOR} to IP: $DISPLAY_IP"
            printf "${COLOR}$PRINTF_FORMAT${RESET_COLOR}" \
                   "$DISPLAY_IP" "$CONNECT_FIELD" "$CREATE" "$PLAY" "$SEEK" "$STOP" "$DESTROY" "$DISCONNECT"
        else
            debug_log "Applying Default color to IP: $DISPLAY_IP"
            printf "$PRINTF_FORMAT" \
                   "$DISPLAY_IP" "$CONNECT_FIELD" "$CREATE" "$PLAY" "$SEEK" "$STOP" "$DESTROY" "$DISCONNECT"
        fi
    done
done
