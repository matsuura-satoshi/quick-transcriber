import Foundation

public struct SegmentCharacterMap {
    public struct Entry {
        public let segmentIndex: Int
        public let characterRange: NSRange
        public let labelRange: NSRange?
    }
    public var entries: [Entry] = []

    public func segmentIndices(overlapping range: NSRange) -> [Int] {
        entries.compactMap { entry in
            let fullRange = NSUnionRange(
                entry.labelRange ?? entry.characterRange,
                entry.characterRange
            )
            if NSIntersectionRange(fullRange, range).length > 0 {
                return entry.segmentIndex
            }
            return nil
        }
    }

    public func consecutiveBlockIndices(from index: Int, segments: [ConfirmedSegment]) -> [Int] {
        guard index < segments.count, let speaker = segments[index].speaker else {
            return [index]
        }
        var result = [Int]()
        // Expand backward
        var i = index
        while i >= 0 && segments[i].speaker == speaker { i -= 1 }
        i += 1
        // Expand forward
        while i < segments.count && segments[i].speaker == speaker {
            result.append(i)
            i += 1
        }
        return result
    }

    public func labelEntry(at characterIndex: Int) -> Entry? {
        entries.first { entry in
            guard let labelRange = entry.labelRange else { return false }
            return NSLocationInRange(characterIndex, labelRange)
        }
    }
}
