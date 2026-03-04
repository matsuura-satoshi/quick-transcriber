import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - GitHub API Models

public struct GitHubRelease: Codable {
    public let tagName: String
    public let htmlUrl: String
    public let assets: [Asset]

    public struct Asset: Codable {
        public let name: String
        public let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }

    public var zipAssetUrl: String? {
        assets.first { $0.name.hasSuffix(".zip") }?.browserDownloadUrl
    }
}

// MARK: - UpdateChecker

@MainActor
public final class UpdateChecker: ObservableObject {
    @Published public var isChecking = false
    @Published public var updateAvailable = false
    @Published public var latestRelease: GitHubRelease?
    @Published public var downloadProgress: Double = 0
    @Published public var isDownloading = false
    @Published public var errorMessage: String?

    public init() {}

    // MARK: - Version Comparison

    public nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = parseVersion(remote)
        let localParts = parseVersion(local)

        guard remoteParts.count == 3, localParts.count == 3 else { return false }

        for i in 0..<3 {
            if remoteParts[i] > localParts[i] { return true }
            if remoteParts[i] < localParts[i] { return false }
        }
        return false
    }

    private nonisolated static func parseVersion(_ version: String) -> [Int] {
        let stripped = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return stripped.split(separator: ".").compactMap { Int($0) }
    }

    // MARK: - Check for Updates

    public func checkForUpdates() async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            let release = try await fetchLatestRelease()
            let currentVersion = Constants.Version.string
            if Self.isNewer(release.tagName, than: currentVersion) {
                latestRelease = release
                updateAvailable = true
            } else {
                updateAvailable = false
                latestRelease = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let urlString = "https://api.github.com/repos/\(Constants.GitHub.owner)/\(Constants.GitHub.repo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.apiError
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Download and Install

    public func downloadAndInstall() async {
        guard let release = latestRelease,
              let zipUrlString = release.zipAssetUrl,
              let zipUrl = URL(string: zipUrlString) else {
            errorMessage = "No download URL available"
            return
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickTranscriberUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Download zip
            let (localUrl, _) = try await URLSession.shared.download(from: zipUrl)
            let zipPath = tempDir.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: localUrl, to: zipPath)
            downloadProgress = 0.5

            // Extract zip using ditto
            let extractDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let dittoProcess = Process()
            dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            dittoProcess.arguments = ["-xk", zipPath.path, extractDir.path]
            try dittoProcess.run()
            dittoProcess.waitUntilExit()

            guard dittoProcess.terminationStatus == 0 else {
                throw UpdateError.extractionFailed
            }
            downloadProgress = 0.7

            // Find .app bundle in extracted directory
            let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.noAppBundle
            }

            // Remove quarantine attribute
            let xattrProcess = Process()
            xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProcess.arguments = ["-dr", "com.apple.quarantine", appBundle.path]
            try xattrProcess.run()
            xattrProcess.waitUntilExit()

            downloadProgress = 0.8

            #if canImport(AppKit)
            // Get current app location
            let currentAppUrl = Bundle.main.bundleURL

            // Move current app to trash
            try await NSWorkspace.shared.recycle([currentAppUrl])
            downloadProgress = 0.9

            // Copy new app to same location
            try FileManager.default.copyItem(at: appBundle, to: currentAppUrl)
            downloadProgress = 1.0

            // Launch new app and terminate current
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = [currentAppUrl.path]
            try openProcess.run()

            NSApplication.shared.terminate(nil)
            #endif
        } catch {
            isDownloading = false
            errorMessage = "Update failed: \(error.localizedDescription)"
            // Fallback: open release page in browser
            openReleasePage()
        }
    }

    public func openReleasePage() {
        #if canImport(AppKit)
        if let release = latestRelease, let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        } else {
            let urlString = "https://github.com/\(Constants.GitHub.owner)/\(Constants.GitHub.repo)/releases/latest"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        #endif
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case invalidUrl
        case apiError
        case extractionFailed
        case noAppBundle

        var errorDescription: String? {
            switch self {
            case .invalidUrl: return "Invalid API URL"
            case .apiError: return "Failed to fetch release information"
            case .extractionFailed: return "Failed to extract update"
            case .noAppBundle: return "No app bundle found in update"
            }
        }
    }
}
