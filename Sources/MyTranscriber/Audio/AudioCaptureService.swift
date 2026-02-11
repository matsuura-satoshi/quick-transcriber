import Foundation

public protocol AudioCaptureService: AnyObject {
    /// Start capturing audio from the microphone.
    /// The callback receives 16kHz mono Float32 buffers (~100ms each).
    func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws
    func stopCapture()
    var isCapturing: Bool { get }
}
