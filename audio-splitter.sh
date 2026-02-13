#!/bin/bash

# Audio Splitter with Metadata
# Splits audio files based on JSON split points or command-line definitions
# and applies metadata tags to the output files.
# Version: 2.0

set -euo pipefail

VERSION="2.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration file path
CONFIG_FILE="${HOME}/.audio-splitter.conf"

# Default values
DEFAULT_OUTPUT_DIR=""
DEFAULT_OUTPUT_FORMAT="auto"
DEFAULT_NAMING_PATTERN="%t"
DEFAULT_QUIET_MODE="false"
DEFAULT_DRY_RUN="false"

# Global variables
INPUT_FILE=""
SPLITS_FILE=""
OUTPUT_DIR=""
OUTPUT_FORMAT=""
NAMING_PATTERN=""
QUIET_MODE=false
DRY_RUN=false

# CLI split accumulation
CLI_SPLITS_JSON=""
CLI_SPLIT_COUNT=0

# Function to print colored messages
print_info() {
    if [[ "$QUIET_MODE" == "false" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

print_success() {
    if [[ "$QUIET_MODE" == "false" ]]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    fi
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()

    if ! command -v ffmpeg &> /dev/null; then
        missing_deps+=("ffmpeg")
    fi

    if ! command -v ffprobe &> /dev/null; then
        missing_deps+=("ffprobe")
    fi

    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi

    # jq only required when using JSON split files
    if [[ -n "$SPLITS_FILE" ]] && ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install the missing dependencies:"
        echo ""
        echo "On Ubuntu/Debian:"
        echo "  sudo apt-get install ffmpeg jq bc"
        echo ""
        echo "On Fedora/RHEL:"
        echo "  sudo dnf install ffmpeg jq bc"
        echo ""
        echo "On macOS (with Homebrew):"
        echo "  brew install ffmpeg jq bc"
        echo ""
        exit 1
    fi
}

# Function to load config file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Config file found: $CONFIG_FILE"
        echo ""
        echo "Current configuration:"
        cat "$CONFIG_FILE"
        echo ""
        read -p "Use this configuration? (y/n) [y]: " use_config
        use_config=${use_config:-y}

        if [[ "$use_config" =~ ^[Yy]$ ]]; then
            while IFS='=' read -r key value; do
                [[ "$key" =~ ^#.*$ ]] && continue
                [[ -z "$key" ]] && continue

                key=$(echo "$key" | xargs)
                value=$(echo "$value" | xargs)

                case "$key" in
                    OUTPUT_DIR) DEFAULT_OUTPUT_DIR="$value" ;;
                    OUTPUT_FORMAT) DEFAULT_OUTPUT_FORMAT="$value" ;;
                    NAMING_PATTERN) DEFAULT_NAMING_PATTERN="$value" ;;
                    QUIET_MODE) DEFAULT_QUIET_MODE="$value" ;;
                    DRY_RUN) DEFAULT_DRY_RUN="$value" ;;
                esac
            done < "$CONFIG_FILE"

            OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
            OUTPUT_FORMAT="$DEFAULT_OUTPUT_FORMAT"
            NAMING_PATTERN="$DEFAULT_NAMING_PATTERN"
            QUIET_MODE="$DEFAULT_QUIET_MODE"
            DRY_RUN="$DEFAULT_DRY_RUN"

            return 0
        fi
    fi
    return 1
}

# Function to create a sample config file
create_sample_config() {
    cat > "$CONFIG_FILE" << 'EOF'
# Audio Splitter Configuration File
# Edit values as needed. Leave blank to be prompted during execution.

# Output directory (leave blank for same directory as input file)
OUTPUT_DIR=

# Output format: auto, flac, wav, opus, mp3
OUTPUT_FORMAT=auto

# Naming pattern (EasyTag-style)
# %n=track, %t=title, %a=artist, %A=album artist, %b=album, %y=year,
# %C=composer, %g=genre, %p=performer, %l=publisher, %d=disc, %D=total discs
NAMING_PATTERN=%n - %t

# Quiet mode: true or false
QUIET_MODE=false

# Dry run mode: true or false
DRY_RUN=false
EOF
    print_success "Sample config file created at: $CONFIG_FILE"
    echo "Edit this file and run the script again."
}

