# MyTranscriber

macOS native real-time transcription app. Captures in-person conversations via microphone and displays live subtitles. Fully local processing powered by WhisperKit on Apple Silicon.

## Features (MVP)

- Real-time speech-to-text using WhisperKit (large-v3-turbo)
- English + Japanese with manual language switching
- Read-only text display with full scroll history and copy support
- Voice Activity Detection for natural speech segmentation
- Runs entirely on-device (Apple Neural Engine)

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 or later)

## Build

```bash
swift build
swift run MyTranscriber
```

## Status

Work in progress. See [design document](docs/plans/2026-02-10-my-transcriber-design.md) for details.
