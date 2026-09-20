import Foundation

final class LaunchHandle {
    let process: Process
    let identity: ProcessIdentity
    let log: URL
    init(process: Process, identity: ProcessIdentity, log: URL) {
        self.process = process; self.identity = identity; self.log = log
    }
}

enum Launcher {
    static var logDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Porthole", isDirectory: true)
    }

    /// Direct exec: no shell expansion, no login scripts, no captured environment.
    static func launch(_ spec: LaunchSpec, logDirectory: URL = logDirectory) throws -> LaunchHandle {
        if let error = spec.validationError { throw LaunchError.message(error) }
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            throw LaunchError.message("The executable is missing or cannot run. Edit the launch recipe.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchError.message("The working folder no longer exists. Edit the launch recipe.")
        }
        try PrivateStorage.prepareDirectory(logDirectory)
        rotateLogs(in: logDirectory)
        let log = logDirectory.appendingPathComponent("porthole-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LaunchError.message("The log file could not be created. Check folder permissions.")
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: spec.directory, isDirectory: true)
        // Keep only a small, non-secret launch environment owned by Porthole.
        // No arbitrary API credentials from Porthole's own launching agent leak to a server.
        let env = ProcessInfo.processInfo.environment
        var launchEnv = [String: String]()
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] { launchEnv[key] = env[key] }
        let executableDir = (spec.executable as NSString).deletingLastPathComponent
        launchEnv["PATH"] = "\(executableDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = launchEnv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let identity = ProcessIdentity(pid: process.processIdentifier, start: Sys.startTime(process.processIdentifier) ?? 0)
        return LaunchHandle(process: process, identity: identity, log: log)
    }

    private static func rotateLogs(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let logs = files.filter { $0.lastPathComponent.hasPrefix("porthole-") && $0.pathExtension == "log" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in logs.dropFirst(39) { try? FileManager.default.removeItem(at: file) }
    }
}

enum LaunchError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum PrivateStorage {
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    static func write(_ data: Data, to file: URL) throws {
        try prepareDirectory(file.deletingLastPathComponent())
        // File-protection classes can make a new file unreadable while macOS is
        // locked. Private directory/file permissions remain available to this user.
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
