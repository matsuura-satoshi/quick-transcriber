import XCTest
@testable import QuickTranscriberLib

final class ParametersTests: XCTestCase {

    func testDefaultParametersChunkedValues() {
        let params = TranscriptionParameters.default
        XCTAssertEqual(params.chunkDuration, 3.0)
        XCTAssertEqual(params.silenceCutoffDuration, 0.8)
        XCTAssertEqual(params.silenceEnergyThreshold, 0.01)
    }

    func testDefaultSilenceLineBreakThreshold() {
        let params = TranscriptionParameters.default
        XCTAssertEqual(params.silenceLineBreakThreshold, 1.0)
    }

    func testDecodingBackwardCompatibilityWithoutNewFields() throws {
        // Simulate old saved parameters without the new fields
        let oldJSON = """
        {"temperature":0,"temperatureFallbackCount":0,"sampleLength":224,"concurrentWorkerCount":4,"chunkDuration":3,"silenceCutoffDuration":0.8,"silenceEnergyThreshold":0.01}
        """
        let data = oldJSON.data(using: .utf8)!
        let params = try JSONDecoder().decode(TranscriptionParameters.self, from: data)
        XCTAssertEqual(params.silenceLineBreakThreshold, 1.0)
        XCTAssertFalse(params.enableSpeakerDiarization)
    }

    func testDefaultEnableSpeakerDiarization() {
        let params = TranscriptionParameters.default
        XCTAssertFalse(params.enableSpeakerDiarization)
    }
}
