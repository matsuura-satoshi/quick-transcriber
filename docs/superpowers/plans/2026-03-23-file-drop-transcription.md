# File Drop Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable drag-and-drop audio file transcription with accuracy-optimized parameters and speaker profile reuse.

**Architecture:** Create `FileAudioSource` conforming to `AudioCaptureService` protocol, inject it into a separate `ChunkedWhisperEngine` instance for file processing. Reuse the entire existing pipeline (VAD, WhisperKit, diarization) with accuracy-tuned parameters. UI adds `.onDrop` to transcription area with progress display in StatusBar.

**Tech Stack:** SwiftUI, AVAudioFile, AVAudioConverter, WhisperKit (shared instance), existing ChunkedWhisperEngine pipeline

**Spec:** `docs/superpowers/specs/2026-03-23-file-drop-transcription-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/QuickTranscriber/Audio/FileAudioSource.swift` | Create | AudioCaptureService conformer that reads audio files incrementally |
| `Tests/QuickTranscriberTests/FileAudioSourceTests.swift` | Create | Unit tests for file reading, resampling, progress, cancellation |
| `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` | Modify | Add `transcribeFile()`, `cancelFileTranscription()`, file mode state |
| `Sources/QuickTranscriber/Views/ContentView.swift` | Modify | Add `.onDrop`, drop zone overlay, StatusBar file progress |
| `Sources/QuickTranscriber/Constants.swift` | Modify | Add `FileTranscription` parameters enum |

---

### Task 1: FileAudioSource — Tests

**Files:**
- Create: `Tests/QuickTranscriberTests/FileAudioSourceTests.swift`

- [ ] **Step 1: Create test WAV helper**

