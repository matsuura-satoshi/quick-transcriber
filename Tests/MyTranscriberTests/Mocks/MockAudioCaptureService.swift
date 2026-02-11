import Foundation
@testable import MyTranscriberLib

final class MockAudioCaptureService: AudioCaptureService {
    private var onBuffer: (@Sendable ([Float]) -> Void)?
    private(set) var isCapturing = false
    var startCaptureCalled = false
    var stopCaptureCalled = false

    func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        startCaptureCalled = true
        self.onBuffer = onBuffer
        isCapturing = true
    }

    func stopCapture() {
        stopCaptureCalled = true
        isCapturing = false
        onBuffer = nil
    }

    /// Simulate audio buffer input for testing.
    func simulateBuffer(_ samples: [Float]) {
        onBuffer?(samples)
    }
}
