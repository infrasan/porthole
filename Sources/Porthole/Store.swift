import AppKit
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

struct ServerGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let servers: [DevServer]
    var isMulti: Bool { servers.count > 1 }
}

struct RecipeDraft: Identifiable {
    let id = UUID()
    var recent: RecentServer
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var others: [DevServer] = []
    @Published private(set) var stopping: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var networkAddress: String?
    @Published private(set) var scanError: String?
    @Published var actionError: String?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var scanning = false
    @Published var ownerFilter: String?
    @Published var query = ""
    @Published private(set) var health: [ProbeKey: Health] = [:]
    @Published private(set) var recents: [RecentServer] = []
    @Published private(set) var starting: Set<UUID> = []
    @Published private(set) var recentErrors: [UUID: String] = [:]
    @Published private(set) var recentLogs: [UUID: URL] = [:]
    @Published private(set) var launchStatus: [UUID: String] = [:]
    @Published private(set) var protectedServices: Set<String> = []
    @Published private(set) var pinned: PinnedService?
    @Published private(set) var events: [LifecycleEvent] = []
    @Published var recipeDraft: RecipeDraft?
    @Published var panelMaxHeight: CGFloat = 700
    @Published var diagnosticsPresented = false
    @Published var notifyNew = false { didSet { defaults?.set(notifyNew, forKey: "notifyNew") } }
    @Published var notifyGone = false { didSet { defaults?.set(notifyGone, forKey: "notifyGone") } }
    @Published var notifyOrphan = false { didSet { defaults?.set(notifyOrphan, forKey: "notifyOrphan") } }

    var isPanelOpen = false {
        didSet {
            guard live, isPanelOpen != oldValue else { return }
            cancelProbes()
            if isPanelOpen { networkAddress = Network.primaryIPv4(); refresh() }
            else { triggerProbes() }
            schedule()
        }
    }
    private let scanner = Scanner()
    private let queue = DispatchQueue(label: "porthole.scan", qos: .utility)
    private let healthChecker = HealthChecker()
    private let history: History
    private let launchLogDirectory: URL
    private let stateDirectory: URL
    private let defaults: UserDefaults?
    let live: Bool
    private var timer: Timer?
    private var isShutDown = false
    private var stoppedAt: [String: Date] = [:]
    private var lastProbeAt: [ProbeKey: Date] = [:]
    private var probeTask: Task<Void, Never>?
    private var probeGeneration = 0
    private var hasBaseline = false
    private var legacyPinnedPort: Int?
    private var protocolOverrides: [String: String] = [:]
    private var launches: [UUID: LaunchHandle] = [:]
    private var launchTasks: [UUID: Task<Void, Never>] = [:]
    private var eventsFile: URL? {
        live ? stateDirectory.appendingPathComponent("events.json") : nil
    }

    init(startTimer: Bool = true, history: History? = nil, defaults: UserDefaults? = nil,
         stateDirectory: URL = History.defaultFile().deletingLastPathComponent(), launchLogDirectory: URL = Launcher.logDirectory) {
        live = startTimer
        self.stateDirectory = stateDirectory; self.launchLogDirectory = launchLogDirectory
        self.history = history ?? History(persistent: startTimer)
        self.defaults = startTimer ? (defaults ?? Preferences.defaults) : nil
        if let defaults = self.defaults {
            legacyPinnedPort = defaults.object(forKey: "pinnedPort") as? Int
            protectedServices = Set(defaults.stringArray(forKey: "protectedServices") ?? [])
            if let data = defaults.data(forKey: "pinnedService") { pinned = try? JSONDecoder().decode(PinnedService.self, from: data) }
            notifyNew = defaults.bool(forKey: "notifyNew"); notifyGone = defaults.bool(forKey: "notifyGone"); notifyOrphan = defaults.bool(forKey: "notifyOrphan")
            protocolOverrides = defaults.dictionary(forKey: "probeProtocols") as? [String: String] ?? [:]
        }
        syncHistory()
        networkAddress = startTimer ? Network.primaryIPv4() : nil
        if let file = eventsFile, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([LifecycleEvent].self, from: data) { events = Array(saved.prefix(100)) }
        if startTimer { refresh(); schedule() }
    }

