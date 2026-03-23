import XCTest
@testable import QuickTranscriberLib

final class FileAudioSourceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileAudioSourceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a WAV file with the given samples using AudioRecordingService.
    /// Returns the URL of the created file.
    private func createWavFile(samples: [Float], prefix: String = "test") -> URL {
        let recorder = AudioRecordingService()
        recorder.startSession(directory: tmpDir, datePrefix: prefix)
        if !samples.isEmpty {
            recorder.appendSamples(samples)
        }
        recorder.endSession()
        return tmpDir.appendingPathComponent("\(prefix)_qt_recording.wav")
    }

    // MARK: - Tests

    func testStartCaptureDeliversBuffers() async throws {
        // 3200 samples → should deliver exactly 2 buffers of 1600 each
        let fileURL = createWavFile(samples: [Float](repeating: 0.5, count: 3200))

        let sut = FileAudioSource(fileURL: fileURL)
        let bufferExpectation = expectation(description: "Received 2 buffers")
        bufferExpectation.expectedFulfillmentCount = 2

        var receivedBuffers: [[Float]] = []
        let lock = NSLock()

        try await sut.startCapture { buffer in
            lock.lock()
            receivedBuffers.append(buffer)
            lock.unlock()
            bufferExpectation.fulfill()
        }

        await fulfillment(of: [bufferExpectation], timeout: 5.0)

        lock.lock()
        XCTAssertEqual(receivedBuffers.count, 2)
        XCTAssertEqual(receivedBuffers[0].count, 1600)
        XCTAssertEqual(receivedBuffers[1].count, 1600)
        lock.unlock()
    }

    func testProgressReporting() async throws {
        // 4800 samples → 3 buffers
        let fileURL = createWavFile(samples: [Float](repeating: 0.3, count: 4800))

        let sut = FileAudioSource(fileURL: fileURL)

        let completeExpectation = expectation(description: "onComplete called")
        var progressValues: [Double] = []
        let lock = NSLock()

        sut.onProgress = { progress in
            lock.lock()
            progressValues.append(progress)
            lock.unlock()
        }
        sut.onComplete = {
            completeExpectation.fulfill()
        }

        try await sut.startCapture { _ in }

        await fulfillment(of: [completeExpectation], timeout: 5.0)

        lock.lock()
        let values = progressValues
        lock.unlock()

        // Progress should increase monotonically
        XCTAssertFalse(values.isEmpty, "Should have reported progress")
        for i in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1],
                                         "Progress should increase monotonically")
        }
        // Last progress should be 1.0
        XCTAssertEqual(values.last ?? 0.0, 1.0, accuracy: 0.01,
                       "Final progress should be 1.0")
    }

    func testStopCaptureCancelsReading() async throws {
        // Large file: 160000 samples = 10 seconds worth = 100 buffers
        let fileURL = createWavFile(samples: [Float](repeating: 0.1, count: 160000))

        let sut = FileAudioSource(fileURL: fileURL)

        let threeBuffers = expectation(description: "Received 3 buffers")
        threeBuffers.expectedFulfillmentCount = 3

        var bufferCount = 0
        let lock = NSLock()

        try await sut.startCapture { _ in
            lock.lock()
            bufferCount += 1
            let count = bufferCount
            lock.unlock()
            if count <= 3 {
                threeBuffers.fulfill()
            }
        }

        await fulfillment(of: [threeBuffers], timeout: 5.0)

        sut.stopCapture()

        // Wait a bit to ensure no more buffers arrive
        try await Task.sleep(nanoseconds: 200_000_000)

        lock.lock()
        let finalCount = bufferCount
        lock.unlock()

        // Should have stopped near 3 buffers (allow some in-flight)
        XCTAssertLessThan(finalCount, 100,
                          "Should have stopped well before processing all 100 buffers")
        XCTAssertFalse(sut.isCapturing, "isCapturing should be false after stop")
    }

    func testInvalidFileThrows() async {
        let nonexistentURL = tmpDir.appendingPathComponent("nonexistent.wav")
        let sut = FileAudioSource(fileURL: nonexistentURL)

        do {
            try await sut.startCapture { _ in }
            XCTFail("Should have thrown for nonexistent file")
        } catch {
            // Expected: error thrown for invalid file
        }
    }

    func testIsCapturingState() async throws {
        let fileURL = createWavFile(samples: [Float](repeating: 0.5, count: 3200))

        let sut = FileAudioSource(fileURL: fileURL)

        XCTAssertFalse(sut.isCapturing, "Should be false before start")

        let completeExpectation = expectation(description: "onComplete called")
        var wasCapturingDuringBuffer = false
        let lock = NSLock()

        sut.onComplete = {
            completeExpectation.fulfill()
        }

        try await sut.startCapture { [weak sut] _ in
            lock.lock()
            if sut?.isCapturing == true {
                wasCapturingDuringBuffer = true
            }
            lock.unlock()
        }

        XCTAssertTrue(sut.isCapturing, "Should be true after startCapture returns")

        await fulfillment(of: [completeExpectation], timeout: 5.0)

        // Give a moment for the task to clean up
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(sut.isCapturing, "Should be false after completion")

        lock.lock()
        XCTAssertTrue(wasCapturingDuringBuffer, "Should be true during buffer delivery")
        lock.unlock()
    }

    func testEmptyFileCallsComplete() async throws {
        let fileURL = createWavFile(samples: [])

        let sut = FileAudioSource(fileURL: fileURL)

        let completeExpectation = expectation(description: "onComplete called")
        var receivedBufferCount = 0
        let lock = NSLock()

        sut.onComplete = {
            completeExpectation.fulfill()
        }

        try await sut.startCapture { _ in
            lock.lock()
            receivedBufferCount += 1
            lock.unlock()
        }

        await fulfillment(of: [completeExpectation], timeout: 5.0)

        lock.lock()
        XCTAssertEqual(receivedBufferCount, 0, "Empty file should deliver no buffers")
        lock.unlock()
    }
}
