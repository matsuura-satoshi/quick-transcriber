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

    func simulateSegments(confirmed: [String], unconfirmed: [String]) {
        segmentChangeCallback?(confirmed, unconfirmed)
    }
}
