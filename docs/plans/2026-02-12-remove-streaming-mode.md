# Streamingモード削除 — Chunked専用化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Streamingモードを完全に削除し、Chunkedモードのみをサポートするシンプルなアプリにする。

**Architecture:** WhisperKitEngine/WhisperKitProviding（Streaming専用）を削除し、共有ユーティリティ（cleanSegmentText, WhisperKitEngineError）を適切な場所に移動する。EngineType enum、エンジン切替UI、Streaming専用パラメータを除去して、コードベース全体をChunked専用に簡素化する。

**Tech Stack:** Swift, SwiftUI, WhisperKit

---

### Task 1: ユーティリティ関数の移動

`WhisperKitEngine.cleanSegmentText` と `WhisperKitEngineError` は ChunkTranscriber と BenchmarkRunner からも参照されている。WhisperKitEngine削除前に、これらを独立した場所に移動する。

**Files:**
- Create: `Sources/MyTranscriber/Engines/TranscriptionUtils.swift`
- Modify: `Sources/MyTranscriber/Engines/ChunkTranscriber.swift`
- Modify: `Tests/MyTranscriberBenchmarks/BenchmarkRunner.swift`
- Modify: `Tests/MyTranscriberTests/WhisperKitEngineUtilTests.swift`

**Step 1: `TranscriptionUtils.swift` を作成**

```swift
import Foundation

public enum TranscriptionUtils {
    public static func cleanSegmentText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\u{FFFD}", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriptionEngineError: LocalizedError {
    case notInitialized
    case tokenizerNotAvailable

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized. Call setup() first."
        case .tokenizerNotAvailable:
            return "Tokenizer is not available. Model may not be loaded correctly."
        }
    }
}
```

**Step 2: `ChunkTranscriber.swift` の参照を更新**

- `WhisperKitEngineError.notInitialized` → `TranscriptionEngineError.notInitialized`
- `WhisperKitEngine.cleanSegmentText($0.text)` → `TranscriptionUtils.cleanSegmentText($0.text)`

**Step 3: `BenchmarkRunner.swift` の参照を更新**

- `WhisperKitEngine.cleanSegmentText($0.text)` → `TranscriptionUtils.cleanSegmentText($0.text)`

**Step 4: `WhisperKitEngineUtilTests.swift` を更新**

- ファイル名を `TranscriptionUtilsTests.swift` にリネーム
- `WhisperKitEngine.cleanSegmentText` → `TranscriptionUtils.cleanSegmentText` に全置換
- クラス名を `TranscriptionUtilsTests` に変更

**Step 5: テスト実行**

Run: `swift test --filter MyTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 6: コミット**

```bash
git add -A && git commit -m "refactor: move cleanSegmentText and error types to TranscriptionUtils"
```

---

### Task 2: Streamingエンジンファイルの削除

**Files:**
- Delete: `Sources/MyTranscriber/Engines/WhisperKitEngine.swift`
- Delete: `Sources/MyTranscriber/Engines/WhisperKitProviding.swift`
- Delete: `Tests/MyTranscriberTests/WhisperKitEngineTests.swift`
- Delete: `Tests/MyTranscriberTests/Mocks/MockWhisperKitProvider.swift`

**Step 1: 4ファイルを削除**

```bash
rm Sources/MyTranscriber/Engines/WhisperKitEngine.swift
rm Sources/MyTranscriber/Engines/WhisperKitProviding.swift
rm Tests/MyTranscriberTests/WhisperKitEngineTests.swift
rm Tests/MyTranscriberTests/Mocks/MockWhisperKitProvider.swift
```

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -10`
Expected: Build complete!

**Step 3: テスト実行**

Run: `swift test --filter MyTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 4: コミット**

```bash
git add -A && git commit -m "remove: delete WhisperKitEngine and WhisperKitProviding (Streaming mode)"
```

---

### Task 3: EngineType enum とエンジン切替ロジックの削除

**Files:**
- Modify: `Sources/MyTranscriber/Models/ParametersStore.swift`
- Modify: `Sources/MyTranscriber/ViewModels/TranscriptionViewModel.swift`

**Step 1: `ParametersStore.swift` を簡素化**

EngineType enum を完全に削除。engineType プロパティと関連するUserDefaults永続化を除去。

```swift
import Foundation

@MainActor
public final class ParametersStore: ObservableObject {
    public static let shared = ParametersStore()

    private static let userDefaultsKey = "transcriptionParameters"

    @Published public var parameters: TranscriptionParameters {
        didSet {
            saveParameters()
        }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(TranscriptionParameters.self, from: data) {
            self.parameters = decoded
        } else {
            self.parameters = .default
        }
    }

