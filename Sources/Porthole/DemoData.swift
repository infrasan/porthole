import Foundation

/// Made-up servers for README screenshots, so nobody publishes their own
/// project names by accident: `Porthole --snapshot out.png --demo`.
enum DemoData {
    static func result() -> ScanResult {
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
                    owner: Owner, orphaned: Bool = false, via: String? = nil, brew: String? = nil,
                    chain: [(pid_t, String)], children: Int = 0, kind: ServerKind = .dev, note: String? = nil) -> DevServer {
            DevServer(pid: pid, start: ago(minutes), kind: kind, name: name, framework: kind == .dev ? framework : nil,
                      ports: ports.map { PortBinding(port: $0, isExposed: exposed) },
                      cwd: "/Users/you/code/\(name)", command: chain.last?.1 ?? name, owner: owner, isOrphaned: orphaned,
                      launchedVia: via, brewService: brew, chain: chain.map { ChainLink(pid: $0.0, label: $0.1) },
                      childCount: children, memory: 0, note: note)
        }

        var result = ScanResult()
        result.servers = [
            server(41210, 130, "storefront", fw("Next.js"), [3000], exposed: true,
                   owner: owner("claude-code", "Started by Claude Code, which is still running (pid 40991)."),
                   via: "npm run dev", chain: [(41210, "npm run dev"), (41236, "node next"), (41237, "next-server (v16.3.1)")], children: 1),
            server(52011, 25, "docs", fw("Astro"), [4321],
                   owner: owner("kimi", "Started by Kimi, which is still running (pid 51870)."),
                   via: "pnpm dev", chain: [(52011, "pnpm dev"), (52040, "node astro")]),
            server(38802, 4320, "dashboard", fw("Vite"), [5173],
                   owner: owner("codex", "Whatever started it has exited. Codex left CODEX_THREAD_ID in its environment."),
                   orphaned: true, via: "npm run dev", chain: [(38802, "npm run dev"), (38830, "node vite")], children: 1),
            server(612, 12960, "postgresql@16", fw("PostgreSQL", http: false), [5432],
                   owner: owner("brew", "Managed by launchd as homebrew.mxcl.postgresql@16."),
                   brew: "postgresql@16", chain: [(612, "postgres postgresql@16")], children: 6),
            server(47120, 64, "design-system", fw("Storybook"), [6006],
                   owner: owner("terminal", "Running in Terminal (pid 1204)."),
                   via: "npm run storybook", chain: [(47120, "npm run storybook"), (47141, "node storybook")]),
            server(33019, 2890, "api", fw("FastAPI"), [8000], exposed: true,
                   owner: owner("gemini", "Whatever started it has exited. Gemini CLI left GEMINI_CLI in its environment."),
                   orphaned: true, chain: [(33019, "python uvicorn")]),
            server(29544, 7300, "landing/dist", fw("http.server"), [8080],
                   owner: owner("opencode", "Whatever started it has exited. OpenCode left OPENCODE_CLIENT in its environment."),
                   orphaned: true, chain: [(29544, "python http.server")]),
            server(50377, 41, "mobile-app", fw("Firebase emulators"), [4000, 4400, 5001, 8080 + 1, 9099, 9199],
                   owner: owner("claude-code", "Started by Claude Code, which is still running (pid 40991)."),
                   via: "npm run emulators", chain: [(50377, "npm run emulators"), (50390, "node firebase")], children: 2),
        ].sorted { $0.primaryPort < $1.primaryPort }
        result.others = [
            server(1114, 20000, "Control Center", fw(""), [5000, 7000], owner: owner("terminal", ""), chain: [(1114, "ControlCenter")],
                   kind: .system, note: "AirPlay Receiver. To free ports 5000 and 7000, turn it off in System Settings › General › AirDrop & Handoff."),
            server(14315, 180, "Gradle daemon", fw(""), [17722, 60476], owner: owner("claude-code", ""), chain: [(14315, "java GradleDaemon")],
                   kind: .tool, note: "Restarts on the next build."),
        ]
        return result
    }
}
