import Foundation

/// JSON ストアの共通書き込み処理（ディレクトリ作成 → encode → atomic write）。
enum JSONFileStorage {
    static func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
    }
}
