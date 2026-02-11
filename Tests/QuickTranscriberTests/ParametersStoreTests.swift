import XCTest
@testable import QuickTranscriberLib

@MainActor
final class ParametersStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "transcriptionParameters")
        super.tearDown()
    }

    // MARK: - Default Initialization

    func testDefaultInitialization() {
        let store = ParametersStore()
        XCTAssertEqual(store.parameters, .default)
    }

    // MARK: - Parameters Persistence

    func testParametersPersistence() {
        let store = ParametersStore()
        var custom = TranscriptionParameters.default
        custom.temperature = 0.8
        store.parameters = custom

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.temperature, 0.8)
        XCTAssertEqual(store2.parameters, custom)
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
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        UserDefaults.standard.set(garbage, forKey: "transcriptionParameters")

        let store = ParametersStore()
        XCTAssertEqual(store.parameters, .default)
    }

    // MARK: - All Fields Persistence

    func testAllParameterFieldsPersist() {
        let store = ParametersStore()
        let custom = TranscriptionParameters(
            temperature: 0.5,
            temperatureFallbackCount: 2,
            sampleLength: 128,
            concurrentWorkerCount: 2,
            chunkDuration: 5.0,
            silenceCutoffDuration: 1.5,
            silenceEnergyThreshold: 0.05
        )
        store.parameters = custom

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.temperature, 0.5)
        XCTAssertEqual(store2.parameters.temperatureFallbackCount, 2)
        XCTAssertEqual(store2.parameters.sampleLength, 128)
        XCTAssertEqual(store2.parameters.concurrentWorkerCount, 2)
        XCTAssertEqual(store2.parameters.chunkDuration, 5.0)
        XCTAssertEqual(store2.parameters.silenceCutoffDuration, 1.5)
        XCTAssertEqual(store2.parameters.silenceEnergyThreshold, 0.05)
        XCTAssertEqual(store2.parameters, custom)
    }

    // MARK: - Multiple Changes Persistence

    func testParametersPersistenceAfterMultipleChanges() {
        let store = ParametersStore()

        var params1 = TranscriptionParameters.default
        params1.temperature = 0.1
        store.parameters = params1

        var params2 = store.parameters
        params2.temperature = 0.5
        params2.sampleLength = 100
        store.parameters = params2

        var params3 = store.parameters
        params3.temperature = 0.9
        store.parameters = params3

        let store2 = ParametersStore()
        XCTAssertEqual(store2.parameters.temperature, 0.9)
        XCTAssertEqual(store2.parameters.sampleLength, 100)
        XCTAssertEqual(store2.parameters, params3)
    }
}
