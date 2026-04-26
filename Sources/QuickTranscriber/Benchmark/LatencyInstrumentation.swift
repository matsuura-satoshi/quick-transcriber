import Foundation

public enum LatencyStage: String, Codable, Sendable {
    case vadOnset
    case vadConfirmSilence
    case chunkDispatched
    case inferenceStart
    case inferenceEnd
    case diarizeStart
    case diarizeEnd
    case emitToUI
}

public struct LatencyRecord: Codable, Sendable {
    public let utteranceId: String
    public let stage: LatencyStage
    public let timestampNanos: UInt64
}

public enum LatencyInstrumentation {
    public static let bufferCapacity = 4096
    public static var isEnabled: Bool = false

    private static let lock = NSLock()
    private static var buffer: [LatencyRecord] = []
    private static var head: Int = 0

    public static func mark(_ stage: LatencyStage, utteranceId: String) {
        guard isEnabled else { return }
        let ts = DispatchTime.now().uptimeNanoseconds
        let record = LatencyRecord(utteranceId: utteranceId, stage: stage, timestampNanos: ts)
        lock.lock()
        defer { lock.unlock() }
        if buffer.count < bufferCapacity {
            buffer.append(record)
        } else {
            buffer[head] = record
            head = (head + 1) % bufferCapacity
        }
    }

    public static func drain() -> [LatencyRecord] {
        lock.lock()
        defer { lock.unlock() }
        let out: [LatencyRecord]
        if buffer.count < bufferCapacity {
            out = buffer
        } else {
            out = Array(buffer[head..<bufferCapacity]) + Array(buffer[0..<head])
        }
        buffer.removeAll(keepingCapacity: true)
        head = 0
        return out
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }
}
