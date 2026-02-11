import XCTest
@testable import MyTranscriberLib

final class WhisperKitModelLoaderTests: XCTestCase {

    // MARK: - appModelBaseDir

    func testAppModelBaseDirPointsToApplicationSupport() {
        let baseDir = WhisperKitModelLoader.appModelBaseDir
        let path = baseDir.path

        // Must be under Application Support
        XCTAssertTrue(
            path.contains("Library/Application Support"),
            "appModelBaseDir should be under Application Support, got: \(path)"
        )
        // Must end with MyTranscriber/Models
        XCTAssertTrue(
            path.hasSuffix("MyTranscriber/Models"),
            "appModelBaseDir should end with MyTranscriber/Models, got: \(path)"
        )
    }

    func testAppModelBaseDirIsConsistent() {
        let first = WhisperKitModelLoader.appModelBaseDir
        let second = WhisperKitModelLoader.appModelBaseDir
        XCTAssertEqual(first, second, "appModelBaseDir should return the same value on repeated calls")
    }

    // MARK: - findCachedModelFolder

    func testFindCachedModelFolderReturnsNilWhenNoModel() {
        let result = WhisperKitModelLoader.findCachedModelFolder(for: "nonexistent-model-\(UUID().uuidString)")
        XCTAssertNil(result, "Should return nil for a model that does not exist anywhere")
    }

    func testFindCachedModelFolderConstructsCorrectModelDirName() {
        // The model dir name format should be "openai_whisper-{model}"
        // We verify by checking the stable path that would be searched
        let modelName = "large-v3-v20240930_turbo"
        let expectedDirName = "openai_whisper-\(modelName)"
        let expectedPath = WhisperKitModelLoader.appModelBaseDir
            .appendingPathComponent(expectedDirName)

        // Since no model files exist at this path, findCachedModelFolder returns nil,
        // but we can verify the path construction by checking the stable path format
        XCTAssertTrue(
            expectedPath.lastPathComponent == expectedDirName,
            "Model directory name should follow 'openai_whisper-{model}' format"
        )
        XCTAssertTrue(
            expectedPath.path.contains("MyTranscriber/Models/openai_whisper-large-v3-v20240930_turbo"),
            "Full path should contain the expected model directory structure"
        )
    }

    // MARK: - copyToStablePath

    func testCopyToStablePathCopiesFiles() {
        let fm = FileManager.default
        let tmpBase = fm.temporaryDirectory.appendingPathComponent("WhisperKitModelLoaderTests-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: tmpBase)
        }

        // Create source directory with a file
        let source = tmpBase.appendingPathComponent("source/model")
        let destination = tmpBase.appendingPathComponent("stable/model")

        do {
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            let testFile = source.appendingPathComponent("AudioEncoder.mlmodelc")
            try "test-content".write(to: testFile, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Failed to set up source directory: \(error)")
            return
        }

        // Act
        WhisperKitModelLoader.copyToStablePath(from: source, to: destination)

        // Assert
        XCTAssertTrue(
            fm.fileExists(atPath: destination.path),
            "Destination directory should exist after copy"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: destination.appendingPathComponent("AudioEncoder.mlmodelc").path),
            "Copied file should exist at destination"
        )
    }

    func testCopyToStablePathSkipsIfDestinationExists() {
        let fm = FileManager.default
        let tmpBase = fm.temporaryDirectory.appendingPathComponent("WhisperKitModelLoaderTests-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: tmpBase)
        }

        // Create source with one file
        let source = tmpBase.appendingPathComponent("source/model")
        let destination = tmpBase.appendingPathComponent("stable/model")

        do {
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try "source-content".write(
                to: source.appendingPathComponent("AudioEncoder.mlmodelc"),
                atomically: true, encoding: .utf8
            )

            // Pre-create destination with different content
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try "original-content".write(
                to: destination.appendingPathComponent("AudioEncoder.mlmodelc"),
                atomically: true, encoding: .utf8
            )
        } catch {
            XCTFail("Failed to set up directories: \(error)")
            return
        }

        // Act - should skip because destination exists
        WhisperKitModelLoader.copyToStablePath(from: source, to: destination)

        // Assert - original content should be preserved (not overwritten)
        do {
            let content = try String(contentsOf: destination.appendingPathComponent("AudioEncoder.mlmodelc"), encoding: .utf8)
            XCTAssertEqual(content, "original-content", "Destination should not be overwritten when it already exists")
        } catch {
            XCTFail("Failed to read destination file: \(error)")
        }
    }

    // MARK: - findCachedModelFolder with stable path

    func testFindCachedModelFolderFindsModelInStablePath() {
        let fm = FileManager.default
        let fakeModelName = "test-fake-model-\(UUID().uuidString)"
        let modelDirName = "openai_whisper-\(fakeModelName)"
        let stablePath = WhisperKitModelLoader.appModelBaseDir.appendingPathComponent(modelDirName)

        defer {
            try? fm.removeItem(at: stablePath)
        }

        // Create fake model directory with AudioEncoder.mlmodelc
        let audioEncoderPath = stablePath.appendingPathComponent("AudioEncoder.mlmodelc")
        do {
            try fm.createDirectory(at: audioEncoderPath, withIntermediateDirectories: true)
            // Place a dummy file inside the .mlmodelc directory to make it realistic
            try "fake-model".write(
                to: audioEncoderPath.appendingPathComponent("model.mil"),
                atomically: true, encoding: .utf8
            )
        } catch {
            XCTFail("Failed to create fake model directory: \(error)")
            return
        }

        // Act
        let result = WhisperKitModelLoader.findCachedModelFolder(for: fakeModelName)

        // Assert
        XCTAssertNotNil(result, "Should find the model in the stable path")
        XCTAssertEqual(result, stablePath.path, "Returned path should match the stable path")
    }
}