    public func resetToDefaults() {
        parameters = .default
    }

    private func saveParameters() {
        if let data = try? JSONEncoder().encode(parameters) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
```

**Step 2: `TranscriptionViewModel.swift` を簡素化**

- `createEngine` のswitch文 → 常に `ChunkedWhisperEngine()` を直接生成
- `switchEngine` メソッドを削除
- `engineType` の `$` 購読を削除

init を以下に変更:
```swift
public init(
    engine: TranscriptionEngine? = nil,
    modelName: String = "large-v3-v20240930_turbo",
    parametersStore: ParametersStore? = nil
) {
    let resolvedStore = parametersStore ?? ParametersStore.shared
    let resolvedEngine = engine ?? ChunkedWhisperEngine()
    self.service = TranscriptionService(engine: resolvedEngine)
    self.modelName = modelName
    self.parametersStore = resolvedStore

    resolvedStore.$parameters
        .dropFirst()
        .removeDuplicates()
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            guard let self, self.isRecording else { return }
            NSLog("[MyTranscriber] Parameters changed, restarting recording")
            self.restartRecording()
        }
        .store(in: &cancellables)
}
```

`createEngine`、`switchEngine` メソッドを完全に削除。

**Step 3: テスト実行**

Run: `swift test --filter MyTranscriberTests 2>&1 | tail -5`
Expected: EngineType 参照でコンパイルエラー（次のTaskで修正）

**Step 4: コミット**

```bash
git add -A && git commit -m "remove: delete EngineType enum and engine switching logic"
```

---

### Task 4: テストのStreaming参照を除去

**Files:**
- Modify: `Tests/MyTranscriberTests/ParametersTests.swift`
- Modify: `Tests/MyTranscriberTests/ParametersStoreTests.swift`
- Modify: `Tests/MyTranscriberTests/TranscriptionViewModelTests.swift`

**Step 1: `ParametersTests.swift` を修正**

- `testAggressivePresetPreservesChunkedDefaults` を削除（aggressive プリセット自体を削除するため）
- `testEngineTypeDisplayNames` を削除

残すテスト:
```swift
import XCTest
@testable import MyTranscriberLib

final class ParametersTests: XCTestCase {