# Function to get audio file info
get_audio_info() {
    local file="$1"
    local codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file")
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file")
    echo "$codec|$duration"
}

# Function to convert timestamp to seconds
timestamp_to_seconds() {
    local timestamp="$1"
    local hours=0
    local minutes=0
    local seconds=0

    if [[ "$timestamp" =~ ^([0-9]+):([0-9]+):([0-9.]+)$ ]]; then
        hours="${BASH_REMATCH[1]}"
        minutes="${BASH_REMATCH[2]}"
        seconds="${BASH_REMATCH[3]}"
    elif [[ "$timestamp" =~ ^([0-9]+):([0-9.]+)$ ]]; then
        minutes="${BASH_REMATCH[1]}"
        seconds="${BASH_REMATCH[2]}"
    elif [[ "$timestamp" =~ ^([0-9.]+)$ ]]; then
        seconds="${BASH_REMATCH[1]}"
    else
        print_error "Invalid timestamp format: $timestamp"
        exit 1
    fi

    echo "scale=3; $hours * 3600 + $minutes * 60 + $seconds" | bc
}

# Function to validate JSON and split points
validate_splits() {
    local splits_file="$1"
    local duration="$2"

    if ! jq empty "$splits_file" 2>/dev/null; then
        print_error "Invalid JSON in splits file: $splits_file"
        exit 1
    fi

    if ! jq -e '.splits' "$splits_file" > /dev/null 2>&1; then
        print_error "JSON must contain a 'splits' array"
        exit 1
    fi

    local prev_time=0
    local split_count=$(jq '.splits | length' "$splits_file")

    for ((i=0; i<split_count; i++)); do
        local start=$(jq -r ".splits[$i].start" "$splits_file")
        local start_seconds=$(timestamp_to_seconds "$start")

        if (( $(echo "$start_seconds < $prev_time" | bc -l) )); then
            print_error "Split points must be in chronological order (error at split $((i+1)))"
            exit 1
        fi

        if (( $(echo "$start_seconds > $duration" | bc -l) )); then
            print_error "Split point $((i+1)) ($start) exceeds audio duration"
            exit 1
        fi

        prev_time=$start_seconds
    done

    print_success "Split points validated successfully"
}

