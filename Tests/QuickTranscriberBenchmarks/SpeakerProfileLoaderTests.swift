import XCTest
@testable import QuickTranscriberLib

final class SpeakerProfileLoaderTests: XCTestCase {
    // MARK: - Synthetic fixtures (no real names)

    private func writeFixture(_ json: String) throws -> String {
        let path = "/tmp/speaker_loader_\(UUID().uuidString).json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func test_load_filtersByDisplayNameWhitelist() throws {
        let json = """
        [
            {"id":"11111111-1111-1111-1111-111111111111","displayName":"alpha","embedding":[0.1,0.2,0.3],"sessionCount":5,"lastUsed":1.0,"isLocked":true,"tags":[]},
            {"id":"22222222-2222-2222-2222-222222222222","displayName":"beta","embedding":[0.4,0.5,0.6],"sessionCount":3,"lastUsed":1.0,"isLocked":false,"tags":[]},
            {"id":"33333333-3333-3333-3333-333333333333","displayName":"gamma","embedding":[0.7,0.8,0.9],"sessionCount":1,"lastUsed":1.0,"isLocked":false,"tags":[]}
        ]
        """
        let path = try writeFixture(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let profiles = try SpeakerProfileLoader.load(path: path, displayNames: ["alpha", "gamma"])

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(Set(profiles.map(\.displayName)), ["alpha", "gamma"])
        XCTAssertEqual(profiles.first(where: { $0.displayName == "alpha" })?.embedding.count, 3)
    }

    func test_load_throwsWhenWhitelistedNameMissing() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","displayName":"alpha","embedding":[0.1],"sessionCount":1,"lastUsed":1.0,"isLocked":false,"tags":[]}]
        """
        let path = try writeFixture(json)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(
            try SpeakerProfileLoader.load(path: path, displayNames: ["alpha", "missing"])
        ) { error in
            guard case SpeakerProfileLoader.LoadError.missingProfiles(let names) = error else {
                XCTFail("expected missingProfiles, got \(error)")
                return
            }
            XCTAssertEqual(names, ["missing"])
        }
    }

    func test_load_throwsOnFileNotFound() {
        XCTAssertThrowsError(
            try SpeakerProfileLoader.load(path: "/tmp/nonexistent_\(UUID().uuidString).json", displayNames: ["x"])
        )
    }

    // MARK: - Real-data smoke

    func test_load_realProductionFile_findsSessionParticipants() throws {
        let path = NSString(string: "~/QuickTranscriber/speakers.json").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "production speakers.json not present")

        let profiles = try SpeakerProfileLoader.load(
            path: path,
            displayNames: ["松浦", "森", "今村", "森谷", "上東", "神野"]
        )
        XCTAssertEqual(profiles.count, 6)
        XCTAssertTrue(profiles.allSatisfy { $0.embedding.count == 256 })
    }

    /// 佐々木 spoke in the 2026-04-21 session but is not in the production profile
    /// store — a real-world failure mode where Manual mode cannot succeed for that
    /// speaker. The loader's strict whitelist must surface this clearly so the
    /// ablation manifest can decide whether to treat it as expected.
    func test_load_realProductionFile_佐々木IsAbsent() throws {
        let path = NSString(string: "~/QuickTranscriber/speakers.json").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "production speakers.json not present")

        XCTAssertThrowsError(
            try SpeakerProfileLoader.load(path: path, displayNames: ["佐々木"])
        ) { error in
            guard case SpeakerProfileLoader.LoadError.missingProfiles(let names) = error else {
                XCTFail("expected missingProfiles, got \(error)")
                return
            }
            XCTAssertEqual(names, ["佐々木"])
        }
    }

    func test_loadReadOnly_doesNotMutateSourceFile() throws {
        let path = NSString(string: "~/QuickTranscriber/speakers.json").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "production speakers.json not present")

        let preAttrs = try FileManager.default.attributesOfItem(atPath: path)
        let preMtime = preAttrs[.modificationDate] as? Date

        _ = try SpeakerProfileLoader.load(path: path, displayNames: ["松浦"])

        let postAttrs = try FileManager.default.attributesOfItem(atPath: path)
        let postMtime = postAttrs[.modificationDate] as? Date
        XCTAssertEqual(preMtime, postMtime, "load() must not modify the production file")
    }
}
