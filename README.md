# Audio Splitter with Metadata

A bash script for splitting audio files into individual tracks based on split point definitions, with comprehensive metadata tagging support. Splits can be defined in a JSON file or directly on the command line.

## Features

- **Multiple Input Formats**: MP3, Opus, WAV, and FLAC
- **Flexible Output Formats**: Auto-detect, or force conversion to FLAC, WAV, Opus, or MP3
- **Smart Split Logic**: Each split's end point is determined by explicit end time, duration, next split's start, or end of file — in that priority order
- **CLI or JSON Splits**: Define splits in a JSON file, or inline on the command line without a file
- **Comprehensive Metadata**: 18+ fields including ISRC, catalog numbers, composer, performer, copyright
- **EasyTag-Style Naming**: 15 pattern variables for custom output filenames
- **Interactive Mode**: Guided prompts when run without arguments
- **Config File Support**: Persistent defaults via `~/.audio-splitter.conf`
- **Dry Run**: Preview operations before executing
- **Safety**: Validates split points, checks dependencies, confirms before overwriting

## Requirements

- `ffmpeg` — audio processing
- `ffprobe` — audio analysis (included with ffmpeg)
- `jq` — JSON parsing (required for JSON split files and CLI splits)
- `bc` — timestamp calculations

### Installation

**Ubuntu/Debian:**
```bash
sudo apt-get install ffmpeg jq bc
```

**Fedora/RHEL:**
```bash
sudo dnf install ffmpeg jq bc
```

**macOS (Homebrew):**
```bash
brew install ffmpeg jq bc
```

## Setup

```bash
chmod +x audio-splitter.sh

# Optionally install system-wide
sudo cp audio-splitter.sh /usr/local/bin/audio-splitter
```

## Usage

### With a JSON Splits File

```bash
./audio-splitter.sh -i recording.flac -s splits.json
./audio-splitter.sh -i recording.flac -s splits.json -o ./output -f mp3
./audio-splitter.sh -i recording.flac -s splits.json -p "%n - %a - %t" -d
```

### With Command-Line Splits (No JSON File)

Each `--split` starts a new split definition. Metadata flags apply to the most recent `--split`.

```bash
./audio-splitter.sh -i concert.flac -o ./tracks \
  --split 00:00:00 --end 00:03:45 --title "Opening" --artist "Orchestra" \
  --split 00:03:45 --end 00:08:00 --title "Adagio" --artist "Orchestra" \
  --split 00:08:00 --title "Finale" --artist "Orchestra"
```

Quick single extract:
```bash
./audio-splitter.sh -i concert.flac -f mp3 \
  --split 00:15:00 --duration 00:05:00 --title "Encore"
```

### Interactive Mode

Run without arguments to be guided through all options:
```bash
./audio-splitter.sh
```

### Create Config File

```bash
./audio-splitter.sh -c
```

## Command-Line Reference

### General Options

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --input FILE` | Input audio file (required) | — |
| `-s, --splits FILE` | JSON split points file | — |
| `-o, --output-dir DIR` | Output directory | Same as input |
| `-f, --format FORMAT` | Output format: `auto`, `flac`, `wav`, `opus`, `mp3` | `auto` |
| `-p, --pattern PATTERN` | Filename pattern | `%t` |
| `-q, --quiet` | Suppress informational output | Off |
| `-d, --dry-run` | Show what would be done without writing files | Off |
| `-c, --create-config` | Create `~/.audio-splitter.conf` with defaults | — |
| `-h, --help` | Show help | — |

### CLI Split Options

Use `--split TIMESTAMP` to start each split definition. The following flags apply to the current split:

| Option | Description |
|--------|-------------|
| `--split TIMESTAMP` | Start a new split at this time (required per split) |
| `--end TIMESTAMP` | End time for this split |
| `--duration TIMESTAMP` | Duration of this split |
| `--title TEXT` | Track title |
| `--artist TEXT` | Artist |
| `--album TEXT` | Album name |
| `--album-artist TEXT` | Album artist |
| `--year TEXT` | Year or date |
| `--composer TEXT` | Composer |
| `--genre TEXT` | Genre |
| `--performer TEXT` | Performer or conductor |
| `--publisher TEXT` | Publisher or label |
| `--comment TEXT` | Comment |
| `--copyright TEXT` | Copyright info |
| `--isrc TEXT` | ISRC code |
| `--catalog TEXT` | Catalog number |
| `--disc-number TEXT` | Disc number |
| `--total-discs TEXT` | Total discs |

JSON file (`-s`) and CLI splits (`--split`) are mutually exclusive.

## Split End-Time Logic

For each split, the end point is determined by the first available source:

1. **Explicit end time** — `"end"` field in JSON or `--end` on CLI
2. **Start + duration** — `"duration"` field in JSON or `--duration` on CLI
3. **Next split's start time** — if another split follows
4. **End of audio file** — for the last split with no end or duration

This means you can mix and match within a single splits file: some tracks with explicit end times, others that simply run to the next track.

## Output Format and MP3 Conversion

### Auto Mode (Default)

When `-f auto` (or no `-f` flag), the output format is chosen based on the input:

| Input Format | Output Format |
|-------------|--------------|
| FLAC | FLAC |
| WAV | FLAC (lossless compression) |
| Opus | Opus |
| MP3 | MP3 |

### Forced Format Conversion

Use `-f FORMAT` to convert all output to a specific format regardless of input:

| Flag | Output | Quality Setting |
|------|--------|----------------|
| `-f flac` | FLAC | Lossless |
| `-f wav` | WAV (PCM 16-bit) | Lossless |
| `-f opus` | Opus | 128 kbps |
| `-f mp3` | MP3 | VBR V0 (highest quality, ~245 kbps average) |

**MP3 conversion examples:**
```bash
# Convert FLAC splits to MP3
./audio-splitter.sh -i recording.flac -s splits.json -f mp3

