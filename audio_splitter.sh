#!/bin/bash

# Audio File Splitter with Metadata Support
# Splits audio files based on JSON-defined split points with metadata tagging

set -euo pipefail

VERSION="1.0.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
INPUT_FILE=""
SPLITS_FILE=""
OUTPUT_DIR=""
SPLIT_MODE="start_to_next"
NAMING_PATTERN="%n - %t"
VERBOSE=false

# Function to print usage
print_usage() {
    cat << EOF
Audio File Splitter v${VERSION}

Usage: $0 [OPTIONS]

Options:
    -i, --input FILE        Input audio file (mp3, opus, wav, or flac)
    -s, --splits FILE       JSON file containing split points and metadata
    -o, --output DIR        Output directory (default: same as input file)
    -m, --mode MODE         Split mode: start_to_end, start_to_next, or start_duration
                            (default: start_to_next)
    -p, --pattern PATTERN   File naming pattern (default: "%n - %t")
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

File Naming Patterns (EasyTag-style):
    %a  Artist
    %A  Album Artist
    %b  Album
    %c  Comment
    %C  Composer
    %d  Disc Number
    %D  Total Discs
    %g  Genre
    %l  Label/Publisher
    %n  Track Number
    %N  Total Tracks
    %p  Performer
    %t  Title
    %y  Year
    %%  Literal %

JSON Split File Format:
    {
        "splits": [
            {
                "timestamp": "00:00:00",
                "duration": "3:45",          // Optional, only for start_duration mode
                "metadata": {
                    "title": "Track Title",
                    "track": "1",
                    "artist": "Artist Name",
                    "album": "Album Name",
                    "albumartist": "Album Artist",
                    "composer": "Composer Name",
                    "performer": "Performer Name",
                    "year": "2024",
                    "date": "2024-01-15",
                    "genre": "Genre",
                    "comment": "Comment",
                    "publisher": "Label Name",
                    "isrc": "USRC12345678",
                    "catalog": "CAT-001",
                    "discnumber": "1",
                    "totaldiscs": "2",
                    "totaltracks": "12",
                    "copyright": "Copyright Info"
                }
            }
        ]
    }

Examples:
    $0 -i input.flac -s splits.json
    $0 -i audio.opus -s splits.json -o ./output -m start_to_end
    $0 -i recording.wav -s splits.json -p "%n. %a - %t" -v

EOF
}

# Function for verbose logging
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Function for info messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Function for warning messages
log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Function for error messages
log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    for cmd in ffmpeg ffprobe jq bc; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install them before running this script"
        exit 1
    fi
}

# Function to convert timestamp to seconds
timestamp_to_seconds() {
    local timestamp="$1"
    
    # Handle HH:MM:SS, MM:SS, or SS formats
    local hours=0
    local minutes=0
    local seconds=0
    
    IFS=':' read -ra parts <<< "$timestamp"
    
    case ${#parts[@]} in
        3)
            hours=${parts[0]}
            minutes=${parts[1]}
            seconds=${parts[2]}
            ;;
        2)
            minutes=${parts[0]}
            seconds=${parts[1]}
            ;;
        1)
            seconds=${parts[0]}
            ;;
        *)
            log_error "Invalid timestamp format: $timestamp"
            exit 1
            ;;
    esac
    
    echo "scale=3; ($hours * 3600) + ($minutes * 60) + $seconds" | bc
}

# Function to get audio file duration
get_audio_duration() {
    local file="$1"
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file"
}

# Function to validate JSON structure
validate_json() {
    local json_file="$1"
    
    log_verbose "Validating JSON structure..."
    
    if ! jq empty "$json_file" 2>/dev/null; then
        log_error "Invalid JSON format in $json_file"
        exit 1
    fi
    
    if ! jq -e '.splits' "$json_file" &>/dev/null; then
        log_error "JSON file must contain a 'splits' array"
        exit 1
    fi
    
    local split_count=$(jq '.splits | length' "$json_file")
    if [ "$split_count" -eq 0 ]; then
        log_error "No splits defined in JSON file"
        exit 1
    fi
    
    log_verbose "JSON validation passed: $split_count splits found"
}

