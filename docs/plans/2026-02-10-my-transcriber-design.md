# MyTranscriber Design Document

## 1. Product Overview

**App Name**: MyTranscriber

**Concept**: macOS native real-time transcription app. Captures in-person conversations via microphone and displays live subtitles. Fully local processing.

### MVP Scope

- Microphone input -> VAD speech detection -> WhisperKit (large-v3-turbo) inference -> text display
- English + Japanese support with manual language switching
- Standard window app with read-only text area, appending downward (Zoom transcription style)
- All text retained until explicit clear, scrollable and copy-pasteable
- Three controls: start/stop recording, language switch, clear

### Post-MVP (design-aware)

- Model selection (other WhisperKit models, FluidAudio/Parakeet integration)
- Session save/export
- Menu bar resident mode, floating overlay
- System audio capture (ScreenCaptureKit)

## 2. Architecture

```
+-------------------------------------------+
|  View Layer (SwiftUI)                     |
|  - TranscriptionView (text display)       |
|  - ControlBar (start/stop, lang, clear)   |
+--------------------+----------------------+
                     |
+--------------------v----------------------+
|  ViewModel                                |
|  - TranscriptionViewModel                 |
|  - @Published bindings to UI              |
+--------------------+----------------------+
                     |
+--------------------v----------------------+
|  Service Layer                            |
|  - AudioCaptureService (mic input)        |
|  - TranscriptionService (inference ctrl)  |
+--------------------+----------------------+
                     |
+--------------------v----------------------+
|  Engine Layer (protocol abstraction)      |
|  - TranscriptionEngine (protocol)         |
|    +- WhisperKitEngine (MVP)              |
|    +- FluidAudioEngine (future)           |
+-------------------------------------------+
```

### Key decisions

- **TranscriptionEngine protocol** abstracts the inference engine. MVP implements WhisperKitEngine only. FluidAudio (Parakeet) can be added later.
- **AudioCaptureService** uses AVAudioEngine for mic input. No premature abstraction for ScreenCaptureKit (YAGNI).
- **MVVM pattern**. ViewModel holds Services, SwiftUI Views observe state.

## 3. Data Flow

```
Mic -> AVAudioEngine -> Audio buffer (Float32, 16kHz)
                            |
                            v
                   VAD (WhisperKit built-in)
                            |
                   On speech segment detected
                            |
                            v
                  WhisperKit.transcribe()
                            |
                            v
                   Text result returned
                            |
                            v
            Append to TranscriptionViewModel
                            |
                            v
                 SwiftUI View updates
                (auto-scroll to bottom)
```

### Audio processing

- AVAudioEngine captures mic input, converts to 16kHz mono Float32
- WhisperKit VAD detects silence gaps, triggers inference per speech segment
- Inference runs on background thread (Swift Concurrency async/await), never blocks UI

### Language switching

- ViewModel holds current language setting (`en` / `ja`)
- Switching updates WhisperKit inference language parameter only. No recording restart needed.
- Insert separator (`--- English -> Japanese ---`) in text at switch point

### VAD fallback

- If VAD does not work well, fixed chunk mode (3 seconds) available as fallback
- Switchable via settings

## 4. Key Components

### TranscriptionEngine protocol

```swift
protocol TranscriptionEngine {
    func setup(model: String) async throws
    func transcribe(audio: [Float], language: String) async throws -> String
    func cleanup()
}
```

- MVP: `WhisperKitEngine` as sole implementation
- `model` parameter enables future model selection

### AudioCaptureService

- Taps AVAudioEngine input node for real-time audio buffer
- Accumulates in ring buffer, sends to TranscriptionService based on VAD
- Handles microphone permission requests

### TranscriptionViewModel

```swift
@MainActor
class TranscriptionViewModel: ObservableObject {
    @Published var transcriptionText: String = ""
    @Published var isRecording: Bool = false
    @Published var currentLanguage: Language = .english

    func toggleRecording()
    func switchLanguage(_ language: Language)
    func clearText()
}
```

- Text appended to single String (MVP simplicity)
- Future: structured data (timestamped array) for session save

### UI Components

- **TranscriptionView**: ScrollView + Text. Selectable/copyable. Auto-scrolls on new text.
- **ControlBar**: Toolbar with record toggle, language segment control, clear button.

## 5. Project Structure and Build

### Directory layout

```
MyTranscriber/
├── Package.swift
├── Sources/
│   └── MyTranscriber/
│       ├── App/
│       │   └── MyTranscriberApp.swift
│       ├── Views/
│       │   ├── ContentView.swift
│       │   ├── TranscriptionView.swift
│       │   └── ControlBar.swift
│       ├── ViewModels/
│       │   └── TranscriptionViewModel.swift
│       ├── Services/
│       │   ├── AudioCaptureService.swift
│       │   └── TranscriptionService.swift
│       ├── Engines/
│       │   ├── TranscriptionEngine.swift
│       │   └── WhisperKitEngine.swift
│       └── Models/
│           └── Language.swift
└── Tests/
    └── MyTranscriberTests/
```

### Build system

- Swift Package Manager based (`swift build` / `swift run`)
- WhisperKit dependency:
  ```swift
  .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
  ```

### Target environment

- macOS 14.0+ (Sonoma or later)
- Apple Silicon required (for ANE)
- Microphone permission (`NSMicrophoneUsageDescription` in Info.plist)

### Model download

- WhisperKit auto-downloads model from HuggingFace on first launch
- Stored in WhisperKit default cache directory

## 6. Error Handling and Edge Cases

### Microphone

- Permission denied -> clear message with link to System Settings
- Mic disconnected -> stop recording, reflect state in UI

### Model

- First launch download -> progress indicator. Disable record button until complete.
- Download failure -> show retry button

### Inference

- Inference error -> log and continue to next speech segment (don't halt app)
- VAD not functioning -> fallback to fixed chunk mode (manual switch in settings)

### Explicitly out of scope (YAGNI)

- Offline detection / network monitoring (app works offline except model download)
- Audio input device selection UI (MVP uses system default mic)
- Crash recovery / session restoration (save feature is post-MVP)

## Technical References

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - On-device Speech Recognition for Apple Silicon (MIT)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - CoreML audio models in Swift (Apache 2.0)
- [Parakeet TDT v3 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) - Future engine candidate
- [mac-whisper-speedtest](https://github.com/anvanvan/mac-whisper-speedtest) - Benchmark comparison of implementations
- [whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) - OpenAI model used in MVP
