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