# Extract a single segment as MP3
./audio-splitter.sh -i concert.wav -f mp3 \
  --split 00:10:00 --duration 00:03:30 --title "Highlight"

# Convert Opus recording to MP3 with custom naming
./audio-splitter.sh -i podcast.opus -s episodes.json -f mp3 -p "%n - %t"
```

MP3 output uses ffmpeg's libmp3lame encoder with VBR quality 0 (the highest quality variable bitrate setting, typically averaging around 245 kbps). This produces files that are transparent to listening tests for most material.

## JSON Split File Format

```json
{
  "splits": [
    {
      "start": "00:00:00",
      "end": "00:03:45",
      "title": "Opening Movement",
      "artist": "Orchestra Ensemble",
      "album": "Classical Collection",
      "album_artist": "Various Artists",
      "year": "2024",
      "composer": "J.S. Bach",
      "genre": "Classical",
      "performer": "Berlin Philharmonic",
      "publisher": "Deutsche Grammophon",
      "catalog_number": "DG-479-0234",
      "disc_number": "1",
      "total_discs": "2",
      "isrc": "DEBG01400001",
      "copyright": "2024 Deutsche Grammophon",
      "comment": "Recorded live"
    },
    {
      "start": "00:03:45",
      "duration": "00:04:20",
      "title": "Adagio",
      "artist": "Orchestra Ensemble"
    },
    {
      "start": "00:08:05",
      "title": "Finale"
    }
  ]
}
```

### Timestamp Formats

All of these are valid:
- `"01:23:45"` — HH:MM:SS
- `"03:45"` — MM:SS
- `"225"` — seconds
- `"03:45.5"` — with decimal seconds

### Metadata Fields

All fields are optional. If no title is provided, tracks are numbered sequentially.

**Core fields:** `title`, `artist`, `album`, `album_artist`, `year` (or `date`), `composer`, `comment`

**Extended fields:** `genre`, `publisher` (or `label`), `performer` (or `conductor`), `isrc`, `catalog_number`, `disc_number`, `total_discs`, `copyright`

## Filename Patterns

Use EasyTag-style patterns with `-p`:

| Pattern | Field | Example |
|---------|-------|---------|
| `%n` | Track number | `01` |
| `%t` | Title | `Song Title` |
| `%a` | Artist | `Artist Name` |
| `%A` | Album artist | `Various Artists` |
| `%b` | Album | `Greatest Hits` |
| `%y` | Year | `2024` |
| `%C` | Composer | `Bach` |
| `%g` | Genre | `Classical` |
| `%p` | Performer | `Berlin Phil` |
| `%l` | Publisher | `DG` |
| `%d` | Disc number | `1` |
| `%D` | Total discs | `2` |
| `%N` | Total tracks | `12` |
| `%c` | Comment | `Live` |
| `%%` | Literal `%` | `%` |

**Examples:**
```bash
-p "%n - %t"              # "01 - Song Title.flac"
-p "%a - %t"              # "Artist - Song Title.flac"
-p "%C - %t [%p]"         # "Bach - Prelude [Berlin Phil].flac"
-p "%n %a - %t (%b, %y)"  # "01 Artist - Song (Album, 2024).flac"
```

Default pattern is `%t` (title only).

## Configuration File

Create a persistent config with `./audio-splitter.sh -c`, then edit `~/.audio-splitter.conf`:

```
OUTPUT_DIR=
OUTPUT_FORMAT=auto
NAMING_PATTERN=%n - %t
QUIET_MODE=false
DRY_RUN=false
```

When the config file exists, the script will prompt to use it on each run.

## Troubleshooting

**"Invalid JSON in splits file"** — Validate with `jq empty splits.json`

**"Split points must be in chronological order"** — Start times must increase sequentially.

**"Split point exceeds audio duration"** — Check timestamps against: `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 file.flac`

**Output files have no metadata** — Verify field names match the supported fields listed above. FLAC has the most comprehensive metadata support.

**Converting lossy to FLAC produces large files** — This doesn't improve quality. Use `-f auto` to preserve the source format.

## License

See [LICENSE](LICENSE) for details.

## Version History

- **2.0** — Consolidated into single script. Added CLI split definitions, enhanced filename patterns (15 variables), MP3 conversion support.
- **1.0** — Initial release with JSON splits, interactive mode, config file support.
