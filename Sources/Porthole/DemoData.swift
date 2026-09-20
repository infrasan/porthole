import Foundation

/// Made-up servers for README screenshots, so nobody publishes their own
/// project names by accident: `Porthole --snapshot out.png --demo`.
enum DemoData {
    static func result(count: Int? = nil) -> ScanResult {
        let now = Date().timeIntervalSince1970
        func ago(_ minutes: Double) -> Int64 { Int64((now - minutes * 60) * 1_000_000) }
        func owner(_ id: String, _ evidence: String) -> Owner {
            if let def = Catalog.owners.first(where: { $0.id == id }) {
                return Owner(id: def.id, name: def.name, kind: def.kind, color: def.color, evidence: evidence)
            }
            return Owner(id: "brew", name: "brew services", kind: .service, color: 0xF9A03F, evidence: evidence)
        }
        func fw(_ name: String, http: Bool = true) -> Framework { Framework(name: name, color: 0x8E8E93, speaksHTTP: http) }
        func server(_ pid: pid_t, _ minutes: Double, _ name: String, _ framework: Framework, _ ports: [Int], exposed: Bool = false,
                    owner: Owner, orphaned: Bool = false, via: String? = nil, brew: String? = nil, docker: String? = nil,
                    chain: [(pid_t, String)], children: Int = 0, kind: ServerKind = .dev, cpu: Int? = nil, memory: UInt64 = 0,
                    cwd: String? = nil, relaunch: String? = nil, group: String? = nil, note: String? = nil) -> DevServer {
            let folder = docker == nil ? (cwd ?? "/Users/you/code/\(name)") : nil
            return DevServer(
                rowID: docker.map { "docker-\($0)" },
                pid: pid, start: ago(minutes), kind: kind, name: name, framework: kind == .dev ? framework : nil,
                ports: ports.map { PortBinding(port: $0, isExposed: exposed) },
                cwd: folder, command: chain.last?.1 ?? name, owner: owner, isOrphaned: orphaned,
                launchedVia: via, brewService: brew, dockerContainer: docker,
                chain: chain.map { ChainLink(pid: $0.0, label: $0.1) },
                childCount: children, memory: memory, cpuPercent: cpu, note: note,
                launchSpec: kind == .dev && docker == nil && brew == nil && via != nil ? LaunchSpec(executable: "/usr/bin/env", arguments: (via ?? "").split(separator: " ").map(String.init), directory: folder ?? "/tmp") : nil,
                groupID: group, groupName: group.map { ($0 as NSString).lastPathComponent },
                stopDisabledReason: kind == .system ? "Managed by macOS" : nil,
                dockerDaemon: docker == nil ? nil : DockerDaemon(socketPath: NSHomeDirectory() + "/.docker/run/docker.sock"))
        }

        var result = ScanResult()
        result.servers = [
            server(41210, 130, "storefront", fw("Next.js"), [3000], exposed: true,
                   owner: owner("claude-code", "Started by Claude Code, which is still running (pid 40991)."),
                   via: "npm run dev", chain: [(41210, "npm run dev"), (41236, "node next"), (41237, "next-server (v16.3.1)")],
                   children: 1, cpu: 14, memory: 412_000_000, group: "/Users/you/code/storefront"),
            server(41255, 128, "storefront/api", fw("FastAPI"), [8000],
                   owner: owner("claude-code", "Started by Claude Code, which is still running (pid 40991)."),
                   via: "npm run dev:api", chain: [(41255, "npm run dev:api"), (41281, "python uvicorn")],
                   cpu: 3, memory: 96_000_000, cwd: "/Users/you/code/storefront/api", group: "/Users/you/code/storefront"),
            server(52011, 25, "docs", fw("Astro"), [4321],
                   owner: owner("kimi", "Started by Kimi, which is still running (pid 51870)."),
                   via: "pnpm dev", chain: [(52011, "pnpm dev"), (52040, "node astro")], cpu: 1, memory: 188_000_000),
            server(38802, 4320, "dashboard", fw("Vite"), [5173],
                   owner: owner("codex", "Whatever started it has exited. Codex left CODEX_THREAD_ID in its environment."),
                   orphaned: true, via: "npm run dev", chain: [(38802, "npm run dev"), (38830, "node vite")], children: 1, memory: 240_000_000),
            server(612, 12960, "postgresql@16", fw("PostgreSQL", http: false), [5432],
                   owner: owner("brew", "Managed by launchd as homebrew.mxcl.postgresql@16."),
                   brew: "postgresql@16", chain: [(612, "postgres postgresql@16")], children: 6, memory: 58_000_000),
            server(92314, 610, "cache", fw("Redis", http: false), [6379],
                   owner: Owner(id: "docker", name: "Docker", kind: .service, color: 0x1D63ED,
                              evidence: "Port 6379 is published by the container \"cache\" (redis:7)."),
                   docker: "b1a2c3d4e5f6", chain: [(92314, "docker proxy")], memory: 0,
                   cwd: nil, relaunch: nil,
                   note: "Container b1a2c3d4e5f6, image redis:7. Stop runs docker stop cache."),
            server(47120, 64, "design-system", fw("Storybook"), [6006],
                   owner: owner("terminal", "Running in Terminal (pid 1204)."),
                   via: "npm run storybook", chain: [(47120, "npm run storybook"), (47141, "node storybook")], cpu: 0, memory: 320_000_000),
            server(29544, 7300, "landing/dist", fw("http.server"), [8080],
                   owner: owner("opencode", "Whatever started it has exited. OpenCode left OPENCODE_CLIENT in its environment."),
                   orphaned: true, chain: [(29544, "python http.server")], memory: 18_000_000),
            server(50377, 41, "mobile-app", fw("Firebase emulators"), [4000, 4400, 5001, 8080 + 1, 9099, 9199],
                   owner: owner("claude-code", "Started by Claude Code, which is still running (pid 40991)."),
                   via: "npm run emulators", chain: [(50377, "npm run emulators"), (50390, "node firebase")], children: 2, cpu: 8, memory: 610_000_000),
        ].sorted { $0.primaryPort < $1.primaryPort }
        result.others = [
            server(1114, 20000, "Control Center", fw(""), [5000, 7000], owner: owner("terminal", ""), chain: [(1114, "ControlCenter")],
                   kind: .system, note: "AirPlay Receiver. To free ports 5000 and 7000, turn it off in System Settings › General › AirDrop & Handoff."),
            server(14315, 180, "Gradle daemon", fw(""), [17722, 60476], owner: owner("claude-code", ""), chain: [(14315, "java GradleDaemon")],
                   kind: .tool, note: "Restarts on the next build."),
        ]
        if let count {
            let rowCount = min(100, max(0, count))
            let demoOwner = owner("codex", "Demo process. No real process is controlled.")
            let framework = fw("Vite")
            result.servers = (0..<rowCount).map { index -> DevServer in
                let pid = pid_t(900000 + index)
                let name = "demo-service-\(index + 1)"
                let ports: [Int] = [10000 + index]
                return server(pid, Double(index + 1), name, framework, ports,
                              owner: demoOwner, via: "npm run dev", chain: [(pid, "node vite")])
            }
            if count == 0 { result.others = [] }
        }
        return result
    }

    /// Health values painted onto the demo servers for screenshots.
    static var health: [Int: Health] {
        [3000: .up(ms: 38), 8000: .up(ms: 12), 4321: .up(ms: 21), 5173: .down,
         5432: .up(ms: 2), 6379: .up(ms: 1), 6006: .up(ms: 154), 8080: .up(ms: 9)]
    }

    /// Recently stopped entries for screenshots.
    static var recents: [RecentServer] {
        var old = RecentServer(server: result().servers.first { $0.primaryPort == 5173 }!)
        old.stoppedAt = Date().addingTimeInterval(-3 * 3600)
        return [old]
    }
}
