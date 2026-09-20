import Foundation

enum ProbeProtocol: String, Codable, CaseIterable, Sendable {
    case http, https, tcp
    var label: String { rawValue.uppercased() }
}

struct PortBinding: Hashable, Codable, Sendable {
    let port: Int
    let isExposed: Bool
    var addresses: [String] = ["127.0.0.1"]
    var protocolHint: ProbeProtocol? = nil

    var loopbackHosts: [String] {
        Array(Set(addresses.compactMap { address in
            switch address {
            case "0.0.0.0": return "127.0.0.1"
            case "::": return "::1"
            default: return Self.isLoopback(address) ? address : nil
            }
        })).sorted()
    }
    static func isLoopback(_ address: String) -> Bool {
        // Accept numeric addresses only; never resolve a hostname supplied by a process.
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: v6) { bytes in
                (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
                    || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127)
            }
        }
        return false
    }
    static func collect(_ sockets: [SocketListener]) -> [PortBinding] {
        Dictionary(grouping: sockets, by: \.port).map { port, sockets in
            PortBinding(port: port, isExposed: sockets.contains { !$0.isLoopback }, addresses: Array(Set(sockets.map(\.address))).sorted())
        }.sorted { $0.port < $1.port }
    }
    func url(scheme: ProbeProtocol, networkHost: String? = nil) -> URL? {
        guard scheme != .tcp, (1...65535).contains(port), let host = networkHost ?? loopbackHosts.first else { return nil }
        let literal = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme.rawValue)://\(literal):\(port)")
    }
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
    /// pid plus start time, so a recycled pid never matches an old row. Docker
    /// containers share their forwarder's pid, so they carry a rowID instead.
    var id: String { rowID ?? "\(pid)-\(start)" }
    let rowID: String?

    let pid: pid_t
    let start: Int64
    let kind: ServerKind
    let name: String
    let framework: Framework?
    var ports: [PortBinding]
    let cwd: String?
    let command: String
    let owner: Owner
    /// No terminal, app or agent is left that owns this process.
    let isOrphaned: Bool
    /// e.g. "npm run dev"
    let launchedVia: String?
    /// Homebrew formula when the process is a `brew services` job.
    let brewService: String?
    /// Docker container id when the port is published by a container.
    let dockerContainer: String?
    /// Processes that Stop will end, outermost first.
    let chain: [ChainLink]
    let childCount: Int
    let memory: UInt64
    /// CPU across the whole job, diffed between scans. One core fully busy = 100.
    let cpuPercent: Int?
    let note: String?
    /// Exact executable, argv and original working directory, when recoverable.
    let launchSpec: LaunchSpec?
    /// Servers sharing a group (same git root or folder) render as one project.
    let groupID: String?
    let groupName: String?
    /// When set, Stop is hidden: the process must not be signaled directly.
    let stopDisabledReason: String?
    var dockerDaemon: DockerDaemon? = nil
    var launchAncestors: [ProcessIdentity] = []

    var identity: ProcessIdentity { ProcessIdentity(pid: pid, start: start) }
    /// Persistent preferences identify a service, never a recycled PID or a bare port.
    var serviceID: String {
        if let container = dockerContainer { return "docker-" + LaunchSpec.digest((dockerDaemon?.socketPath ?? "") + container) }
        if let brewService { return "brew-" + brewService }
        // Project + name + framework + ports identify the service across process restarts.
        return "service-" + LaunchSpec.digest([groupID ?? cwd ?? "", name, framework?.name ?? "", ports.map { String($0.port) }.joined(separator: ",")].joined(separator: "\0"))
    }

    var startedAt: Date { Date(timeIntervalSince1970: TimeInterval(start) / 1_000_000) }
    var primaryPort: Int { ports.first?.port ?? 0 }
    var isExposed: Bool { ports.contains { $0.isExposed } }
    var canOpen: Bool { protocolFor(ports.first) != .tcp }
    var canStop: Bool { stopDisabledReason == nil && kind != .system }
    var canForceStop: Bool { canStop && brewService == nil }
    /// Docker containers restart with `docker restart`, brew services with
    /// `brew services restart`, everything else by re-running its command.
    var canRestart: Bool { canStop && (launchSpec != nil || (dockerContainer != nil && dockerDaemon != nil) || brewService != nil) }

    func protocolFor(_ binding: PortBinding?) -> ProbeProtocol {
        binding?.protocolHint ?? (framework?.speaksHTTP == true ? .http : .tcp)
    }
    var url: URL? { ports.first?.url(scheme: protocolFor(ports.first)) }
    func networkURL(host: String?) -> URL? {
        guard let binding = ports.first, binding.isExposed, let host else { return nil }
        let explicit = binding.addresses.first { $0 != "0.0.0.0" && $0 != "::" && !PortBinding.isLoopback($0) }
        return binding.url(scheme: protocolFor(binding), networkHost: explicit ?? host)
    }

}

struct ScanResult {
    var servers: [DevServer] = []
    var others: [DevServer] = []
    var scannedAt = Date()
    var duration: TimeInterval = 0
    var error: String? = nil
}
