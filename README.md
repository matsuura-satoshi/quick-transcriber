# Quick Transcriber

[日本語](README_ja.md)

A macOS real-time transcription app. High-accuracy speech recognition with WhisperKit (large-v3-turbo), speaker diarization, and real-time translation — all running completely on-device.

## Highlights

- **WhisperKit (large-v3-turbo)** — Apple Silicon-optimized speech recognition
- **Speaker Diarization** — FluidAudio-based speaker identification with persistent profiles
- **Real-time Translation** — EN↔JA translation via Apple Translation framework
- **Auto-save to Markdown** — Transcripts saved with YAML front matter, symlinked for easy access
- **Fully Local** — All processing runs on-device, no network required
- **Auto-Update** — Check for updates from the app menu or automatically on launch

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon (M1 or later)
- Microphone access permission

## Getting Started

### Download

Download the latest zip from [GitHub Releases](https://github.com/matsuura-satoshi/quick-transcriber/releases), extract it, and move `QuickTranscriber.app` to your Applications folder.

The app is not notarized, so you need to remove the quarantine attribute before first launch:

```bash
xattr -d com.apple.quarantine /Applications/QuickTranscriber.app
```

The WhisperKit model will be downloaded automatically on first launch (~1.5 GB, one-time only).

### Build from Source

Requires Xcode + macOS 15 SDK.

```bash
# Build & run
swift build && swift run QuickTranscriber

# Build .app bundle (for distribution)
./Scripts/build_app.sh
```

## Features

### Transcription

Real-time transcription powered by the WhisperKit large-v3-turbo model. Supports English and Japanese with VAD (Voice Activity Detection) for natural utterance segmentation.

**Usage:** Press `Space` or `Cmd+R` to start/stop recording. Switch languages using the toolbar picker.

### Speaker Diarization

Speaker identification using FluidAudio embeddings, cosine similarity matching, and Viterbi smoothing.

- **Auto mode** — Automatically detect and track speakers
- **Manual mode** — Pre-define participants for identification
- **Persistent profiles** — Remember speakers across sessions
- **Profile management** — Rename, tag, lock, and merge speaker profiles

**Usage:** Enable in Settings > Speakers. Click speaker labels in the transcript to reassign, right-click for the speaker menu. Tag speakers after recording stops.

### Translation

Fully local EN↔JA real-time translation via Apple Translation framework. Uses a two-pass approach: immediate translation on utterance, then re-translation with concatenated text when a group is finalized for improved accuracy.

**Usage:** `Cmd+T` to toggle the translation panel (HSplitView). Translation models are downloaded automatically on first use.

### Transcript Output

Transcripts are auto-saved to `~/QuickTranscriber/` in Markdown format with YAML front matter (datetime, language, speaker info). A symlink at `~/QuickTranscriber/qt_transcript.md` always points to the latest file.

**Usage:** Auto-saved during recording. Change the output directory in Settings > Output. `Cmd+Shift+C` to copy all text.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Space` | Start/Stop recording |
| `Cmd+R` | Start/Stop recording |
| `Cmd+T` | Toggle translation panel |
| `Cmd+Shift+C` | Copy all text |
| `Cmd+E` | Export |
| `Cmd+Delete` | Clear transcript |
| `Cmd++` / `Cmd+-` | Increase/Decrease font size |
| `Cmd+0` | Reset font size |
| `Cmd+,` | Settings |

## Data Storage

Default transcript location is `~/QuickTranscriber/`, configurable in Settings > Output. Speaker profiles are stored in `~/QuickTranscriber/` (fixed).

| Data | File |
|---|---|
| Transcripts | `<output dir>/YYYY-MM-DD_HHmmss.md` |
| Latest transcript link | `<output dir>/qt_transcript.md` (symlink) |
| Speaker profiles | `~/QuickTranscriber/speakers.json` (fixed) |

## Building & Development

```bash
# Unit tests
swift test --filter QuickTranscriberTests

# Benchmarks (requires WhisperKit model + test datasets)
swift test --filter QuickTranscriberBenchmarks
```

Architecture: MVVM (Views → TranscriptionViewModel → TranscriptionService → ChunkedWhisperEngine). See [CLAUDE.md](CLAUDE.md) for details.

## Technologies

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Speech recognition for Apple Silicon
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Speaker embedding extraction
- [Apple Translation](https://developer.apple.com/documentation/translation) — On-device translation

## License

[MIT](LICENSE)
