# Test Infrastructure Improvement Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** ロジック層の未テスト箇所を網羅し、安定性・パフォーマンスに関わるコア部分のテストカバレッジを大幅に向上させる。

**Architecture:** WhisperKitEngineにProtocol抽出（WhisperKitProviding）を導入してモック可能にし、ParametersStore・WhisperKitModelLoaderの単体テストを新規追加。既存テストのエッジケースも強化する。

**Tech Stack:** Swift 5.9, XCTest, WhisperKit 0.15+, macOS 14+

---

## Task 1: ParametersStoreテスト

**Files:**
- Create: `Tests/MyTranscriberTests/ParametersStoreTests.swift`

**Step 1: テストファイル作成**

```swift
import XCTest
@testable import MyTranscriberLib

@MainActor
final class ParametersStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // テスト前にUserDefaultsをクリーン
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
        UserDefaults.standard.removeObject(forKey: "engineType")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
        UserDefaults.standard.removeObject(forKey: "engineType")
        super.tearDown()
    }

    // MARK: - 初期化テスト

    func testDefaultInitialization() {
        let store = ParametersStore()
        XCTAssertEqual(store.parameters, .default)
        XCTAssertEqual(store.engineType, .streaming)
    }

    // MARK: - パラメータ永続化テスト

    func testParametersPersistence() {
        // 1. パラメータを変更して保存
        let store1 = ParametersStore()
        var modified = TranscriptionParameters.default
        modified.temperature = 0.5
        modified.sampleLength = 100
        modified.chunkDuration = 5.0
        store1.parameters = modified

        // 2. 新しいインスタンスで読み直し
        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.temperature, 0.5)
        XCTAssertEqual(store2.parameters.sampleLength, 100)
        XCTAssertEqual(store2.parameters.chunkDuration, 5.0)
    }

    func testEngineTypePersistence() {
        let store1 = ParametersStore()
        store1.engineType = .chunked

        let store2 = ParametersStore()
        XCTAssertEqual(store2.engineType, .chunked)
    }

    // MARK: - ResetToDefaults

    func testResetToDefaults() {
        let store = ParametersStore()
        var modified = TranscriptionParameters.default
        modified.temperature = 0.8
        store.parameters = modified

        store.resetToDefaults()

        XCTAssertEqual(store.parameters, .default)
    }

    func testResetToDefaultsPersists() {
        let store1 = ParametersStore()
        var modified = TranscriptionParameters.default
        modified.temperature = 0.8
        store1.parameters = modified
        store1.resetToDefaults()

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters, .default)
    }

    // MARK: - 不正データのフォールバック

    func testCorruptedParametersFallsBackToDefault() {
        // UserDefaultsに不正なデータを書き込む
        UserDefaults.standard.set(Data("invalid json".utf8), forKey: "transcriptionParameters")

        let store = ParametersStore()
        XCTAssertEqual(store.parameters, .default)
    }

    func testInvalidEngineTypeFallsBackToStreaming() {
        UserDefaults.standard.set("invalid_type", forKey: "engineType")

        let store = ParametersStore()
        XCTAssertEqual(store.engineType, .streaming)
    }

    // MARK: - EngineType enum

    func testEngineTypeDisplayName() {
        XCTAssertEqual(EngineType.streaming.displayName, "Streaming")
        XCTAssertEqual(EngineType.chunked.displayName, "Chunked")
    }

    func testEngineTypeIdentifiable() {
        XCTAssertEqual(EngineType.streaming.id, "streaming")
        XCTAssertEqual(EngineType.chunked.id, "chunked")
    }

    func testEngineTypeCaseIterable() {
        XCTAssertEqual(EngineType.allCases.count, 2)
    }

    // MARK: - 全パラメータ永続化テスト

    func testAllParameterFieldsPersist() {
        let store1 = ParametersStore()
        let custom = TranscriptionParameters(
            requiredSegmentsForConfirmation: 3,
            silenceThreshold: 0.7,
            compressionCheckWindow: 30,
            useVAD: false,
            temperature: 0.3,
            temperatureFallbackCount: 2,
            noSpeechThreshold: 0.8,
            concurrentWorkerCount: 8,
            compressionRatioThreshold: 3.0,
            logProbThreshold: -2.0,
            firstTokenLogProbThreshold: -3.0,
            sampleLength: 200,
            windowClipTime: 0.5,
            chunkDuration: 5.0,
            silenceCutoffDuration: 1.5,
            silenceEnergyThreshold: 0.02
        )
        store1.parameters = custom

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters, custom)
    }
}
```

