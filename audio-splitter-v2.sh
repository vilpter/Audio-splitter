#!/bin/bash

# Audio Splitter with Metadata
# Version: 2.0 - Uses Python for JSON parsing (no jq required)

set -euo pipefail

# Find script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Config
CONFIG_FILE="${HOME}/.audio-splitter.conf"
INPUT_FILE=""
SPLITS_FILE=""
OUTPUT_DIR=""
OUTPUT_FORMAT="auto"
NAMING_PATTERN="%t"
QUIET_MODE=false
DRY_RUN=false

print_info() { [[ "$QUIET_MODE" == "false" ]] && echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { [[ "$QUIET_MODE" == "false" ]] && echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_dependencies() {
    local missing_deps=()
    command -v ffmpeg &>/dev/null || missing_deps+=("ffmpeg")
    command -v python3 &>/dev/null || missing_deps+=("python3")
    command -v ffprobe &>/dev/null || missing_deps+=("ffprobe")
    command -v bc &>/dev/null || missing_deps+=("bc")
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing: ${missing_deps[*]}"
        echo "Install with: sudo apt-get install ${missing_deps[*]}"
        exit 1
    fi
    
    if [ ! -f "$SCRIPT_DIR/json-parser.py" ]; then
        print_error "json-parser.py not found in $SCRIPT_DIR"
        exit 1
    fi
}

timestamp_to_seconds() {
    local ts="$1"
    local h=0 m=0 s=0
    
    if [[ "$ts" =~ ^([0-9]+):([0-9]+):([0-9.]+)$ ]]; then
        h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" s="${BASH_REMATCH[3]}"
    elif [[ "$ts" =~ ^([0-9]+):([0-9.]+)$ ]]; then
        m="${BASH_REMATCH[1]}" s="${BASH_REMATCH[2]}"
    elif [[ "$ts" =~ ^([0-9.]+)$ ]]; then
        s="${BASH_REMATCH[1]}"
    else
        print_error "Invalid timestamp: $ts"
        exit 1
    fi
    
    echo "scale=3; $h * 3600 + $m * 60 + $s" | bc
}

get_json_field() {
    python3 "$SCRIPT_DIR/json-parser.py" "$SPLITS_FILE" get_field "$1" "$2" 2>/dev/null || echo ""
}

validate_json() {
    if ! python3 "$SCRIPT_DIR/json-parser.py" "$SPLITS_FILE" validate &>/dev/null; then
        print_error "Invalid JSON in $SPLITS_FILE"
        exit 1
    fi
    
    local has_splits=$(python3 "$SCRIPT_DIR/json-parser.py" "$SPLITS_FILE" has_splits)
    if [ "$has_splits" != "true" ]; then
        print_error "JSON must contain a 'splits' array"
        exit 1
    fi
}

format_filename() {
    local pattern="$1" track="$2" title="$3" artist="$4" album="$5" year="$6"
    local result="$pattern"
    result="${result//%n/$track}"
    result="${result//%t/$title}"
    result="${result//%a/$artist}"
    result="${result//%A/$album}"
    result="${result//%y/$year}"
    echo "$result" | sed 's/[\/:\\*?"<>|]/_/g'
}

process_splits() {
    local input="$1" splits_json="$2" out_dir="$3" out_fmt="$4" pattern="$5"
    
    validate_json
    
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input")
    local input_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input")
    
    print_info "Duration: $duration s, Codec: $input_codec"
    
    # Determine output format
    local actual_fmt="$out_fmt"
    if [ "$out_fmt" == "auto" ]; then
        if [[ "$input_codec" =~ ^(flac|wav|alac|ape|wavpack)$ ]]; then
            actual_fmt="flac"
        else
            actual_fmt="$input_codec"
        fi
    fi
    
    local out_codec out_ext
    case "$actual_fmt" in
        flac) out_codec="flac"; out_ext="flac" ;;
        wav) out_codec="pcm_s16le"; out_ext="wav" ;;
        opus) out_codec="libopus"; out_ext="opus" ;;
        mp3) out_codec="libmp3lame"; out_ext="mp3" ;;
        *) out_codec="copy"; out_ext="$actual_fmt" ;;
    esac
    
    local count=$(python3 "$SCRIPT_DIR/json-parser.py" "$splits_json" count)
    print_info "Processing $count split(s) to format: $actual_fmt"
    
    # Validate all timestamps are within duration
    for ((i=0; i<count; i++)); do
        local check_start=$(get_json_field $i start)
        local check_start_sec=$(timestamp_to_seconds "$check_start")
        
        if (( $(echo "$check_start_sec > $duration" | bc -l) )); then
            print_warning "Split $((i+1)) start time ($check_start) exceeds audio duration (${duration}s)"
        fi
        
        local check_end=$(get_json_field $i end)
        if [ -n "$check_end" ]; then
            local check_end_sec=$(timestamp_to_seconds "$check_end")
            if (( $(echo "$check_end_sec > $duration" | bc -l) )); then
                print_warning "Split $((i+1)) end time ($check_end) exceeds audio duration (${duration}s)"
            fi
        fi
    done
    
    for ((i=0; i<count; i++)); do
        local track=$((i+1))
        local start=$(get_json_field $i start)
        local start_sec=$(timestamp_to_seconds "$start")
        
        # Determine end time
        local end_sec=""
        local end_val=$(get_json_field $i end)
        local dur_val=$(get_json_field $i duration)
        
        if [ -n "$end_val" ]; then
            end_sec=$(timestamp_to_seconds "$end_val")
        elif [ -n "$dur_val" ]; then
            local dur_sec=$(timestamp_to_seconds "$dur_val")
            end_sec=$(echo "$start_sec + $dur_sec" | bc)
        else
            if ((i < count - 1)); then
                local next_start=$(get_json_field $((i+1)) start)
                end_sec=$(timestamp_to_seconds "$next_start")
            else
                end_sec="$duration"
            fi
        fi
        
        local split_dur=$(echo "$end_sec - $start_sec" | bc)
        
        # Get metadata
        local title=$(get_json_field $i title)
        local artist=$(get_json_field $i artist)
        local album=$(get_json_field $i album)
        local year=$(get_json_field $i year)
        local composer=$(get_json_field $i composer)
        local album_artist=$(get_json_field $i album_artist)
        local performer=$(get_json_field $i performer)
        local comment=$(get_json_field $i comment)
        
        # Generate filename
        local filename
        if [ -z "$title" ]; then
            filename="$track"
        else
            filename=$(format_filename "$pattern" "$track" "$title" "$artist" "$album" "$year")
        fi
        
        local output_file="${out_dir}/${filename}.${out_ext}"
        
        if [ -f "$output_file" ] && [ "$DRY_RUN" != "true" ]; then
            read -p "Overwrite $output_file? (y/n) [n]: " ow
            [[ ! "$ow" =~ ^[Yy]$ ]] && continue
        fi
        
        print_info "Track $track/$count: $filename"
        
        if [ "$DRY_RUN" == "true" ]; then
            echo "  Would create: $output_file (${split_dur}s)"
            continue
        fi
        
        # Build ffmpeg command
        local cmd="ffmpeg -y -v error -stats -i \"$input\" -ss $start_sec -t $split_dur"
        
        if [ "$out_codec" == "copy" ]; then
            cmd="$cmd -c copy"
        else
            cmd="$cmd -c:a $out_codec"
            [ "$actual_fmt" == "mp3" ] && cmd="$cmd -q:a 0"
            [ "$actual_fmt" == "opus" ] && cmd="$cmd -b:a 128k"
        fi
        
        # Add metadata
        [ -n "$title" ] && cmd="$cmd -metadata title=\"$title\""
        [ -n "$artist" ] && cmd="$cmd -metadata artist=\"$artist\""
        [ -n "$album" ] && cmd="$cmd -metadata album=\"$album\""
        [ -n "$year" ] && cmd="$cmd -metadata date=\"$year\""
        [ -n "$composer" ] && cmd="$cmd -metadata composer=\"$composer\""
        [ -n "$album_artist" ] && cmd="$cmd -metadata album_artist=\"$album_artist\""
        [ -n "$performer" ] && cmd="$cmd -metadata performer=\"$performer\""
        [ -n "$comment" ] && cmd="$cmd -metadata comment=\"$comment\""
        cmd="$cmd -metadata track=\"$track\""
        
        cmd="$cmd \"$output_file\""
        
        if [ "$QUIET_MODE" == "true" ]; then
            eval "$cmd" 2>&1 | grep -v "^size=" || true
        else
            eval "$cmd"
        fi
        
        print_success "Created: $(basename "$output_file")"
    done
    
    print_success "All splits complete!"
}

