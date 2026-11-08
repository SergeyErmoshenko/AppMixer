import Foundation

/// Append-only file log for on-device debugging. The unified log is fine in
/// development, but diagnosing a user's machine needs a file the user (or a
/// sandboxed helper) can simply read: engine/tap lifecycle events land in
/// `~/Library/Logs/appmixer-debug.log` — inside the app container when
/// sandboxed, which is exactly where support tooling looks.
///
/// MainActor-only: every call site so far is on the main actor, and keeping
/// it single-threaded makes the append path trivially safe.
@MainActor
enum Diag {
    private static let maxSize: UInt64 = 512 * 1024
    private static var handle: FileHandle?

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        append("\(stamp) \(message)\n")
    }

    private static func append(_ line: String) {
        let url = location
        do {
            if handle == nil {
                let manager = FileManager.default
                try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
                if !manager.fileExists(atPath: url.path) {
                    manager.createFile(atPath: url.path, contents: nil)
                }
                // Truncate oversized logs instead of growing forever.
                if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
                   size > maxSize {
                    try? manager.removeItem(at: url)
                    manager.createFile(atPath: url.path, contents: nil)
                }
                handle = try FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            try handle?.write(contentsOf: Data(line.utf8))
        } catch {
            // Diagnostics must never take the audio path down with them.
        }
    }

    private static var location: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/appmixer-debug.log")
    }
}
