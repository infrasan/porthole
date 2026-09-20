import Foundation

struct RecentServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var ports: [Int]
    var cwd: String?
    var frameworkName: String?
    var ownerName: String?
    var speaksHTTP: Bool
    var brewService: String?
    var dockerContainer: String?
    var stoppedAt: Date
    var launchSpec: LaunchSpec?
    var dockerDaemon: DockerDaemon?
    var serviceID: String?
    var groupID: String?
    var groupName: String?
    var saved: Bool?
    var failure: String?
    var logPath: String?

    var primaryPort: Int { ports.first ?? 0 }
    var canStart: Bool { launchSpec != nil || brewService != nil || (dockerContainer != nil && dockerDaemon != nil) }
    var command: String? { launchSpec?.display }
    var isSaved: Bool { saved == true }

    init(server: DevServer) {
        id = UUID(); name = server.name; ports = server.ports.map(\.port); cwd = server.cwd
        frameworkName = server.framework?.name; ownerName = server.owner.name
        speaksHTTP = server.canOpen; brewService = server.brewService; dockerContainer = server.dockerContainer
        stoppedAt = Date(); launchSpec = server.launchSpec; dockerDaemon = server.dockerDaemon
        serviceID = server.serviceID; groupID = server.groupID; groupName = server.groupName
    }
    // Old `command` strings are deliberately not decoded into executable recipes.
    // Existing metadata survives; the user can review a recipe before starting it.
}

final class History {
    private(set) var recents: [RecentServer] = []
    private(set) var error: String?
    let file: URL?
    init(file: URL? = History.defaultFile(), persistent: Bool = true) {
        self.file = persistent ? file : nil
        if persistent { load() }
    }
    static func defaultFile() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Porthole/recents.json")
    }
    @discardableResult
    func add(_ server: DevServer) -> RecentServer {
        var recent = RecentServer(server: server)
        if let existing = recents.first(where: { $0.serviceID == recent.serviceID && recent.serviceID != nil }) {
            recent = existing; recent.stoppedAt = Date(); recent.failure = nil
            recent.launchSpec = existing.isSaved ? existing.launchSpec ?? server.launchSpec : server.launchSpec ?? existing.launchSpec
        }
        upsert(recent)
        return recent
    }
    func upsert(_ value: RecentServer) {
        var recent = value
        if recent.launchSpec?.validationError != nil {
            recent.launchSpec = nil; recent.failure = "Review this launch recipe before starting it."
        }
        recents.removeAll { $0.id == recent.id || ($0.serviceID != nil && $0.serviceID == recent.serviceID) }
        recents.insert(recent, at: 0)
        let saved = recents.filter(\.isSaved)
        recents = saved + Array(recents.filter { !$0.isSaved }.prefix(12))
        save()
    }
    func remove(_ id: UUID) { recents.removeAll { $0.id == id }; save() }
    func update(_ id: UUID, _ body: (inout RecentServer) -> Void) {
        guard let index = recents.firstIndex(where: { $0.id == id }) else { return }
        body(&recents[index]); save()
    }
    private func load() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            recents = try JSONDecoder().decode([RecentServer].self, from: data)
            // Never trust a tampered/malformed persisted launch specification.
            for index in recents.indices where recents[index].launchSpec?.validationError != nil {
                recents[index].launchSpec = nil
                recents[index].failure = "Review this launch recipe before starting it."
            }
        } catch { self.error = "Saved servers could not be read. Your existing file has been kept." }
    }
    private func save() {
        guard let file else { return }
        // Do not silently replace an unreadable history file.
        guard error == nil else { return }
        do { try PrivateStorage.write(JSONEncoder().encode(recents), to: file) }
        catch { self.error = "Saved servers could not be written. Check folder permissions." }
    }
}
