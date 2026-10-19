import Foundation
import OSLog

/// Unified-logging categories. Filter in Console.app or with
/// `log stream --level debug --predicate 'subsystem == "<bundle id>"'`.
///
/// User content (input, recognized text, replies, system prompt) is logged with `privacy: .private`;
/// the API key is never logged.
extension Logger {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "Construe"

    /// Messages API requests, responses and the SSE stream.
    nonisolated static let api = Logger(subsystem: subsystem, category: "api")
    /// Region selection and screen capture.
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Text recognition in screenshots.
    nonisolated static let ocr = Logger(subsystem: subsystem, category: "ocr")
    /// Keychain and launch-at-login changes.
    nonisolated static let settings = Logger(subsystem: subsystem, category: "settings")
    /// App lifecycle and the quick panel.
    nonisolated static let panel = Logger(subsystem: subsystem, category: "panel")
}

/// Collects this process's recent log entries for a bug report.
enum Diagnostics {
    /// Entries from the last `interval` seconds, one per line, after a version header.
    ///
    /// Only entries the system kept are returned: `.debug` ones appear only while still buffered,
    /// and private values read back as `<private>`.
    static func recentEntries(within interval: TimeInterval = 3600) throws -> (text: String, count: Int) {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(timeIntervalSinceEnd: -interval),
            matching: NSPredicate(format: "subsystem == %@", Logger.subsystem)
        )
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            "\(entry.date.formatted(.iso8601)) [\(levelName(entry.level))] \(entry.category): \(entry.composedMessage)"
        }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = "Construe \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        return (([header] + lines).joined(separator: "\n"), lines.count)
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }
}
