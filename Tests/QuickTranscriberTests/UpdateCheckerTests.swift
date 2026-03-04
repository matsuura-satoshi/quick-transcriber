import XCTest
@testable import QuickTranscriberLib

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version Comparison Tests

    func testIsNewer_patchHigher_returnsTrue() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.61", than: "1.0.60"))
    }

    func testIsNewer_patchLower_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.59", than: "1.0.60"))
    }

    func testIsNewer_sameVersion_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.60", than: "1.0.60"))
    }

    func testIsNewer_minorHigher_returnsTrue() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0", than: "1.0.60"))
    }

    func testIsNewer_minorLower_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.60", than: "1.1.0"))
    }

    func testIsNewer_majorHigher_returnsTrue() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.0.60"))
    }

    func testIsNewer_majorLower_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0.60", than: "2.0.0"))
    }

    func testIsNewer_stripsVPrefix() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.61", than: "1.0.60"))
    }

    func testIsNewer_invalidVersion_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer("invalid", than: "1.0.60"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.60", than: "invalid"))
    }

    func testIsNewer_twoComponentVersion_returnsFalse() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.60"))
    }

    // MARK: - GitHubRelease Decoding Tests

    func testGitHubRelease_decodesValidJSON() throws {
        let json = """
        {
            "tag_name": "v1.0.61",
            "html_url": "https://github.com/owner/repo/releases/tag/v1.0.61",
            "assets": [
                {
                    "name": "QuickTranscriber-v1.0.61.zip",
                    "browser_download_url": "https://github.com/owner/repo/releases/download/v1.0.61/QuickTranscriber-v1.0.61.zip"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v1.0.61")
        XCTAssertEqual(release.htmlUrl, "https://github.com/owner/repo/releases/tag/v1.0.61")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "QuickTranscriber-v1.0.61.zip")
        XCTAssertEqual(release.assets[0].browserDownloadUrl, "https://github.com/owner/repo/releases/download/v1.0.61/QuickTranscriber-v1.0.61.zip")
    }

    func testGitHubRelease_decodesEmptyAssets() throws {
        let json = """
        {
            "tag_name": "v1.0.61",
            "html_url": "https://github.com/owner/repo/releases/tag/v1.0.61",
            "assets": []
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v1.0.61")
        XCTAssertTrue(release.assets.isEmpty)
    }

    func testGitHubRelease_zipAssetUrl_findsZip() throws {
        let json = """
        {
            "tag_name": "v1.0.61",
            "html_url": "https://github.com/owner/repo/releases/tag/v1.0.61",
            "assets": [
                {
                    "name": "checksums.txt",
                    "browser_download_url": "https://example.com/checksums.txt"
                },
                {
                    "name": "QuickTranscriber-v1.0.61.zip",
                    "browser_download_url": "https://example.com/QuickTranscriber-v1.0.61.zip"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.zipAssetUrl, "https://example.com/QuickTranscriber-v1.0.61.zip")
    }

    func testGitHubRelease_zipAssetUrl_noZip_returnsNil() throws {
        let json = """
        {
            "tag_name": "v1.0.61",
            "html_url": "https://github.com/owner/repo/releases/tag/v1.0.61",
            "assets": [
                {
                    "name": "checksums.txt",
                    "browser_download_url": "https://example.com/checksums.txt"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertNil(release.zipAssetUrl)
    }

    // MARK: - GitHub Constants Tests

    func testGitHubConstants_exist() {
        XCTAssertEqual(Constants.GitHub.owner, "matsuura-satoshi")
        XCTAssertEqual(Constants.GitHub.repo, "quick-transcriber")
    }
}
