import AVFoundation

public final class AVAudioCaptureService: AudioCaptureService {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    public private(set) var isCapturing = false

    /// Target format: 16kHz mono Float32
    private static let targetSampleRate: Double = Constants.Audio.sampleRate
    /// Requested buffer size for tap (~100ms at 48kHz). Actual size may vary.
    private static let bufferFrameCount: AVAudioFrameCount = 4800

    public init() {}

    public func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        try await requestMicrophonePermission()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[AVAudioCaptureService] Hardware format: \(hwFormat)")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let audioConverter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.converter = audioConverter

        // Capture converter locally to avoid accessing self.converter from the audio thread.
        // stopCapture() sets self.converter = nil, which could race with an in-flight tap callback.
        let localConverter = audioConverter
        inputNode.installTap(onBus: 0, bufferSize: Self.bufferFrameCount, format: hwFormat) {
            buffer, _ in
            let ratio = Self.targetSampleRate / hwFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var error: NSError?
            let status = localConverter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil,
                  let channelData = outputBuffer.floatChannelData else { return }

            let frameCount = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            onBuffer(samples)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        self.isCapturing = true
        NSLog("[AVAudioCaptureService] Capture started")
    }

    public func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        isCapturing = false
        NSLog("[AVAudioCaptureService] Capture stopped")
    }

    private func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw AudioCaptureError.microphonePermissionDenied }
        default:
            throw AudioCaptureError.microphonePermissionDenied
        }
    }
}

public enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case formatCreationFailed
    case converterCreationFailed

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for transcription."
        case .formatCreationFailed:
            return "Failed to create target audio format."
        case .converterCreationFailed:
            return "Failed to create audio converter."
        }
    }
}
