# Loopback Capture Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zoom 等のリモート会議音声をスピーカー再録音ではなく loopback でデジタルに同時録音し、次の実会議で separability 事前計測の資産（`*_qt_loopback.wav`）を取得できる状態にする。

**Architecture:** Core Audio Process Tap（全プロセス mixdown・自プロセス除外）を `ProcessTap` ラッパーに隔離し、`SystemAudioCaptureService`（既存 `AudioCaptureService` プロトコル準拠）→ `LoopbackRecordingSession`（2 つ目の `AudioRecordingService`）で `{日付}_qt_loopback.wav` を書く。配線は `TranscriptionService` 層のみ。**`ChunkedWhisperEngine` は一切変更しない**。

**Tech Stack:** Swift 6 toolchain（言語モード v5）/ SwiftPM / Core Audio Process Tap API（macOS 14.4+、target 15.0）/ AVAudioConverter / XCTest

**Spec:** `docs/superpowers/specs/2026-07-17-loopback-capture-design.md`

## Global Constraints

- ターゲット: macOS 15.0（`Package.swift` の `.macOS(.v15)`）、言語モード v5（各ターゲットの `swiftSettings`）
- **`ChunkedWhisperEngine.swift` と `TranscriptionEngine.swift`（protocol）には触れない**（spec 制約）
- ユニットテスト: `swift test --filter QuickTranscriberTests`（モデル不要、~2 秒、Xcode 必須）。既存 803 件を壊さない
- GUI アプリでは `print()` が出ない。ログは `NSLog` を使う
- シェルでのファイル削除は `trash`（`rm` は使わない）
- バージョン: `Constants.Version.patch` は PR 番号。**PR のコミット内でのみ更新**（Task 10）
- コミットメッセージは既存慣例（`feat:`/`test:`/`chore:` プレフィックス + 日本語本文可）に従い、末尾に `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` を付ける
- 新規公開型は `public`（QuickTranscriberLib はライブラリターゲット。テストは `@testable import QuickTranscriberLib`）

## File Structure

| File | 責務 | 種別 |
|---|---|---|
| `Sources/QuickTranscriber/Audio/TapAudioConverter.swift` | 任意フォーマット → 16kHz mono Float32 変換（デバイス非依存・テスト可能） | Create |
| `Sources/QuickTranscriber/Audio/ProcessTap.swift` | Core Audio Process Tap C API の隔離ラッパー | Create |
| `Sources/QuickTranscriber/Audio/SystemAudioCaptureService.swift` | ProcessTap + TapAudioConverter を束ねた `AudioCaptureService` 準拠サービス | Create |
| `Sources/QuickTranscriber/Services/LoopbackRecordingSession.swift` | loopback キャプチャ + WAV 録音のセッションコーディネータ | Create |
| `Sources/QuickTranscriber/Services/AudioRecordingService.swift` | ファイル接尾辞の init パラメータ化 | Modify |
| `Sources/QuickTranscriber/Constants.swift` | `loopbackFileSuffix` / `loopbackEnabledKey` 追加、version bump | Modify |
| `Sources/QuickTranscriber/Services/TranscriptionService.swift` | loopback セッションの開始/停止配線 + `loopbackStartError` | Modify |
| `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift` | 設定解決 + 失敗アラート | Modify |
| `Sources/QuickTranscriber/Views/SettingsView.swift` | サブトグル追加 | Modify |
| `Scripts/build_app.sh` | `NSAudioCaptureUsageDescription` 追加 | Modify |

---

### Task 1: AudioRecordingService の接尾辞パラメータ化 + Constants 追加

**Files:**
- Modify: `Sources/QuickTranscriber/Services/AudioRecordingService.swift`
- Modify: `Sources/QuickTranscriber/Constants.swift`（`enum AudioRecording`、71-76 行付近）
- Test: `Tests/QuickTranscriberTests/AudioRecordingServiceTests.swift`（追記）

**Interfaces:**
- Consumes: なし
- Produces: `AudioRecordingService(fileSuffix: String = Constants.AudioRecording.fileSuffix)`、`Constants.AudioRecording.loopbackFileSuffix == "_qt_loopback"`、`Constants.AudioRecording.loopbackEnabledKey == "loopbackRecordingEnabled"`（Task 5, 7 が使用）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/AudioRecordingServiceTests.swift` の `testCurrentFileURL` の後（クラス閉じ括弧の前）に追記:

```swift
    // MARK: - Custom Suffix

    func testCustomSuffixFilename() {
        let loopback = AudioRecordingService(fileSuffix: Constants.AudioRecording.loopbackFileSuffix)
        loopback.startSession(directory: tmpDir, datePrefix: "2026-07-17_0900")
        loopback.endSession()

        let files = try! FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let wavFile = files.first { $0.pathExtension == "wav" }!
        XCTAssertEqual(wavFile.lastPathComponent, "2026-07-17_0900_qt_loopback.wav")
    }
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter AudioRecordingServiceTests 2>&1 | tail -5`
Expected: コンパイルエラー（`AudioRecordingService` に `fileSuffix:` init がない / `loopbackFileSuffix` が未定義）

- [ ] **Step 3: 最小実装**

`Sources/QuickTranscriber/Constants.swift` の `enum AudioRecording` に 2 定数を追加:

```swift
    public enum AudioRecording {
        public static let fileSuffix = "_qt_recording"
        public static let loopbackFileSuffix = "_qt_loopback"
        /// SettingsView の @AppStorage と ViewModel の解決ロジックで共有するキー
        public static let loopbackEnabledKey = "loopbackRecordingEnabled"
        public static let sampleRate: UInt32 = 16000
        public static let channels: UInt16 = 1
        public static let bitsPerSample: UInt16 = 16
    }
```

`Sources/QuickTranscriber/Services/AudioRecordingService.swift` を変更。`private static let fileSuffix = Constants.AudioRecording.fileSuffix` を削除し、インスタンスプロパティ + init パラメータに:

```swift
public final class AudioRecordingService {