show_usage() {
    cat << EOF
Audio Splitter v2.0 - Python-based (no jq required)

Usage: $(basename "$0") [OPTIONS]

Options:
  -i, --input FILE      Input audio file
  -s, --splits FILE     JSON splits file
  -o, --output-dir DIR  Output directory
  -f, --format FORMAT   Output format (auto/flac/wav/opus/mp3)
  -p, --pattern PAT     Filename pattern (%n/%t/%a/%A/%y)
  -q, --quiet           Quiet mode
  -d, --dry-run         Dry run
  -h, --help            Show help
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--input) INPUT_FILE="$2"; shift 2 ;;
        -s|--splits) SPLITS_FILE="$2"; shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -f|--format) OUTPUT_FORMAT="$2"; shift 2 ;;
        -p|--pattern) NAMING_PATTERN="$2"; shift 2 ;;
        -q|--quiet) QUIET_MODE=true; shift ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_usage; exit 0 ;;
        *) print_error "Unknown: $1"; show_usage; exit 1 ;;
    esac
done

check_dependencies

if [ -z "$INPUT_FILE" ] || [ -z "$SPLITS_FILE" ]; then
    print_error "Required: -i and -s"
    show_usage
    exit 1
fi

[ ! -f "$INPUT_FILE" ] && { print_error "Input not found: $INPUT_FILE"; exit 1; }
[ ! -f "$SPLITS_FILE" ] && { print_error "Splits not found: $SPLITS_FILE"; exit 1; }

OUTPUT_DIR=${OUTPUT_DIR:-$(dirname "$INPUT_FILE")}
mkdir -p "$OUTPUT_DIR"

process_splits "$INPUT_FILE" "$SPLITS_FILE" "$OUTPUT_DIR" "$OUTPUT_FORMAT" "$NAMING_PATTERN"