# Function to format filename based on pattern
# Accepts a JSON string as the split data to extract all metadata fields
format_filename() {
    local pattern="$1"
    local track="$2"
    local split_json="$3"

    # Extract all metadata fields from JSON
    local title=$(echo "$split_json" | jq -r '.title // empty')
    local artist=$(echo "$split_json" | jq -r '.artist // empty')
    local album=$(echo "$split_json" | jq -r '.album // empty')
    local album_artist=$(echo "$split_json" | jq -r '.album_artist // empty')
    local year=$(echo "$split_json" | jq -r '.year // .date // empty')
    local composer=$(echo "$split_json" | jq -r '.composer // empty')
    local genre=$(echo "$split_json" | jq -r '.genre // empty')
    local performer=$(echo "$split_json" | jq -r '.performer // .conductor // empty')
    local publisher=$(echo "$split_json" | jq -r '.publisher // .label // empty')
    local comment=$(echo "$split_json" | jq -r '.comment // empty')
    local disc_number=$(echo "$split_json" | jq -r '.disc_number // empty')
    local total_discs=$(echo "$split_json" | jq -r '.total_discs // empty')
    local total_tracks=$(echo "$split_json" | jq -r '.total_tracks // empty')

    local result="$pattern"

    # Replace EasyTag-style patterns (order matters: %% last to avoid double-replace)
    result="${result//%C/$composer}"
    result="${result//%D/$total_discs}"
    result="${result//%N/$total_tracks}"
    result="${result//%A/$album_artist}"
    result="${result//%n/$track}"
    result="${result//%t/${title:-Track $track}}"
    result="${result//%a/$artist}"
    result="${result//%b/$album}"
    result="${result//%c/$comment}"
    result="${result//%d/$disc_number}"
    result="${result//%g/$genre}"
    result="${result//%l/$publisher}"
    result="${result//%p/$performer}"
    result="${result//%y/$year}"
    result="${result//%%/%}"

    # Clean up empty pattern leftovers and extra spaces
    result=$(echo "$result" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

    # Remove invalid filename characters
    result=$(echo "$result" | sed 's/[\/:\\*?"<>|]/_/g')

    echo "$result"
}

# Function to build ffmpeg metadata options
build_metadata_options() {
    local json_split="$1"
    local track_num="$2"
    local options=""

    local title=$(echo "$json_split" | jq -r '.title // empty')
    local artist=$(echo "$json_split" | jq -r '.artist // empty')
    local album=$(echo "$json_split" | jq -r '.album // empty')
    local year=$(echo "$json_split" | jq -r '.year // .date // empty')
    local composer=$(echo "$json_split" | jq -r '.composer // empty')
    local album_artist=$(echo "$json_split" | jq -r '.album_artist // empty')
    local comment=$(echo "$json_split" | jq -r '.comment // empty')
    local genre=$(echo "$json_split" | jq -r '.genre // empty')
    local publisher=$(echo "$json_split" | jq -r '.publisher // .label // empty')
    local isrc=$(echo "$json_split" | jq -r '.isrc // empty')
    local catalog_number=$(echo "$json_split" | jq -r '.catalog_number // empty')
    local disc_number=$(echo "$json_split" | jq -r '.disc_number // empty')
    local total_discs=$(echo "$json_split" | jq -r '.total_discs // empty')
    local performer=$(echo "$json_split" | jq -r '.performer // .conductor // empty')
    local copyright=$(echo "$json_split" | jq -r '.copyright // empty')

    [[ -n "$title" ]] && options="$options -metadata title=\"$title\""
    [[ -n "$artist" ]] && options="$options -metadata artist=\"$artist\""
    [[ -n "$album" ]] && options="$options -metadata album=\"$album\""
    [[ -n "$year" ]] && options="$options -metadata date=\"$year\""
    [[ -n "$composer" ]] && options="$options -metadata composer=\"$composer\""
    [[ -n "$album_artist" ]] && options="$options -metadata album_artist=\"$album_artist\""
    [[ -n "$comment" ]] && options="$options -metadata comment=\"$comment\""
    [[ -n "$genre" ]] && options="$options -metadata genre=\"$genre\""
    [[ -n "$publisher" ]] && options="$options -metadata publisher=\"$publisher\""
    [[ -n "$isrc" ]] && options="$options -metadata isrc=\"$isrc\""
    [[ -n "$catalog_number" ]] && options="$options -metadata catalog_number=\"$catalog_number\""
    [[ -n "$performer" ]] && options="$options -metadata performer=\"$performer\""
    [[ -n "$copyright" ]] && options="$options -metadata copyright=\"$copyright\""

    if [[ -n "$disc_number" ]] && [[ -n "$total_discs" ]]; then
        options="$options -metadata disc=\"$disc_number/$total_discs\""
    elif [[ -n "$disc_number" ]]; then
        options="$options -metadata disc=\"$disc_number\""
    fi

    options="$options -metadata track=\"$track_num\""

    echo "$options"
}

# Function to determine output format
determine_output_format() {
    local input_codec="$1"
    local requested_format="$2"

    if [[ "$requested_format" == "auto" ]]; then
        if [[ "$input_codec" =~ ^(flac|wav|alac|ape|wavpack|pcm_s16le|pcm_s24le|pcm_s32le)$ ]]; then
            echo "flac"
        else
            echo "$input_codec"
        fi
    else
        echo "$requested_format"
    fi
}

# Function to get ffmpeg codec and extension for format
get_format_details() {
    local format="$1"

    case "$format" in
        flac)
            echo "flac|flac"
            ;;
        wav)
            echo "pcm_s16le|wav"
            ;;
        opus)
            echo "libopus|opus"
            ;;
        mp3)
            echo "libmp3lame|mp3"
            ;;
        *)
            echo "copy|$format"
            ;;
    esac
}