    /// Stops this store's observation work. Servers it launched keep running.
    func shutdown() {
        isShutDown = true
        timer?.invalidate(); timer = nil; cancelProbes()
        for task in launchTasks.values { task.cancel() }
        launchTasks = [:]
    }

    func refresh() {
        guard live, !isShutDown, !scanning else { return }
        scanning = true
        Task { apply(await scanFresh()) }
    }
    private func scanFresh() async -> ScanResult {
        let includeMemory = isPanelOpen
        return await withCheckedContinuation { continuation in
            queue.async { [scanner] in continuation.resume(returning: scanner.scan(includeMemory: includeMemory)) }
        }
    }
    func refreshNow() { guard !live else { refresh(); return }; apply(scanner.scan()) }
    func show(_ result: ScanResult) { apply(result) }
    func preview(health: [Int: Health], recents: [RecentServer]) {
        guard !live else { return }
        self.health = Dictionary(servers.flatMap { server in server.ports.map { (probeKey(server, $0), health[$0.port] ?? .unknown) } }, uniquingKeysWith: { a, _ in a })
        self.recents = recents
    }
    private func apply(_ result: ScanResult) {
        guard !isShutDown else { return }
        scanning = false
        if let error = result.error { scanError = error; return }
        guard result.scannedAt >= (scannedAt ?? .distantPast) else { return }
        scannedAt = result.scannedAt; scanError = nil
        stoppedAt = stoppedAt.filter { Date().timeIntervalSince($0.value) < 4 }
        let fresh = result.servers.filter { stoppedAt[$0.id] == nil }
        let freshOthers = result.others.filter { stoppedAt[$0.id] == nil }
        if live { notifyDiff(from: servers, to: fresh) }
        if fresh != servers { servers = fresh }
        if freshOthers != others { others = freshOthers }
        if pinned == nil, let port = legacyPinnedPort {
            let matches = servers.filter { $0.ports.contains { $0.port == port } }
            if matches.count == 1 { pin(matches[0], port: port); defaults?.removeObject(forKey: "pinnedPort"); legacyPinnedPort = nil }
        }
        let ids = Set((servers + others).map(\.id))
        errors = errors.filter { ids.contains($0.key) }
        if let filter = ownerFilter, !servers.contains(where: { $0.owner.id == filter }) { ownerFilter = nil }
        let keys = Set(servers.flatMap { server in server.ports.map { probeKey(server, $0) } })
        health = health.filter { keys.contains($0.key) }
        lastProbeAt = lastProbeAt.filter { keys.contains($0.key) }
        triggerProbes()
    }
    private func schedule() {
        guard live else { return }
        timer?.invalidate()
        let interval: TimeInterval = isPanelOpen ? 2 : 5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = interval / 4
    }

    // MARK: - Endpoints
    func protocolFor(_ server: DevServer, _ port: PortBinding) -> ProbeProtocol {
        protocolOverrides[server.serviceID + ":" + String(port.port)].flatMap(ProbeProtocol.init(rawValue:)) ?? server.protocolFor(port)
    }
    func setProtocol(_ mode: ProbeProtocol, server: DevServer, port: PortBinding) {
        guard live else { return }
        protocolOverrides[server.serviceID + ":" + String(port.port)] = mode.rawValue
        defaults?.set(protocolOverrides, forKey: "probeProtocols")
        cancelProbes(); lastProbeAt = [:]; objectWillChange.send(); triggerProbes()
    }
    func probeKey(_ server: DevServer, _ port: PortBinding) -> ProbeKey {
        ProbeKey(serverID: server.id, port: port.port, addresses: port.addresses, mode: protocolFor(server, port))
    }
    func healthFor(_ server: DevServer, port: PortBinding? = nil) -> Health {
        guard let port = port ?? server.ports.first else { return .unknown }
        return health[probeKey(server, port)] ?? .unknown
    }
    func url(_ server: DevServer, port: PortBinding? = nil) -> URL? {
        guard let port = port ?? server.ports.first else { return nil }
        return port.url(scheme: protocolFor(server, port))
    }
    func networkURL(_ server: DevServer, port: PortBinding? = nil) -> URL? {
        guard let port = port ?? server.ports.first, port.isExposed else { return nil }
        let explicit = port.addresses.first { !["0.0.0.0", "::"].contains($0) && !PortBinding.isLoopback($0) }
        guard let host = explicit ?? networkAddress else { return nil }
        return port.url(scheme: protocolFor(server, port), networkHost: host)
    }
    private var probeTargets: [ProbeTarget] {
        let selected = isPanelOpen ? servers : pinnedServer.map { [$0] } ?? []
        return selected.flatMap { server in
            server.ports.filter { isPanelOpen || $0.port == pinnedPort }.map { ProbeTarget(key: probeKey(server, $0)) }
        }
    }
    private func cancelProbes() { probeGeneration += 1; probeTask?.cancel(); probeTask = nil }
    private func triggerProbes() {
        guard live, probeTask == nil else { return }
        let now = Date()
        let due = probeTargets.filter { now.timeIntervalSince(lastProbeAt[$0.key] ?? .distantPast) > 4 }
        guard !due.isEmpty else { return }
        for target in due { lastProbeAt[target.key] = now; if health[target.key] == nil { health[target.key] = .checking } }
        let generation = probeGeneration
        probeTask = Task {
            let result = await healthChecker.probe(due)
            guard !Task.isCancelled, generation == probeGeneration else { return }
            let current = Set(probeTargets.map(\.key))
            for (key, value) in result where current.contains(key) { health[key] = value }
            probeTask = nil
        }
    }

