import AVFoundation

public final class FileAudioSource: AudioCaptureService {
    private let fileURL: URL
    private var readingTask: Task<Void, Never>?

    public private(set) var isCapturing = false

    /// Reports read progress as a fraction (0.0 to 1.0).
    public var onProgress: (@Sendable (Double) -> Void)?
    /// Called when the file has been fully read.
    public var onComplete: (@Sendable () -> Void)?

    /// Number of samples per buffer delivery (100ms at 16kHz).
    private static let samplesPerBuffer = 1600

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func startCapture(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let totalFrames = AVAudioFrameCount(audioFile.length)

        let targetSampleRate = Constants.Audio.sampleRate
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        let sourceFormat = audioFile.processingFormat
        let needsConversion = sourceFormat.sampleRate != targetSampleRate
            || sourceFormat.channelCount != 1

        var converter: AVAudioConverter?
        if needsConversion {
            guard let conv = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AudioCaptureError.converterCreationFailed
            }
            converter = conv
        }

        // Capture callbacks as local lets for Sendable compliance
        let onProgress = self.onProgress
        let onComplete = self.onComplete
        let samplesPerBuffer = Self.samplesPerBuffer

        isCapturing = true

        readingTask = Task { [weak self] in
            defer {
                self?.isCapturing = false
                self?.readingTask = nil
            }

            // Handle empty file
            if totalFrames == 0 {
                onProgress?(1.0)
                onComplete?()
                return
            }

            // Read chunk size: read enough source frames to produce ~samplesPerBuffer output samples.
            let readChunkFrames: AVAudioFrameCount
            if needsConversion {
                let ratio = sourceFormat.sampleRate / targetSampleRate
                readChunkFrames = AVAudioFrameCount(Double(samplesPerBuffer) * ratio)
            } else {
                readChunkFrames = AVAudioFrameCount(samplesPerBuffer)
            }

            var accumulatedSamples: [Float] = []
            var framesRead: AVAudioFrameCount = 0

            while !Task.isCancelled {
                let remainingFrames = totalFrames - framesRead
                if remainingFrames == 0 { break }

                let framesToRead = min(readChunkFrames, remainingFrames)
                guard let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: framesToRead
                ) else { break }

                do {
                    try audioFile.read(into: readBuffer, frameCount: framesToRead)
                } catch {
                    NSLog("[FileAudioSource] Read error: \(error)")
                    break
                }

                framesRead += readBuffer.frameLength

                // Convert or use directly
                let samples: [Float]
                if needsConversion, let converter = converter {
                    let outputFrameCount = AVAudioFrameCount(
                        Double(readBuffer.frameLength) * (targetSampleRate / sourceFormat.sampleRate)
                    )
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: targetFormat,
                        frameCapacity: outputFrameCount + 1
                    ) else { break }

                    var convError: NSError?
                    let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                        outStatus.pointee = .haveData
                        return readBuffer
                    }

                    guard status != .error, convError == nil,
                          let channelData = outputBuffer.floatChannelData else { break }

                    let count = Int(outputBuffer.frameLength)
                    samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
                } else {
                    guard let channelData = readBuffer.floatChannelData else { break }
                    let count = Int(readBuffer.frameLength)
                    samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
                }

                accumulatedSamples.append(contentsOf: samples)

                // Deliver full buffers
                while accumulatedSamples.count >= samplesPerBuffer {
                    if Task.isCancelled { return }

                    let buffer = Array(accumulatedSamples.prefix(samplesPerBuffer))
                    accumulatedSamples.removeFirst(samplesPerBuffer)
                    onBuffer(buffer)

                    let progress = Double(framesRead) / Double(totalFrames)
                    onProgress?(min(progress, 1.0))

                    await Task.yield()
                }
            }

            // Deliver any remaining samples as a final partial buffer
            if !Task.isCancelled && !accumulatedSamples.isEmpty {
                onBuffer(accumulatedSamples)
            }

            if !Task.isCancelled {
                onProgress?(1.0)
                onComplete?()
            }
        }
    }

    public func stopCapture() {
        readingTask?.cancel()
        readingTask = nil
        isCapturing = false
    }
}