    private let fileSuffix: String
    private static let wavHeaderSize = 44

    // ...（既存プロパティはそのまま）...

    public init(fileSuffix: String = Constants.AudioRecording.fileSuffix) {
        self.fileSuffix = fileSuffix
    }
```

`startSession` 内の参照を変更:

```swift
        let filename = datePrefix + fileSuffix + ".wav"
```

（変更前は `datePrefix + Self.fileSuffix + ".wav"`）

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter AudioRecordingServiceTests 2>&1 | tail -5`
Expected: 全件 PASS（既存テストがデフォルト接尾辞の後方互換を保証）

- [ ] **Step 5: コミット**

```bash
git add Sources/QuickTranscriber/Services/AudioRecordingService.swift Sources/QuickTranscriber/Constants.swift Tests/QuickTranscriberTests/AudioRecordingServiceTests.swift
git commit -m "feat: AudioRecordingService のファイル接尾辞をパラメータ化

loopback 録音（_qt_loopback.wav）が同一実装を再利用できるようにする。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: TapAudioConverter — 任意フォーマット → 16kHz mono 変換

**Files:**
- Create: `Sources/QuickTranscriber/Audio/TapAudioConverter.swift`
- Test: `Tests/QuickTranscriberTests/TapAudioConverterTests.swift`（新規）

**Interfaces:**
- Consumes: `Constants.Audio.sampleRate`（16000.0）
- Produces: `TapAudioConverter(inputFormat: AVAudioFormat)`（failable init）、`func convert(_ buffer: AVAudioPCMBuffer) -> [Float]`（Task 4 が使用）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/TapAudioConverterTests.swift` を新規作成:

```swift
import XCTest
import AVFoundation
@testable import QuickTranscriberLib

final class TapAudioConverterTests: XCTestCase {

    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    /// fill(チャネル, フレーム番号) -> サンプル値 でバッファを構築
    private func makeBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        fill: (Int, Int) -> Float
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = fill(ch, i)
            }
        }
        return buffer
    }

    func testInitSucceedsForTypicalTapFormat() {
        XCTAssertNotNil(TapAudioConverter(inputFormat: makeFormat(sampleRate: 48000, channels: 2)))
    }

    func test48kStereoTo16kMonoFrameCountAndSignal() {
        let input = makeFormat(sampleRate: 48000, channels: 2)
        let sut = TapAudioConverter(inputFormat: input)!
        // 440Hz サイン波 0.1 秒（両チャネル同一、振幅 0.5）
        let buffer = makeBuffer(format: input, frames: 4800) { _, i in
            sin(Float(i) * 2.0 * .pi * 440.0 / 48000.0) * 0.5
        }

        let out = sut.convert(buffer)

        // 48k→16k で 1/3。リサンプラの priming 遅延で最初の呼び出しは少なめになりうる
        XCTAssertGreaterThan(out.count, 1300)
        XCTAssertLessThanOrEqual(out.count, 1700)
        // 信号エネルギーが残っている
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.2)
    }

    func testStereoOppositePhaseCancelsToNearZero() {
        let input = makeFormat(sampleRate: 48000, channels: 2)
        let sut = TapAudioConverter(inputFormat: input)!
        // L = +0.5, R = -0.5 の定常信号 → ダウンミックスでほぼ相殺
        let buffer = makeBuffer(format: input, frames: 4800) { ch, _ in
            ch == 0 ? 0.5 : -0.5
        }

        let out = sut.convert(buffer)

        XCTAssertFalse(out.isEmpty)
        XCTAssertLessThan(out.map(abs).max() ?? 1.0, 0.05)
    }

    func testMonoSameRatePreservesFrameCount() {
        let input = makeFormat(sampleRate: 16000, channels: 1)
        let sut = TapAudioConverter(inputFormat: input)!
        let buffer = makeBuffer(format: input, frames: 1600) { _, i in
            Float(i % 100) / 100.0
        }

        let out = sut.convert(buffer)

        XCTAssertEqual(out.count, 1600)
        // 同レートなのでリサンプラ遅延なし・値がほぼ保存される
        for i in 0..<100 {
            XCTAssertEqual(out[i], Float(i % 100) / 100.0, accuracy: 0.01, "sample \(i)")
        }
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter TapAudioConverterTests 2>&1 | tail -5`
Expected: コンパイルエラー（`TapAudioConverter` が存在しない）

- [ ] **Step 3: 実装**

`Sources/QuickTranscriber/Audio/TapAudioConverter.swift` を新規作成:

```swift
import AVFoundation

/// タップ出力（任意のサンプルレート・チャネル数）→ 16kHz mono Float32 変換。
/// デバイス非依存の変換ロジックなのでユニットテスト可能。
/// IO コールバックの直列 queue 上で使う前提（内部状態はスレッド安全ではない）。
public final class TapAudioConverter {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat

    public init?(inputFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Constants.Audio.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            return nil
        }
        self.inputFormat = inputFormat
        self.targetFormat = target
        self.converter = converter
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        // リサンプラの内部遅延ゆらぎ分の余裕を持たせる
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil,
              let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter TapAudioConverterTests 2>&1 | tail -5`
Expected: 4 件 PASS。`test48kStereoTo16kMonoFrameCountAndSignal` の frame count 境界（1300/1700）で落ちる場合は実測値を確認し、48k→16k の理論値 1600 ± リサンプラ遅延の実測に合わせて境界を調整してよい（ただし 0 や 4800 になる場合は実装バグ）

- [ ] **Step 5: コミット**

```bash
git add Sources/QuickTranscriber/Audio/TapAudioConverter.swift Tests/QuickTranscriberTests/TapAudioConverterTests.swift
git commit -m "feat: TapAudioConverter — タップ出力を 16kHz mono に変換

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ProcessTap — Core Audio C API の隔離ラッパー

**Files:**
- Create: `Sources/QuickTranscriber/Audio/ProcessTap.swift`

**Interfaces:**
- Consumes: なし（Core Audio のみ）
- Produces: `ProcessTap` — `func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws` / `func stop()`、`public enum ProcessTapError: LocalizedError`（Task 4, 5, 7 が使用）

**TDD 適用外の根拠:** 実ハードウェア + TCC 権限が必要で CI 不可（spec のテスト戦略で手動スモークテスト対象と定義済み）。ビルド成功を機械的検証とし、動作検証は Task 9 のスモークテストで行う。

- [ ] **Step 1: 実装**

`Sources/QuickTranscriber/Audio/ProcessTap.swift` を新規作成:

```swift
import AVFoundation
import CoreAudio

/// Core Audio Process Tap のエラー。OSStatus を保持しログ・アラート表示に使う。
public enum ProcessTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case defaultOutputDeviceUnavailable(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Failed to create system audio tap (status \(status)). "
                + "System audio recording permission may be denied."
        case .tapFormatUnavailable(let status):
            return "Failed to read tap audio format (status \(status))."
        case .defaultOutputDeviceUnavailable(let status):
            return "Failed to resolve default output device (status \(status))."
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate device (status \(status))."
        case .ioProcCreationFailed(let status):
            return "Failed to install audio IO proc (status \(status))."
        case .deviceStartFailed(let status):
            return "Failed to start audio device (status \(status))."
        }
    }
}

