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
# User Configuration
###############################################################################
# --- Behavior ---
IDLE_TIME=14400             # Seconds after which an inactive IP-ClientID key is removed (e.g., 14400 for 4 hours)
DISCONNECT_TIME=60          # Seconds after a 'disconnect' event that a key is removed (e.g., 60 for 1 minute)
DISPLAY_UPDATE_INTERVAL=1   # Seconds between display refreshes (e.g., 1 or 2 seconds)
LOG_FILE_PATH="/usr/local/WowzaStreamingEngine/logs/wowzastreamingengine_access.log" # Path to the Wowza log file

# --- Display & Formatting ---
IP_WIDTH=15                 # Width of the IP address column
# CONNECT_WIDTH is set via -c/--connect_width, defaults to 15 below
DECIMAL_PLACES=1            # Number of decimal places for duration values (min 1)
BASE_DURATION_WIDTHS=(5 4 6 6 6 6)  # Base widths for: creat, play, seek, stop, destry, discnt
                                    # Actual width will be base + DECIMAL_PLACES - 1

# --- Filtering ---
IGNORE_IPLIST=" \
137.135.108.237 \
20.194.188.192 \
52.187.110.61 \
" # Space-separated list of IPs to ignore

###############################################################################
# 1. Parse command-line arguments
###############################################################################
TARGET_MODE=false
DEBUG_MODE=false
CONNECT_WIDTH=15  # Default value, can be overridden by -c

# Initialize LOG_FILE_PATH with default from config section, can be overridden by -l
# This is already done when LOG_FILE_PATH is defined in config section.

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
        -l|--log-file)
            if [[ -n "$2" ]]; then
                LOG_FILE_PATH="$2"
                shift 2
            else
                echo "Error: --log-file requires a path argument."
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
            echo "  -c, --connect_width <width>   Set the width of the \"connect\" column (default: $CONNECT_WIDTH)"
            echo "  -l, --log-file <path>         Path to the Wowza log file (default: \"$LOG_FILE_PATH\")"
            echo "  -t, --target                  Enable target mode (show truncated video name instead of client-id)"
            echo "  -d, --debug                   Enable debug mode (write logs to debug.log)"
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
        # SC2145: Use "$*" to treat all positional parameters as a single string.
        echo "$(date +"%Y-%m-%d %H:%M:%S") - [${VERSION}] - $*" >> debug.log
    fi
}

# detailed_log has been consolidated into debug_log.
# If more verbosity is needed, consider adding levels to debug_log.

###############################################################################
# 3. Declare associative arrays
###############################################################################
declare -A IP_TABLE
declare -A LAST_ACTIVE
declare -A final_duration
declare -A IP_COLORS  # Map IPs to their assigned colors

###############################################################################
# 4. Validate Configurations & Derived Settings (Post Argument Parsing)
###############################################################################
# Ensure DECIMAL_PLACES is at least 1
if (( DECIMAL_PLACES < 1 )); then
    debug_log "CONFIG ERROR: DECIMAL_PLACES cannot be less than 1. Setting to 1."
    DECIMAL_PLACES=1
fi

# Note: IGNORE_IPLIST is used directly as defined.
# Note: IP_WIDTH is used directly as defined.
# Note: IDLE_TIME, DISCONNECT_TIME, DISPLAY_UPDATE_INTERVAL are used directly.

###############################################################################
# 5. Column widths and dynamic formatting strings
###############################################################################
# CONNECT_WIDTH is set via command-line argument or defaulted

ADJUSTED_DURATION_WIDTHS=()
for base_width in "${BASE_DURATION_WIDTHS[@]}"; do
    # Ensure base_width is treated as a number
    declare -i current_base_width="$base_width"
    adjusted_width=$(( current_base_width + DECIMAL_PLACES - 1 ))
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
            # SC2295: Quote expansions inside ${..} separately.
            format="${format#"${BASH_REMATCH[0]}"}"
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
            # SC2295: Quote expansions inside ${..} separately.
            format="${format#"${BASH_REMATCH[0]}"}"
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

