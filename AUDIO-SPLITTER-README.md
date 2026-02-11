# Audio Splitter with Metadata

A powerful bash script for splitting audio files based on JSON-defined split points with comprehensive metadata support.

## Features

- **Multiple Input Formats**: Supports OPUS, WAV, and FLAC
- **Smart Output Format**: Automatically converts to FLAC for lossless sources, or matches input format
- **Comprehensive Metadata**: Supports all major audio metadata fields including:
  - Core: title, artist, album, track, year, composer, album_artist, comment
  - Extended: genre, publisher/label, ISRC, catalog number, disc number, performer/conductor, copyright
- **Flexible Split Points**: Define splits using absolute timestamps, durations, or a mix of both
- **EasyTag-Style Naming**: Customizable filename patterns using familiar patterns
- **Interactive Mode**: Guided prompts with sensible defaults
- **Config File Support**: Save your preferences for repeated use
- **Safety Features**: 
  - Dependency checking with installation hints
  - Validation of split points (chronological order, duration checks)
  - Confirmation before overwriting files
  - Dry-run mode to preview operations
- **Quality Preservation**: Maintains audio quality; lossy formats use high-quality settings

## Requirements

- `ffmpeg` - Audio processing
- `ffprobe` - Audio file information
- `jq` - JSON parsing
- `bc` - Timestamp calculations

### Installation

**Ubuntu/Debian:**
```bash
sudo apt-get install ffmpeg jq bc
```

**Fedora/RHEL:**
```bash
sudo dnf install ffmpeg jq bc
```

**macOS (with Homebrew):**
```bash
brew install ffmpeg jq bc
```

## Installation

1. Download the script:
```bash
curl -O https://example.com/audio-splitter.sh
# Or copy the audio-splitter.sh file to your system
```

2. Make it executable:
```bash
chmod +x audio-splitter.sh
```

3. (Optional) Move to PATH for system-wide access:
```bash
sudo mv audio-splitter.sh /usr/local/bin/audio-splitter
```

## Quick Start

### Interactive Mode
Simply run the script without arguments:
```bash
./audio-splitter.sh
```

The script will guide you through all options with helpful prompts.

### Command-Line Mode
```bash
./audio-splitter.sh -i recording.flac -s splits.json
```

### Create Config File
```bash
./audio-splitter.sh --create-config
```

This creates `~/.audio-splitter.conf` with default settings.

## JSON Split Points Format

The script accepts JSON files with a `splits` array. Each split can use either:
- `end` time (absolute timestamp where the split ends)
- `duration` (length of the segment)
- Neither (automatically extends to the next split or end of file)

### Basic Example (simple-splits.json)
```json
{
  "splits": [
    {
      "start": "00:00:00",
      "duration": "00:03:15",
      "title": "Track One",
      "artist": "The Artist",
      "album": "Greatest Hits",
      "year": "2024"
    },
    {
      "start": "00:03:15",
      "duration": "00:04:02",
      "title": "Track Two",
      "artist": "The Artist",
      "album": "Greatest Hits",
      "year": "2024"
    },
    {
      "start": "00:07:17",
      "end": "00:11:00",
      "title": "Track Three",
      "artist": "The Artist",
      "album": "Greatest Hits",
      "year": "2024"
    }
  ]
}
```

### Advanced Example (example-splits.json)
```json
{
  "splits": [
    {
      "start": "00:00:00",
      "end": "00:03:45",
      "title": "Opening Movement",
      "artist": "Orchestra Ensemble",
      "album": "Classical Collection Vol. 1",
      "album_artist": "Various Artists",
      "year": "2024",
      "composer": "Johann Sebastian Bach",
      "genre": "Classical",
      "performer": "Berlin Philharmonic",
      "publisher": "Deutsche Grammophon",
      "catalog_number": "DG-479-0234",
      "disc_number": "1",
      "total_discs": "2",
      "isrc": "DEBG01400001",
      "copyright": "℗ 2024 Deutsche Grammophon",
      "comment": "Recorded live at Berlin Konzerthaus"
    }
  ]
}
```

### Timestamp Formats

All of these are valid:
- `"00:03:45"` - Hours:Minutes:Seconds
- `"03:45"` - Minutes:Seconds
- `"225"` - Seconds only
- `"03:45.5"` - With decimal seconds

## Metadata Fields

### Core Fields
- `title` - Track title
- `artist` - Track artist
- `album` - Album name
- `year` or `date` - Release year
- `composer` - Composer name
- `album_artist` - Album artist (for compilations)
- `comment` - Comments or notes
- `track` - Track number (automatically set)

### Extended Fields
- `genre` - Music genre
- `publisher` or `label` - Record label
- `isrc` - International Standard Recording Code
- `catalog_number` - Release catalog number
- `disc_number` - Disc number (for multi-disc sets)
- `total_discs` - Total number of discs
- `performer` or `conductor` - Performer/conductor
- `copyright` - Copyright information

All fields are optional. If metadata is not provided, files are simply numbered (1, 2, 3, etc.).

## Filename Patterns

Use EasyTag-style patterns for custom filenames:

- `%n` - Track number
- `%t` - Title
- `%a` - Artist
- `%A` - Album
- `%y` - Year