    // MARK: - Notifications and local history
    private func notifyDiff(from old: [DevServer], to fresh: [DevServer]) {
        guard hasBaseline else { hasBaseline = true; return }
        let changes = LifecycleEvent.changes(from: old, to: fresh, intentionallyStopped: Set(stoppedAt.keys))
        for event in changes {
            record(event)
            if (event.kind == "appeared" && notifyNew) || (event.kind == "stopped" && notifyGone) || (event.kind == "orphaned" && notifyOrphan) {
                let title = event.kind == "appeared" ? "New dev server" : event.kind == "stopped" ? "Server stopped" : "Orphaned server"
                notify(title: title, body: "\(event.name) on port \(event.port) \(event.kind == "orphaned" ? "has lost its parent app or terminal" : event.kind).")
            }
        }
    }
    private func record(_ event: LifecycleEvent) {
        guard live else { return }
        events.insert(event, at: 0); events = Array(events.prefix(100))
        if let file = eventsFile {
            do { try PrivateStorage.write(JSONEncoder().encode(events), to: file) }
            catch { actionError = "Local activity could not be saved. Check folder permissions." }
        }
    }
    func requestNotificationPermission() {
        guard live, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted { Task { @MainActor in self.actionError = error == nil ? "Notifications are off in System Settings." : "Notification permission could not be requested." } }
        }
    }
    private func notify(title: String, body: String) {
        guard live, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Lists and preferences
    var visibleServers: [DevServer] {
        servers.filter { (ownerFilter == nil || $0.owner.id == ownerFilter) && matchesQuery([$0.name, $0.framework?.name ?? "", $0.owner.name, $0.cwd ?? ""] + $0.ports.map { String($0.port) }) }
    }
    var visibleRecents: [RecentServer] {
        recents.filter { matchesQuery([$0.name, $0.frameworkName ?? "", $0.cwd ?? ""] + $0.ports.map(String.init)) }
    }
    private func matchesQuery(_ values: [String]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(q) }
    }
    var groups: [ServerGroup] {
        var order: [String] = []; var map: [String: [DevServer]] = [:]
        for server in visibleServers { let key = server.groupID ?? server.id; if map[key] == nil { order.append(key) }; map[key, default: []].append(server) }
        return order.map { key in ServerGroup(id: key, name: map[key]?.first?.groupName ?? map[key]?.first?.name ?? "", servers: map[key] ?? []) }
    }
    var orphans: [DevServer] { servers.filter(\.isOrphaned) }
    var exposedCount: Int { servers.filter(\.isExposed).count }
    var owners: [(owner: Owner, count: Int)] {
        var counts: [String: (Owner, Int)] = [:]
        for s in servers { counts[s.owner.id, default: (s.owner, 0)].1 += 1 }
        return counts.values.sorted { ($1.1, $0.0.name) < ($0.1, $1.0.name) }.map { ($0.0, $0.1) }
    }
    var pinnedPort: Int? {
        guard let pinned else { return nil }
        if pinned.groupID != nil, let server = pinnedServer {
            return server.ports.first(where: { $0.port == pinned.port })?.port ?? server.primaryPort
        }
        return pinned.port
    }
    var pinnedServer: DevServer? {
        guard let pinned else { return nil }
        return servers.first { $0.serviceID == pinned.serviceID && $0.ports.contains { $0.port == pinned.port } }
            ?? pinned.groupID.flatMap { group in servers.first { $0.groupID == group } }
    }
    var pinnedHealth: Health? {
        guard pinned != nil else { return nil }
        guard let server = pinnedServer, let port = server.ports.first(where: { $0.port == pinnedPort }) else { return .down }
        return healthFor(server, port: port)
    }
    func pinProject(_ group: ServerGroup) {
        guard live, let server = group.servers.first else { return }
        pinned = PinnedService(serviceID: server.serviceID, name: group.name, port: server.primaryPort, groupID: group.id)
        defaults?.set(try? JSONEncoder().encode(pinned), forKey: "pinnedService")
        cancelProbes(); triggerProbes()
    }
    func pin(_ server: DevServer, port: Int? = nil) {
        guard live else { return }
        pinned = PinnedService(serviceID: server.serviceID, name: server.name, port: port ?? server.primaryPort)
        defaults?.set(try? JSONEncoder().encode(pinned), forKey: "pinnedService")
        cancelProbes(); triggerProbes()
    }
    func unpin() { guard live else { return }; pinned = nil; defaults?.removeObject(forKey: "pinnedService"); cancelProbes() }
    func isProtected(_ server: DevServer) -> Bool { protectedServices.contains(server.serviceID) }
    func toggleProtection(_ server: DevServer) {
        guard live else { return }
        if isProtected(server) { protectedServices.remove(server.serviceID) } else { protectedServices.insert(server.serviceID) }
        defaults?.set(protectedServices.sorted(), forKey: "protectedServices")
    }
    func canRestart(_ server: DevServer) -> Bool {
        canStop(server) && (server.canRestart || recents.contains { $0.serviceID == server.serviceID && $0.launchSpec != nil })
    }
    func canStop(_ server: DevServer) -> Bool { Stopper.refusal(server, protectedServices: protectedServices) == nil }
    func stoppable(_ rows: [DevServer]) -> [DevServer] { rows.filter { canStop($0) && !stopping.contains($0.id) } }

    private func invalidateContainerCache() {
        queue.async { [scanner] in scanner.invalidateDockerInventory() }
    }

    // MARK: - Stop / launch
    func stop(_ server: DevServer, force: Bool = false) {
        guard live, !stopping.contains(server.id) else { return }
        guard canStop(server) else { actionError = Stopper.refusal(server, protectedServices: protectedServices); return }
        stopping.insert(server.id); errors[server.id] = nil
        Task {
            let outcome = await Stopper.stop(server, force: force)
            stopping.remove(server.id)
            if case .failed(let message) = outcome { errors[server.id] = message; actionError = message }
            else {
                if server.dockerContainer != nil { invalidateContainerCache() }
                history.add(server); syncHistory(); stoppedAt[server.id] = Date()
                servers.removeAll { $0.id == server.id }; others.removeAll { $0.id == server.id }
                record(LifecycleEvent(kind: "stopped", name: server.name, port: server.primaryPort))
            }
            refresh()
        }
    }
    func stop(_ rows: [DevServer]) { stoppable(rows).forEach { stop($0) } }
    func restart(_ server: DevServer) {
        guard live, !stopping.contains(server.id), canRestart(server) else { return }
        guard canStop(server) else { actionError = Stopper.refusal(server, protectedServices: protectedServices); return }
        stopping.insert(server.id); errors[server.id] = nil
        let recent = history.add(server); syncHistory(); starting.insert(recent.id)
        launchStatus[recent.id] = "Restarting…"
        launchTasks[recent.id] = Task {
            let managed = await Stopper.restart(server)
            let outcome: StopOutcome
            if let managed { outcome = managed } else { outcome = await Stopper.stop(server, force: false) }
            stopping.remove(server.id)
            if case .failed(let message) = outcome { finishLaunch(recent, error: message); return }
            if managed == nil { stoppedAt[server.id] = Date(); servers.removeAll { $0.id == server.id } }
            await launch(recent, managerAlreadyStarted: managed != nil)
        }
    }
    func start(_ recent: RecentServer) {
        guard live, !starting.contains(recent.id), recent.canStart else { return }
        if let handle = launches[recent.id], handle.process.isRunning {
            finishLaunch(recent, error: "The previous launch is still running. Open its log or stop that launch before retrying."); return
        }
        starting.insert(recent.id); recentErrors[recent.id] = nil; launchStatus[recent.id] = "Checking ports…"
        launchTasks[recent.id] = Task {
            let result = await scanFresh(); apply(result)
            if let error = result.error { finishLaunch(recent, error: error); return }
            let occupants = (result.servers + result.others).filter { !$0.ports.filter { recent.ports.contains($0.port) }.isEmpty }
            guard occupants.isEmpty else {
                finishLaunch(recent, error: "Port \(recent.primaryPort) is already in use by \(occupants[0].name). Stop it or change the launch recipe."); return
            }
            await launch(recent)
        }
    }
    func startProject(_ groupID: String) {
        for recent in recents where recent.groupID == groupID && recent.canStart {
            if !servers.contains(where: { $0.serviceID == recent.serviceID }) { start(recent) }
        }
    }
    private func launch(_ recent: RecentServer, managerAlreadyStarted: Bool = false) async {
        launchStatus[recent.id] = "Starting…"
        var handle: LaunchHandle?
        if !managerAlreadyStarted {
            if let outcome = await Stopper.start(recent) {
                if case .failed(let message) = outcome { finishLaunch(recent, error: message); return }
            } else {
                guard let spec = recent.launchSpec else { finishLaunch(recent, error: "Review the launch recipe before starting it."); return }
                do {
                    let started = try Launcher.launch(spec, logDirectory: launchLogDirectory); handle = started; launches[recent.id] = started
                    recentLogs[recent.id] = started.log
                    history.update(recent.id) { $0.logPath = started.log.path; $0.failure = nil }; syncHistory()
                } catch { finishLaunch(recent, error: error.localizedDescription); return }
            }
        }
        if recent.dockerContainer != nil { invalidateContainerCache() }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        launchStatus[recent.id] = recent.ports.count == 1 ? "Waiting for port \(recent.primaryPort)…" : "Waiting for \(recent.ports.count) ports…"
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            let result = await scanFresh(); apply(result)
            if result.error == nil, let server = result.servers.first(where: { LaunchReadiness.matches($0, recent: recent, identity: handle?.identity) }) {
                // Binding ownership, not an unrelated process on the old port, determines startup success.
                history.update(recent.id) { $0.serviceID = server.serviceID }
                if let oldID = recent.serviceID, oldID != server.serviceID {
                    if protectedServices.remove(oldID) != nil {
                        protectedServices.insert(server.serviceID)
                        defaults?.set(protectedServices.sorted(), forKey: "protectedServices")
                    }
                    if pinned?.serviceID == oldID { pin(server, port: recent.primaryPort) }
                }
                finishLaunch(recent, error: nil)
                record(LifecycleEvent(kind: "started", name: server.name, port: server.primaryPort)); return
            }
            if let handle, !handle.process.isRunning {
                finishLaunch(recent, error: "The command exited before its port opened. Open the log to check what happened."); return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !Task.isCancelled { finishLaunch(recent, error: "The server has not opened its port after 30 seconds. Open the log; the launch may still be running.") }
    }
    private func finishLaunch(_ recent: RecentServer, error: String?) {
        starting.remove(recent.id); launchStatus[recent.id] = nil; launchTasks[recent.id] = nil
        recentErrors[recent.id] = error
        if error == nil || launches[recent.id]?.process.isRunning != true { launches[recent.id] = nil }
        if let error { history.update(recent.id) { $0.failure = error } }
        else if recent.isSaved { history.update(recent.id) { $0.failure = nil } }
        else { history.remove(recent.id) }
        syncHistory(); refresh()
    }
    func hasLaunch(_ recent: RecentServer) -> Bool { launches[recent.id]?.process.isRunning == true }
    func stopLaunch(_ recent: RecentServer) {
        guard live, let handle = launches[recent.id] else { return }
        if let serviceID = recent.serviceID, protectedServices.contains(serviceID) {
            actionError = "This service is protected. Unprotect it before stopping its launch."; return
        }
        launchTasks[recent.id]?.cancel(); launchTasks[recent.id] = nil
        let pending = DevServer(rowID: nil, pid: handle.identity.pid, start: handle.identity.start, kind: .dev, name: recent.name,
                                framework: nil, ports: [], cwd: recent.launchSpec?.directory, command: recent.command ?? "",
                                owner: Owner(id: "porthole", name: "Porthole", kind: .app, color: 0, evidence: "Started here"),
                                isOrphaned: false, launchedVia: nil, brewService: nil, dockerContainer: nil, chain: [], childCount: 0,
                                memory: 0, cpuPercent: nil, note: nil, launchSpec: recent.launchSpec, groupID: recent.groupID,
                                groupName: recent.groupName, stopDisabledReason: nil)
        Task {
            let outcome = await Stopper.stop(pending, force: false)
            if case .failed(let message) = outcome { finishLaunch(recent, error: message) }
            else { launches[recent.id] = nil; finishLaunch(recent, error: "Launch stopped. You can edit the recipe and try again.") }
        }
    }
    private func syncHistory() {
        recents = history.recents
        let ids = Set(recents.map(\.id))
        launches = launches.filter { $0.value.process.isRunning }
        recentErrors = recentErrors.filter { ids.contains($0.key) }
        recentLogs = recentLogs.filter { ids.contains($0.key) }
        for recent in recents {
            if let failure = recent.failure { recentErrors[recent.id] = failure }
            if let log = recent.logPath { recentLogs[recent.id] = URL(fileURLWithPath: log) }
        }
        if let error = history.error { actionError = error }
    }
    func removeRecent(_ id: UUID) {
        guard live, !starting.contains(id), launches[id]?.process.isRunning != true else { return }
        history.remove(id); syncHistory(); recentErrors[id] = nil; recentLogs[id] = nil; launches[id] = nil
    }
    func editRecipe(_ server: DevServer) { guard live else { return }; recipeDraft = RecipeDraft(recent: history.recents.first { $0.serviceID == server.serviceID } ?? RecentServer(server: server)) }
    func editRecipe(_ recent: RecentServer) { guard live else { return }; recipeDraft = RecipeDraft(recent: recent) }
    func saveRecipe(_ draft: RecentServer, spec: LaunchSpec) {
        guard live else { return }
        if let error = spec.validationError { actionError = error; return }
        var recent = draft; recent.launchSpec = spec; recent.saved = true; recent.failure = nil
        history.upsert(recent); syncHistory(); recipeDraft = nil
    }
    func saveManagedRecipe(_ server: DevServer) {
        guard live else { return }
        var recent = history.add(server); recent.saved = true; history.upsert(recent); syncHistory()
    }
    func open(_ server: DevServer, port: PortBinding? = nil) { if live, let url = url(server, port: port) { NSWorkspace.shared.open(url) } }
    func openOnNetwork(_ server: DevServer) { if live, let url = networkURL(server) { NSWorkspace.shared.open(url) } }
    func copy(_ text: String) { guard live else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func reveal(_ server: DevServer) { guard live, let cwd = server.cwd else { return }; NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
    // MARK: - Open in editor / terminal

    private static let editors: [(name: String, bundleID: String)] = [
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    /// The first editor found on this Mac, for the menu item's label.
    var editorName: String? {
        Self.editors.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }?.name
    }

    func openInEditor(_ server: DevServer) {
        guard live, let cwd = server.cwd else { return }
        let folder = URL(fileURLWithPath: cwd)
        for editor in Self.editors {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(folder)
    }

    func openInTerminal(_ server: DevServer) {
        guard live, let cwd = server.cwd else { return }
        let folder = URL(fileURLWithPath: cwd)
        for bundleID in ["com.googlecode.iterm2", "com.apple.Terminal"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    // MARK: - Settings

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard live else { return }
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                actionError = "Launch at login could not be changed. Check Login Items in System Settings."
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