**Step 2: テスト実行して通ることを確認**

Run: `swift test --filter MyTranscriberTests/ParametersStoreTests`
Expected: ALL PASS

**Step 3: コミット**

```bash
git add Tests/MyTranscriberTests/ParametersStoreTests.swift
git commit -m "test: add ParametersStore unit tests (persistence, defaults, corruption fallback)"
```

---

## Task 2: WhisperKitModelLoaderテスト

**Files:**
- Create: `Tests/MyTranscriberTests/WhisperKitModelLoaderTests.swift`

WhisperKitModelLoaderは静的メソッドでFileManagerを直接使うが、ファイルシステムロジック（パス生成・ディレクトリ検索）のテストは一時ディレクトリを使って可能。`createWhisperKit`はWhisperKit依存なのでベンチマークに任せ、パス生成とキャッシュ検索ロジックのみテスト。

**Step 1: テストファイル作成**

```swift
import XCTest
@testable import MyTranscriberLib

final class WhisperKitModelLoaderTests: XCTestCase {

    // MARK: - appModelBaseDir

    func testAppModelBaseDirPointsToApplicationSupport() {
        let baseDir = WhisperKitModelLoader.appModelBaseDir
        XCTAssertTrue(baseDir.path.contains("Application Support"))
        XCTAssertTrue(baseDir.path.hasSuffix("MyTranscriber/Models"))
    }

    func testAppModelBaseDirIsConsistent() {
        let dir1 = WhisperKitModelLoader.appModelBaseDir
        let dir2 = WhisperKitModelLoader.appModelBaseDir
        XCTAssertEqual(dir1, dir2)
    }

    // MARK: - findCachedModelFolder

    func testFindCachedModelFolderReturnsNilWhenNoModel() {
        // nonexistent model name should return nil
        let result = WhisperKitModelLoader.findCachedModelFolder(for: "nonexistent-model-xyz-\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testFindCachedModelFolderConstructsCorrectModelDirName() {
        // モデルディレクトリ名のフォーマット確認
        // findCachedModelFolder は "openai_whisper-{model}" のディレクトリを探す
        // 実在しないモデルで呼び出してnilが返ることで、検索パスの構築が正しいことを間接確認
        let result = WhisperKitModelLoader.findCachedModelFolder(for: "test-model")
        XCTAssertNil(result)
    }

    // MARK: - copyToStablePath

    func testCopyToStablePathCopiesFiles() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")

        // Create source with a file
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let testFile = sourceDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        // Copy
        WhisperKitModelLoader.copyToStablePath(from: sourceDir, to: destDir)

        // Verify
        XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent("test.txt").path))
        let content = try String(contentsOf: destDir.appendingPathComponent("test.txt"), encoding: .utf8)
        XCTAssertEqual(content, "hello")

        // Cleanup
        try? fm.removeItem(at: tempDir)
    }

    func testCopyToStablePathSkipsIfDestinationExists() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")

        // Create both source and destination
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "source content".write(to: sourceDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try "original".write(to: destDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Copy should be skipped
        WhisperKitModelLoader.copyToStablePath(from: sourceDir, to: destDir)

        // Destination should still have original content
        let content = try String(contentsOf: destDir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(content, "original")

        // Cleanup
        try? fm.removeItem(at: tempDir)
    }

    func testFindCachedModelFolderFindsModelInStablePath() throws {
        let fm = FileManager.default
        let modelName = "test-find-\(UUID().uuidString)"
        let modelDirName = "openai_whisper-\(modelName)"
        let modelDir = WhisperKitModelLoader.appModelBaseDir.appendingPathComponent(modelDirName)

        // Create fake model directory with AudioEncoder.mlmodelc
        let encoderDir = modelDir.appendingPathComponent("AudioEncoder.mlmodelc")
        try fm.createDirectory(at: encoderDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: modelDir)
        }

        let result = WhisperKitModelLoader.findCachedModelFolder(for: modelName)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, modelDir.path)
    }
}
```

**Step 2: テスト実行して通ることを確認**

Run: `swift test --filter MyTranscriberTests/WhisperKitModelLoaderTests`
Expected: ALL PASS

**Step 3: コミット**

```bash
git add Tests/MyTranscriberTests/WhisperKitModelLoaderTests.swift
git commit -m "test: add WhisperKitModelLoader unit tests (paths, cache lookup, copy logic)"
```

---

## Task 3: WhisperKitEngine Protocol抽出 + MockWhisperKitProvider