    func testDefaultParametersChunkedValues() {
        let params = TranscriptionParameters.default
        XCTAssertEqual(params.chunkDuration, 3.0)
        XCTAssertEqual(params.silenceCutoffDuration, 0.8)
        XCTAssertEqual(params.silenceEnergyThreshold, 0.01)
    }
}
```

**Step 2: `ParametersStoreTests.swift` を修正**

以下のテストを削除:
- `testDefaultInitialization` の `engineType` アサーション行
- `testEngineTypePersistence`
- `testInvalidEngineTypeFallsBackToStreaming`
- `testEngineTypeDisplayName`
- `testEngineTypeIdentifiable`
- `testEngineTypeCaseIterable`
- `testAllParameterFieldsPersist` のStreaming専用パラメータのアサーション行
- `testParametersPersistenceAfterMultipleChanges` の `noSpeechThreshold` 関連行

setUp/tearDown の `UserDefaults.standard.removeObject(forKey: "engineType")` も削除。

`testAllParameterFieldsPersist` の `TranscriptionParameters(...)` 初期化からStreaming専用パラメータを除去。

**Step 3: `TranscriptionViewModelTests.swift` を修正**

- `testSwitchEngineReloadsModel` テストを削除

**Step 4: テスト実行**

Run: `swift test --filter MyTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 5: コミット**

```bash
git add -A && git commit -m "test: remove Streaming-specific test cases"
```

---

### Task 5: TranscriptionParameters のStreaming専用フィールド削除

**Files:**
- Modify: `Sources/MyTranscriber/Models/TranscriptionParameters.swift`

**Step 1: Streaming専用フィールドと aggressive プリセットを削除**

```swift
import Foundation

public struct TranscriptionParameters: Codable, Sendable, Equatable {
    public var temperature: Float
    public var temperatureFallbackCount: Int
    /// Max 224 for large-v3-turbo model (WhisperKit internal buffer limit)
    public var sampleLength: Int
    public var concurrentWorkerCount: Int

    // Chunked engine parameters
    public var chunkDuration: TimeInterval
    public var silenceCutoffDuration: TimeInterval
    public var silenceEnergyThreshold: Float

    public init(
        temperature: Float = 0.0,
        temperatureFallbackCount: Int = 0,
        sampleLength: Int = 224,
        concurrentWorkerCount: Int = 4,
        chunkDuration: TimeInterval = 3.0,
        silenceCutoffDuration: TimeInterval = 0.8,
        silenceEnergyThreshold: Float = 0.01
    ) {
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.sampleLength = sampleLength
        self.concurrentWorkerCount = concurrentWorkerCount
        self.chunkDuration = chunkDuration
        self.silenceCutoffDuration = silenceCutoffDuration
        self.silenceEnergyThreshold = silenceEnergyThreshold
    }

    public static let `default` = TranscriptionParameters()
}
```

**Step 2: テスト実行**

Run: `swift test --filter MyTranscriberTests 2>&1 | tail -5`
Expected: All tests passed

**Step 3: コミット**

```bash
git add -A && git commit -m "refactor: remove Streaming-only parameters from TranscriptionParameters"
```

---

### Task 6: SettingsView のStreaming UI 削除

**Files:**
- Modify: `Sources/MyTranscriber/Views/SettingsView.swift`

**Step 1: SettingsView を Chunked 専用に簡素化**

- `engineSection`（Engine Picker）を削除
- `vadSection`（Voice Activity Detection）を削除
- `segmentSection`（Segment Confirmation）を削除
- `thresholdsSection`（Quality Thresholds）を削除
- Presetsセクション（Aggressive / Default）を削除
- `engineType` による条件分岐を削除
- `chunkedSection` と `decodingSection` をフラットに配置
- ウィンドウ高さを縮小（580 → 400程度）

```swift
import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var store = ParametersStore.shared

    public init() {}

    public var body: some View {
        TabView {
            TranscriptionSettingsTab(store: store)
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }
        }
        .frame(width: 480, height: 400)
    }
}

private struct TranscriptionSettingsTab: View {
    @ObservedObject var store: ParametersStore

    var body: some View {
        Form {
            chunkSection
            decodingSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Chunk Settings

    private var chunkSection: some View {
        Section("Chunk Settings") {
            DoubleSliderRow(
                label: "Chunk Duration",
                value: $store.parameters.chunkDuration,
                range: 1.0...10.0,
                step: 0.5,
                format: "%.1f s"
            )

            DoubleSliderRow(
                label: "Silence Cutoff",
                value: $store.parameters.silenceCutoffDuration,
                range: 0.3...2.0,
                step: 0.1,
                format: "%.1f s"
            )

            SliderRow(
                label: "Silence Threshold",
                value: $store.parameters.silenceEnergyThreshold,
                range: 0.001...0.1,
                step: 0.001,
                format: "%.3f"
            )
        }
    }

    // MARK: - Decoding

    private var decodingSection: some View {
        Section("Decoding") {
            SliderRow(
                label: "Temperature",
                value: $store.parameters.temperature,
                range: 0.0...1.0,
                step: 0.05,
                format: "%.2f"
            )

            StepperRow(
                label: "Temperature Fallback Count",
                value: $store.parameters.temperatureFallbackCount,
                range: 0...5
            )

            StepperRow(
                label: "Sample Length",
                value: $store.parameters.sampleLength,
                range: 1...224
            )

            StepperRow(
                label: "Concurrent Workers",
                value: $store.parameters.concurrentWorkerCount,
                range: 1...8
            )
        }
    }
}

// MARK: - Reusable Controls
// SliderRow, DoubleSliderRow, StepperRow はそのまま残す
```

**Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -10`
Expected: Build complete!

**Step 3: コミット**

```bash
git add -A && git commit -m "ui: simplify SettingsView to Chunked-only parameters"
```

---

### Task 7: CLAUDE.md とドキュメントの更新

**Files:**
- Modify: `CLAUDE.md`

**Step 1: CLAUDE.md を更新**

Architecture セクションから Streaming/エンジン切替の記述を削除。Chunked専用であることを明記。

**Step 2: コミット**

```bash
git add CLAUDE.md && git commit -m "docs: update CLAUDE.md for Chunked-only architecture"
```

---

### Task 8: 最終検証

**Step 1: ビルド**

Run: `swift build 2>&1 | tail -10`
Expected: Build complete!

**Step 2: 全ユニットテスト**

Run: `swift test --filter MyTranscriberTests 2>&1 | tail -10`
Expected: All tests passed

**Step 3: Streaming関連の残骸がないか確認**

Run: `grep -r "streaming\|WhisperKitEngine\|EngineType\|WhisperKitProviding" Sources/ Tests/MyTranscriberTests/ --include="*.swift" -l`
Expected: 該当なし（TranscriptionUtils内のリネーム後の参照のみ）