/// 全プロセスのシステム出力ミックスダウン（自プロセス除外）をキャプチャする
/// Core Audio Process Tap の C API 隔離ラッパー（参考実装: insidegui/AudioCap）。
/// 初回の AudioHardwareCreateProcessTap で TCC「システムオーディオ録音」
/// ダイアログが自動表示される。権限照会 API はなく、タップ作成の成否が唯一の判定手段。
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "process-tap-io", qos: .userInitiated)

    /// タップ作成 → フォーマット取得 → aggregate device → IOProc → 開始。
    /// onBuffer は ioQueue 上で直列に呼ばれる。
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let excluded: [NSNumber] = ownProcessObjectID().map { [NSNumber(value: $0)] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw ProcessTapError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try readTapFormat()
            let outputUID = try defaultOutputDeviceUID()
            try createAggregateDevice(tapUUID: description.uuid.uuidString, outputUID: outputUID)
            try installIOProc(format: format, onBuffer: onBuffer)
            status = AudioDeviceStart(aggregateDeviceID, deviceProcID)
            guard status == noErr else { throw ProcessTapError.deviceStartFailed(status) }
        } catch {
            cleanup()
            throw error
        }
        NSLog("[ProcessTap] Started (tap %u, aggregate %u)", tapID, aggregateDeviceID)
    }

    func stop() {
        cleanup()
        NSLog("[ProcessTap] Stopped")
    }

    // MARK: - Steps

    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw ProcessTapError.tapFormatUnavailable(status)
        }
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw ProcessTapError.defaultOutputDeviceUnavailable(status)
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, uidPtr)
        }
        guard status == noErr else {
            throw ProcessTapError.defaultOutputDeviceUnavailable(status)
        }
        return uid as String
    }

    private func createAggregateDevice(tapUUID: String, outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "QuickTranscriber Loopback",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID,
                ]
            ],
        ]
        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard status == noErr else {
            throw ProcessTapError.aggregateDeviceCreationFailed(status)
        }
        aggregateDeviceID = newDeviceID
    }

    private func installIOProc(
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, ioQueue) {
            _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            onBuffer(buffer)
        }
        guard status == noErr, deviceProcID != nil else {
            throw ProcessTapError.ioProcCreationFailed(status)
        }
    }

    /// 自プロセスの AudioObjectID（タップの除外リスト用）。失敗時は nil（除外なしで続行）。
    private func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &objectID)
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func cleanup() {
        if aggregateDeviceID != kAudioObjectUnknown, let procID = deviceProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        deviceProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
```

- [ ] **Step 2: ビルドが通ることを確認**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`。API 名の不一致でコンパイルエラーが出た場合は macOS 15 SDK のヘッダ（`CoreAudio/AudioHardwareTapping.h`, `CoreAudio/CATapDescription.h`, `CoreAudio/AudioHardware.h`）で正確なシグネチャを確認して合わせる（例: `CATapDescription(stereoGlobalTapButExcludeProcesses:)` の引数型は `[NSNumber]`）

- [ ] **Step 3: 既存テストが壊れていないことを確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: 全件 PASS

- [ ] **Step 4: コミット**

```bash
git add Sources/QuickTranscriber/Audio/ProcessTap.swift
git commit -m "feat: ProcessTap — Core Audio Process Tap の隔離ラッパー

全プロセス mixdown（自プロセス除外）をキャプチャ。実ハード + TCC が
必要なため自動テスト対象外（PR の手動スモークテストで検証）。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: SystemAudioCaptureService — AudioCaptureService 準拠の合成

**Files:**
- Create: `Sources/QuickTranscriber/Audio/SystemAudioCaptureService.swift`
- Test: `Tests/QuickTranscriberTests/SystemAudioCaptureServiceTests.swift`（新規、状態遷移の安全性のみ）

**Interfaces:**
- Consumes: `ProcessTap.start(onBuffer:)/stop()`（Task 3）、`TapAudioConverter`（Task 2）、`AudioCaptureService` protocol（既存: `startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws` / `stopCapture()` / `isCapturing`）
- Produces: `SystemAudioCaptureService()` — `AudioCaptureService` 準拠（Task 5 のデフォルト captureService）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/SystemAudioCaptureServiceTests.swift` を新規作成（ハードに触れない状態遷移のみ）:

```swift
import XCTest
@testable import QuickTranscriberLib

final class SystemAudioCaptureServiceTests: XCTestCase {

    func testInitialStateIsNotCapturing() {
        let sut = SystemAudioCaptureService()
        XCTAssertFalse(sut.isCapturing)
    }

    func testStopWithoutStartIsNoOp() {
        let sut = SystemAudioCaptureService()
        sut.stopCapture() // クラッシュしないこと
        XCTAssertFalse(sut.isCapturing)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter SystemAudioCaptureServiceTests 2>&1 | tail -5`
Expected: コンパイルエラー（`SystemAudioCaptureService` が存在しない）

- [ ] **Step 3: 実装**

`Sources/QuickTranscriber/Audio/SystemAudioCaptureService.swift` を新規作成:

```swift
import AVFoundation

/// システム出力（loopback）を 16kHz mono Float32 ストリームとして提供する。
/// マイク版 AVAudioCaptureService と同じ AudioCaptureService プロトコル準拠。
/// Phase 2 ではこのサービスをそのままエンジンの第 2 ストリームとして注入できる。
public final class SystemAudioCaptureService: AudioCaptureService {
    /// IO コールバック（ProcessTap の直列 queue 上）専用の変換器ホルダ。
    /// stopCapture との競合を避けるためサービス本体のプロパティにはしない
    /// （AVAudioCaptureService の localConverter と同じ理由）。
    private final class ConverterBox {
        var converter: TapAudioConverter?
    }

    private let tap = ProcessTap()
    public private(set) var isCapturing = false

    public init() {}

    public func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        let box = ConverterBox()
        try tap.start { pcmBuffer in
            // ProcessTap の ioQueue 上で直列実行されるため box アクセスは安全
            if box.converter == nil {
                box.converter = TapAudioConverter(inputFormat: pcmBuffer.format)
                NSLog("[SystemAudioCaptureService] Tap format: \(pcmBuffer.format)")
            }
            guard let samples = box.converter?.convert(pcmBuffer), !samples.isEmpty else { return }
            onBuffer(samples)
        }
        isCapturing = true
        NSLog("[SystemAudioCaptureService] Capture started")
    }

    public func stopCapture() {
        guard isCapturing else { return }
        tap.stop()
        isCapturing = false
        NSLog("[SystemAudioCaptureService] Capture stopped")
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter SystemAudioCaptureServiceTests 2>&1 | tail -5`
Expected: 2 件 PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/QuickTranscriber/Audio/SystemAudioCaptureService.swift Tests/QuickTranscriberTests/SystemAudioCaptureServiceTests.swift
git commit -m "feat: SystemAudioCaptureService — loopback の AudioCaptureService 準拠実装

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: LoopbackRecordingSession — キャプチャ + WAV 録音のコーディネータ

**Files:**
- Create: `Sources/QuickTranscriber/Services/LoopbackRecordingSession.swift`
- Test: `Tests/QuickTranscriberTests/LoopbackRecordingSessionTests.swift`（新規）

**Interfaces:**
- Consumes: `AudioCaptureService` protocol、`SystemAudioCaptureService()`（Task 4）、`AudioRecordingService(fileSuffix:)` + `currentFileURL` + `startSession/appendSamples/endSession`（Task 1）、`Constants.AudioRecording.loopbackFileSuffix` / `.loopbackEnabledKey`（Task 1）、テストで `Tests/QuickTranscriberTests/Mocks/MockAudioCaptureService.swift`（既存: `simulateBuffer(_:)` / `startCaptureCalled` / `stopCaptureCalled`）
- Produces: `LoopbackRecordingSession(captureService: AudioCaptureService = SystemAudioCaptureService())` — `func start(directory: URL, datePrefix: String) async throws` / `func stop()` / `var isActive: Bool` / `static func isEnabled(in defaults: UserDefaults = .standard) -> Bool`（Task 6, 7 が使用）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/LoopbackRecordingSessionTests.swift` を新規作成:

```swift
import XCTest
@testable import QuickTranscriberLib

private final class FailingCaptureService: AudioCaptureService {
    private(set) var isCapturing = false
    func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        throw ProcessTapError.tapCreationFailed(-1)
    }
    func stopCapture() {}
}

final class LoopbackRecordingSessionTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopbackRecordingSessionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func wavFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "wav" }
    }

    // MARK: - Recording

    func testStartRecordsBuffersToLoopbackWav() async throws {
        let capture = MockAudioCaptureService()
        let sut = LoopbackRecordingSession(captureService: capture)

        try await sut.start(directory: tmpDir, datePrefix: "2026-07-17_0900")
        XCTAssertTrue(sut.isActive)
        XCTAssertTrue(capture.startCaptureCalled)

        capture.simulateBuffer([0.5, -0.5])
        sut.stop()
        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(capture.stopCaptureCalled)

        let files = wavFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "2026-07-17_0900_qt_loopback.wav")

        // 2 サンプル × 2 バイト = data チャンク 4 バイト
        let data = try Data(contentsOf: files[0])
        let dataChunkSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(dataChunkSize, 4)
    }

    // MARK: - Failure Fallback

    func testStartFailureRemovesStubAndThrows() async {
        let sut = LoopbackRecordingSession(captureService: FailingCaptureService())

        do {
            try await sut.start(directory: tmpDir, datePrefix: "2026-07-17_0900")
            XCTFail("Expected error")
        } catch {
            // ProcessTapError が伝播すること
            XCTAssertTrue(error is ProcessTapError)
        }
        XCTAssertFalse(sut.isActive)
        // 空の WAV スタブが残らないこと
        XCTAssertTrue(wavFiles().isEmpty)
    }

    func testStopWithoutStartIsNoOp() {
        let sut = LoopbackRecordingSession(captureService: MockAudioCaptureService())
        sut.stop() // クラッシュしないこと
        XCTAssertFalse(sut.isActive)
    }

    // MARK: - Settings Resolution

    func testIsEnabledDefaultsTrueWhenUnset() {
        let defaults = UserDefaults(suiteName: "LoopbackTests-\(UUID().uuidString)")!
        XCTAssertTrue(LoopbackRecordingSession.isEnabled(in: defaults))
    }

    func testIsEnabledRespectsStoredFalse() {
        let suiteName = "LoopbackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: Constants.AudioRecording.loopbackEnabledKey)
        XCTAssertFalse(LoopbackRecordingSession.isEnabled(in: defaults))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testIsEnabledRespectsStoredTrue() {
        let suiteName = "LoopbackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: Constants.AudioRecording.loopbackEnabledKey)
        XCTAssertTrue(LoopbackRecordingSession.isEnabled(in: defaults))
        defaults.removePersistentDomain(forName: suiteName)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter LoopbackRecordingSessionTests 2>&1 | tail -5`
Expected: コンパイルエラー（`LoopbackRecordingSession` が存在しない）

- [ ] **Step 3: 実装**

`Sources/QuickTranscriber/Services/LoopbackRecordingSession.swift` を新規作成:

```swift
import Foundation

/// システムオーディオ（loopback）の同時録音セッション。
/// SystemAudioCaptureService と専用 AudioRecordingService を束ね、
/// {datePrefix}_qt_loopback.wav をマイク録音と同じディレクトリに書く。
public final class LoopbackRecordingSession {
    private let captureService: AudioCaptureService
    private let recorder: AudioRecordingService
    public private(set) var isActive = false

    public init(captureService: AudioCaptureService = SystemAudioCaptureService()) {
        self.captureService = captureService
        self.recorder = AudioRecordingService(
            fileSuffix: Constants.AudioRecording.loopbackFileSuffix)
    }

    /// loopback 録音のユーザー設定。キー未設定なら true（デフォルト ON）。
    /// UserDefaults.bool(forKey:) は未設定で false を返すため object(forKey:) 経由で判定。
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Constants.AudioRecording.loopbackEnabledKey) as? Bool ?? true
    }

    /// キャプチャ開始失敗時は空の WAV スタブを削除して rethrow する
    /// （呼び出し側はマイク録音のみで続行する）。
    public func start(directory: URL, datePrefix: String) async throws {
        recorder.startSession(directory: directory, datePrefix: datePrefix)
        do {
            try await captureService.startCapture { [recorder] samples in
                recorder.appendSamples(samples)
            }
        } catch {
            let stubURL = recorder.currentFileURL
            recorder.endSession()
            if let stubURL {
                try? FileManager.default.removeItem(at: stubURL)
            }
            throw error
        }
        isActive = true
        NSLog("[LoopbackRecordingSession] Started: %@%@.wav",
              datePrefix, Constants.AudioRecording.loopbackFileSuffix)
    }

    public func stop() {
        guard isActive else { return }
        captureService.stopCapture()
        recorder.endSession()
        isActive = false
        NSLog("[LoopbackRecordingSession] Stopped")
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter LoopbackRecordingSessionTests 2>&1 | tail -5`
Expected: 6 件 PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/QuickTranscriber/Services/LoopbackRecordingSession.swift Tests/QuickTranscriberTests/LoopbackRecordingSessionTests.swift
git commit -m "feat: LoopbackRecordingSession — loopback キャプチャ + WAV 録音のコーディネータ

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: TranscriptionService への配線

**Files:**
- Modify: `Sources/QuickTranscriber/Services/TranscriptionService.swift`
- Test: `Tests/QuickTranscriberTests/TranscriptionServiceTests.swift`（追記）

**Interfaces:**
- Consumes: `LoopbackRecordingSession`（Task 5）、既存 `MockTranscriptionEngine` / `MockAudioCaptureService`（`Tests/QuickTranscriberTests/Mocks/`）
- Produces: `TranscriptionService(engine:loopbackSessionFactory:)`、`startTranscription(..., loopbackRecordingEnabled: Bool = false, ...)`、`var loopbackStartError: Error?`（Task 7 が使用）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/QuickTranscriberTests/TranscriptionServiceTests.swift` のクラス末尾（閉じ括弧の前）に追記。`FailingCaptureService` は `private` なので Task 5 のテストファイルとは独立に本ファイルにも定義する（ファイルスコープ、クラス定義の外・import の後に置く）:

```swift
private final class FailingLoopbackCaptureService: AudioCaptureService {
    private(set) var isCapturing = false
    func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        throw ProcessTapError.tapCreationFailed(-1)
    }
    func stopCapture() {}
}
```

テストメソッド（クラス内に追記）:

```swift
    // MARK: - Loopback Recording

    private func makeTmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionServiceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLoopbackSessionStartsAndStopsWhenEnabled() async throws {
        let engine = MockTranscriptionEngine()
        let capture = MockAudioCaptureService()
        let session = LoopbackRecordingSession(captureService: capture)
        let service = TranscriptionService(engine: engine, loopbackSessionFactory: { session })
        let tmpDir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try await service.prepare(model: "test-model")
        try await service.startTranscription(
            language: "ja",
            audioRecordingDirectory: tmpDir,
            audioRecordingDatePrefix: "2026-07-17_0900",
            loopbackRecordingEnabled: true
        ) { _ in }

        XCTAssertTrue(capture.startCaptureCalled)
        XCTAssertTrue(session.isActive)
        XCTAssertNil(service.loopbackStartError)

        await service.stopTranscription()
        XCTAssertTrue(capture.stopCaptureCalled)
        XCTAssertFalse(session.isActive)
    }

    func testLoopbackNotStartedWhenDisabled() async throws {
        let engine = MockTranscriptionEngine()
        var factoryCalled = false
        let service = TranscriptionService(engine: engine, loopbackSessionFactory: {
            factoryCalled = true
            return LoopbackRecordingSession(captureService: MockAudioCaptureService())
        })
        let tmpDir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try await service.prepare(model: "test-model")
        try await service.startTranscription(
            language: "ja",
            audioRecordingDirectory: tmpDir,
            audioRecordingDatePrefix: "2026-07-17_0900",
            loopbackRecordingEnabled: false
        ) { _ in }

        XCTAssertFalse(factoryCalled)
        XCTAssertNil(service.loopbackStartError)
        await service.stopTranscription()
    }

    func testLoopbackNotStartedWithoutRecordingDirectory() async throws {
        let engine = MockTranscriptionEngine()
        var factoryCalled = false
        let service = TranscriptionService(engine: engine, loopbackSessionFactory: {
            factoryCalled = true
            return LoopbackRecordingSession(captureService: MockAudioCaptureService())
        })

        try await service.prepare(model: "test-model")
        // 録音ディレクトリ nil（録音無効）なら loopback も開始しない
        try await service.startTranscription(
            language: "ja",
            loopbackRecordingEnabled: true
        ) { _ in }

        XCTAssertFalse(factoryCalled)
        await service.stopTranscription()
    }

    func testLoopbackFailureDoesNotBlockTranscription() async throws {
        let engine = MockTranscriptionEngine()
        let session = LoopbackRecordingSession(captureService: FailingLoopbackCaptureService())
        let service = TranscriptionService(engine: engine, loopbackSessionFactory: { session })
        let tmpDir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try await service.prepare(model: "test-model")
        // throw しないこと（文字起こしは続行）
        try await service.startTranscription(
            language: "ja",
            audioRecordingDirectory: tmpDir,
            audioRecordingDatePrefix: "2026-07-17_0900",
            loopbackRecordingEnabled: true
        ) { _ in }

        XCTAssertTrue(engine.startStreamingCalled)
        XCTAssertNotNil(service.loopbackStartError)
        XCTAssertFalse(session.isActive)
        await service.stopTranscription()
    }
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter TranscriptionServiceTests 2>&1 | tail -5`
Expected: コンパイルエラー（`loopbackSessionFactory:` / `loopbackRecordingEnabled:` / `loopbackStartError` が存在しない）

- [ ] **Step 3: 実装**

`Sources/QuickTranscriber/Services/TranscriptionService.swift` を変更。

init とプロパティ（既存の `private let engine` / `isReady` の並びに追加）:

```swift
public final class TranscriptionService {
    private let engine: TranscriptionEngine
    private let loopbackSessionFactory: () -> LoopbackRecordingSession
    private var loopbackSession: LoopbackRecordingSession?
    /// 直近の startTranscription で loopback 開始に失敗した場合のエラー。
    /// 文字起こしは続行するため throw せずここに保持し、UI がアラート表示に使う。
    public private(set) var loopbackStartError: Error?
    public private(set) var isReady = false

    public init(
        engine: TranscriptionEngine,
        loopbackSessionFactory: @escaping () -> LoopbackRecordingSession = { LoopbackRecordingSession() }
    ) {
        self.engine = engine
        self.loopbackSessionFactory = loopbackSessionFactory
    }
```

`startTranscription` にパラメータと開始処理を追加（`engine.startStreaming` の後）:

```swift
    public func startTranscription(
        language: String,
        parameters: TranscriptionParameters = .default,
        participantProfiles: [(speakerId: UUID, embedding: [Float])]? = nil,
        audioRecordingDirectory: URL? = nil,
        audioRecordingDatePrefix: String? = nil,
        loopbackRecordingEnabled: Bool = false,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        guard isReady else {
            throw TranscriptionServiceError.engineNotReady
        }
        guard await !engine.isStreaming else {
            throw TranscriptionServiceError.alreadyStreaming
        }
        try await engine.startStreaming(language: language, parameters: parameters, participantProfiles: participantProfiles, audioRecordingDirectory: audioRecordingDirectory, audioRecordingDatePrefix: audioRecordingDatePrefix, onStateChange: onStateChange)

        loopbackStartError = nil
        if loopbackRecordingEnabled,
           let directory = audioRecordingDirectory,
           let datePrefix = audioRecordingDatePrefix {
            let session = loopbackSessionFactory()
            do {
                try await session.start(directory: directory, datePrefix: datePrefix)
                loopbackSession = session
            } catch {
                // loopback は計測用の付加機能。失敗しても文字起こし・マイク録音は続行
                loopbackStartError = error
                NSLog("[TranscriptionService] Loopback recording failed to start: \(error)")
            }
        }
    }
```

`stopTranscription` の先頭で loopback を停止:

```swift
    public func stopTranscription(speakerDisplayNames: [String: String] = [:]) async {
        loopbackSession?.stop()
        loopbackSession = nil
        // 発行済みの speaker 系操作が engine に届いてから stop する
        // （同期呼び出し時代の「補正が stop より先に届く」順序を保存）
        await engineSyncTask?.value
        await engine.stopStreaming(speakerDisplayNames: speakerDisplayNames)
    }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter TranscriptionServiceTests 2>&1 | tail -5`
Expected: 既存 + 新規 4 件すべて PASS

- [ ] **Step 5: 全ユニットテストで回帰確認**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: 全件 PASS

- [ ] **Step 6: コミット**

```bash
git add Sources/QuickTranscriber/Services/TranscriptionService.swift Tests/QuickTranscriberTests/TranscriptionServiceTests.swift
git commit -m "feat: TranscriptionService に loopback 録音セッションを配線

開始失敗は loopbackStartError に保持して文字起こしは続行
（エンジンは無変更）。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: UI 配線 — SettingsView サブトグル + ViewModel 解決 + 失敗アラート

**Files:**
- Modify: `Sources/QuickTranscriber/Views/SettingsView.swift`（`OutputSettingsTab`、486 行付近と 529-537 行の `Section("Audio Recording")`）
- Modify: `Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift`（`startRecording()`、744-767 行付近）

**Interfaces:**
- Consumes: `LoopbackRecordingSession.isEnabled()`（Task 5）、`Constants.AudioRecording.loopbackEnabledKey`（Task 1）、`service.startTranscription(..., loopbackRecordingEnabled:)` + `service.loopbackStartError`（Task 6）
- Produces: なし（末端の UI 層）

**自動テスト対象外の根拠:** SwiftUI ビューと NSAlert は本プロジェクトにビューテスト基盤がなく、判定ロジック（`isEnabled` の default-ON 解決）は Task 5 でテスト済み。ビルド + Task 9 の手動確認で検証する。

- [ ] **Step 1: SettingsView にサブトグルを追加**

`OutputSettingsTab` のプロパティに追加（`audioRecordingEnabled` の直下）:

```swift
    @AppStorage(Constants.AudioRecording.loopbackEnabledKey)
    private var loopbackRecordingEnabled: Bool = true
```

`Section("Audio Recording")` を以下に変更:

```swift
            Section("Audio Recording") {
                Toggle("Record audio during transcription", isOn: $audioRecordingEnabled)
                    .disabled(isRecording)
                if audioRecordingEnabled {
                    Text("Audio is saved as WAV (16kHz mono) alongside the transcript file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle("Record system audio (loopback)", isOn: $loopbackRecordingEnabled)
                        .disabled(isRecording)
                        .padding(.leading, 20)
                    if loopbackRecordingEnabled {
                        Text("Remote meeting voices are captured digitally and saved as a separate **_qt_loopback.wav** file. Requires system audio recording permission on first use.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            }
```

- [ ] **Step 2: ViewModel で設定を解決して渡す**

`TranscriptionViewModel.swift` の `startRecording()` 内、「Resolve audio recording settings」ブロック（744-747 行付近）を変更:

```swift
        // Resolve audio recording settings
        let audioRecordingEnabled = UserDefaults.standard.bool(forKey: "audioRecordingEnabled")
        let audioRecordingDirectory: URL? = audioRecordingEnabled ? fileWriter.resolvedDirectory : nil
        let audioRecordingDatePrefix: String? = audioRecordingEnabled ? datePrefix : nil
        let loopbackRecordingEnabled = audioRecordingEnabled && LoopbackRecordingSession.isEnabled()
```

`service.startTranscription` 呼び出し（752-758 行付近）にパラメータを追加し、成功後に失敗アラートをチェック:

```swift
        let sessionSegments = self.previousSessionSegments
        Task {
            do {
                try await service.startTranscription(
                    language: currentLanguage.rawValue,
                    parameters: params,
                    participantProfiles: participantProfiles,
                    audioRecordingDirectory: audioRecordingDirectory,
                    audioRecordingDatePrefix: audioRecordingDatePrefix,
                    loopbackRecordingEnabled: loopbackRecordingEnabled
                ) { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.applyIncomingState(state, sessionSegments: sessionSegments)
                    }
                }
                if let loopbackError = service.loopbackStartError {
                    Self.showLoopbackFailureAlert(loopbackError)
                }
            } catch {
                NSLog("[QuickTranscriber] Recording error: \(error)")
                isRecording = false
            }
        }
```

- [ ] **Step 3: アラート表示の static メソッドを追加**

`TranscriptionViewModel.swift` のファイル先頭に `import AppKit` を追加（既にあればスキップ）。クラス内（`startRecording()` の後ろ）に追加:

```swift
    /// loopback 録音の開始失敗をユーザーに通知する。
    /// 黙って失敗すると実会議 1 回分の計測機会を失うため、ログだけでなく可視化する。
    /// 文字起こし・マイク録音は既に続行中（TranscriptionService が throw しない設計）。
    private static func showLoopbackFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "System Audio Recording Unavailable"
        alert.informativeText = """
        Loopback recording could not start: \(error.localizedDescription)

        Microphone recording and transcription continue normally.

        To enable loopback: System Settings > Privacy & Security > \
        Screen & System Audio Recording, allow Quick Transcriber, \
        then stop and restart recording.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
```

- [ ] **Step 4: ビルドと回帰テスト**

Run: `swift build 2>&1 | tail -3 && swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: `Build complete!` + 全テスト PASS

- [ ] **Step 5: コミット**

```bash
git add Sources/QuickTranscriber/Views/SettingsView.swift Sources/QuickTranscriber/ViewModels/TranscriptionViewModel.swift
git commit -m "feat: loopback 録音のサブトグルと失敗アラートを追加

デフォルト ON（親トグル OFF なら無効）。開始失敗時は
マイク録音のみで続行し NSAlert で再許可手順を案内する。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: build_app.sh に NSAudioCaptureUsageDescription を追加

**Files:**
- Modify: `Scripts/build_app.sh`（Info.plist 生成の heredoc 内、`NSMicrophoneUsageDescription` の直後）

**Interfaces:**
- Consumes: なし
- Produces: .app バンドルの Info.plist に TCC ダイアログ文言（Task 9 のスモークテストが依存）

- [ ] **Step 1: Info.plist 生成に権限キーを追加**

`Scripts/build_app.sh` の heredoc 内、以下の 2 行:

```
    <key>NSMicrophoneUsageDescription</key>
    <string>Quick Transcriber needs microphone access for real-time transcription.</string>
```

の直後に追加:

```
    <key>NSAudioCaptureUsageDescription</key>
    <string>Quick Transcriber records system audio to capture remote meeting participants digitally (loopback).</string>
```

- [ ] **Step 2: 生成される Info.plist を検証**

Run: `./Scripts/build_app.sh 2>&1 | tail -5 && plutil -lint build/QuickTranscriber.app/Contents/Info.plist && grep -A1 NSAudioCaptureUsageDescription build/QuickTranscriber.app/Contents/Info.plist`
Expected: ビルド成功、`Info.plist: OK`、キーと文言が出力される

- [ ] **Step 3: コミット**

```bash
git add Scripts/build_app.sh
git commit -m "feat: Info.plist に NSAudioCaptureUsageDescription を追加

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: 全テスト + 手動スモークテスト（人間チェックポイント）

**Files:** なし（検証のみ）

**Interfaces:**
- Consumes: Task 1-8 の全成果物
- Produces: スモークテスト結果（Task 10 の PR 本文に記載）

- [ ] **Step 1: 全ユニットテストを実行**

Run: `swift test --filter QuickTranscriberTests 2>&1 | tail -3`
Expected: 全件 PASS（既存 803 件 + 本 PR の新規分、失敗ゼロ）。**失敗があれば Task 10 に進まず修正する**

- [ ] **Step 2: .app をビルドして起動**

Run: `./Scripts/build_app.sh && open build/QuickTranscriber.app`
Expected: アプリが起動する

- [ ] **Step 3: 手動スモークテスト（ユーザーに依頼する）**

エージェントはここで停止し、以下のチェックリストをユーザーに依頼する（GUI 操作と TCC ダイアログは自動化不可）:

1. Settings > Output タブで「Record audio during transcription」を ON にし、サブトグル「Record system audio (loopback)」が ON（デフォルト）で表示されることを確認
2. 音楽（Music.app / YouTube 等）を再生した状態で録音を開始し、10 秒程度話してから停止
3. 初回のみ「システムオーディオ録音」の TCC ダイアログが出るので許可
4. 出力フォルダ（Settings に表示されているディレクトリ）に `{日付}_qt_recording.wav` と `{日付}_qt_loopback.wav` の両方があることを確認
5. loopback WAV の中身を検証（パスは実ファイルに置き換え）:

```bash
afinfo <出力フォルダ>/<日付>_qt_loopback.wav
python3 -c "
import wave, sys, math, struct
w = wave.open(sys.argv[1], 'rb')
n = w.getnframes()
data = w.readframes(n)
samples = struct.unpack('<%dh' % (len(data) // 2), data)
rms = math.sqrt(sum(s * s for s in samples) / max(len(samples), 1))
print('frames:', n, 'duration_s:', n / 16000.0, 'rms:', round(rms, 1))
" <出力フォルダ>/<日付>_qt_loopback.wav
```

Expected: `afinfo` が 16000 Hz / 1 ch / 16-bit を表示、`rms` が 100 以上（int16 スケール、音楽再生中なら十分超える）

6. 権限拒否フォールバック: システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で Quick Transcriber を OFF にして録音を開始 → NSAlert（System Audio Recording Unavailable）が表示され、文字起こしとマイク録音（`_qt_recording.wav`）は正常動作、loopback WAV は生成されないことを確認。確認後は権限を ON に戻す

- [ ] **Step 4: スモークテスト結果を記録**

チェックリストの各項目の合否をメモする（Task 10 の PR 本文に記載する）。不合格項目があれば superpowers:systematic-debugging で原因を特定して修正し、Step 1 からやり直す

---

### Task 10: PR 作成 + バージョン更新

**Files:**
- Modify: `Sources/QuickTranscriber/Constants.swift`（`Version.patch`、61 行付近）

**Interfaces:**
- Consumes: Task 9 の全テスト PASS + スモークテスト結果
- Produces: レビュー可能な PR

- [ ] **Step 1: ブランチを push して PR を作成**

（ブランチは実行開始時に superpowers:using-git-worktrees で作成済みの前提。ブランチ名例: `feature/loopback-capture-phase1`）

```bash
git push -u origin feature/loopback-capture-phase1
gh pr create --title "feat: システムオーディオ loopback 同時録音 (Phase 1)" --body "$(cat <<'EOF'
## Summary
- Zoom 等のリモート会議音声を Core Audio Process Tap（全プロセス mixdown・自プロセス除外）でデジタルにキャプチャし、`{日付}_qt_loopback.wav` としてマイク録音と並行保存する
- Settings にサブトグル「Record system audio (loopback)」を追加（デフォルト ON、親トグル OFF なら無効）。権限拒否時はマイク録音のみで続行し NSAlert で再許可手順を案内
- `ChunkedWhisperEngine` は無変更（配線は TranscriptionService 層のみ）

## 背景
PR #91 で話者分離不能の犯人が「Zoom 遠端音声の音響経路（共有伝達関数）」と確定。本 PR はその対策 Phase 1 で、次の実会議で separability 事前計測の資産を取得できる状態にする。spec: `docs/superpowers/specs/2026-07-17-loopback-capture-design.md`

## Test plan
- [ ] `swift test --filter QuickTranscriberTests` 全件 PASS
- [ ] 手動スモークテスト（結果を追記）: 音楽再生中の 10 秒録音で loopback WAV が非無音（RMS 実測値）・16kHz/mono/16-bit、権限拒否時のフォールバック動作

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL が出力される。**URL 中の PR 番号を控える**

- [ ] **Step 2: Version.patch を PR 番号に更新**

`Sources/QuickTranscriber/Constants.swift` の `Version.patch` を Step 1 で得た PR 番号（N）に変更:

```swift
        public static let patch = N  // ← 実際の PR 番号
```

- [ ] **Step 3: ビルド確認とコミット**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

```bash
git add Sources/QuickTranscriber/Constants.swift
git commit -m "chore: bump version to 2.4.N

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

（N は実際の PR 番号に置き換え）

- [ ] **Step 4: スモークテスト結果を PR 本文に反映**

```bash
gh pr edit <PR番号> --body "..."  # Test plan のチェックボックスを実測結果で更新
```

その後は superpowers:requesting-code-review → superpowers:finishing-a-development-branch でマージ判断へ。

---

## Phase 1.5 リマインダ（本計画の実装対象外）

マージ・リリース後、次の Zoom 実会議で録音 + loopback を ON にして 4 ファイル一式
（`*_qt_recording.wav` / `*_qt_loopback.wav` / `qt_transcript.md` / `zoom_transcript.txt`）を
`~/Documents/QuickTranscriber/real-sessions/` に保存し、separability プロトコル
（spec の「計測プロトコル」参照）で Phase 2 GO/NO-GO を判定する。
