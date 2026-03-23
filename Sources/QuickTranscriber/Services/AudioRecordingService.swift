import Foundation

public final class AudioRecordingService {

    private static let fileSuffix = Constants.AudioRecording.fileSuffix
    private static let wavHeaderSize = 44

    private let writeQueue = DispatchQueue(label: "audio-recording-write", qos: .utility)
    private var fileHandle: FileHandle?
    private var _currentFileURL: URL?
    private var sampleCount: Int = 0

    public private(set) var currentFileURL: URL? {
        get { _currentFileURL }
        set { _currentFileURL = newValue }
    }

    public init() {}

    public func startSession(directory: URL, datePrefix: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = datePrefix + Self.fileSuffix + ".wav"
        let fileURL = directory.appendingPathComponent(filename)
        _currentFileURL = fileURL
        sampleCount = 0

        // Write placeholder WAV header (44 bytes of zeros, finalized in endSession)
        let header = Self.buildWavHeader(dataSize: 0)
        do {
            try header.write(to: fileURL)
            fileHandle = try FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
        } catch {
            NSLog("[AudioRecordingService] Failed to create file: \(error)")
            _currentFileURL = nil
        }
    }

    public func appendSamples(_ samples: [Float]) {
        guard let fileHandle else { return }

        let int16Data = Self.convertToInt16(samples)
        sampleCount += samples.count

        writeQueue.async {
            do {
                try fileHandle.write(contentsOf: int16Data)
            } catch {
                NSLog("[AudioRecordingService] Write error: \(error)")
            }
        }
    }

    public func endSession() {
        guard let fileHandle else { return }

        writeQueue.sync {
            // Finalize WAV header with correct sizes
            let dataSize = UInt32(self.sampleCount * 2) // 2 bytes per Int16 sample
            let header = Self.buildWavHeader(dataSize: dataSize)

            do {
                try fileHandle.seek(toOffset: 0)
                try fileHandle.write(contentsOf: header)
                try fileHandle.close()
            } catch {
                NSLog("[AudioRecordingService] Failed to finalize WAV header: \(error)")
            }
        }

        self.fileHandle = nil
        _currentFileURL = nil
        sampleCount = 0
    }

    deinit {
        if fileHandle != nil {
            endSession()
        }
    }

    // MARK: - Private

    private static func convertToInt16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func buildWavHeader(dataSize: UInt32) -> Data {
        let sampleRate = Constants.AudioRecording.sampleRate
        let channels = Constants.AudioRecording.channels
        let bitsPerSample = Constants.AudioRecording.bitsPerSample
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8
        let chunkSize = 36 + dataSize

        var header = Data(capacity: wavHeaderSize)

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        appendUInt32(&header, chunkSize)
        header.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        appendUInt32(&header, 16)          // Subchunk1 size (PCM = 16)
        appendUInt16(&header, 1)           // Audio format (PCM = 1)
        appendUInt16(&header, channels)
        appendUInt32(&header, sampleRate)
        appendUInt32(&header, byteRate)
        appendUInt16(&header, blockAlign)
        appendUInt16(&header, bitsPerSample)

        // data chunk
        header.append(contentsOf: "data".utf8)
        appendUInt32(&header, dataSize)

        return header
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