# Function to validate split points
validate_splits() {
    local json_file="$1"
    local audio_duration="$2"
    
    log_verbose "Validating split points..."
    
    local split_count=$(jq '.splits | length' "$json_file")
    local prev_timestamp=0
    
    for ((i=0; i<split_count; i++)); do
        local timestamp=$(jq -r ".splits[$i].timestamp" "$json_file")
        local seconds=$(timestamp_to_seconds "$timestamp")
        
        # Check chronological order
        if (( $(echo "$seconds < $prev_timestamp" | bc -l) )); then
            log_error "Split points are not in chronological order at index $i"
            exit 1
        fi
        
        # Check if timestamp exceeds duration
        if (( $(echo "$seconds > $audio_duration" | bc -l) )); then
            log_error "Split point $timestamp exceeds audio duration at index $i"
            exit 1
        fi
        
        prev_timestamp=$seconds
        log_verbose "Split $((i+1)): $timestamp (${seconds}s) - OK"
    done
    
    log_info "All split points validated successfully"
}

# Function to determine output format
determine_output_format() {
    local input_file="$1"
    local extension="${input_file##*.}"
    extension=$(echo "$extension" | tr '[:upper:]' '[:lower:]')
    
    case "$extension" in
        opus)
            echo "opus"
            ;;
        wav)
            echo "flac"
            ;;
        flac)
            echo "flac"
            ;;
        mp3)
            echo "mp3"
            ;;
        *)
            log_error "Unsupported input format: $extension"
            exit 1
            ;;
    esac
}

# Function to get codec parameters for output
get_codec_params() {
    local input_file="$1"
    local output_format="$2"
    
    case "$output_format" in
        flac)
            echo "-c:a flac -compression_level 8"
            ;;
        opus)
            # Match input bitrate for opus
            local bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$input_file")
            if [ -n "$bitrate" ] && [ "$bitrate" != "N/A" ]; then
                echo "-c:a libopus -b:a ${bitrate}"
            else
                echo "-c:a libopus -b:a 128k"
            fi
            ;;
        mp3)
            # Match input bitrate for mp3
            local bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$input_file")
            if [ -n "$bitrate" ] && [ "$bitrate" != "N/A" ]; then
                echo "-c:a libmp3lame -b:a ${bitrate}"
            else
                echo "-c:a libmp3lame -b:a 192k"
            fi
            ;;
        *)
            echo "-c:a copy"
            ;;
    esac
}

