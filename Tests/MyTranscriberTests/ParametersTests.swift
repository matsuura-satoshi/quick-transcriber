import XCTest
@testable import MyTranscriberLib

final class ParametersTests: XCTestCase {

    func testDefaultParametersChunkedValues() {
        let params = TranscriptionParameters.default
        XCTAssertEqual(params.chunkDuration, 3.0)
        XCTAssertEqual(params.silenceCutoffDuration, 0.8)
        XCTAssertEqual(params.silenceEnergyThreshold, 0.01)
    }

    func testAggressivePresetPreservesChunkedDefaults() {
        let aggressive = TranscriptionParameters.aggressive
        // Aggressive is a Streaming preset — chunked params should stay at defaults
        XCTAssertEqual(aggressive.chunkDuration, 3.0)
        XCTAssertEqual(aggressive.silenceCutoffDuration, 0.8)
        XCTAssertEqual(aggressive.silenceEnergyThreshold, 0.01)
    }

    func testEngineTypeDisplayNames() {
        XCTAssertEqual(EngineType.streaming.displayName, "Streaming")
        XCTAssertEqual(EngineType.chunked.displayName, "Chunked")
        XCTAssertEqual(EngineType.allCases.count, 2)
    }
}
