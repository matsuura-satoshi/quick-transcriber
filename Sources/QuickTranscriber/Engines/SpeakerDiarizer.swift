import Foundation
import FluidAudio

/// Protocol for identifying the current speaker from an audio chunk.
public protocol SpeakerDiarizer: AnyObject, Sendable {
    func setup() async throws
    func identifySpeaker(audioChunk: [Float]) async -> String?
}

/// Speaker diarizer backed by FluidAudio's OfflineDiarizerManager.
/// Uses a rolling buffer (30-second window) to accumulate audio and diarize
/// the window, returning the last speaker as the current speaker.
public final class FluidAudioSpeakerDiarizer: SpeakerDiarizer, @unchecked Sendable {
    private let sampleRate: Int = 16000
    private let windowDuration: TimeInterval = 30.0
    private var rollingBuffer: [Float] = []
    private var diarizer: OfflineDiarizerManager?
    private var speakerMapping: [String: String] = [:]
    private var nextSpeakerIndex: Int = 0
    private let lock = NSLock()

    public init() {}

    public func setup() async throws {
        let config = OfflineDiarizerConfig()
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        diarizer = manager
        NSLog("[SpeakerDiarizer] FluidAudio models prepared")
    }

    public func identifySpeaker(audioChunk: [Float]) async -> String? {
        guard let diarizer else { return nil }

        let windowSamples = Int(windowDuration * Double(sampleRate))
        let currentBuffer = lock.withLock {
            rollingBuffer.append(contentsOf: audioChunk)
            if rollingBuffer.count > windowSamples {
                rollingBuffer.removeFirst(rollingBuffer.count - windowSamples)
            }
            return rollingBuffer
        }

        // Need at least 1 second of audio for meaningful diarization
        guard currentBuffer.count >= sampleRate else { return nil }

        do {
            let result = try await diarizer.process(audio: currentBuffer)
            guard let lastSegment = result.segments.last else { return nil }
            return mapSpeakerId(lastSegment.speakerId)
        } catch {
            NSLog("[SpeakerDiarizer] Diarization failed: \(error)")
            return nil
        }
    }

    /// Map internal speaker IDs to human-readable labels (A, B, C, ...).
    private func mapSpeakerId(_ internalId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let mapped = speakerMapping[internalId] {
            return mapped
        }
        let label = String(UnicodeScalar(UInt8(65 + nextSpeakerIndex % 26)))  // A, B, C, ...
        speakerMapping[internalId] = label
        nextSpeakerIndex += 1
        return label
    }
}