# Function to expand naming pattern
expand_pattern() {
    local pattern="$1"
    local -n metadata_ref=$2
    local track_num="$3"
    
    local result="$pattern"
    
    # Replace patterns with metadata values
    result="${result//%a/${metadata_ref[artist]:-}}"
    result="${result//%A/${metadata_ref[albumartist]:-}}"
    result="${result//%b/${metadata_ref[album]:-}}"
    result="${result//%c/${metadata_ref[comment]:-}}"
    result="${result//%C/${metadata_ref[composer]:-}}"
    result="${result//%d/${metadata_ref[discnumber]:-}}"
    result="${result//%D/${metadata_ref[totaldiscs]:-}}"
    result="${result//%g/${metadata_ref[genre]:-}}"
    result="${result//%l/${metadata_ref[publisher]:-}}"
    result="${result//%n/${metadata_ref[track]:-$track_num}}"
    result="${result//%N/${metadata_ref[totaltracks]:-}}"
    result="${result//%p/${metadata_ref[performer]:-}}"
    result="${result//%t/${metadata_ref[title]:-Track $track_num}}"
    result="${result//%y/${metadata_ref[year]:-}}"
    result="${result//%%/%}"
    
    # Remove any double spaces and trim
    result=$(echo "$result" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    
    # Sanitize filename (remove/replace invalid characters)
    result=$(echo "$result" | sed 's/[\/\\:*?"<>|]/_/g')
    
    echo "$result"
}

# Function to build metadata arguments for ffmpeg
build_metadata_args() {
    local -n metadata_ref=$1
    local args=""
    
    [ -n "${metadata_ref[title]:-}" ] && args="$args -metadata title=\"${metadata_ref[title]}\""
    [ -n "${metadata_ref[artist]:-}" ] && args="$args -metadata artist=\"${metadata_ref[artist]}\""
    [ -n "${metadata_ref[album]:-}" ] && args="$args -metadata album=\"${metadata_ref[album]}\""
    [ -n "${metadata_ref[albumartist]:-}" ] && args="$args -metadata album_artist=\"${metadata_ref[albumartist]}\""
    [ -n "${metadata_ref[composer]:-}" ] && args="$args -metadata composer=\"${metadata_ref[composer]}\""
    [ -n "${metadata_ref[performer]:-}" ] && args="$args -metadata performer=\"${metadata_ref[performer]}\""
    [ -n "${metadata_ref[track]:-}" ] && args="$args -metadata track=\"${metadata_ref[track]}\""
    [ -n "${metadata_ref[year]:-}" ] && args="$args -metadata date=\"${metadata_ref[year]}\""
    [ -n "${metadata_ref[date]:-}" ] && args="$args -metadata date=\"${metadata_ref[date]}\""
    [ -n "${metadata_ref[genre]:-}" ] && args="$args -metadata genre=\"${metadata_ref[genre]}\""
    [ -n "${metadata_ref[comment]:-}" ] && args="$args -metadata comment=\"${metadata_ref[comment]}\""
    [ -n "${metadata_ref[publisher]:-}" ] && args="$args -metadata publisher=\"${metadata_ref[publisher]}\""
    [ -n "${metadata_ref[isrc]:-}" ] && args="$args -metadata isrc=\"${metadata_ref[isrc]}\""
    [ -n "${metadata_ref[catalog]:-}" ] && args="$args -metadata catalog=\"${metadata_ref[catalog]}\""
    [ -n "${metadata_ref[discnumber]:-}" ] && args="$args -metadata disc=\"${metadata_ref[discnumber]}\""
    [ -n "${metadata_ref[totaldiscs]:-}" ] && args="$args -metadata totaldiscs=\"${metadata_ref[totaldiscs]}\""
    [ -n "${metadata_ref[totaltracks]:-}" ] && args="$args -metadata totaltracks=\"${metadata_ref[totaltracks]}\""
    [ -n "${metadata_ref[copyright]:-}" ] && args="$args -metadata copyright=\"${metadata_ref[copyright]}\""
    
    echo "$args"
}

# Function to process splits
process_splits() {
    local input_file="$1"
    local splits_file="$2"
    local output_dir="$3"
    local split_mode="$4"
    local pattern="$5"
    
    local audio_duration=$(get_audio_duration "$input_file")
    local output_format=$(determine_output_format "$input_file")
    local codec_params=$(get_codec_params "$input_file" "$output_format")
    local split_count=$(jq '.splits | length' "$splits_file")
    
    log_info "Processing $split_count splits from $input_file"
    log_info "Audio duration: ${audio_duration}s"
    log_info "Output format: $output_format"
    log_verbose "Codec parameters: $codec_params"
    
    for ((i=0; i<split_count; i++)); do
        local track_num=$((i+1))
        log_info "Processing split $track_num of $split_count..."
        
        # Parse JSON for this split
        local split_data=$(jq ".splits[$i]" "$splits_file")
        local start_timestamp=$(echo "$split_data" | jq -r '.timestamp')
        local start_seconds=$(timestamp_to_seconds "$start_timestamp")
        
        log_verbose "Start timestamp: $start_timestamp (${start_seconds}s)"
        
        # Calculate duration based on mode
        local duration=""
        case "$split_mode" in
            start_to_next)
                if [ $((i+1)) -lt $split_count ]; then
                    local next_timestamp=$(jq -r ".splits[$((i+1))].timestamp" "$splits_file")
                    local next_seconds=$(timestamp_to_seconds "$next_timestamp")
                    duration=$(echo "scale=3; $next_seconds - $start_seconds" | bc)
                else
                    duration=$(echo "scale=3; $audio_duration - $start_seconds" | bc)
                fi
                log_verbose "Duration (to next): ${duration}s"
                ;;
            start_to_end)
                duration=$(echo "scale=3; $audio_duration - $start_seconds" | bc)
                log_verbose "Duration (to end): ${duration}s"
                ;;
            start_duration)
                local duration_str=$(echo "$split_data" | jq -r '.duration // empty')
                if [ -z "$duration_str" ]; then
                    log_error "Split $track_num: duration not specified for start_duration mode"
                    exit 1
                fi
                duration=$(timestamp_to_seconds "$duration_str")
                log_verbose "Duration (specified): ${duration}s"
                ;;
        esac
        
        # Parse metadata
        declare -A metadata
        metadata[title]=$(echo "$split_data" | jq -r '.metadata.title // empty')
        metadata[artist]=$(echo "$split_data" | jq -r '.metadata.artist // empty')
        metadata[album]=$(echo "$split_data" | jq -r '.metadata.album // empty')
        metadata[albumartist]=$(echo "$split_data" | jq -r '.metadata.albumartist // empty')
        metadata[composer]=$(echo "$split_data" | jq -r '.metadata.composer // empty')
        metadata[performer]=$(echo "$split_data" | jq -r '.metadata.performer // empty')
        metadata[track]=$(echo "$split_data" | jq -r '.metadata.track // empty')
        metadata[year]=$(echo "$split_data" | jq -r '.metadata.year // empty')
        metadata[date]=$(echo "$split_data" | jq -r '.metadata.date // empty')
        metadata[genre]=$(echo "$split_data" | jq -r '.metadata.genre // empty')
        metadata[comment]=$(echo "$split_data" | jq -r '.metadata.comment // empty')
        metadata[publisher]=$(echo "$split_data" | jq -r '.metadata.publisher // empty')
        metadata[isrc]=$(echo "$split_data" | jq -r '.metadata.isrc // empty')
        metadata[catalog]=$(echo "$split_data" | jq -r '.metadata.catalog // empty')
        metadata[discnumber]=$(echo "$split_data" | jq -r '.metadata.discnumber // empty')
        metadata[totaldiscs]=$(echo "$split_data" | jq -r '.metadata.totaldiscs // empty')
        metadata[totaltracks]=$(echo "$split_data" | jq -r '.metadata.totaltracks // empty')
        metadata[copyright]=$(echo "$split_data" | jq -r '.metadata.copyright // empty')
        
        # Generate output filename
        local filename=$(expand_pattern "$pattern" metadata "$track_num")
        [ -z "$filename" ] && filename="$track_num"
        local output_file="${output_dir}/${filename}.${output_format}"
        
        log_verbose "Output file: $output_file"
        
        # Build metadata arguments
        local metadata_args=$(build_metadata_args metadata)
        
        # Build ffmpeg command
        local ffmpeg_cmd="ffmpeg -y -i \"$input_file\" -ss $start_seconds -t $duration"
        ffmpeg_cmd="$ffmpeg_cmd $codec_params $metadata_args"
        ffmpeg_cmd="$ffmpeg_cmd \"$output_file\""
        
        if [ "$VERBOSE" = true ]; then
            log_verbose "FFmpeg command: $ffmpeg_cmd"
            eval $ffmpeg_cmd
        else
            eval $ffmpeg_cmd 2>&1 | grep -v "^frame=" | grep -v "^size=" || true
        fi
        
        if [ $? -eq 0 ]; then
            log_info "✓ Created: $filename.$output_format"
        else
            log_error "✗ Failed to create split $track_num"
            exit 1
        fi
    done
    
    log_info "All splits completed successfully!"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input)
            INPUT_FILE="$2"
            shift 2
            ;;
        -s|--splits)
            SPLITS_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -m|--mode)
            SPLIT_MODE="$2"
            shift 2
            ;;
        -p|--pattern)
            NAMING_PATTERN="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    echo "Audio File Splitter v${VERSION}"
    echo "================================"
    echo
    
    # Check dependencies
    check_dependencies
    
    # Validate required arguments
    if [ -z "$INPUT_FILE" ] || [ -z "$SPLITS_FILE" ]; then
        log_error "Input file and splits file are required"
        print_usage
        exit 1
    fi
    
    # Validate files exist
    if [ ! -f "$INPUT_FILE" ]; then
        log_error "Input file not found: $INPUT_FILE"
        exit 1
    fi
    
    if [ ! -f "$SPLITS_FILE" ]; then
        log_error "Splits file not found: $SPLITS_FILE"
        exit 1
    fi
    
    # Set output directory
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR=$(dirname "$INPUT_FILE")
        log_verbose "Using default output directory: $OUTPUT_DIR"
    fi
    
    # Create output directory if it doesn't exist
    mkdir -p "$OUTPUT_DIR"
    
    # Validate split mode
    case "$SPLIT_MODE" in
        start_to_next|start_to_end|start_duration)
            log_verbose "Split mode: $SPLIT_MODE"
            ;;
        *)
            log_error "Invalid split mode: $SPLIT_MODE"
            log_error "Valid modes: start_to_next, start_to_end, start_duration"
            exit 1
            ;;
    esac
    
    # Validate JSON
    validate_json "$SPLITS_FILE"
    
    # Get audio duration and validate splits
    local audio_duration=$(get_audio_duration "$INPUT_FILE")
    validate_splits "$SPLITS_FILE" "$audio_duration"
    
    # Process splits
    process_splits "$INPUT_FILE" "$SPLITS_FILE" "$OUTPUT_DIR" "$SPLIT_MODE" "$NAMING_PATTERN"
}

# Run main function
main
