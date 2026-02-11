# Audio File Splitter with Metadata Support

A bash script for splitting audio files based on JSON-defined split points with comprehensive metadata tagging support.

## Features

- **Multiple Input Formats**: Supports MP3, Opus, WAV, and FLAC
- **Smart Output Format**: Converts to FLAC for lossless sources, maintains format for lossy
- **Flexible Split Modes**: Split from start-to-next, start-to-end, or start-with-duration
- **Comprehensive Metadata**: Supports 18+ metadata fields including ISRC, catalog numbers, performer info
- **EasyTag-Compatible Naming**: Full support for EasyTag-style filename patterns
- **Validation**: Automatic validation of split points and JSON structure
- **Quality Preservation**: Maintains original audio quality for lossy formats

## Requirements

- `ffmpeg` - Audio processing
- `ffprobe` - Audio analysis
- `jq` - JSON parsing
- `bc` - Calculations

Install on Debian/Ubuntu:
```bash
sudo apt install ffmpeg jq bc
```

## Installation

```bash
# Make the script executable
chmod +x audio_splitter.sh

# Optionally, move to a directory in your PATH
sudo mv audio_splitter.sh /usr/local/bin/audio-splitter
```

## Usage

### Basic Usage

```bash
./audio_splitter.sh -i input.flac -s splits.json
```

### With Options

```bash
# Specify output directory and naming pattern
./audio_splitter.sh -i recording.wav -s splits.json -o ./output -p "%n. %a - %t"

# Use start_to_end mode with verbose output
./audio_splitter.sh -i audio.opus -s splits.json -m start_to_end -v

# Custom pattern with album info
./audio_splitter.sh -i input.flac -s splits.json -p "%n - %t (%a)"
```

### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --input FILE` | Input audio file (required) | - |
| `-s, --splits FILE` | JSON splits file (required) | - |
| `-o, --output DIR` | Output directory | Same as input |
| `-m, --mode MODE` | Split mode (see below) | `start_to_next` |
| `-p, --pattern PATTERN` | Filename pattern (see below) | `%n - %t` |
| `-v, --verbose` | Enable verbose output | Off |
| `-h, --help` | Show help message | - |

### Split Modes

1. **start_to_next** (default): Splits from each timestamp to the next one
   - Last track extends to end of file
   - No gaps between tracks

2. **start_to_end**: Each split goes from its timestamp to the end
   - Creates overlapping files
   - Useful for extracting multiple versions

3. **start_duration**: Uses explicit duration for each split
   - Requires `duration` field in JSON
   - Allows gaps between tracks

## JSON File Format

### Basic Structure

```json
{
    "splits": [
        {
            "timestamp": "00:00:00",
            "duration": "3:45",
            "metadata": {
                "title": "Track Title",
                "track": "1",
                "artist": "Artist Name"
            }
        }
    ]
}
```

### Supported Metadata Fields

| Field | Description | Example |
|-------|-------------|---------|
| `title` | Track title | "Symphony No. 5" |
| `track` | Track number | "1" |
| `artist` | Track artist | "Beethoven" |
| `album` | Album name | "Greatest Symphonies" |
| `albumartist` | Album artist | "Various Artists" |
| `composer` | Composer name | "Ludwig van Beethoven" |
| `performer` | Performer/conductor | "Berlin Philharmonic" |
| `year` | Year | "2024" |
| `date` | Full date | "2024-01-15" |
| `genre` | Genre | "Classical" |
| `comment` | Comment | "Live recording" |
| `publisher` | Label/publisher | "Deutsche Grammophon" |
| `isrc` | ISRC code | "USRC12345678" |
| `catalog` | Catalog number | "CAT-001" |
| `discnumber` | Disc number | "1" |
| `totaldiscs` | Total discs | "2" |
| `totaltracks` | Total tracks | "12" |
| `copyright` | Copyright info | "© 2024 Example Records" |

All metadata fields are optional. If no metadata is provided, files will be named with sequential numbers.

### Timestamp Formats

Timestamps can be in any of these formats:
- `HH:MM:SS` - Hours, minutes, seconds (e.g., "01:23:45")
- `MM:SS` - Minutes, seconds (e.g., "23:45")
- `SS` - Seconds only (e.g., "145")

Decimals are supported: `01:23:45.500`

## Filename Patterns (EasyTag-Style)

### Available Pattern Variables