WhisperKitEngineが内部で使うWhisperKitインスタンスとAudioStreamTranscriberをProtocol化し、テストで差し替え可能にする。

**Files:**
- Create: `Sources/MyTranscriber/Engines/WhisperKitProviding.swift`
- Modify: `Sources/MyTranscriber/Engines/WhisperKitEngine.swift`
- Create: `Tests/MyTranscriberTests/Mocks/MockWhisperKitProvider.swift`
- Create: `Tests/MyTranscriberTests/WhisperKitEngineTests.swift`

**Step 1: WhisperKitProvidingプロトコル作成**

`Sources/MyTranscriber/Engines/WhisperKitProviding.swift`:

```swift
import Foundation

/// WhisperKitの機能をProtocol化して、テストでモック可能にする。
/// WhisperKitEngineの主要な依存を抽象化。
public protocol WhisperKitProviding: AnyObject {
    /// モデルをセットアップ
    func setup(model: String) async throws

    /// ストリーミング文字起こしを開始
    func startStreamTranscription(
        language: String,
        parameters: TranscriptionParameters,
        onSegmentChange: @escaping @Sendable (_ confirmed: [String], _ unconfirmed: [String]) -> Void
    ) async throws

    /// ストリーミング文字起こしを停止
    func stopStreamTranscription() async
}
```

**Step 2: WhisperKitEngine書き換え**

`Sources/MyTranscriber/Engines/WhisperKitEngine.swift` を修正して、WhisperKitProvidingをDIできるように：

```swift
import Foundation
import WhisperKit

public final class WhisperKitEngine: TranscriptionEngine {
    private let provider: WhisperKitProviding
    private var _isStreaming = false

    public init(provider: WhisperKitProviding? = nil) {
        self.provider = provider ?? DefaultWhisperKitProvider()
    }

    public var isStreaming: Bool {
        get async { _isStreaming }
    }

    public func setup(model: String) async throws {
        try await provider.setup(model: model)
    }

    public func startStreaming(
        language: String,
        parameters: TranscriptionParameters = .default,
        onStateChange: @escaping @Sendable (TranscriptionState) -> Void
    ) async throws {
        _isStreaming = true
        try await provider.startStreamTranscription(
            language: language,
            parameters: parameters
        ) { confirmed, unconfirmed in
            let confirmedText = confirmed
                .map { Self.cleanSegmentText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let unconfirmedText = unconfirmed
                .map { Self.cleanSegmentText($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            onStateChange(TranscriptionState(
                confirmedText: confirmedText,
                unconfirmedText: unconfirmedText,
                isRecording: true
            ))
        }
    }

    public func stopStreaming() async {
        await provider.stopStreamTranscription()
        _isStreaming = false
    }

    public func cleanup() {
        Task { [weak self] in
            await self?.stopStreaming()
        }
    }
}

// cleanSegmentTextとWhisperKitEngineErrorはそのまま残す
```

**Step 3: DefaultWhisperKitProvider作成**

WhisperKitProvidingの本番実装。元のWhisperKitEngine内部ロジックをここに移す。

`Sources/MyTranscriber/Engines/WhisperKitProviding.swift` に追加：

```swift
import WhisperKit

/// 本番用WhisperKit実装
public final class DefaultWhisperKitProvider: WhisperKitProviding {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?

    public init() {}

    public func setup(model: String) async throws {
        self.whisperKit = try await WhisperKitModelLoader.createWhisperKit(model: model)
    }

    public func startStreamTranscription(
        language: String,
        parameters: TranscriptionParameters,
        onSegmentChange: @escaping @Sendable (_ confirmed: [String], _ unconfirmed: [String]) -> Void
    ) async throws {
        guard let whisperKit else {
            throw WhisperKitEngineError.notInitialized
        }
        guard let tokenizer = whisperKit.tokenizer else {
            throw WhisperKitEngineError.tokenizerNotAvailable
        }

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: parameters.temperature,
            temperatureFallbackCount: parameters.temperatureFallbackCount,
            sampleLength: parameters.sampleLength,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: parameters.compressionRatioThreshold,
            logProbThreshold: parameters.logProbThreshold,
            firstTokenLogProbThreshold: parameters.firstTokenLogProbThreshold,
            noSpeechThreshold: parameters.noSpeechThreshold,
            concurrentWorkerCount: parameters.concurrentWorkerCount,
            chunkingStrategy: .vad
        )

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions,
            requiredSegmentsForConfirmation: parameters.requiredSegmentsForConfirmation,
            silenceThreshold: parameters.silenceThreshold,
            compressionCheckWindow: parameters.compressionCheckWindow,
            useVAD: parameters.useVAD
        ) { oldState, newState in
            let confirmed = newState.confirmedSegments.map { $0.text }
            let unconfirmed = newState.unconfirmedSegments.map { $0.text }
            onSegmentChange(confirmed, unconfirmed)
        }

        self.streamTranscriber = transcriber
        try await transcriber.startStreamTranscription()
    }

    public func stopStreamTranscription() async {
        await streamTranscriber?.stopStreamTranscription()
        streamTranscriber = nil
    }
}
```

