import Foundation
import AppKit

enum Diagnostics {
    static func data(_ result: ScanResult, events: [LifecycleEvent] = []) throws -> Data {
        struct Report: Encodable {
            let version: Int
            let generatedAt: Date
            let scanMilliseconds: Int
            let scanError: String?
            let servers: [Entry]
            let events: [LifecycleEvent]
        }
        struct Entry: Encodable {
            let id: String
            let name: String
            let ports: [PortBinding]
            let folder: String?
            let command: String
            let framework: String?
            let owner: String
            let orphaned: Bool
            let canStop: Bool
        }
        let entries = (result.servers + result.others).map {
            Entry(id: $0.id, name: $0.name, ports: $0.ports, folder: $0.cwd,
                  command: $0.command, framework: $0.framework?.name, owner: $0.owner.name,
                  orphaned: $0.isOrphaned, canStop: $0.canStop)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Report(version: 1, generatedAt: Date(), scanMilliseconds: Int(result.duration * 1000), scanError: result.error, servers: entries, events: events))
    }
}

extension Store {
    func exportDiagnostics() {
        guard live else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Porthole-diagnostics.json"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try Diagnostics.data(ScanResult(servers: self.servers, others: self.others, error: self.scanError), events: self.events)
                    // The selected directory belongs to the user; do not chmod it.
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch { self.actionError = "The diagnostics file could not be saved. Choose another location." }
            }
        }
    }
}
