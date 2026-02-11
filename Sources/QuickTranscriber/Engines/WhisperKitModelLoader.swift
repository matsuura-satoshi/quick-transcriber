import Foundation
import WhisperKit

public enum WhisperKitModelLoader {
    /// Stable model storage path under Application Support.
    public static var appModelBaseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MyTranscriber/Models")
    }

    /// Search for a cached model folder. First checks our stable App Support path,
    /// then known HuggingFace download locations.
    public static func findCachedModelFolder(for model: String) -> String? {
        let modelDirName = "openai_whisper-\(model)"
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser

        // Priority 1: Our stable Application Support path
        let stablePath = appModelBaseDir.appendingPathComponent(modelDirName)
        if fm.fileExists(atPath: stablePath.appendingPathComponent("AudioEncoder.mlmodelc").path) {
            return stablePath.path
        }

        // Priority 2: Known download locations
        let searchPaths = [
            homeDir.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml"),
            homeDir.appendingPathComponent("Library/Application Support/MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml"),
        ]

        for basePath in searchPaths {
            let candidateDir = basePath.appendingPathComponent(modelDirName)
            if fm.fileExists(atPath: candidateDir.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                copyToStablePath(from: candidateDir, to: stablePath)
                return stablePath.path
            }
        }
        return nil
    }

    /// Copy model files to the stable Application Support path.
    static func copyToStablePath(from source: URL, to destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            NSLog("[WhisperKitModelLoader] Copied model to stable path: \(destination.path)")
        } catch {
            NSLog("[WhisperKitModelLoader] Failed to copy model to stable path: \(error)")
        }
    }

    /// Create a WhisperKit instance with standard settings (cpuAndGPU, load: true).
    public static func createWhisperKit(model: String) async throws -> WhisperKit {
        let modelFolder = findCachedModelFolder(for: model)
        NSLog("[WhisperKitModelLoader] Model folder: \(modelFolder ?? "none, will download")")

        let computeOptions = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuAndGPU
        )

        if let modelFolder {
            return try await WhisperKit(
                modelFolder: modelFolder,
                computeOptions: computeOptions,
                verbose: true,
                logLevel: .info,
                load: true,
                download: false
            )
        } else {
            return try await WhisperKit(
                model: model,
                computeOptions: computeOptions,
                verbose: true,
                logLevel: .info,
                load: true,
                download: true
            )
        }
    }
}