# Function to process splits from a JSON file
process_splits() {
    local input_file="$1"
    local splits_file="$2"
    local output_dir="$3"
    local output_format="$4"
    local naming_pattern="$5"

    # Get audio info
    local audio_info=$(get_audio_info "$input_file")
    local input_codec=$(echo "$audio_info" | cut -d'|' -f1)
    local duration=$(echo "$audio_info" | cut -d'|' -f2)

    print_info "Input codec: $input_codec"
    print_info "Duration: $duration seconds"

    # Validate splits
    validate_splits "$splits_file" "$duration"

    # Determine actual output format
    local actual_format=$(determine_output_format "$input_codec" "$output_format")
    print_info "Output format: $actual_format"

    # Get format details
    local format_details=$(get_format_details "$actual_format")
    local output_codec=$(echo "$format_details" | cut -d'|' -f1)
    local output_ext=$(echo "$format_details" | cut -d'|' -f2)

    # Get number of splits
    local split_count=$(jq '.splits | length' "$splits_file")
    print_info "Processing $split_count split(s)..."
    echo ""

    # Process each split
    for ((i=0; i<split_count; i++)); do
        local track_num=$((i+1))
        local split=$(jq -c ".splits[$i]" "$splits_file")

        # Get start time
        local start=$(echo "$split" | jq -r '.start')
        local start_seconds=$(timestamp_to_seconds "$start")

        # Determine end time: end field -> duration field -> next start -> end of file
        local end_seconds=""
        if echo "$split" | jq -e '.end' > /dev/null 2>&1; then
            local end=$(echo "$split" | jq -r '.end')
            end_seconds=$(timestamp_to_seconds "$end")
        elif echo "$split" | jq -e '.duration' > /dev/null 2>&1; then
            local dur=$(echo "$split" | jq -r '.duration')
            local dur_seconds=$(timestamp_to_seconds "$dur")
            end_seconds=$(echo "$start_seconds + $dur_seconds" | bc)
        else
            if ((i < split_count - 1)); then
                local next_start=$(jq -r ".splits[$((i+1))].start" "$splits_file")
                end_seconds=$(timestamp_to_seconds "$next_start")
            else
                end_seconds="$duration"
            fi
        fi

        local split_duration=$(echo "$end_seconds - $start_seconds" | bc)

        # Generate filename
        local title=$(echo "$split" | jq -r '.title // empty')
        local filename=""
        if [[ -z "$title" ]]; then
            filename="${track_num}"
        else
            filename=$(format_filename "$naming_pattern" "$track_num" "$split")
        fi

        local output_file="${output_dir}/${filename}.${output_ext}"

        # Check if file exists
        if [[ -f "$output_file" ]]; then
            read -p "File exists: $output_file. Overwrite? (y/n) [n]: " overwrite
            overwrite=${overwrite:-n}
            if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                print_warning "Skipping track $track_num"
                continue
            fi
        fi

        print_info "Processing track $track_num of $split_count: $filename"

        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  Would create: $output_file"
            echo "  Start: $start ($start_seconds s)"
            echo "  Duration: $split_duration s"
            continue
        fi

        # Build metadata options
        local metadata_opts=$(build_metadata_options "$split" "$track_num")

        # Build ffmpeg command
        local ffmpeg_cmd="ffmpeg -y -i \"$input_file\" -ss $start_seconds -t $split_duration"

        if [[ "$output_codec" == "copy" ]]; then
            ffmpeg_cmd="$ffmpeg_cmd -c copy"
        else
            ffmpeg_cmd="$ffmpeg_cmd -c:a $output_codec"

            if [[ "$actual_format" == "mp3" ]]; then
                ffmpeg_cmd="$ffmpeg_cmd -q:a 0"  # VBR highest quality
            elif [[ "$actual_format" == "opus" ]]; then
                ffmpeg_cmd="$ffmpeg_cmd -b:a 128k"
            fi
        fi

        ffmpeg_cmd="$ffmpeg_cmd $metadata_opts \"$output_file\""

        if [[ "$QUIET_MODE" == "true" ]]; then
            eval "$ffmpeg_cmd" -loglevel error
        else
            eval "$ffmpeg_cmd" -loglevel warning -stats
        fi

        print_success "Created: $output_file"
        echo ""
    done

    print_success "All splits processed successfully!"
}

# --- CLI split helpers ---