### Examples:
- `%n - %t` → "01 - Song Title.flac"
- `%a - %t` → "Artist Name - Song Title.flac"
- `%n. %a - %t` → "01. Artist Name - Song Title.flac"
- `%t (%y)` → "Song Title (2024).flac"

Default pattern is `%t` (title only).

## Command-Line Options

```
Usage: audio-splitter [OPTIONS]

Options:
  -i, --input FILE          Input audio file (required)
  -s, --splits FILE         JSON file with split points (required)
  -o, --output-dir DIR      Output directory (default: same as input)
  -f, --format FORMAT       Output format: auto, flac, wav, opus, mp3 (default: auto)
  -p, --pattern PATTERN     Filename pattern (default: %t)
  -q, --quiet               Quiet mode (minimal output)
  -d, --dry-run             Dry run (show what would be done)
  -c, --create-config       Create sample config file
  -h, --help                Show help message
```

## Usage Examples

### Basic Split
```bash
./audio-splitter.sh -i concert.flac -s splits.json
```

### Custom Output Directory
```bash
./audio-splitter.sh -i recording.wav -s splits.json -o ./split-tracks
```

### Force FLAC Output with Custom Pattern
```bash
./audio-splitter.sh -i audio.opus -s splits.json -f flac -p "%n - %a - %t"
```

### Dry Run (Preview)
```bash
./audio-splitter.sh -i input.flac -s splits.json -d
```

### Quiet Mode (for scripts)
```bash
./audio-splitter.sh -i input.flac -s splits.json -q
```

## Configuration File

Create a config file to set defaults:

```bash
./audio-splitter.sh --create-config
```

Edit `~/.audio-splitter.conf`:
```bash
# Audio Splitter Configuration File

# Output directory (leave blank for same directory as input file)
OUTPUT_DIR=

# Output format: auto, flac, wav, opus, mp3
OUTPUT_FORMAT=auto

# Naming pattern (EasyTag-style)
NAMING_PATTERN=%n - %t

# Quiet mode: true or false
QUIET_MODE=false

# Dry run mode: true or false
DRY_RUN=false
```

When you run the script, it will ask if you want to use the config file settings.

## Output Format Logic

The script uses smart format selection:

1. **auto** (default):
   - If input is lossless (FLAC, WAV, ALAC, etc.) → outputs FLAC
   - If input is lossy (OPUS, MP3, etc.) → matches input format

2. **Specified format** (flac, wav, opus, mp3):
   - Converts to the specified format
   - For lossy formats, uses high-quality settings

3. **Quality preservation**:
   - Lossless formats: bit-perfect copy or FLAC compression
   - MP3: VBR V0 (highest quality)
   - OPUS: 128kbps (transparent quality)

## Validation & Safety

The script performs several validation checks:

1. **JSON validation**: Ensures valid JSON syntax
2. **Chronological order**: Split points must be in order
3. **Duration check**: Split points can't exceed file duration
4. **File existence**: Prompts before overwriting existing files
5. **Dependency check**: Verifies required tools are installed

## Error Handling

The script stops immediately on errors:
- Invalid JSON format
- Missing dependencies
- Invalid timestamps
- Out-of-order split points
- Split points exceeding audio duration

Use `--dry-run` to preview operations before committing.

## Troubleshooting

### "Missing required dependencies"
Install the required tools (see Requirements section above).

### "Invalid JSON in splits file"
Validate your JSON at https://jsonlint.com/ or use:
```bash
jq empty your-splits.json
```

### "Split points must be in chronological order"
Ensure all start times are sequential in your JSON file.

### "Split point exceeds audio duration"
Check your timestamps against the actual file duration:
```bash
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 your-file.flac
```

### Metadata not appearing
Some formats have limited metadata support. FLAC has the most comprehensive support.

### Output files are too large
If converting lossy to lossless (e.g., OPUS to FLAC), you're not gaining quality. Use `--format auto` to preserve the original format.

## Tips & Best Practices

1. **Use absolute timestamps**: They're easier to work with than durations
2. **Leave gaps automatic**: Don't specify `end` or `duration` unless needed; the script will handle gaps
3. **Test with dry-run**: Always preview with `-d` for complex splits
4. **Keep metadata consistent**: Copy common fields (album, artist, year) across tracks
5. **Use config file**: Save time on repeated operations
6. **FLAC for archival**: Use FLAC output for long-term storage
7. **Validate JSON**: Use `jq` to check your splits file before running

## Integration with Your Archiving System

This script is designed to work well with your dual-mono audio archiving system:

1. Record complete performances/sessions as single files
2. Create JSON split points files during or after recording
3. Run this script to split into individual tracks with metadata
4. Files are ready for cataloging and playback

## Contributing

Feel free to modify and enhance this script for your needs. Key areas for extension:
- Additional metadata fields
- More output formats
- Batch processing multiple files
- Integration with music databases (MusicBrainz, Discogs)

## License

This script is provided as-is for personal and commercial use.

## Version History

- **1.0** (2025-01-14)
  - Initial release
  - Interactive and command-line modes
  - Comprehensive metadata support
  - Config file support
  - Validation and safety features

## Author

Created for audio archiving and processing workflows.
