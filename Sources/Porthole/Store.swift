import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var others: [DevServer] = []
    @Published private(set) var stopping: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var networkAddress: String?
    @Published var ownerFilter: String?

    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            if isPanelOpen { networkAddress = Network.primaryIPv4(); refresh() }
            schedule()
        }
    }

    private let scanner = Scanner()
    private let queue = DispatchQueue(label: "porthole.scan", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    /// Servers stopped moments ago. A scan that started before the stop
    /// finished would otherwise bring the row back for a cycle.
    private var stoppedAt: [String: Date] = [:]

    init(startTimer: Bool = true) {
        networkAddress = Network.primaryIPv4()
        if startTimer {
            refresh()
            schedule()
        }
    }

    // MARK: - Scanning

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let includeMemory = isPanelOpen
        queue.async { [scanner] in
            let result = scanner.scan(includeMemory: includeMemory)
            Task { @MainActor in self.apply(result) }
        }
    }

    /// Synchronous scan, for snapshots and tests.
    func refreshNow() {
        apply(scanner.scan())
    }

    func show(_ result: ScanResult) {
        apply(result)
    }

    private func apply(_ result: ScanResult) {
        scanning = false
        stoppedAt = stoppedAt.filter { Date().timeIntervalSince($0.value) < 4 }
        let fresh = result.servers.filter { stoppedAt[$0.id] == nil }
        let freshOthers = result.others.filter { stoppedAt[$0.id] == nil }
        // Publishing redraws the menu bar item, so skip it when nothing changed.
        if fresh != servers { servers = fresh }
        if freshOthers != others { others = freshOthers }
        let live = Set((servers + others).map(\.id))
        errors = errors.filter { live.contains($0.key) }
        if let filter = ownerFilter, !servers.contains(where: { $0.owner.id == filter }) { ownerFilter = nil }
    }

    private func schedule() {
        timer?.invalidate()
        // Fast while the panel is open; slower in the background, just enough
        // to keep the menu bar count honest.
        let interval: TimeInterval = isPanelOpen ? 2 : 5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = interval / 4
    }

    // MARK: - Derived

    var visibleServers: [DevServer] {
        guard let filter = ownerFilter else { return servers }
        return servers.filter { $0.owner.id == filter }
    }

    var orphans: [DevServer] { servers.filter(\.isOrphaned) }

    /// Owners in order of how many servers they started.
    var owners: [(owner: Owner, count: Int)] {
        var counts: [String: (Owner, Int)] = [:]
        for s in servers { counts[s.owner.id, default: (s.owner, 0)].1 += 1 }
        return counts.values.sorted { ($1.1, $0.0.name) < ($0.1, $1.0.name) }.map { ($0.0, $0.1) }
    }

    // MARK: - Actions

    func stop(_ server: DevServer, force: Bool = false) {
        guard !stopping.contains(server.id) else { return }
        stopping.insert(server.id)
        errors[server.id] = nil
        Task {
            let outcome = await Stopper.stop(server, force: force)
            stopping.remove(server.id)
            if case .failed(let message) = outcome {
                errors[server.id] = message
            } else {
                stoppedAt[server.id] = Date()
                servers.removeAll { $0.id == server.id }
                others.removeAll { $0.id == server.id }
            }
            refresh()
        }
    }

    func stop(_ servers: [DevServer]) {
        servers.forEach { stop($0) }
    }

    func open(_ server: DevServer) {
        if let url = server.url { NSWorkspace.shared.open(url) }
    }

    func openOnNetwork(_ server: DevServer) {
        if let url = server.networkURL(host: networkAddress) { NSWorkspace.shared.open(url) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ server: DevServer) {
        guard let cwd = server.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    // MARK: - Settings

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Porthole: launch at login failed: \(error.localizedDescription)")
            }
        }
    }
}

enum Network {
    /// The Mac's LAN address, for opening a server from a phone on the same network.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            candidates.append((name, String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        // Prefer Wi-Fi and Ethernet over VPN and bridge interfaces.
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}
