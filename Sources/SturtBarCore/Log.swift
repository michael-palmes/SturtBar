import Foundation
import os
import Synchronization

// MARK: - SturtBarLog

public enum SturtBarLog {
    private static let levelMutex = Mutex<Level>({
        let raw = UserDefaults.standard.string(forKey: "debugLogLevel")
        return Level(rawValue: raw ?? "") ?? .info
    }())

    /// Create a logger for the given category.
    public static func logger(_ category: String) -> SturtBarLogger {
        SturtBarLogger(subsystem: "com.michaelpalmes.sturtbar", category: category)
    }

    /// Persist and update the in-process minimum level gate.
    public static func setMinimumLevel(_ level: Level) {
        self.levelMutex.withLock { stored in
            stored = level
            UserDefaults.standard.set(level.rawValue, forKey: "debugLogLevel")
        }
    }

    public static func minimumLevel() -> Level {
        self.levelMutex.withLock { $0 }
    }

    static func shouldLog(_ level: Level) -> Bool {
        level.rank >= self.minimumLevel().rank
    }

    // MARK: - Level

    public enum Level: String, CaseIterable, Sendable {
        case trace
        case verbose
        case debug
        case info
        case warning
        case error
        case critical

        public var rank: Int {
            switch self {
            case .trace: 0
            case .verbose: 1
            case .debug: 2
            case .info: 3
            case .warning: 4
            case .error: 5
            case .critical: 6
            }
        }

        var osLogType: OSLogType {
            switch self {
            case .trace, .verbose: .debug
            case .debug: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            case .critical: .fault
            }
        }
    }
}

// MARK: - SturtBarLogger

public struct SturtBarLogger: Sendable {
    private let inner: os.Logger

    fileprivate init(subsystem: String, category: String) {
        self.inner = os.Logger(subsystem: subsystem, category: category)
    }

    public func trace(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .trace, message: message, metadata: metadata)
    }

    public func verbose(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .verbose, message: message, metadata: metadata)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .debug, message: message, metadata: metadata)
    }

    public func info(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .info, message: message, metadata: metadata)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .warning, message: message, metadata: metadata)
    }

    public func error(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .error, message: message, metadata: metadata)
    }

    public func critical(_ message: @autoclosure () -> String, metadata: [String: String]? = nil) {
        self.log(level: .critical, message: message, metadata: metadata)
    }

    // MARK: - Private

    private func log(level: SturtBarLog.Level, message: () -> String, metadata: [String: String]?) {
        guard SturtBarLog.shouldLog(level) else { return }
        let safe = LogRedactor.redact(message())
        let full: String
        if let metadata, !metadata.isEmpty {
            let suffix = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(LogRedactor.redact($0.value))" }
                .joined(separator: " ")
            full = "\(safe) \(suffix)"
        } else {
            full = safe
        }
        self.inner.log(level: level.osLogType, "\(full, privacy: .public)")
    }
}

// MARK: - LogRedactor

enum LogRedactor {
    private static let fallbackRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "$^", options: [])
        } catch {
            fatalError("Failed to build fallback regex: \(error)")
        }
    }()

    private static let emailRegex = makeRegex(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])
    private static let cookieHeaderRegex = makeRegex(
        pattern: #"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    private static let authorizationRegex = makeRegex(
        pattern: #"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let anthropicTokenRegex = makeRegex(
        pattern: #"sk-ant-[^\s"'`;,)>\]]+"#)
    private static let bearerRegex = makeRegex(
        pattern: #"(?i)\bbearer\s+[a-z0-9._\-]+=*\b"#)

    static func redact(_ text: String) -> String {
        var output = text
        // Email is broad and safe first
        output = self.replace(self.emailRegex, in: output, with: "<redacted-email>")
        // Anthropic tokens before broader bearer/authorization rules
        output = self.replace(self.anthropicTokenRegex, in: output, with: "sk-ant-***")
        // Bearer catches "bearer <token>" before authorization wraps it
        output = self.replace(self.bearerRegex, in: output, with: "Bearer <redacted>")
        // Authorization catches the rest (already-redacted content)
        output = self.replace(self.cookieHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.authorizationRegex, in: output, with: "$1<redacted>")
        return output
    }

    private static func makeRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? self.fallbackRegex
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
