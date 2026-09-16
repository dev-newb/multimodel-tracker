import Foundation

/// A line per alert trigger, kept on disk. Three rounds of "why did the
/// choir play?" were answered by guesswork because the only trace was an
/// MMT_DEBUG print nobody had running. Now the answer is always in
/// ~/Library/Logs/Multimodel Tracker/alerts.log: which account, which
/// pool, the before and after, and what the vendor had promised.
enum AlertLog {
    static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Multimodel Tracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("alerts.log")
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func stamp(_ d: Date) -> String { clock.string(from: d) }

    static func write(_ line: String) {
        let entry = "\(stamp(Date()))  \(line)\n"
        if ProcessInfo.processInfo.environment["MMT_DEBUG"] != nil {
            FileHandle.standardError.write(entry.data(using: .utf8)!)
        }
        rotateIfLarge()
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: entry.data(using: .utf8)!)
        } else {
            try? entry.data(using: .utf8)!.write(to: url)
        }
    }

    /// Alerts are rare, so this will take years to matter — but a log that
    /// can grow without bound is a bug waiting for a long-lived install.
    private static func rotateIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 256 * 1024 else { return }
        let old = url.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