# Start a new CLI split entry. Writes the previous one (if any) to CLI_SPLITS_JSON.
cli_flush_split() {
    if [[ -n "${_cli_start:-}" ]]; then
        local obj="{\"start\":\"$_cli_start\""
        [[ -n "${_cli_end:-}" ]] && obj="$obj,\"end\":\"$_cli_end\""
        [[ -n "${_cli_duration:-}" ]] && obj="$obj,\"duration\":\"$_cli_duration\""
        [[ -n "${_cli_title:-}" ]] && obj="$obj,\"title\":$(jq -n --arg v "$_cli_title" '$v')"
        [[ -n "${_cli_artist:-}" ]] && obj="$obj,\"artist\":$(jq -n --arg v "$_cli_artist" '$v')"
        [[ -n "${_cli_album:-}" ]] && obj="$obj,\"album\":$(jq -n --arg v "$_cli_album" '$v')"
        [[ -n "${_cli_album_artist:-}" ]] && obj="$obj,\"album_artist\":$(jq -n --arg v "$_cli_album_artist" '$v')"
        [[ -n "${_cli_year:-}" ]] && obj="$obj,\"year\":$(jq -n --arg v "$_cli_year" '$v')"
        [[ -n "${_cli_composer:-}" ]] && obj="$obj,\"composer\":$(jq -n --arg v "$_cli_composer" '$v')"
        [[ -n "${_cli_genre:-}" ]] && obj="$obj,\"genre\":$(jq -n --arg v "$_cli_genre" '$v')"
        [[ -n "${_cli_performer:-}" ]] && obj="$obj,\"performer\":$(jq -n --arg v "$_cli_performer" '$v')"
        [[ -n "${_cli_publisher:-}" ]] && obj="$obj,\"publisher\":$(jq -n --arg v "$_cli_publisher" '$v')"
        [[ -n "${_cli_comment:-}" ]] && obj="$obj,\"comment\":$(jq -n --arg v "$_cli_comment" '$v')"
        [[ -n "${_cli_copyright:-}" ]] && obj="$obj,\"copyright\":$(jq -n --arg v "$_cli_copyright" '$v')"
        [[ -n "${_cli_isrc:-}" ]] && obj="$obj,\"isrc\":$(jq -n --arg v "$_cli_isrc" '$v')"
        [[ -n "${_cli_catalog:-}" ]] && obj="$obj,\"catalog_number\":$(jq -n --arg v "$_cli_catalog" '$v')"
        [[ -n "${_cli_disc_number:-}" ]] && obj="$obj,\"disc_number\":$(jq -n --arg v "$_cli_disc_number" '$v')"
        [[ -n "${_cli_total_discs:-}" ]] && obj="$obj,\"total_discs\":$(jq -n --arg v "$_cli_total_discs" '$v')"
        obj="$obj}"

        if [[ -z "$CLI_SPLITS_JSON" ]]; then
            CLI_SPLITS_JSON="$obj"
        else
            CLI_SPLITS_JSON="$CLI_SPLITS_JSON,$obj"
        fi
        CLI_SPLIT_COUNT=$((CLI_SPLIT_COUNT + 1))
    fi
}

cli_reset_split() {
    _cli_start=""
    _cli_end=""
    _cli_duration=""
    _cli_title=""
    _cli_artist=""
    _cli_album=""
    _cli_album_artist=""
    _cli_year=""
    _cli_composer=""
    _cli_genre=""
    _cli_performer=""
    _cli_publisher=""
    _cli_comment=""
    _cli_copyright=""
    _cli_isrc=""
    _cli_catalog=""
    _cli_disc_number=""
    _cli_total_discs=""
}

