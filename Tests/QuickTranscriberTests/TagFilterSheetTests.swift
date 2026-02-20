import XCTest
@testable import QuickTranscriberLib

final class TagFilterSheetTests: XCTestCase {

    private let profiles: [RegisteredSpeakerInfo] = [
        RegisteredSpeakerInfo(profileId: UUID(), label: "A", displayName: "Alice", tags: ["eng", "backend"], isAlreadyActive: false),
        RegisteredSpeakerInfo(profileId: UUID(), label: "B", displayName: "Bob", tags: ["eng", "frontend"], isAlreadyActive: false),
        RegisteredSpeakerInfo(profileId: UUID(), label: "C", displayName: "Charlie", tags: ["design"], isAlreadyActive: false),
        RegisteredSpeakerInfo(profileId: UUID(), label: "D", displayName: "Dave", tags: ["eng", "backend"], isAlreadyActive: true),
    ]

    func testFilterAnyTag() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["backend"]), matchMode: .any
        )
        XCTAssertEqual(result.count, 2)  // Alice + Dave have "backend"
        XCTAssertEqual(result.filter { !$0.isAlreadyActive }.count, 1)  // Only Alice is addable
    }

    func testFilterAllTags() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["eng", "backend"]), matchMode: .all
        )
        XCTAssertEqual(result.count, 2)  // Alice + Dave have both
        XCTAssertEqual(Set(result.map { $0.label }), Set(["A", "D"]))
    }

    func testFilterNoTagsReturnsAll() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(), matchMode: .any
        )
        XCTAssertEqual(result.count, 4)
    }

    func testFilterAnyMultipleTags() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["backend", "design"]), matchMode: .any
        )
        // Alice(backend), Charlie(design), Dave(backend)
        XCTAssertEqual(result.count, 3)
    }

    func testFilterAllNoMatch() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["eng", "design"]), matchMode: .all
        )
        XCTAssertEqual(result.count, 0)
    }

    func testAddableProfiles() {
        let result = TagFilterSheet.filterProfiles(
            profiles, selectedTags: Set(["eng"]), matchMode: .any
        )
        let addable = result.filter { !$0.isAlreadyActive }
        // Alice + Bob are addable, Dave is already active
        XCTAssertEqual(addable.count, 2)
    }
}