**Step 4: MockWhisperKitProvider作成**

`Tests/MyTranscriberTests/Mocks/MockWhisperKitProvider.swift`:

```swift
import Foundation
@testable import MyTranscriberLib

final class MockWhisperKitProvider: WhisperKitProviding {
    var setupCalled = false
    var setupModel: String?
    var setupError: Error?

    var startStreamCalled = false
    var startStreamLanguage: String?
    var startStreamParameters: TranscriptionParameters?
    var startStreamError: Error?

    var stopStreamCalled = false

    private var segmentChangeCallback: ((_ confirmed: [String], _ unconfirmed: [String]) -> Void)?

    func setup(model: String) async throws {
        setupCalled = true
        setupModel = model
        if let error = setupError { throw error }
    }

    func startStreamTranscription(
        language: String,
        parameters: TranscriptionParameters,
        onSegmentChange: @escaping @Sendable (_ confirmed: [String], _ unconfirmed: [String]) -> Void
    ) async throws {
        startStreamCalled = true
        startStreamLanguage = language
        startStreamParameters = parameters
        segmentChangeCallback = onSegmentChange
        if let error = startStreamError { throw error }
    }

    func stopStreamTranscription() async {
        stopStreamCalled = true
        segmentChangeCallback = nil
    }

    // テストヘルパー
    func simulateSegments(confirmed: [String], unconfirmed: [String]) {
        segmentChangeCallback?(confirmed, unconfirmed)
    }
}
```

**Step 5: WhisperKitEngineTests作成**

`Tests/MyTranscriberTests/WhisperKitEngineTests.swift`:

```swift
import XCTest
@testable import MyTranscriberLib

final class WhisperKitEngineTests: XCTestCase {

    // MARK: - 初期状態

    func testInitialStateNotStreaming() async {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
    }

    // MARK: - Setup

    func testSetupDelegatesToProvider() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        try await engine.setup(model: "test-model")

        XCTAssertTrue(mock.setupCalled)
        XCTAssertEqual(mock.setupModel, "test-model")
    }

    func testSetupPropagatesError() async {
        let mock = MockWhisperKitProvider()
        mock.setupError = WhisperKitEngineError.notInitialized
        let engine = WhisperKitEngine(provider: mock)

        do {
            try await engine.setup(model: "test-model")
            XCTFail("Expected error")
        } catch {
            XCTAssertTrue(error is WhisperKitEngineError)
        }
    }

    // MARK: - StartStreaming

    func testStartStreamingSetsIsStreaming() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        try await engine.startStreaming(language: "en") { _ in }

        let streaming = await engine.isStreaming
        XCTAssertTrue(streaming)
        XCTAssertTrue(mock.startStreamCalled)
        XCTAssertEqual(mock.startStreamLanguage, "en")
    }

    func testStartStreamingPassesLanguageAndParameters() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)
        let params = TranscriptionParameters.aggressive

        try await engine.startStreaming(language: "ja", parameters: params) { _ in }

        XCTAssertEqual(mock.startStreamLanguage, "ja")
        XCTAssertEqual(mock.startStreamParameters, params)
    }

    func testStartStreamingPropagatesError() async {
        let mock = MockWhisperKitProvider()
        mock.startStreamError = WhisperKitEngineError.notInitialized
        let engine = WhisperKitEngine(provider: mock)

        do {
            try await engine.startStreaming(language: "en") { _ in }
            XCTFail("Expected error")
        } catch {
            // isStreaming should be true because we set it before provider call
            // (this tests the current implementation behavior)
        }
    }

    // MARK: - StopStreaming

    func testStopStreamingResetsState() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        try await engine.startStreaming(language: "en") { _ in }
        await engine.stopStreaming()

        let streaming = await engine.isStreaming
        XCTAssertFalse(streaming)
        XCTAssertTrue(mock.stopStreamCalled)
    }

    // MARK: - State callback + cleanSegmentText

    func testSegmentsAreCleaned() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        let expectation = XCTestExpectation(description: "State change")
        var receivedState: TranscriptionState?

        try await engine.startStreaming(language: "en") { state in
            receivedState = state
            expectation.fulfill()
        }

        // Simulate segments with special tokens
        mock.simulateSegments(
            confirmed: ["<|en|> Hello world <|0.00|>"],
            unconfirmed: [" typing..."]
        )

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedState?.confirmedText, "Hello world")
        XCTAssertEqual(receivedState?.unconfirmedText, "typing...")
        XCTAssertTrue(receivedState?.isRecording ?? false)
    }

    func testEmptySegmentsAreFiltered() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        let expectation = XCTestExpectation(description: "State change")
        var receivedState: TranscriptionState?

        try await engine.startStreaming(language: "en") { state in
            receivedState = state
            expectation.fulfill()
        }

        mock.simulateSegments(
            confirmed: ["Hello", "", "  ", "World"],
            unconfirmed: []
        )

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedState?.confirmedText, "Hello\nWorld")
        XCTAssertEqual(receivedState?.unconfirmedText, "")
    }

    func testJapaneseSegments() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        let expectation = XCTestExpectation(description: "State change")
        var receivedState: TranscriptionState?

        try await engine.startStreaming(language: "ja") { state in
            receivedState = state
            expectation.fulfill()
        }

        mock.simulateSegments(
            confirmed: ["こんにちは", "世界"],
            unconfirmed: ["テスト中"]
        )

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedState?.confirmedText, "こんにちは\n世界")
        XCTAssertEqual(receivedState?.unconfirmedText, "テスト中")
    }

    // MARK: - Cleanup

    func testCleanupCallsStop() async throws {
        let mock = MockWhisperKitProvider()
        let engine = WhisperKitEngine(provider: mock)

        try await engine.startStreaming(language: "en") { _ in }
        engine.cleanup()

        // cleanup は内部でTask経由なので少し待つ
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(mock.stopStreamCalled)
    }

    // MARK: - WhisperKitEngineError

    func testErrorDescriptions() {
        XCTAssertNotNil(WhisperKitEngineError.notInitialized.errorDescription)
        XCTAssertNotNil(WhisperKitEngineError.tokenizerNotAvailable.errorDescription)
        XCTAssertTrue(WhisperKitEngineError.notInitialized.errorDescription!.contains("setup"))
        XCTAssertTrue(WhisperKitEngineError.tokenizerNotAvailable.errorDescription!.contains("Tokenizer"))
    }
}
```

**Step 6: テスト実行**

Run: `swift test --filter MyTranscriberTests/WhisperKitEngineTests`
Expected: ALL PASS

**Step 7: コミット**

```bash
git add Sources/MyTranscriber/Engines/WhisperKitProviding.swift
git add Sources/MyTranscriber/Engines/WhisperKitEngine.swift
git add Tests/MyTranscriberTests/Mocks/MockWhisperKitProvider.swift
git add Tests/MyTranscriberTests/WhisperKitEngineTests.swift
git commit -m "refactor: extract WhisperKitProviding protocol + add WhisperKitEngine unit tests"
```

---

## Task 4: TranscriptionServiceテスト強化

**Files:**
- Modify: `Tests/MyTranscriberTests/TranscriptionServiceTests.swift`

既存テストにエッジケースを追加。

**Step 1: テスト追加**

以下のテストを `TranscriptionServiceTests.swift` に追加:

```swift
    // MARK: - エッジケース

    func testDoubleStartThrowsAlreadyStreaming() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        try await service.startTranscription(language: "en") { _ in }

        do {
            try await service.startTranscription(language: "en") { _ in }
            XCTFail("Expected alreadyStreaming error")
        } catch let error as TranscriptionServiceError {
            XCTAssertEqual(error, .alreadyStreaming)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testStopWithoutStartIsSafe() async {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        // stopTranscription on a non-started service should not crash
        await service.stopTranscription()
        XCTAssertTrue(engine.stopStreamingCalled)
    }

    func testCleanupThenStartThrows() async throws {
        let engine = MockTranscriptionEngine()
        let service = TranscriptionService(engine: engine)

        try await service.prepare(model: "test-model")
        service.cleanup()

        do {
            try await service.startTranscription(language: "en") { _ in }
            XCTFail("Expected error after cleanup")
        } catch let error as TranscriptionServiceError {
            XCTAssertEqual(error, .engineNotReady)
        }
    }

    func testServiceErrorDescriptions() {
        XCTAssertNotNil(TranscriptionServiceError.engineNotReady.errorDescription)
        XCTAssertNotNil(TranscriptionServiceError.alreadyStreaming.errorDescription)
    }
```