# Validates the key format (IP-ClientID).
# IMPORTANT: This function has side effects:
# - If the key is invalid, it clears IP_COLORS, IP_TABLE, and LAST_ACTIVE entries for the key.
# - It also clears the screen and reprints the header.
function validate_key() {
    local key="$1"
    if [[ ! "$key" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}-[0-9]{5,10}$ ]]; then
        # Using debug_log for this event as it's a key format validation.
        debug_log "WARNING: Invalid key format detected: '$key'. Removing associated entries."
        # The following lines already use debug_log indirectly if $DEBUG_MODE is true,
        # by calling print_table_header which might call other functions that log.
        # Explicitly logging the removal action here.
        if $DEBUG_MODE; then
            debug_log "WARNING: Action: Unsetting IP_COLORS, IP_TABLE, LAST_ACTIVE for key '$key' and its IP component."
        fi
        # Extract IP from key
        local ip="${key%%-*}"
        # Remove color assignment if IP is invalid
        unset IP_COLORS["$ip"]
        unset IP_TABLE["$key"]
        unset LAST_ACTIVE["$key"]
        clear
        print_table_header # Renamed from print_header
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
# 11. Print table header function
###############################################################################
function print_table_header() {
    # SC2059: Using PRINTF_FORMAT as the format string is intentional here as it's constructed by the script.
    # Adding -- to signify end of options for printf.
    printf -- "$PRINTF_FORMAT" \
           "IP x29" "connect" "creat" "play" "seek" "stop" "destry" "discnt"
    local separator_line
    separator_line=$(generate_separator_line)
    echo "$separator_line"
}

# Clears the screen, positions cursor at home, and prints the table header.
function refresh_full_display() {
    clear
    echo -en "\e[H" # Move cursor to home position (top-left)
    print_table_header
}

# Removes a client entry and refreshes the display.
# Args: $1 client_key (e.g., "IP-ClientID")
#       $2 reason_message (string for logging)
function remove_client_and_refresh() {
    local client_key="$1"
    local reason_message="$2"
    local ip

    debug_log "$reason_message" # Log the provided reason

    ip="${client_key%%-*}" # Extract IP from key

    unset IP_TABLE["$client_key"]
    unset LAST_ACTIVE["$client_key"]
    # Unset color for the IP. Note: This is the current simple logic.
    # If multiple distinct client_keys share an IP, this clears the color for all of them
    # if they rely on the same IP_COLORS[$ip] entry.
    # However, IP_COLORS is usually assigned when ip_count[ip] > 1,
    # so this direct unset is likely okay for the current color assignment strategy.
    unset IP_COLORS["$ip"]

    refresh_full_display
}

# Initialize display
refresh_full_display

###############################################################################
# 12. Refactored processing functions
###############################################################################

