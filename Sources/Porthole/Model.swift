import Foundation

struct PortBinding: Hashable {
    let port: Int
    /// True when the socket accepts connections from other machines (bound to
    /// all interfaces or to a non-loopback address).
    let isExposed: Bool
}

enum ServerKind {
    /// Something you started: a dev server, a watcher, a local database.
    case dev
    /// A third-party app listening on a port (Spotify, Figma, a browser).
    case app
    /// Part of macOS. Stopping it does nothing useful because launchd restarts it.
    case system
    /// Background tooling: build daemons, the agents themselves.
    case tool
}

/// Who started a server.
struct Owner: Hashable {
    enum Kind { case agent, app, terminal, service, unknown }

    let id: String
    let name: String
    let kind: Kind
    let color: UInt32
    /// Plain-language reason, shown in the details view.
    let evidence: String

    var isAgent: Bool { kind == .agent }
}

struct Framework: Hashable {
    let name: String
    let color: UInt32
    /// False for things like Postgres or Redis that have no page to open.
    let speaksHTTP: Bool
}

struct ChainLink: Hashable {
    let pid: pid_t
    let label: String
}

struct DevServer: Identifiable, Hashable {
    /// pid plus start time, so a recycled pid never matches an old row.
    var id: String { "\(pid)-\(start)" }

    let pid: pid_t
    let start: Int64
    let kind: ServerKind
    let name: String
    let framework: Framework?
    let ports: [PortBinding]
    let cwd: String?
    let command: String
    let owner: Owner
    /// No terminal, app or agent is left that owns this process.
    let isOrphaned: Bool
    /// e.g. "npm run dev"
    let launchedVia: String?
    /// Homebrew formula when the process is a `brew services` job.
    let brewService: String?
    /// Processes that Stop will end, outermost first.
    let chain: [ChainLink]
    let childCount: Int
    let memory: UInt64
    let note: String?

    var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(start) / 1_000_000) }
    var primaryPort: Int { ports.first?.port ?? 0 }
    var isExposed: Bool { ports.contains { $0.isExposed } }
    var canOpen: Bool { framework?.speaksHTTP ?? true }

    var url: URL? { URL(string: "http://localhost:\(primaryPort)") }

    func networkURL(host: String?) -> URL? {
        guard isExposed, let host else { return nil }
        return URL(string: "http://\(host):\(primaryPort)")
    }
}

struct ScanResult {
    var servers: [DevServer] = []
    var others: [DevServer] = []
    var scannedAt = Date()
    var duration: TimeInterval = 0
}
