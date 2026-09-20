import Foundation
import CryptoKit

struct ProcessIdentity: Codable, Hashable, Sendable {
    let pid: pid_t
    let start: Int64
}

/// Executable arguments are data, never reconstructed shell syntax.
struct LaunchSpec: Codable, Hashable, Sendable {
    var executable: String
    var arguments: [String]
    var directory: String

    static func capture(_ detail: ProcDetail) -> LaunchSpec? {
        guard detail.exe.hasPrefix("/"), let cwd = detail.cwd, let first = detail.args.first else { return nil }
        let resolved = URL(fileURLWithPath: first, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).resolvingSymlinksInPath().path
        let executable = URL(fileURLWithPath: detail.exe).resolvingSymlinksInPath().path
        // A renamed process title (npm, next-server, etc.) is not an argv vector.
        guard resolved == executable || (first == (detail.exe as NSString).lastPathComponent) else { return nil }
        let spec = LaunchSpec(executable: detail.exe, arguments: Array(detail.args.dropFirst()), directory: cwd)
        return spec.validationError == nil ? spec : nil
    }

    var validationError: String? {
        guard executable.hasPrefix("/"), directory.hasPrefix("/"),
              !([executable, directory] + arguments).contains(where: { $0.contains("\0") }) else {
            return "Choose an absolute executable path and working folder."
        }
        guard !CommandPrivacy.hasSecrets(arguments) else {
            return "This command contains credentials. Move them to your project's configuration before saving a recipe."
        }
        return nil
    }

    var display: String { CommandPrivacy.display([executable] + arguments) }
    var fingerprint: String { Self.digest(([executable, directory] + arguments).joined(separator: "\0")) }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum CommandPrivacy {
    private static let sensitive = try! NSRegularExpression(pattern: #"(?i)(?:^|[^a-zA-Z0-9])(?:password|passwd|secret|token|api[-_]?key|authorization|credential)(?:$|[=\s])|://[^/\s]+:[^/@\s]+@|(?i:bearer)\s+|\b(?:sk|ghp|gho)_[A-Za-z0-9_-]+"#)

    static func isSensitive(_ text: String) -> Bool {
        sensitive.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func hasSecrets(_ arguments: [String]) -> Bool { arguments.contains(where: isSensitive) }
    static func display(_ args: [String]) -> String {
        var hideNext = false
        return args.map { arg in
            if hideNext { hideNext = false; return "[redacted]" }
            if isSensitive(arg) {
                hideNext = arg.hasPrefix("-") && !arg.contains("=")
                return arg.hasPrefix("-") ? String(arg.prefix { $0 != "=" && !$0.isWhitespace }) + "=[redacted]" : "[redacted]"
            }
            if arg.isEmpty { return "''" }
            return arg.contains(where: { $0.isWhitespace || "'\"$`;|&<>\\()".contains($0) })
                ? "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'" : arg
        }.joined(separator: " ")
    }
}

struct PinnedService: Codable, Equatable {
    let serviceID: String
    let name: String
    let port: Int
    var groupID: String? = nil
}

/// One preference domain shared by the app and CLI. Preview stores never use it.
enum Preferences {
    static let domain = "io.github.infrasan.porthole"
    static var defaults: UserDefaults { defaults(for: Bundle.main.bundleIdentifier) }
    static func defaults(for bundleID: String?) -> UserDefaults {
        // Foundation rejects a suite matching the running app's own domain.
        if bundleID == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }
    static var protectedServices: Set<String> { Set(defaults.stringArray(forKey: "protectedServices") ?? []) }
}