| Pattern | Description | Example Output |
|---------|-------------|----------------|
| `%a` | Artist | "John Doe" |
| `%A` | Album Artist | "Various Artists" |
| `%b` | Album | "Greatest Hits" |
| `%c` | Comment | "Live" |
| `%C` | Composer | "Jane Smith" |
| `%d` | Disc Number | "1" |
| `%D` | Total Discs | "2" |
| `%g` | Genre | "Classical" |
| `%l` | Label/Publisher | "Example Records" |
| `%n` | Track Number | "01" |
| `%N` | Total Tracks | "12" |
| `%p` | Performer | "Orchestra" |
| `%t` | Title | "Track Title" |
| `%y` | Year | "2024" |
| `%%` | Literal % | "%" |

### Pattern Examples

```bash
# Simple: "01 - Track Title"
-p "%n - %t"

# With artist: "01. Artist Name - Track Title"
-p "%n. %a - %t"

# Album format: "Track Title (Artist Name)"
-p "%t (%a)"

# Classical: "Composer - Title [Performer]"
-p "%C - %t [%p]"

# Full metadata: "01 Artist - Title (Album, Year)"
-p "%n %a - %t (%b, %y)"
```

## Examples

### Example 1: Basic Album Split

**Command:**
```bash
./audio_splitter.sh -i concert.flac -s concert_splits.json
```

**concert_splits.json:**
```json
{
    "splits": [
        {
            "timestamp": "00:00:00",
            "metadata": {
                "title": "Opening Theme",
                "track": "1",
                "artist": "Orchestra",
                "album": "Live Concert 2024"
            }
        },
        {
            "timestamp": "00:05:30",
            "metadata": {
                "title": "Second Movement",
                "track": "2",
                "artist": "Orchestra",
                "album": "Live Concert 2024"
            }
        }
    ]
}
```

**Output:**
- `1 - Opening Theme.flac`
- `2 - Second Movement.flac`

### Example 2: Classical Music with Full Metadata

**Command:**
```bash
./audio_splitter.sh -i beethoven.flac -s beethoven.json -p "%C - %t [%p]"
```

**beethoven.json:**
```json
{
    "splits": [
        {
            "timestamp": "00:00:00",
            "metadata": {
                "title": "Symphony No. 5 - I. Allegro con brio",
                "composer": "Beethoven",
                "performer": "Berlin Philharmonic",
                "track": "1",
                "album": "Beethoven: Complete Symphonies",
                "albumartist": "Various",
                "year": "2024"
            }
        }
    ]
}
```

**Output:**
- `Beethoven - Symphony No. 5 - I. Allegro con brio [Berlin Philharmonic].flac`

### Example 3: Duration-Based Splitting

**Command:**
```bash
./audio_splitter.sh -i radio_show.opus -s show.json -m start_duration
```

**show.json:**
```json
{
    "splits": [
        {
            "timestamp": "00:00:00",
            "duration": "15:00",
            "metadata": {
                "title": "News Segment",
                "track": "1"
            }
        },
        {
            "timestamp": "00:20:00",
            "duration": "30:00",
            "metadata": {
                "title": "Interview",
                "track": "2"
            }
        }
    ]
}
```

This creates 15-minute news segment starting at 0:00 and 30-minute interview starting at 20:00, with a 5-minute gap between them.

## Output Format Logic

- **WAV input** → FLAC output (lossless compression)
- **FLAC input** → FLAC output (maintains lossless)
- **Opus input** → Opus output (matches input bitrate)
- **MP3 input** → MP3 output (matches input bitrate)

## Validation

The script validates:
- JSON syntax and structure
- Split points are in chronological order
- Split points don't exceed audio duration
- Required fields for selected split mode
- Input file existence and format

## Tips

1. **Verbose mode** (`-v`) shows detailed progress and ffmpeg commands
2. **Test with small files** first to verify your JSON format
3. **Use start_to_next** for continuous recordings (no gaps)
4. **Use start_duration** for recordings with intentional gaps
5. **Pattern variables** are optional - missing metadata fields are simply omitted
6. **Track numbering** - if no track number in metadata, uses sequential numbering

## Troubleshooting

### "Invalid JSON format"
- Validate your JSON with `jq empty splits.json`
- Check for missing commas, brackets, or quotes

### "Split points not in chronological order"
- Ensure timestamps increase: 00:00:00, 00:05:00, 00:10:00...

### "Duration not specified"
- When using `start_duration` mode, each split needs a `duration` field

### Output files have no metadata
- Check that metadata fields are correctly spelled
- Verify JSON structure with example files

### Wrong output format
- Script auto-detects based on input format
- WAV and FLAC → FLAC output
- Opus → Opus output
- MP3 → MP3 output

## License

This script is provided as-is for personal and commercial use.

## Version

Current version: 1.0.0