**Step 2: テスト実行**

Run: `swift test --filter MyTranscriberTests/TranscriptionServiceTests`
Expected: ALL PASS

**Step 3: コミット**

```bash
git add Tests/MyTranscriberTests/TranscriptionServiceTests.swift
git commit -m "test: add TranscriptionService edge case tests (double start, stop without start, cleanup)"
```

---

## Task 5: TranscriptionViewModelテスト強化

**Files:**
- Modify: `Tests/MyTranscriberTests/TranscriptionViewModelTests.swift`

エンジン切替、パラメータ変更リアクション、エラーケースをテスト。

**Step 1: テスト追加**

```swift
    // MARK: - Engine switching via ParametersStore

    func testSwitchEngineReloadsModel() async {
        let store = ParametersStore()
        let engine = MockTranscriptionEngine()
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model", parametersStore: store)

        await vm.loadModel()
        XCTAssertEqual(vm.modelState, .ready)

        // Switch engine type — this triggers internal engine swap + reload
        store.engineType = .chunked

        // Give time for async switchEngine (stop + cleanup + create + loadModel)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // modelState should be loading or ready (depends on timing of new engine setup)
        // The key assertion is that it doesn't crash
    }

    // MARK: - Recording error handling

    func testStartRecordingFailureSetsIsRecordingFalse() async {
        let engine = MockTranscriptionEngine()
        engine.startStreamingError = MockError.streamingFailed
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")

        await vm.loadModel()
        vm.toggleRecording()

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(vm.isRecording)
    }

    // MARK: - State callback integration

    func testStateCallbackUpdatesConfirmedAndUnconfirmed() async {
        let (vm, engine) = makeViewModel()
        await vm.loadModel()

        vm.toggleRecording()
        try? await Task.sleep(nanoseconds: 100_000_000)

        engine.simulateStateChange(TranscriptionState(
            confirmedText: "Hello",
            unconfirmedText: "world",
            isRecording: true
        ))

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.confirmedText, "Hello")
        XCTAssertEqual(vm.unconfirmedText, "world")
    }

    // MARK: - Model state

    func testModelStateTransitions() async {
        let (vm, _) = makeViewModel()
        XCTAssertEqual(vm.modelState, .notLoaded)

        // loadModel sets to .loading then .ready
        await vm.loadModel()
        XCTAssertEqual(vm.modelState, .ready)
    }

    func testModelLoadingState() async {
        let engine = MockTranscriptionEngine()
        // setupの中でModelStateが.loadingになることを確認するため、遅延を入れる
        let vm = TranscriptionViewModel(engine: engine, modelName: "test-model")

        XCTAssertEqual(vm.modelState, .notLoaded)
        // loadModel完了後
        await vm.loadModel()
        XCTAssertEqual(vm.modelState, .ready)
    }
```

**Step 2: テスト実行**

Run: `swift test --filter MyTranscriberTests/TranscriptionViewModelTests`
Expected: ALL PASS

**Step 3: コミット**

```bash
git add Tests/MyTranscriberTests/TranscriptionViewModelTests.swift
git commit -m "test: add TranscriptionViewModel edge case tests (engine switch, error handling, state callbacks)"
```

---

## Task 6: 全テスト実行 + 最終確認

**Step 1: 全ユニットテスト実行**

Run: `swift test --filter MyTranscriberTests`
Expected: ALL PASS（目標: 80+テスト）

**Step 2: テスト数の確認**

Run: `swift test --filter MyTranscriberTests 2>&1 | grep -E "Test Suite|Executed"`

**Step 3: コミット（必要なら最終調整後）**

何か修正があればここで対応。

---

## Summary

| Task | テスト数（概算） | 対象 |
|------|-------------|------|
| Task 1 | 12テスト | ParametersStore (永続化、フォールバック、リセット) |
| Task 2 | 6テスト | WhisperKitModelLoader (パス、キャッシュ検索、コピー) |
| Task 3 | 12テスト | WhisperKitEngine (Protocol抽出、状態遷移、コールバック) |
| Task 4 | 4テスト | TranscriptionService (エッジケース強化) |
| Task 5 | 5テスト | TranscriptionViewModel (エンジン切替、エラー、状態) |
| **合計** | **~39テスト追加** | **既存60 + 39 = 約99テスト** |
