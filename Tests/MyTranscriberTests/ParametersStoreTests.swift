import XCTest
@testable import MyTranscriberLib

@MainActor
final class ParametersStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
        UserDefaults.standard.removeObject(forKey: "engineType")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
        UserDefaults.standard.removeObject(forKey: "engineType")
        super.tearDown()
    }

    // MARK: - Default Initialization

    func testDefaultInitialization() {
        let store = ParametersStore()
        XCTAssertEqual(store.parameters, .default)
        XCTAssertEqual(store.engineType, .streaming)
    }

    // MARK: - Parameters Persistence

    func testParametersPersistence() {
        let store = ParametersStore()
        var custom = TranscriptionParameters.default
        custom.temperature = 0.8
        custom.noSpeechThreshold = 0.9
        store.parameters = custom

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.temperature, 0.8)
        XCTAssertEqual(store2.parameters.noSpeechThreshold, 0.9)
        XCTAssertEqual(store2.parameters, custom)
    }

    // MARK: - EngineType Persistence

    func testEngineTypePersistence() {
        let store = ParametersStore()
        store.engineType = .chunked

        let store2 = ParametersStore()
        XCTAssertEqual(store2.engineType, .chunked)
    }

    // MARK: - Reset to Defaults

    func testResetToDefaults() {
        let store = ParametersStore()
        var custom = TranscriptionParameters.default
        custom.temperature = 0.5
        custom.sampleLength = 100
        store.parameters = custom
        XCTAssertNotEqual(store.parameters, .default)

        store.resetToDefaults()
        XCTAssertEqual(store.parameters, .default)
    }

    func testResetToDefaultsPersists() {
        let store = ParametersStore()
        var custom = TranscriptionParameters.default
        custom.temperature = 0.5
        store.parameters = custom

        store.resetToDefaults()

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters, .default)
    }

    // MARK: - Corruption Fallback

    func testCorruptedParametersFallsBackToDefault() {
        // Write invalid Data that cannot be decoded as TranscriptionParameters
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        UserDefaults.standard.set(garbage, forKey: "transcriptionParameters")

        let store = ParametersStore()
        XCTAssertEqual(store.parameters, .default)
    }

    func testInvalidEngineTypeFallsBackToStreaming() {
        UserDefaults.standard.set("nonexistent_engine", forKey: "engineType")

        let store = ParametersStore()
        XCTAssertEqual(store.engineType, .streaming)
    }

    // MARK: - EngineType Properties

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
        XCTAssertTrue(EngineType.allCases.contains(.streaming))
        XCTAssertTrue(EngineType.allCases.contains(.chunked))
    }

    // MARK: - All Fields Persistence

    func testAllParameterFieldsPersist() {
        let store = ParametersStore()
        let custom = TranscriptionParameters(
            requiredSegmentsForConfirmation: 3,
            silenceThreshold: 0.7,
            compressionCheckWindow: 15,
            useVAD: false,
            temperature: 0.5,
            temperatureFallbackCount: 2,
            noSpeechThreshold: 0.8,
            concurrentWorkerCount: 2,
            compressionRatioThreshold: 3.0,
            logProbThreshold: -2.0,
            firstTokenLogProbThreshold: -3.0,
            sampleLength: 128,
            windowClipTime: 2.0,
            chunkDuration: 5.0,
            silenceCutoffDuration: 1.5,
            silenceEnergyThreshold: 0.05
        )
        store.parameters = custom

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.requiredSegmentsForConfirmation, 3)
        XCTAssertEqual(store2.parameters.silenceThreshold, 0.7)
        XCTAssertEqual(store2.parameters.compressionCheckWindow, 15)
        XCTAssertEqual(store2.parameters.useVAD, false)
        XCTAssertEqual(store2.parameters.temperature, 0.5)
        XCTAssertEqual(store2.parameters.temperatureFallbackCount, 2)
        XCTAssertEqual(store2.parameters.noSpeechThreshold, 0.8)
        XCTAssertEqual(store2.parameters.concurrentWorkerCount, 2)
        XCTAssertEqual(store2.parameters.compressionRatioThreshold, 3.0)
        XCTAssertEqual(store2.parameters.logProbThreshold, -2.0)
        XCTAssertEqual(store2.parameters.firstTokenLogProbThreshold, -3.0)
        XCTAssertEqual(store2.parameters.sampleLength, 128)
        XCTAssertEqual(store2.parameters.windowClipTime, 2.0)
        XCTAssertEqual(store2.parameters.chunkDuration, 5.0)
        XCTAssertEqual(store2.parameters.silenceCutoffDuration, 1.5)
        XCTAssertEqual(store2.parameters.silenceEnergyThreshold, 0.05)
        XCTAssertEqual(store2.parameters, custom)
    }

    // MARK: - Multiple Changes Persistence

    func testParametersPersistenceAfterMultipleChanges() {
        let store = ParametersStore()

        // First change
        var params1 = TranscriptionParameters.default
        params1.temperature = 0.1
        store.parameters = params1

        // Second change
        var params2 = store.parameters
        params2.temperature = 0.5
        params2.sampleLength = 100
        store.parameters = params2

        // Third change
        var params3 = store.parameters
        params3.temperature = 0.9
        params3.noSpeechThreshold = 0.3
        store.parameters = params3

        // New instance should have the last values
        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.temperature, 0.9)
        XCTAssertEqual(store2.parameters.sampleLength, 100)
        XCTAssertEqual(store2.parameters.noSpeechThreshold, 0.3)
        XCTAssertEqual(store2.parameters, params3)
    }
}
