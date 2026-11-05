import Foundation

/// Sets aside a data file that could not be decoded so it is never silently overwritten.
///
/// The file is renamed to `<name>.corrupt-<timestamp>.<ext>` next to the original, preserving its bytes
/// for manual recovery while allowing the app to start from a clean state.
enum FileQuarantine {
    /// Renames the file at `url` and returns the new location.
    ///
    /// - Throws: A file system error if the rename fails.
    static func quarantine(fileAt url: URL, now: Date = Date()) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).corrupt-\(stamp).\(ext)")

        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base).corrupt-\(stamp)-\(suffix).\(ext)")
            suffix += 1
        }

        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }
}