# Function to show usage
show_usage() {
    cat << EOF
Audio Splitter with Metadata - Version ${VERSION}

Usage: $(basename "$0") [OPTIONS]

Split definitions (choose one method):
  -s, --splits FILE         JSON file with split points
  --split TIMESTAMP         Start a CLI-defined split at TIMESTAMP
                            (repeat for multiple splits; see below)

General options:
  -i, --input FILE          Input audio file (required)
  -o, --output-dir DIR      Output directory (default: same as input)
  -f, --format FORMAT       Output format: auto, flac, wav, opus, mp3 (default: auto)
  -p, --pattern PATTERN     Filename pattern (default: %t)
  -q, --quiet               Quiet mode (minimal output)
  -d, --dry-run             Dry run (show what would be done)
  -c, --create-config       Create sample config file
  -h, --help                Show this help message

CLI split options (follow each --split):
  --end TIMESTAMP           End time for the current split
  --duration TIMESTAMP      Duration of the current split
  --title TEXT              Track title
  --artist TEXT             Track artist
  --album TEXT              Album name
  --album-artist TEXT       Album artist
  --year TEXT               Year or date
  --composer TEXT            Composer
  --genre TEXT              Genre
  --performer TEXT          Performer or conductor
  --publisher TEXT          Publisher or label
  --comment TEXT            Comment
  --copyright TEXT          Copyright info
  --isrc TEXT               ISRC code
  --catalog TEXT            Catalog number
  --disc-number TEXT        Disc number
  --total-discs TEXT        Total number of discs

Filename patterns (EasyTag-style):
  %n  Track number          %t  Title
  %a  Artist                %A  Album artist
  %b  Album                 %y  Year
  %C  Composer              %g  Genre
  %p  Performer             %l  Publisher
  %d  Disc number           %D  Total discs
  %N  Total tracks          %c  Comment
  %%  Literal %

Split end-time priority (per split):
  1. Explicit end time if provided
  2. Start + duration if provided
  3. Next split's start time
  4. End of audio file

Output format logic:
  auto (default):
    Lossless input (FLAC/WAV) -> FLAC output
    Lossy input (Opus/MP3)    -> same format as input
  -f mp3:
    Any input -> MP3 (VBR V0, highest quality)
  -f flac / wav / opus:
    Converts to specified format

Examples:
  # Using a JSON splits file
  $(basename "$0") -i input.flac -s splits.json
  $(basename "$0") -i input.wav -s splits.json -o ./output -f mp3

  # Using CLI-defined splits
  $(basename "$0") -i input.flac -o ./output \\
    --split 00:00:00 --end 00:03:45 --title "Opening" --artist "Orchestra" \\
    --split 00:03:45 --end 00:08:00 --title "Adagio" --artist "Orchestra" \\
    --split 00:08:00 --title "Finale" --artist "Orchestra"

  # Quick single extract to MP3
  $(basename "$0") -i concert.flac -f mp3 \\
    --split 00:15:00 --duration 00:05:00 --title "Encore"

  # Interactive mode
  $(basename "$0")

  # Create config file
  $(basename "$0") -c

EOF
}

# Main interactive prompt function
interactive_mode() {
    echo ""
    echo "======================================"
    echo "  Audio Splitter - Interactive Mode"
    echo "======================================"
    echo ""

    if [[ -z "$INPUT_FILE" ]]; then
        read -p "Input audio file: " INPUT_FILE
        if [[ ! -f "$INPUT_FILE" ]]; then
            print_error "Input file not found: $INPUT_FILE"
            exit 1
        fi
    fi

    if [[ -z "$SPLITS_FILE" ]]; then
        read -p "Splits JSON file: " SPLITS_FILE
        if [[ ! -f "$SPLITS_FILE" ]]; then
            print_error "Splits file not found: $SPLITS_FILE"
            exit 1
        fi
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        local default_dir=$(dirname "$INPUT_FILE")
        read -p "Output directory [$default_dir]: " OUTPUT_DIR
        OUTPUT_DIR=${OUTPUT_DIR:-$default_dir}
    fi

    mkdir -p "$OUTPUT_DIR"

    if [[ -z "$OUTPUT_FORMAT" ]] || [[ "$OUTPUT_FORMAT" == "auto" ]]; then
        read -p "Output format (auto/flac/wav/opus/mp3) [auto]: " OUTPUT_FORMAT
        OUTPUT_FORMAT=${OUTPUT_FORMAT:-auto}
    fi

    if [[ -z "$NAMING_PATTERN" ]]; then
        read -p "Filename pattern (%n=track, %t=title, %a=artist, %b=album, %y=year) [%t]: " NAMING_PATTERN
        NAMING_PATTERN=${NAMING_PATTERN:-%t}
    fi

    if [[ "$QUIET_MODE" == "false" ]]; then
        read -p "Quiet mode? (y/n) [n]: " quiet_input
        if [[ "$quiet_input" =~ ^[Yy]$ ]]; then
            QUIET_MODE=true
        fi
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
        read -p "Dry run? (y/n) [n]: " dryrun_input
        if [[ "$dryrun_input" =~ ^[Yy]$ ]]; then
            DRY_RUN=true
        fi
    fi

    echo ""
    print_info "Configuration summary:"
    echo "  Input: $INPUT_FILE"
    echo "  Splits: $SPLITS_FILE"
    echo "  Output dir: $OUTPUT_DIR"
    echo "  Format: $OUTPUT_FORMAT"
    echo "  Pattern: $NAMING_PATTERN"
    echo "  Quiet: $QUIET_MODE"
    echo "  Dry run: $DRY_RUN"
    echo ""

    read -p "Proceed? (y/n) [y]: " proceed
    proceed=${proceed:-y}
    if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
        print_info "Aborted by user"
        exit 0
    fi
}

