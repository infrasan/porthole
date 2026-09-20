import Foundation

struct LifecycleEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: String
    let name: String
    let port: Int
    init(kind: String, name: String, port: Int) {
        id = UUID(); date = Date(); self.kind = kind; self.name = name; self.port = port
    }
    static func changes(from old: [DevServer], to fresh: [DevServer], intentionallyStopped: Set<String> = []) -> [LifecycleEvent] {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let current = Set(fresh.map(\.id))
        var events: [LifecycleEvent] = []
        for server in fresh {
            if let before = previous[server.id] {
                if !before.isOrphaned && server.isOrphaned { events.append(LifecycleEvent(kind: "orphaned", name: server.name, port: server.primaryPort)) }
            } else { events.append(LifecycleEvent(kind: server.isOrphaned ? "orphaned" : "appeared", name: server.name, port: server.primaryPort)) }
        }
        for server in old where !current.contains(server.id) && !intentionallyStopped.contains(server.id) {
            events.append(LifecycleEvent(kind: "stopped", name: server.name, port: server.primaryPort))
        }
        return events
    }
}

enum LaunchReadiness {
    static func matches(_ server: DevServer, recent: RecentServer, identity: ProcessIdentity?) -> Bool {
        guard !recent.ports.isEmpty, Set(recent.ports).isSubset(of: Set(server.ports.map(\.port))) else { return false }
        if let id = recent.dockerContainer { return server.dockerContainer == id && server.dockerDaemon == recent.dockerDaemon }
        if let formula = recent.brewService { return server.brewService == formula }
        guard let identity, identity.start != 0 else { return false }
        return server.identity == identity || server.launchAncestors.contains(identity)
    }
}
