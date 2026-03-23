import XCTest
@testable import QuickTranscriberLib

final class AudioRecordingServiceTests: XCTestCase {
    private var tmpDir: URL!
    private var sut: AudioRecordingService!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecordingServiceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        sut = AudioRecordingService()
    }

    override func tearDown() {
        sut = nil
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - File Creation

    func testStartSessionCreatesWavFile() {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        sut.endSession()

        let files = try! FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let wavFiles = files.filter { $0.pathExtension == "wav" }
        XCTAssertEqual(wavFiles.count, 1)
    }

    func testFilenameFormat() {
        let datePrefix = "2026-03-23_1430"
        sut.startSession(directory: tmpDir, datePrefix: datePrefix)
        sut.endSession()

        let files = try! FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let wavFile = files.first { $0.pathExtension == "wav" }!
        XCTAssertEqual(wavFile.lastPathComponent, "2026-03-23_1430_qt_recording.wav")
    }

    // MARK: - WAV Header

    func testEndSessionFinalizesWavHeader() throws {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        // Write 100 samples
        let samples: [Float] = (0..<100).map { Float($0) / 100.0 }
        sut.appendSamples(samples)
        sut.endSession()

        let fileURL = tmpDir.appendingPathComponent("2026-03-23_1430_qt_recording.wav")
        let data = try Data(contentsOf: fileURL)

        // WAV header is 44 bytes minimum
        XCTAssertGreaterThanOrEqual(data.count, 44)

        // RIFF header
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        // WAVE format
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        // fmt  chunk
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        // data chunk
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")

        // PCM format (1)
        let audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
        XCTAssertEqual(audioFormat, 1)

        // 1 channel
        let channels = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        XCTAssertEqual(channels, 1)

        // 16000 Hz sample rate
        let sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        XCTAssertEqual(sampleRate, 16000)

        // 16 bits per sample
        let bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
        XCTAssertEqual(bitsPerSample, 16)

        // Data chunk size = 100 samples * 2 bytes
        let dataChunkSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(dataChunkSize, 200)

        // RIFF chunk size = file size - 8
        let riffSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(riffSize, UInt32(data.count - 8))
    }

    // MARK: - Sample Data

    func testAppendSamplesWritesCorrectData() throws {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        // Known samples: 0.0, 0.5, 1.0, -1.0
        let samples: [Float] = [0.0, 0.5, 1.0, -1.0]
        sut.appendSamples(samples)
        sut.endSession()

        let fileURL = tmpDir.appendingPathComponent("2026-03-23_1430_qt_recording.wav")
        let data = try Data(contentsOf: fileURL)

        // PCM data starts at byte 44
        let pcmData = data[44...]
        XCTAssertEqual(pcmData.count, 8) // 4 samples * 2 bytes

        // Read Int16 values
        let int16Values: [Int16] = pcmData.withUnsafeBytes { buffer in
            let typed = buffer.bindMemory(to: Int16.self)
            return Array(typed)
        }

        // Float32 → Int16 conversion: value * 32767
        XCTAssertEqual(int16Values[0], 0)       // 0.0 → 0
        XCTAssertEqual(int16Values[1], 16383)   // 0.5 → 16383 (Int16(0.5 * 32767))
        XCTAssertEqual(int16Values[2], 32767)   // 1.0 → 32767
        XCTAssertEqual(int16Values[3], -32767)  // -1.0 → -32767
    }

    func testRoundTrip() throws {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        let original: [Float] = [0.0, 0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1.0, -1.0]
        sut.appendSamples(original)
        sut.endSession()

        let fileURL = tmpDir.appendingPathComponent("2026-03-23_1430_qt_recording.wav")
        let data = try Data(contentsOf: fileURL)
        let pcmData = data[44...]

        let int16Values: [Int16] = pcmData.withUnsafeBytes { buffer in
            let typed = buffer.bindMemory(to: Int16.self)
            return Array(typed)
        }

        // Convert back to Float and check within quantization tolerance
        for (i, int16) in int16Values.enumerated() {
            let recovered = Float(int16) / 32767.0
            XCTAssertEqual(recovered, original[i], accuracy: 1.0 / 32767.0,
                           "Sample \(i): expected \(original[i]), got \(recovered)")
        }
    }

    func testMultipleAppendCalls() throws {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        sut.appendSamples([0.1, 0.2])
        sut.appendSamples([0.3, 0.4])
        sut.appendSamples([0.5])
        sut.endSession()

        let fileURL = tmpDir.appendingPathComponent("2026-03-23_1430_qt_recording.wav")
        let data = try Data(contentsOf: fileURL)

        // Data chunk size = 5 samples * 2 bytes = 10
        let dataChunkSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(dataChunkSize, 10)
    }

    // MARK: - Safety

    func testEndSessionWithoutStartIsNoOp() {
        // Should not crash
        sut.endSession()
    }

    func testAppendSamplesWithoutStartIsNoOp() {
        // Should not crash
        sut.appendSamples([0.1, 0.2, 0.3])
    }

    func testMultipleSessions() throws {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        sut.appendSamples([0.1])
        sut.endSession()

        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1431")
        sut.appendSamples([0.2])
        sut.endSession()

        let files = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        let wavFiles = files.filter { $0.pathExtension == "wav" }
        XCTAssertEqual(wavFiles.count, 2)
    }

    func testEmptyRecordingProducesValidWavFile() throws {
        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        sut.endSession()

        let fileURL = tmpDir.appendingPathComponent("2026-03-23_1430_qt_recording.wav")
        let data = try Data(contentsOf: fileURL)

        // Valid WAV with 0 data bytes
        XCTAssertEqual(data.count, 44)

        let dataChunkSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(dataChunkSize, 0)

        let riffSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(riffSize, 36) // 44 - 8
    }

    func testCurrentFileURL() {
        XCTAssertNil(sut.currentFileURL)

        sut.startSession(directory: tmpDir, datePrefix: "2026-03-23_1430")
        XCTAssertNotNil(sut.currentFileURL)
        XCTAssertEqual(sut.currentFileURL?.lastPathComponent, "2026-03-23_1430_qt_recording.wav")

        sut.endSession()
        XCTAssertNil(sut.currentFileURL)
    }
}