# Parses essential fields from a raw log line using a single awk command.
# Outputs fields to global variables:
#   RAW_EVENT, RAW_IP, RAW_CLIENT_ID_COL22, RAW_VIDEO_FIELD_COL8, RAW_DURATION_COL13
# Returns: 0 on success, 1 if awk fails or essential fields are missing.
function parse_line_fields() {
    local line="$1"
    # Read multiple fields using one awk call.
    # Ensure OFS is a simple space for reliable splitting by read.
    # Handle cases where some fields might be missing in the log line by checking NF.
    local awk_output
    awk_output=$(echo "$line" | awk '
    {
        # Output placeholder "-" if field is beyond NF
        event = (NF >= 4) ? $4 : "-";
        ip = (NF >= 17) ? $17 : "-";
        client_id_col22 = (NF >= 22) ? $22 : "-";
        video_field_col8 = (NF >= 8) ? $8 : "-";
        duration_col13 = (NF >= 13) ? $13 : "-";
        print event, ip, client_id_col22, video_field_col8, duration_col13;
    }')

    if [[ -z "$awk_output" ]]; then
        debug_log "ERROR: parse_line_fields: awk command returned empty. Line: '$line'"
        return 1
    fi

    read -r RAW_EVENT RAW_IP RAW_CLIENT_ID_COL22 RAW_VIDEO_FIELD_COL8 RAW_DURATION_COL13 <<< "$awk_output"

    if [[ "$RAW_EVENT" == "-" ]] || [[ "$RAW_IP" == "-" ]]; then
         debug_log "ERROR: parse_line_fields: Essential fields (EVENT or IP) are missing after awk parse. Line: '$line'"
         RAW_EVENT="" # Ensure they are empty for checks in caller
         RAW_IP=""
         return 1
    fi
    # Other fields like RAW_CLIENT_ID_COL22, RAW_VIDEO_FIELD_COL8, RAW_DURATION_COL13 can be "-" (placeholder)
    # and will be handled by downstream functions.
    debug_log "parse_line_fields: RAW_EVENT='$RAW_EVENT', RAW_IP='$RAW_IP', RAW_CLIENT_ID_COL22='$RAW_CLIENT_ID_COL22', RAW_VIDEO_FIELD_COL8='$RAW_VIDEO_FIELD_COL8', RAW_DURATION_COL13='$RAW_DURATION_COL13'"
    return 0
}


# Sets global EVENT and IP based on pre-parsed raw fields.
# Returns: 0 on success, 1 on failure.
function process_parsed_event_ip() {
    # Args: $1 RAW_EVENT, $2 RAW_IP (passed implicitly via global RAW_EVENT, RAW_IP)
    EVENT="$RAW_EVENT"
    IP="$RAW_IP"

    if [[ -z "$EVENT" ]]; then # Should have been caught by parse_line_fields if it was "-"
        debug_log "ERROR: process_parsed_event_ip: EVENT is empty."
        return 1
    fi
    if [[ -z "$IP" ]]; then # Should have been caught by parse_line_fields
        debug_log "ERROR: process_parsed_event_ip: IP is empty."
        return 1
    fi
    # Redundant log if parse_line_fields already logged, but good for clarity here
    # debug_log "process_parsed_event_ip: EVENT='$EVENT', IP='$IP'"
    return 0
}

# Extracts Client ID using pre-parsed RAW_CLIENT_ID_COL22 and original line for fallback.
# Sets global CLIENT_ID.
# Returns: 0 on success, 1 on failure.
function process_parsed_client_id() {
    local line="$1" # Original line for fallback
    # Args: $2 RAW_CLIENT_ID_COL22 (passed implicitly via global)
    CLIENT_ID="" # Reset

    if [[ "$RAW_CLIENT_ID_COL22" != "-" && "$RAW_CLIENT_ID_COL22" =~ ^[0-9]{5,10}$ ]]; then
        CLIENT_ID="$RAW_CLIENT_ID_COL22"
        debug_log "process_parsed_client_id: CLIENT_ID from pre-parsed col 22 => '$CLIENT_ID'"
    else
        # Fallback extraction using original line
        CLIENT_ID=$(awk '{
            if ($1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && $2 ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
                for(i=3;i<=NF;i++) {
                    if ($i ~ /^[0-9]{5,10}$/) {
                        print $i;
                        exit;
                    }
                }
            }
        }' <<< "$line") # Original line needed here
        if [[ -n "$CLIENT_ID" ]]; then
            debug_log "process_parsed_client_id: CLIENT_ID via fallback from line => '$CLIENT_ID'"
        fi
    fi

    if [[ -z "$CLIENT_ID" ]]; then
        debug_log "ERROR: process_parsed_client_id: CLIENT_ID is empty after all attempts. Line: '$line'"
        return 1
    fi
    return 0
}

# Parses video name using pre-parsed RAW_VIDEO_FIELD_COL8.
# Sets global VIDEO_NAME.
# The awk logic aims to extract a simplified video identifier:
# - If RAW_VIDEO_FIELD_COL8 is like "vod/folder/video_stem.mp4" or "vod/folder/video_stem/playlist.m3u8",
#   it attempts to get "folder/video_stem".
# - If it's like "vod/video_file.mp4", it attempts to get "video_file.mp4".
# - It only processes fields starting with "vod/".
function process_parsed_video_name() {
    local current_event="$1" # Current EVENT value
    # Args: $2 RAW_VIDEO_FIELD_COL8 (passed implicitly via global)
    VIDEO_NAME="" # Ensure it's reset

    if [[ "$current_event" != "connect" && "$current_event" != "disconnect" ]]; then
        if [[ "$RAW_VIDEO_FIELD_COL8" != "-" && -n "$RAW_VIDEO_FIELD_COL8" ]]; then
            if [[ "$RAW_VIDEO_FIELD_COL8" == vod/* ]]; then
                local temp_video_field="${RAW_VIDEO_FIELD_COL8#vod/}"
                local parsed_name
                # Extracts the first two path components after "vod/", or just the first if only one exists.
                # e.g., "movie/part1" from "movie/part1/segment.mp4" or "movie.mp4" from "movie.mp4"
                parsed_name=$(echo "$temp_video_field" | awk -F'/' '{if(NF>=2) {print $1"/"$2} else {print $1}}')

                if [[ -z "$parsed_name" ]]; then
                    debug_log "WARNING: process_parsed_video_name: RAW_VIDEO_FIELD_COL8 ('$RAW_VIDEO_FIELD_COL8') resulted in an empty parsed_name."
                else
                    VIDEO_NAME="$parsed_name"
                    if (( ${#VIDEO_NAME} > CONNECT_WIDTH )); then
                        debug_log "process_parsed_video_name: Truncating VIDEO_NAME from '$VIDEO_NAME' to CONNECT_WIDTH=$CONNECT_WIDTH"
                        VIDEO_NAME="${VIDEO_NAME:0:${CONNECT_WIDTH}}"
                    fi
                fi
            else
                 debug_log "process_parsed_video_name: RAW_VIDEO_FIELD_COL8 is '$RAW_VIDEO_FIELD_COL8', does not start with 'vod/'. Not treated as standard video name."
            fi
        fi
    fi
    debug_log "process_parsed_video_name: VIDEO_NAME='$VIDEO_NAME' for EVENT='$current_event'"
}

# Calculates duration based on event type, using pre-parsed RAW_DURATION_COL13.
# Args: $1 current_event, $2 current_key, $3 current_now
# Implicitly uses global RAW_DURATION_COL13, IP_TABLE, final_duration
# Sets global DURATION.
# Returns: 0 for success/proceed, 1 for critical error or connect-ignore.
function calculate_parsed_duration() {
    local current_event="$1"
    local current_key="$2"
    local current_now="$3"
    # RAW_DURATION_COL13 is used implicitly from global scope

    DURATION="" # Ensure it's reset
    if [[ "$current_event" == "connect" ]]; then
        if [[ -n "${IP_TABLE["$current_key"]}" && "${IP_TABLE["$current_key"]}" =~ connect: ]]; then
            debug_log "calculate_parsed_duration: Found existing connect for $current_key => IGNORING new connect event"
            return 1 # Indicates to skip further processing
        fi
        DURATION=$current_now
        debug_log "calculate_parsed_duration: connect => DURATION=$DURATION (timestamp)"

    elif [[ "$current_event" == "disconnect" ]];then
        if [[ ${IP_TABLE["$current_key"]} =~ "connect:" ]]; then
            local connect_moment
            connect_moment=$(echo "${IP_TABLE["$current_key"]}" \
                | awk -F ',' '{for(i=1;i<=NF;i++) if($i ~ /connect:/) print $i}' \
                | cut -d':' -f2) # This awk call is specific and less frequent
            debug_log "calculate_parsed_duration: disconnect => CONNECT_MOMENT raw='$connect_moment' NOW=$current_now"

            if [[ "$connect_moment" =~ ^[0-9]+$ ]]; then
                DURATION=$(( current_now - connect_moment ))
                debug_log "calculate_parsed_duration: DISCONNECT DURATION=$DURATION"
            else
                debug_log "WARNING: calculate_parsed_duration: CONNECT_MOMENT not purely numeric => '$connect_moment'. Setting DURATION to 0."
                DURATION="0"
            fi
        else
            debug_log "WARNING: calculate_parsed_duration: 'connect:' event not found in IP_TABLE for KEY='$current_key' during disconnect. Using fallback logic."
            # Fallback logic as before
            if [[ ${IP_TABLE["$current_key"]} =~ "disconnect:" ]]; then
                 local nearest_event_duration
                 nearest_event_duration=$(echo "${IP_TABLE["$current_key"]}" \
                    | awk -F ',' '{n=split($0,a,","); print a[n-1]}' \
                    | cut -d':' -f2) # Specific awk call
                DURATION="$nearest_event_duration"
                debug_log "calculate_parsed_duration: disconnect => found existing disconnect, using its duration: $DURATION"
            else
                local last_item_duration
                last_item_duration=$(echo "${IP_TABLE["$current_key"]}" | awk -F ',' '{print $NF}') # Specific awk call
                DURATION="${last_item_duration#*:}"
                debug_log "calculate_parsed_duration: disconnect => no connect/disconnect found, using last event's duration: $DURATION"
            fi
        fi

        if [[ ${final_duration["$current_key"]} ]]; then
            # SC2034: last_ts appears unused. Changed to _.
            IFS=":" read -r old_total_duration _ <<< "${final_duration["$current_key"]}"
            if [[ "$old_total_duration" =~ ^[0-9]+(\.[0-9]+)?$ && "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                DURATION=$(echo "$DURATION + $old_total_duration" | bc)
                debug_log "calculate_parsed_duration: Updated DURATION with final_duration => $DURATION"
            else
                debug_log "WARNING: calculate_parsed_duration: final_duration or current DURATION not numeric for KEY='$current_key'. OLD_TOTAL='$old_total_duration', NEW_DISCONNECT_DURATION='$DURATION'"
            fi
        fi
        final_duration["$current_key"]="$DURATION:$current_now"
    else
        # For other events (create, play, seek, stop, destroy)
        # Use pre-parsed RAW_DURATION_COL13
        if [[ "$RAW_DURATION_COL13" != "-" && "$RAW_DURATION_COL13" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            DURATION="$RAW_DURATION_COL13"
            debug_log "calculate_parsed_duration: EVENT=$current_event => numeric DURATION=$DURATION from pre-parsed col13"
        else
            debug_log "WARNING: calculate_parsed_duration: Pre-parsed Column 13 value ('$RAW_DURATION_COL13') for EVENT='$current_event' is not numeric or missing. Setting DURATION to 0."
            DURATION="0"
        fi
    fi
    return 0 # Success
}

# Checks video name consistency for a given key.
# It compares the newly parsed 'current_video_name' with the video name
# already stored in IP_TABLE (which represents the *first* video name
# associated with this key).
# This function is primarily for logging purposes to detect if a client (key)
# starts playing a different video.
# Args: $1 current_key
#       $2 current_video_name (the video name from the current log line)
function check_video_consistency() {
    local current_key="$1"
    local current_video_name="$2"
    local old_video=""

    if [[ "${IP_TABLE["$current_key"]}" =~ (video:[^,]+) ]]; then
        old_video="${BASH_REMATCH[1]#video:}"
    fi

    if [[ -n "$current_video_name" ]]; then
        if [[ -n "$old_video" ]]; then
            if [[ "$current_video_name" != "$old_video" ]]; then
                debug_log "check_video_consistency: ******************video mismatch for KEY=$current_key => old='$old_video', new='$current_video_name'"
            else
                debug_log "check_video_consistency: ******************video same for KEY=$current_key => video='$current_video_name'"
            fi
        else
            debug_log "check_video_consistency: ******************video newly assigned for KEY=$current_key => video='$current_video_name'"
        fi
    fi
}

# Updates the IP_TABLE entry for the given key.
# Appends the current event and duration.
# Crucially, for the video name, it follows the "first video name is kept" rule:
# The `video:VIDEO_NAME` string is added to IP_TABLE only if:
#   1. A `VIDEO_NAME` is parsed from the current event.
#   2. No `video:` entry already exists in IP_TABLE for this key.
# Subsequent changes to the video name for this key (detected by
# `check_video_consistency`) are logged but do *not* alter the original
# `video:VIDEO_NAME` entry in IP_TABLE.
#
# Args: $1 current_key
#       $2 current_event
    local current_duration="$3"
    local current_video_name="$4"

    local previous_data="${IP_TABLE[$current_key]}"
    local event_duration_string="$current_event:$current_duration"

    local existing_video_entry=""
    if [[ "$previous_data" =~ (video:[^,]+) ]]; then
        existing_video_entry="${BASH_REMATCH[1]}"
    fi

    local new_video_entry=""
    if [[ -n "$current_video_name" ]]; then
        new_video_entry="video:$current_video_name"
    fi

    if [[ -z "$previous_data" ]]; then
        if [[ -n "$new_video_entry" ]]; then
            IP_TABLE[$current_key]="$event_duration_string,$new_video_entry"
        else
            IP_TABLE[$current_key]="$event_duration_string"
        fi
    else
        local updated_data="$previous_data,$event_duration_string"
        # Add video entry only if it's new and wasn't there before
        if [[ -z "$existing_video_entry" && -n "$new_video_entry" ]]; then
            updated_data="$updated_data,$new_video_entry"
        # Or if there is an existing video entry but the new video entry is different
        # (This part might be redundant if check_video_consistency handles logging,
        # but ensures the table stores the LATEST video name if it changes, though
        # the design is to keep the first one if TARGET_MODE is not used for display)
        # For now, let's stick to adding if new_video_entry is present and no old one.
        # If an old one exists, it should have been there from a previous event.
        # The video name in IP_TABLE is more for display/TARGET_MODE than for state.
        fi
        IP_TABLE[$current_key]="$updated_data"
    fi
    debug_log "update_ip_table_entry: IP_TABLE[$current_key] => ${IP_TABLE[$current_key]}"
}


###############################################################################
# Main processing function for each log line
###############################################################################
function process_line() {
    local line="$1"
    debug_log "Raw line: $line"

    # Global vars set by parse_line_fields: RAW_EVENT, RAW_IP, RAW_CLIENT_ID_COL22, RAW_VIDEO_FIELD_COL8, RAW_DURATION_COL13
    # Global vars set by subsequent functions: EVENT, IP, CLIENT_ID, VIDEO_NAME, DURATION
    if ! parse_line_fields "$line"; then
        debug_log "ERROR: process_line: Skipping line due to error in parse_line_fields. Line: '$line'"
        return
    fi

    # process_parsed_event_ip uses RAW_EVENT and RAW_IP
    if ! process_parsed_event_ip; then # Reads globals RAW_EVENT, RAW_IP; Sets EVENT, IP
        debug_log "ERROR: process_line: Skipping line due to error in process_parsed_event_ip. Line: '$line'"
        return
    fi

    if [[ "$EVENT" == "comment" ]]; then
        debug_log "process_line: Skipping 'comment' line."
        return
    fi

    if contains_element "$IP" "$IGNORE_IPLIST"; then # IGNORE_IPLIST is global
        debug_log "process_line: Ignored IP: $IP. Skipping line."
        return
    fi

    # process_parsed_client_id uses RAW_CLIENT_ID_COL22 and original line for fallback
    if ! process_parsed_client_id "$line"; then # Reads global RAW_CLIENT_ID_COL22; Sets CLIENT_ID
        debug_log "ERROR: process_line: Skipping line due to error in process_parsed_client_id. Line: '$line'"
        return
    fi

    # SC2155: Declare and assign separately to avoid masking return values.
    local NOW
    NOW=$(date +%s)
    # process_parsed_video_name uses RAW_VIDEO_FIELD_COL8
    process_parsed_video_name "$EVENT" # Reads global RAW_VIDEO_FIELD_COL8; Sets VIDEO_NAME

    local KEY="$IP-$CLIENT_ID"
    debug_log "process_line: Constructed KEY='$KEY', VIDEO_NAME='$VIDEO_NAME'"

    # calculate_parsed_duration uses RAW_DURATION_COL13
    if ! calculate_parsed_duration "$EVENT" "$KEY" "$NOW"; then # Reads global RAW_DURATION_COL13; Sets DURATION
        debug_log "process_line: Skipping line based on calculate_parsed_duration status for KEY='$KEY', EVENT='$EVENT'."
        return
    fi

    check_video_consistency "$KEY" "$VIDEO_NAME" # Logs inconsistencies

    # Store last active & validate key (validate_key has side effects)
    LAST_ACTIVE["$KEY"]=$NOW
    validate_key "$KEY" # validate_key is global and uses print_table_header

    update_ip_table_entry "$KEY" "$EVENT" "$DURATION" "$VIDEO_NAME"

    # If debug, write IP_TABLE to file
    if $DEBUG_MODE; then
        {
            for k in "${!IP_TABLE[@]}"; do
                echo "$k: ${IP_TABLE[$k]}"
            done
        } > IP_TABLE.txt # IP_TABLE.txt is global
    fi
}

###############################################################################
# 13. Safe increment function
###############################################################################
function safe_increment_ip_count() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        debug_log "ERROR: safe_increment_ip_count: Attempted to increment count for an empty IP."
        return 1 # Indicate failure
    fi

    (( ip_count["$ip"]++ ))
    return 0 # Indicate success
}

###############################################################################
# 14. Main loop: tail the log, update, display
###############################################################################
LAST_REFRESH_TIME=$(date +%s)

# Check if log file exists and is readable
if [[ ! -f "$LOG_FILE_PATH" ]]; then
    echo "ERROR: Log file not found: $LOG_FILE_PATH"
    exit 1
elif [[ ! -r "$LOG_FILE_PATH" ]]; then
    echo "ERROR: Log file not readable: $LOG_FILE_PATH"
    exit 1
fi

debug_log "Tailing log file: $LOG_FILE_PATH"
tail -F "$LOG_FILE_PATH" |
while read -r line; do
    process_line "$line" # Processes the line and updates IP_TABLE, LAST_ACTIVE etc.

    CURRENT_TIMESTAMP=$(date +%s) # Renamed NOW to CURRENT_TIMESTAMP to avoid conflict if process_line used NOW

    # Remove idle or disconnected clients.
    for k in "${!LAST_ACTIVE[@]}"; do
        # SC2168: 'local' is not valid in the main script body here.
        if (( CURRENT_TIMESTAMP - LAST_ACTIVE[$k] > IDLE_TIME )); then
            idled_time=$(( CURRENT_TIMESTAMP - LAST_ACTIVE[$k] ))
            remove_client_and_refresh "$k" "MainLoop: Removing $k (IDLED $idled_time seconds)"
        elif [[ ${IP_TABLE["$k"]} =~ disconnect: ]] && (( CURRENT_TIMESTAMP - LAST_ACTIVE[$k] > DISCONNECT_TIME )); then
            stopped_time=$(( CURRENT_TIMESTAMP - LAST_ACTIVE[$k] ))
            remove_client_and_refresh "$k" "MainLoop: Removing $k (marked as disconnect, $stopped_time seconds idle post-disconnect)"
        fi
    done

    # Time-based display refresh
    if (( CURRENT_TIMESTAMP - LAST_REFRESH_TIME > DISPLAY_UPDATE_INTERVAL )); then
        debug_log "MainLoop: Refreshing display. NOW=$CURRENT_TIMESTAMP, LAST_REFRESH_TIME=$LAST_REFRESH_TIME"

        echo -en "\e[3;1H"

        # SC2207: Prefer mapfile or read -a to split command output.
        mapfile -t sorted_keys < <(printf '%s\n' "${!IP_TABLE[@]}" | sort)

        unset ip_count # Reset ip_count for fresh counting
        declare -A ip_count

        # Count how many unique client IDs per IP
        for entry_key in "${sorted_keys[@]}"; do
            ip="${entry_key%%-*}"
            if ! safe_increment_ip_count "$ip"; then
                continue
            fi
        done

        # Iterate through sorted keys and print table rows
        for entry_key in "${sorted_keys[@]}"; do
            if $DEBUG_MODE; then
                # This appends to ADDR.txt on each refresh, maybe too much?
                # Consider if this should be less frequent or cleared.
                echo "$entry_key: ${IP_TABLE[$entry_key]}" >> ADDR.txt
            fi

            IFS=',' read -ra parts <<< "${IP_TABLE[$entry_key]}"
            DISPLAY_IP="${entry_key%%-*}"
            CLIENT_ID="${entry_key##*-}"

            CREATE="" PLAY="" SEEK="" STOP="" DESTROY="" DISCONNECT="" VIDEO_NAME=""

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
            COLOR=""
            RESET_COLOR=""

            if (( connection_count > 1 )); then
                if [[ -z "${IP_COLORS[$DISPLAY_IP]}" ]]; then
                    IP_COLORS[$DISPLAY_IP]="${COLOR_CODES[$(( COLOR_INDEX % NUM_COLORS ))]}"
                    debug_log "MainLoop: Assigned Color: ${IP_COLORS[$DISPLAY_IP]} to IP: $DISPLAY_IP"
                    (( COLOR_INDEX++ ))
                fi
                COLOR="${IP_COLORS[$DISPLAY_IP]}"
                RESET_COLOR="\e[0m"
            fi

            # Ensure output below header. If header is 2 lines, data starts at 3.
            # The \e[3;1H at start of refresh block handles cursor positioning.

            # SC2059: Using variables in printf format string.
            # Construct the format string dynamically if color is needed.
            # PRINTF_FORMAT already ends with \n, so color codes should wrap content before \n.
            # For simplicity, the current approach of direct concatenation is kept,
            # but with printf --. A more robust way is to build the format string carefully.
            # current_printf_format="$PRINTF_FORMAT" # Default
            # if [[ -n "$COLOR" ]]; then
            #    current_printf_format="${COLOR}${PRINTF_FORMAT%\\n}${RESET_COLOR}\n"
            # fi
            # For now, will use the simpler concatenation with -- for printf
            # This was a complex change, keeping it simple for now:
            if (( connection_count > 1 )); then
                printf -- "${COLOR}${PRINTF_FORMAT}${RESET_COLOR}" \
                       "$DISPLAY_IP" "$CONNECT_FIELD" "$CREATE" "$PLAY" "$SEEK" "$STOP" "$DESTROY" "$DISCONNECT"
            else
                printf -- "$PRINTF_FORMAT" \
                       "$DISPLAY_IP" "$CONNECT_FIELD" "$CREATE" "$PLAY" "$SEEK" "$STOP" "$DESTROY" "$DISCONNECT"
            fi
        done
        echo -en "\e[J"
        LAST_REFRESH_TIME=$CURRENT_TIMESTAMP
    fi
done