We need a helper to generate test WAV files. Reuse `AudioRecordingService` (already tested in PR#72) to create fixtures.

```swift
import XCTest
import AVFoundation
@testable import QuickTranscriberLib

final class FileAudioSourceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileAudioSourceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    /// Create a test WAV file with known samples using AudioRecordingService
    private func createTestWav(name: String, samples: [Float]) -> URL {
        let recorder = AudioRecordingService()
        recorder.startSession(directory: tmpDir, datePrefix: name)
        recorder.appendSamples(samples)
        recorder.endSession()
        return tmpDir.appendingPathComponent("\(name)_qt_recording.wav")
    }
}
```

- [ ] **Step 2: Write test — startCapture delivers buffers and returns immediately**

```swift
func testStartCaptureDeliversBuffersAndReturnsImmediately() async throws {
    // 3200 samples = 200ms at 16kHz → should produce 2 buffers of 1600
    let samples = [Float](repeating: 0.5, count: 3200)
    let fileURL = createTestWav(name: "test_buffers", samples: samples)

    let source = FileAudioSource(fileURL: fileURL)
    var receivedBuffers: [[Float]] = []
    let expectation = XCTestExpectation(description: "All buffers delivered")

    source.onComplete = { expectation.fulfill() }

    try await source.startCapture { buffer in
        receivedBuffers.append(buffer)
    }

    // startCapture should return immediately (not block until file is read)
    // Wait for completion
    await fulfillment(of: [expectation], timeout: 5.0)

    XCTAssertEqual(receivedBuffers.count, 2)
    XCTAssertEqual(receivedBuffers[0].count, 1600)
    XCTAssertEqual(receivedBuffers[1].count, 1600)
}
```

- [ ] **Step 3: Write test — progress reporting**

```swift
func testProgressReporting() async throws {
    let samples = [Float](repeating: 0.3, count: 4800) // 300ms = 3 buffers
    let fileURL = createTestWav(name: "test_progress", samples: samples)

    let source = FileAudioSource(fileURL: fileURL)
    var progressValues: [Double] = []
    let expectation = XCTestExpectation(description: "Complete")

    source.onProgress = { progress in progressValues.append(progress) }
    source.onComplete = { expectation.fulfill() }

    try await source.startCapture { _ in }
    await fulfillment(of: [expectation], timeout: 5.0)

    // Progress should increase monotonically and end at 1.0
    XCTAssertFalse(progressValues.isEmpty)
    XCTAssertEqual(progressValues.last!, 1.0, accuracy: 0.01)
    for i in 1..<progressValues.count {
        XCTAssertGreaterThanOrEqual(progressValues[i], progressValues[i - 1])
    }
}
```

- [ ] **Step 4: Write test — stopCapture cancels reading**

```swift
func testStopCaptureCancelsReading() async throws {
    // Large file: 160000 samples = 10 seconds
    let samples = [Float](repeating: 0.1, count: 160000)
    let fileURL = createTestWav(name: "test_cancel", samples: samples)

    let source = FileAudioSource(fileURL: fileURL)
    var bufferCount = 0
    let gotSomeBuffers = XCTestExpectation(description: "Got some buffers")

    try await source.startCapture { _ in
        bufferCount += 1
        if bufferCount == 3 {
            gotSomeBuffers.fulfill()
        }
    }

    await fulfillment(of: [gotSomeBuffers], timeout: 5.0)
    source.stopCapture()

    // Wait a bit to ensure no more buffers are delivered
    try await Task.sleep(nanoseconds: 200_000_000)
    let finalCount = bufferCount
    XCTAssertLessThan(finalCount, 100) // Should have stopped well before all 100 buffers
}
```

- [ ] **Step 5: Write test — invalid file throws error**

```swift
func testInvalidFileThrows() async {
    let badURL = tmpDir.appendingPathComponent("nonexistent.wav")
    let source = FileAudioSource(fileURL: badURL)

    do {
        try await source.startCapture { _ in }
        XCTFail("Should have thrown")
    } catch {
        // Expected: file not found or unreadable
    }
}
```

- [ ] **Step 6: Write test — isCapturing state**

```swift
func testIsCapturingState() async throws {
    let samples = [Float](repeating: 0.5, count: 1600)
    let fileURL = createTestWav(name: "test_state", samples: samples)

    let source = FileAudioSource(fileURL: fileURL)
    XCTAssertFalse(source.isCapturing)

    let expectation = XCTestExpectation(description: "Complete")
    source.onComplete = { expectation.fulfill() }

    try await source.startCapture { _ in }
    // Should be capturing after startCapture returns
    XCTAssertTrue(source.isCapturing)

    await fulfillment(of: [expectation], timeout: 5.0)
    // After completion, isCapturing should be false
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(source.isCapturing)
}
```

- [ ] **Step 7: Run tests to verify they fail (RED)**

Run: `swift test --filter FileAudioSourceTests 2>&1 | tail -10`
Expected: Compilation error — `FileAudioSource` not found

- [ ] **Step 8: Commit tests**

```bash
git add Tests/QuickTranscriberTests/FileAudioSourceTests.swift
git commit -m "test: add FileAudioSource tests (RED)"
```

---

### Task 2: FileAudioSource — Implementation

**Files:**
- Create: `Sources/QuickTranscriber/Audio/FileAudioSource.swift`

- [ ] **Step 1: Implement FileAudioSource**

```swift
import AVFoundation

public final class FileAudioSource: AudioCaptureService {
    private let fileURL: URL
    private var readingTask: Task<Void, Never>?
    private var _isCapturing = false

    public var onProgress: ((@Sendable (Double) -> Void))?
    public var onComplete: ((@Sendable () -> Void))?

    public var isCapturing: Bool { _isCapturing }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let totalFrames = AVAudioFrameCount(audioFile.length)
        guard totalFrames > 0 else {
            onComplete?()
            return
        }

        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Constants.Audio.sampleRateInt),
            channels: 1,
            interleaved: false
        )!

        let sourceFormat = audioFile.processingFormat
        let needsConversion = sourceFormat.sampleRate != Double(Constants.Audio.sampleRateInt)
            || sourceFormat.channelCount != 1

        _isCapturing = true

        let onProgress = self.onProgress
        let onComplete = self.onComplete

        readingTask = Task { [weak self] in
            let bufferSize: AVAudioFrameCount = 4800  // Read in ~300ms source chunks
            let outputBufferSize: Int = 1600           // Deliver 100ms at 16kHz

            guard let readBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: bufferSize
            ) else { return }

            var converter: AVAudioConverter?
            if needsConversion {
                converter = AVAudioConverter(from: sourceFormat, to: processingFormat)
            }

            var framesRead: AVAudioFrameCount = 0
            var sampleAccumulator: [Float] = []

            while !Task.isCancelled {
                do {
                    readBuffer.frameLength = 0
                    try audioFile.read(into: readBuffer, frameCount: bufferSize)
                } catch {
                    break
                }

                guard readBuffer.frameLength > 0 else { break }
                framesRead += readBuffer.frameLength

                // Convert to 16kHz mono if needed
                let samples: [Float]
                if let converter {
                    guard let convertedBuffer = AVAudioPCMBuffer(
                        pcmFormat: processingFormat,
                        frameCapacity: AVAudioFrameCount(
                            Double(readBuffer.frameLength) * Double(Constants.Audio.sampleRateInt) / sourceFormat.sampleRate
                        ) + 100
                    ) else { break }

                    var error: NSError?
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return readBuffer
                    }
                    if error != nil { break }

                    let ptr = convertedBuffer.floatChannelData![0]
                    samples = Array(UnsafeBufferPointer(start: ptr, count: Int(convertedBuffer.frameLength)))
                } else {
                    let ptr = readBuffer.floatChannelData![0]
                    samples = Array(UnsafeBufferPointer(start: ptr, count: Int(readBuffer.frameLength)))
                }

                sampleAccumulator.append(contentsOf: samples)

                // Deliver in 100ms (1600 sample) chunks
                while sampleAccumulator.count >= outputBufferSize && !Task.isCancelled {
                    let chunk = Array(sampleAccumulator.prefix(outputBufferSize))
                    sampleAccumulator.removeFirst(outputBufferSize)
                    onBuffer(chunk)
                    await Task.yield()
                }

                // Report progress
                let progress = Double(framesRead) / Double(totalFrames)
                onProgress?(min(progress, 1.0))
            }

            // Deliver remaining samples (possibly < 1600)
            if !sampleAccumulator.isEmpty && !Task.isCancelled {
                onBuffer(sampleAccumulator)
            }

            onProgress?(1.0)
            self?._isCapturing = false
            onComplete?()
        }
    }

    public func stopCapture() {
        readingTask?.cancel()
        readingTask = nil
        _isCapturing = false
    }
}
```

- [ ] **Step 2: Run tests (GREEN)**

Run: `swift test --filter FileAudioSourceTests 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Audio/FileAudioSource.swift
git commit -m "feat: add FileAudioSource for file-based audio capture"
```

---

### Task 3: Constants — File Transcription Parameters

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift`

- [ ] **Step 1: Add FileTranscription constants**

Add after `AudioRecording` enum (line ~61):

```swift
public enum FileTranscription {
    public static let chunkDuration: TimeInterval = 15.0
    public static let endOfUtteranceSilence: TimeInterval = 1.0
    public static let temperatureFallbackCount: Int = 2
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete!

- [ ] **Step 3: Commit**

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "feat: add FileTranscription constants for accuracy-optimized params"
```

---

### Task 4: TranscriptionViewModel — File Transcription Logic

**Files:**
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`

**前提**: VM init（line 136-140）で `ChunkedWhisperEngine` が生成されるが、`diarizer` と `transcriber` はローカル変数で保持されていない。ファイルモード用エンジンでこれらを共有するため、VMに保持させる必要がある。

- [ ] **Step 1: Store shared components as VM properties**

VM のプロパティ宣言エリア（line 70付近）に追加：

```swift
private let sharedTranscriber: ChunkTranscriber
private let sharedDiarizer: SpeakerDiarizer?
```

init内（line 134-141）を修正。`diarizer` と `transcriber` をプロパティに保存してからエンジンに渡す：

```swift
let resolvedDiarizer: SpeakerDiarizer? = diarizer ?? FluidAudioSpeakerDiarizer()
let resolvedTranscriber: ChunkTranscriber = WhisperKitChunkTranscriber()
self.sharedDiarizer = resolvedDiarizer
self.sharedTranscriber = resolvedTranscriber
let resolvedEngine = engine ?? ChunkedWhisperEngine(
    transcriber: resolvedTranscriber,
    diarizer: resolvedDiarizer,
    speakerProfileStore: profileStore,
    embeddingHistoryStore: resolvedEmbeddingHistoryStore
)
self.service = TranscriptionService(engine: resolvedEngine)
```

- [ ] **Step 2: Add file transcription state properties**

Near line 50 (where other `@Published` properties are), add:

```swift
@Published var isTranscribingFile = false
@Published var fileTranscriptionProgress: Double = 0.0
@Published var showReplaceFileAlert = false
@Published var fileTranscriptionError: String?
var pendingFileURL: URL?
var transcribingFileName: String?
private var fileTranscriptionEngine: ChunkedWhisperEngine?
```

- [ ] **Step 3: Add `transcribeFile()` and related methods**

Add after `stopRecording()` (around line 810):

```swift
func transcribeFile(_ url: URL) {
    guard modelState == .ready else {
        NSLog("[QuickTranscriber] Cannot transcribe file: model not ready")
        return
    }
    guard !isTranscribingFile else {
        NSLog("[QuickTranscriber] Already transcribing a file")
        return
    }
    guard !isRecording else {
        NSLog("[QuickTranscriber] Cannot transcribe file during recording")
        return
    }

    // If there's existing text, show confirmation dialog
    if !confirmedText.isEmpty {
        pendingFileURL = url
        showReplaceFileAlert = true
        return
    }

    startFileTranscription(url)
}

func confirmReplaceAndTranscribe() {
    guard let url = pendingFileURL else { return }
    pendingFileURL = nil
    startFileTranscription(url)
}

private func startFileTranscription(_ url: URL) {
    Task {
        await beginFileTranscription(url)
    }
}

private func beginFileTranscription(_ url: URL) async {
    clearText()
    isTranscribingFile = true
    fileTranscriptionProgress = 0.0
    transcribingFileName = url.lastPathComponent

    let fileSource = FileAudioSource(fileURL: url)
    fileSource.onProgress = { [weak self] progress in
        Task { @MainActor [weak self] in
            self?.fileTranscriptionProgress = progress
        }
    }
    fileSource.onComplete = { [weak self] in
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishFileTranscription()
        }
    }

    // Create separate engine with shared transcriber and diarizer
    let fileEngine = ChunkedWhisperEngine(
        audioCaptureService: fileSource,
        transcriber: sharedTranscriber,
        diarizer: sharedDiarizer,
        speakerProfileStore: speakerProfileStore,
        embeddingHistoryStore: coordinator.embeddingHistoryStore
    )
    self.fileTranscriptionEngine = fileEngine

    // Build accuracy-optimized parameters
    var params = parametersStore.parameters
    params.chunkDuration = Constants.FileTranscription.chunkDuration
    params.silenceCutoffDuration = Constants.FileTranscription.endOfUtteranceSilence
    params.temperatureFallbackCount = Constants.FileTranscription.temperatureFallbackCount

    // Start file writer
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HHmm"
    let datePrefix = formatter.string(from: Date())
    if !fileSessionActive {
        fileWriter.startSession(language: currentLanguage, initialText: "", datePrefix: datePrefix)
        fileSessionActive = true
    }

    NSLog("[QuickTranscriber] Starting file transcription: %@", url.lastPathComponent)

    do {
        try await fileEngine.startStreaming(
            language: currentLanguage.rawValue,
            parameters: params,
            participantProfiles: nil,
            audioRecordingDirectory: nil,
            audioRecordingDatePrefix: nil
        ) { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.isTranscribingFile else { return }
                self.unconfirmedText = state.unconfirmedText
                var stateSegments = state.confirmedSegments
                if stateSegments.isEmpty && !state.confirmedText.isEmpty {
                    stateSegments = [ConfirmedSegment(text: state.confirmedText)]
                }
                self.confirmedSegments = Self.mergePreservingUserCorrections(
                    existing: self.confirmedSegments,
                    incoming: stateSegments
                )
                // Auto-detect speakers (same pattern as startRecording line 724-731)
                for segment in stateSegments {
                    if let speakerId = segment.speaker {
                        self.coordinator.addAutoDetectedSpeaker(
                            speakerId: speakerId,
                            embedding: segment.speakerEmbedding
                        )
                    }
                }
                self.syncSpeakerState()
                self.fileWriter.updateText(self.confirmedText)
            }
        }
    } catch {
        NSLog("[QuickTranscriber] File transcription error: %@", error.localizedDescription)
        fileTranscriptionError = error.localizedDescription
        isTranscribingFile = false
        fileTranscriptionEngine = nil
        transcribingFileName = nil
    }
}

private func finishFileTranscription() async {
    guard let engine = fileTranscriptionEngine else { return }
    await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
    fileTranscriptionEngine = nil
    isTranscribingFile = false
    fileTranscriptionProgress = 1.0
    transcribingFileName = nil
    NSLog("[QuickTranscriber] File transcription complete: %d segments", confirmedSegments.count)
}

func cancelFileTranscription() {
    guard let engine = fileTranscriptionEngine else { return }
    Task {
        // Empty display names → skips profile merge via nil-guard in stopStreaming
        await engine.stopStreaming(speakerDisplayNames: [:])
        fileTranscriptionEngine = nil
        clearText()
        isTranscribingFile = false
        fileTranscriptionProgress = 0.0
        transcribingFileName = nil
        NSLog("[QuickTranscriber] File transcription cancelled")
    }
}
```

- [ ] **Step 3: Disable recording during file transcription**

`toggleRecording()` (line 221付近) の先頭にガードを追加：

```swift
guard !isTranscribingFile else { return }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 5: Commit**

```bash
git add Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: add file transcription logic to TranscriptionViewModel"
```

---

### Task 5: ContentView — Drop Zone and UI

**Files:**
- Modify: `Sources/QuickTranscriber/Views/ContentView.swift`

- [ ] **Step 1: Add `.onDrop` to transcription area**

Find the `transcriptionArea` section (around line 173-191). Wrap it or chain `.onDrop`:

```swift
// Add state to ContentView
@State private var isDropTargeted = false
```

Add `.onDrop` modifier to the transcription area (or the HSplitView wrapping it):

```swift
.onDrop(of: [.audio], isTargeted: $isDropTargeted) { providers in
    guard viewModel.modelState == .ready,
          !viewModel.isRecording,
          !viewModel.isTranscribingFile else { return false }

    guard let provider = providers.first else { return false }

    provider.loadFileRepresentation(forTypeIdentifier: "public.audio") { url, error in
        guard let url else { return }
        // Copy to temp location since the provided URL is temporary
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmpURL)
        try? FileManager.default.copyItem(at: url, to: tmpURL)

        Task { @MainActor in
            viewModel.transcribeFile(tmpURL)
        }
    }
    return true
}
```

- [ ] **Step 2: Add drop zone overlay**

Add an overlay to the transcription area when empty and not recording:

```swift
.overlay {
    if !viewModel.isRecording && !viewModel.isTranscribingFile
        && viewModel.confirmedText.isEmpty && viewModel.unconfirmedText.isEmpty {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Drop audio file to transcribe")
                .font(.headline)
                .foregroundStyle(.tertiary)
        }
        .allowsHitTesting(false)
    }
}
.border(isDropTargeted ? Color.accentColor : Color.clear, width: 2)
```

- [ ] **Step 3: Add confirmation alert**

Add `.alert` for file replacement:

```swift
.alert("Re-transcribe from file?", isPresented: $viewModel.showReplaceFileAlert) {
    Button("Replace") {
        viewModel.confirmReplaceAndTranscribe()
    }
    Button("Cancel", role: .cancel) {
        viewModel.pendingFileURL = nil
    }
} message: {
    Text("This will replace the current transcription. Speaker profiles will be preserved.")
}
.alert("File Transcription Error", isPresented: Binding(
    get: { viewModel.fileTranscriptionError != nil },
    set: { if !$0 { viewModel.fileTranscriptionError = nil } }
)) {
    Button("OK") { viewModel.fileTranscriptionError = nil }
} message: {
    Text(viewModel.fileTranscriptionError ?? "")
}
```

- [ ] **Step 4: Update StatusBar for file transcription**

In the `statusBar` (line 135-171), add file transcription state display. Between the recording state and model state:

```swift
if viewModel.isTranscribingFile {
    HStack(spacing: 6) {
        ProgressView(value: viewModel.fileTranscriptionProgress)
            .frame(width: 100)
        Text("Transcribing \(viewModel.transcribingFileName ?? "file")... \(Int(viewModel.fileTranscriptionProgress * 100))%")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        Button {
            viewModel.cancelFileTranscription()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
```

Also, disable the mic button during file transcription:

```swift
.disabled(viewModel.isTranscribingFile)
```

- [ ] **Step 5: Update space key handler**

Find the `.onKeyPress(.space)` handler. Add file transcription cancel:

```swift
if viewModel.isTranscribingFile {
    viewModel.cancelFileTranscription()
    return .handled
}
```

- [ ] **Step 6: Build and test manually**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete!

- [ ] **Step 7: Commit**

```bash
git add Sources/QuickTranscriber/Views/ContentView.swift
git commit -m "feat: add drop zone UI and file transcription progress to ContentView"
```

---

### Task 6: Integration Testing and Refinement

- [ ] **Step 1: Run all unit tests**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -5`
Expected: All tests pass (700+ tests, 0 failures)

- [ ] **Step 2: Run FileAudioSource tests specifically**

Run: `swift test --filter FileAudioSourceTests 2>&1 | tail -10`
Expected: All 6 tests pass

- [ ] **Step 3: Manual testing**

1. Launch app: `swift build && swift run QuickTranscriber`
2. Verify drop zone hint is shown when text area is empty
3. Drop a WAV file → verify transcription starts with progress in StatusBar
4. Verify cancellation via X button or space key
5. With existing text, drop a file → verify confirmation dialog appears
6. During file transcription, verify mic button is disabled

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration fixes for file drop transcription"
```

---

### Task 7: Version Update and PR

- [ ] **Step 1: Update version**

Update `Constants.Version.patch` to match the PR number (check with `gh pr list`).

- [ ] **Step 2: Final build and test**

```bash
swift build && swift test --filter QuickTranscriberTests 2>&1 | tail -5
```

- [ ] **Step 3: Create PR**

```bash
git checkout -b feature/file-drop-transcription
git push -u origin feature/file-drop-transcription
gh pr create --title "feat: add drag-and-drop file transcription" --body "..."
```
