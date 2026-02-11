#!/bin/bash

# Audio Splitter with Metadata
# Splits audio files based on JSON split points and applies metadata
# Version: 1.0

set -euo pipefail

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
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v ffprobe &> /dev/null; then
        missing_deps+=("ffprobe")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Please install the missing dependencies:"
        echo ""
        echo "On Ubuntu/Debian:"
        echo "  sudo apt-get install ffmpeg jq"
        echo ""
        echo "On Fedora/RHEL:"
        echo "  sudo dnf install ffmpeg jq"
        echo ""
        echo "On macOS (with Homebrew):"
        echo "  brew install ffmpeg jq"
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
            # Source the config file
            while IFS='=' read -r key value; do
                # Skip comments and empty lines
                [[ "$key" =~ ^#.*$ ]] && continue
                [[ -z "$key" ]] && continue
                
                # Remove leading/trailing whitespace
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
            
            # Set global variables from config
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
# %n = track number, %t = title, %a = artist, %A = album, %y = year
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
    
    # Handle different timestamp formats
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
    
    # Check if file exists and is valid JSON
    if ! jq empty "$splits_file" 2>/dev/null; then
        print_error "Invalid JSON in splits file: $splits_file"
        exit 1
    fi
    
    # Check if splits array exists
    if ! jq -e '.splits' "$splits_file" > /dev/null 2>&1; then
        print_error "JSON must contain a 'splits' array"
        exit 1
    fi
    
    # Validate timestamps are in chronological order
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
format_filename() {
    local pattern="$1"
    local track="$2"
    local title="$3"
    local artist="$4"
    local album="$5"
    local year="$6"
    
    local result="$pattern"
    
    # Replace EasyTag-style patterns
    result="${result//%n/$track}"
    result="${result//%t/$title}"
    result="${result//%a/$artist}"
    result="${result//%A/$album}"
    result="${result//%y/$year}"
    
    # Remove any remaining invalid filename characters
    result=$(echo "$result" | sed 's/[\/:\\*?"<>|]/_/g')
    
    echo "$result"
}

# Function to build ffmpeg metadata options
build_metadata_options() {
    local json_split="$1"
    local track_num="$2"
    local options=""
    
    # Core metadata fields
    local title=$(echo "$json_split" | jq -r '.title // empty')
    local artist=$(echo "$json_split" | jq -r '.artist // empty')
    local album=$(echo "$json_split" | jq -r '.album // empty')
    local year=$(echo "$json_split" | jq -r '.year // .date // empty')
    local composer=$(echo "$json_split" | jq -r '.composer // empty')
    local album_artist=$(echo "$json_split" | jq -r '.album_artist // empty')
    local comment=$(echo "$json_split" | jq -r '.comment // empty')
    
    # Additional optional metadata fields
    local genre=$(echo "$json_split" | jq -r '.genre // empty')
    local publisher=$(echo "$json_split" | jq -r '.publisher // .label // empty')
    local isrc=$(echo "$json_split" | jq -r '.isrc // empty')
    local catalog_number=$(echo "$json_split" | jq -r '.catalog_number // empty')
    local disc_number=$(echo "$json_split" | jq -r '.disc_number // empty')
    local total_discs=$(echo "$json_split" | jq -r '.total_discs // empty')
    local performer=$(echo "$json_split" | jq -r '.performer // .conductor // empty')
    local copyright=$(echo "$json_split" | jq -r '.copyright // empty')
    
    # Add metadata options if values exist
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
    
    # Handle disc information
    if [[ -n "$disc_number" ]] && [[ -n "$total_discs" ]]; then
        options="$options -metadata disc=\"$disc_number/$total_discs\""
    elif [[ -n "$disc_number" ]]; then
        options="$options -metadata disc=\"$disc_number\""
    fi
    
    # Always add track number
    options="$options -metadata track=\"$track_num\""
    
    echo "$options"
}

# Function to determine output format
determine_output_format() {
    local input_codec="$1"
    local requested_format="$2"
    
    if [[ "$requested_format" == "auto" ]]; then
        # If input is lossless, output FLAC
        if [[ "$input_codec" =~ ^(flac|wav|alac|ape|wavpack)$ ]]; then
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

# Function to process splits
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
        
        # Get start time and duration
        local start=$(echo "$split" | jq -r '.start')
        local start_seconds=$(timestamp_to_seconds "$start")
        
        # Determine end time
        local end_seconds=""
        if echo "$split" | jq -e '.end' > /dev/null 2>&1; then
            local end=$(echo "$split" | jq -r '.end')
            end_seconds=$(timestamp_to_seconds "$end")
        elif echo "$split" | jq -e '.duration' > /dev/null 2>&1; then
            local dur=$(echo "$split" | jq -r '.duration')
            local dur_seconds=$(timestamp_to_seconds "$dur")
            end_seconds=$(echo "$start_seconds + $dur_seconds" | bc)
        else
            # Use next split's start time or end of file
            if ((i < split_count - 1)); then
                local next_start=$(jq -r ".splits[$((i+1))].start" "$splits_file")
                end_seconds=$(timestamp_to_seconds "$next_start")
            else
                end_seconds="$duration"
            fi
        fi
        
        local split_duration=$(echo "$end_seconds - $start_seconds" | bc)
        
        # Get metadata for filename
        local title=$(echo "$split" | jq -r '.title // empty')
        local artist=$(echo "$split" | jq -r '.artist // empty')
        local album=$(echo "$split" | jq -r '.album // empty')
        local year=$(echo "$split" | jq -r '.year // .date // empty')
        
        # Generate filename
        local filename=""
        if [[ -z "$title" ]]; then
            filename="${track_num}"
        else
            filename=$(format_filename "$naming_pattern" "$track_num" "$title" "$artist" "$album" "$year")
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
        
        # Add codec options
        if [[ "$output_codec" == "copy" ]]; then
            ffmpeg_cmd="$ffmpeg_cmd -c copy"
        else
            ffmpeg_cmd="$ffmpeg_cmd -c:a $output_codec"
            
            # Add quality settings for lossy formats
            if [[ "$actual_format" == "mp3" ]]; then
                ffmpeg_cmd="$ffmpeg_cmd -q:a 0"  # VBR highest quality
            elif [[ "$actual_format" == "opus" ]]; then
                ffmpeg_cmd="$ffmpeg_cmd -b:a 128k"
            fi
        fi
        
        # Add metadata and output file
        ffmpeg_cmd="$ffmpeg_cmd $metadata_opts \"$output_file\""
        
        # Execute ffmpeg
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

# Function to show usage
show_usage() {
    cat << EOF
Audio Splitter with Metadata - Version 1.0

Usage: $(basename "$0") [OPTIONS]

Options:
  -i, --input FILE          Input audio file (required)
  -s, --splits FILE         JSON file with split points (required)
  -o, --output-dir DIR      Output directory (default: same as input)
  -f, --format FORMAT       Output format: auto, flac, wav, opus, mp3 (default: auto)
  -p, --pattern PATTERN     Filename pattern (default: %t)
                            Patterns: %n=track, %t=title, %a=artist, %A=album, %y=year
  -q, --quiet               Quiet mode (minimal output)
  -d, --dry-run             Dry run (show what would be done)
  -c, --create-config       Create sample config file
  -h, --help                Show this help message

JSON Format:
  {
    "splits": [
      {
        "start": "00:00:00",
        "end": "00:03:45",          // Optional: use 'duration' instead
        "duration": "00:03:45",     // Optional: use 'end' instead
        "title": "Track Title",
        "artist": "Artist Name",
        "album": "Album Name",
        "year": "2024",
        "composer": "Composer",
        "album_artist": "Album Artist",
        "comment": "Comment",
        "genre": "Genre",
        "publisher": "Label",
        "isrc": "USXX12345678",
        "catalog_number": "CAT-001",
        "disc_number": "1",
        "total_discs": "2",
        "performer": "Performer",
        "copyright": "Copyright Info"
      }
    ]
  }

Examples:
  $(basename "$0")                                    # Interactive mode
  $(basename "$0") -i input.flac -s splits.json       # Basic usage
  $(basename "$0") -i input.wav -s splits.json -o ./output -f flac
  $(basename "$0") -c                                 # Create config file

EOF
}

# Main interactive prompt function
interactive_mode() {
    echo ""
    echo "======================================"
    echo "  Audio Splitter - Interactive Mode"
    echo "======================================"
    echo ""
    
    # Input file
    if [[ -z "$INPUT_FILE" ]]; then
        read -p "Input audio file: " INPUT_FILE
        if [[ ! -f "$INPUT_FILE" ]]; then
            print_error "Input file not found: $INPUT_FILE"
            exit 1
        fi
    fi
    
    # Splits file
    if [[ -z "$SPLITS_FILE" ]]; then
        read -p "Splits JSON file: " SPLITS_FILE
        if [[ ! -f "$SPLITS_FILE" ]]; then
            print_error "Splits file not found: $SPLITS_FILE"
            exit 1
        fi
    fi
    
    # Output directory
    if [[ -z "$OUTPUT_DIR" ]]; then
        local default_dir=$(dirname "$INPUT_FILE")
        read -p "Output directory [$default_dir]: " OUTPUT_DIR
        OUTPUT_DIR=${OUTPUT_DIR:-$default_dir}
    fi
    
    # Create output directory if it doesn't exist
    mkdir -p "$OUTPUT_DIR"
    
    # Output format
    if [[ -z "$OUTPUT_FORMAT" ]] || [[ "$OUTPUT_FORMAT" == "auto" ]]; then
        read -p "Output format (auto/flac/wav/opus/mp3) [auto]: " OUTPUT_FORMAT
        OUTPUT_FORMAT=${OUTPUT_FORMAT:-auto}
    fi
    
    # Naming pattern
    if [[ -z "$NAMING_PATTERN" ]]; then
        read -p "Filename pattern (%n=track, %t=title, %a=artist, %A=album, %y=year) [%t]: " NAMING_PATTERN
        NAMING_PATTERN=${NAMING_PATTERN:-%t}
    fi
    
    # Quiet mode
    if [[ "$QUIET_MODE" == "false" ]]; then
        read -p "Quiet mode? (y/n) [n]: " quiet_input
        if [[ "$quiet_input" =~ ^[Yy]$ ]]; then
            QUIET_MODE=true
        fi
    fi
    
    # Dry run
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
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    # Check dependencies first
    check_dependencies
    
    # Parse command line arguments
    parse_args "$@"
    
    # Try to load config file first
    config_loaded=false
    if load_config; then
        config_loaded=true
    fi
    
    # If not all required args provided and config not fully loaded, go interactive
    if [[ -z "$INPUT_FILE" ]] || [[ -z "$SPLITS_FILE" ]]; then
        interactive_mode
    else
        # Set defaults for missing options
        OUTPUT_DIR=${OUTPUT_DIR:-$(dirname "$INPUT_FILE")}
        OUTPUT_FORMAT=${OUTPUT_FORMAT:-auto}
        NAMING_PATTERN=${NAMING_PATTERN:-%t}
    fi
    
    # Process the splits
    process_splits "$INPUT_FILE" "$SPLITS_FILE" "$OUTPUT_DIR" "$OUTPUT_FORMAT" "$NAMING_PATTERN"
}

# Run main function with all arguments
main "$@"