# Parse command line arguments
parse_args() {
    cli_reset_split

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
            -o|--output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -f|--format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -p|--pattern)
                NAMING_PATTERN="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -c|--create-config)
                create_sample_config
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            # CLI split options
            --split)
                cli_flush_split
                cli_reset_split
                _cli_start="$2"
                shift 2
                ;;
            --end)
                _cli_end="$2"
                shift 2
                ;;
            --duration)
                _cli_duration="$2"
                shift 2
                ;;
            --title)
                _cli_title="$2"
                shift 2
                ;;
            --artist)
                _cli_artist="$2"
                shift 2
                ;;
            --album)
                _cli_album="$2"
                shift 2
                ;;
            --album-artist)
                _cli_album_artist="$2"
                shift 2
                ;;
            --year)
                _cli_year="$2"
                shift 2
                ;;
            --composer)
                _cli_composer="$2"
                shift 2
                ;;
            --genre)
                _cli_genre="$2"
                shift 2
                ;;
            --performer)
                _cli_performer="$2"
                shift 2
                ;;
            --publisher)
                _cli_publisher="$2"
                shift 2
                ;;
            --comment)
                _cli_comment="$2"
                shift 2
                ;;
            --copyright)
                _cli_copyright="$2"
                shift 2
                ;;
            --isrc)
                _cli_isrc="$2"
                shift 2
                ;;
            --catalog)
                _cli_catalog="$2"
                shift 2
                ;;
            --disc-number)
                _cli_disc_number="$2"
                shift 2
                ;;
            --total-discs)
                _cli_total_discs="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Flush the last CLI split if any
    cli_flush_split
}

# Main function
main() {
    # Parse command line arguments first (before dependency check, so --help works)
    parse_args "$@"

    # Check dependencies
    check_dependencies

    # Error if both JSON and CLI splits provided
    if [[ -n "$SPLITS_FILE" ]] && [[ $CLI_SPLIT_COUNT -gt 0 ]]; then
        print_error "Cannot use both -s/--splits and --split. Choose one method."
        exit 1
    fi

    # If CLI splits were defined, write them to a temp JSON file
    local tmp_splits=""
    if [[ $CLI_SPLIT_COUNT -gt 0 ]]; then
        tmp_splits=$(mktemp /tmp/audio-splitter-XXXXXX.json)
        echo "{\"splits\":[$CLI_SPLITS_JSON]}" > "$tmp_splits"
        SPLITS_FILE="$tmp_splits"
    fi

    # Try to load config file
    config_loaded=false
    if load_config; then
        config_loaded=true
    fi

    # If not all required args provided, go interactive
    if [[ -z "$INPUT_FILE" ]] || [[ -z "$SPLITS_FILE" ]]; then
        interactive_mode
    else
        OUTPUT_DIR=${OUTPUT_DIR:-$(dirname "$INPUT_FILE")}
        OUTPUT_FORMAT=${OUTPUT_FORMAT:-auto}
        NAMING_PATTERN=${NAMING_PATTERN:-%t}
    fi

    # Create output directory if needed
    mkdir -p "$OUTPUT_DIR"

    # Process the splits
    process_splits "$INPUT_FILE" "$SPLITS_FILE" "$OUTPUT_DIR" "$OUTPUT_FORMAT" "$NAMING_PATTERN"

    # Clean up temp file
    if [[ -n "$tmp_splits" ]] && [[ -f "$tmp_splits" ]]; then
        rm -f "$tmp_splits"
    fi
}

# Run main function with all arguments
main "$@"
