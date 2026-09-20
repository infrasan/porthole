import Foundation

struct ProjectInfo {
    var name: String?
    /// The name came from package.json or another manifest, not the folder.
    var fromManifest = false
    var dependencies: Set<String> = []
}

extension Scanner {
    func makeServer(root: pid_t, members: [pid_t], listening: [pid_t: [SocketListener]], includeMemory: Bool) -> DevServer? {
        guard let rootProc = table[root] else { return nil }
        let d = detail(root)
        let (kind, appName, note) = classify(root, d, listening[root] ?? [])

        let top = kind == .dev ? topOfJob(root) : root
        let chain = path(from: top, to: root)
        let tree = [top] + descendants(of: top)
        let job = chain + tree.filter { !chain.contains($0) }
        let envs = job.map { detail($0).env }

        let ports = PortBinding.collect(members.flatMap { listening[$0] ?? [] })

        var (owner, orphaned) = attribute(top: top, envs: envs)
        if kind != .dev { orphaned = false }
        if kind == .system {
            owner = Owner(id: "macos", name: "macOS", kind: .service, color: 0x8E8E93, evidence: "Part of macOS.")
        }
        let dir = servedDirectory(d)
        let project = projectInfo(dir)
        let commands = chain.map { detail($0).args } + members.map { detail($0).args }
        let framework = Frameworks.detect(commands: commands, dependencies: project.dependencies)
        let brew = envs.lazy.compactMap { $0["XPC_SERVICE_NAME"] }.first { $0.hasPrefix("homebrew.mxcl.") }
            .map { String($0.dropFirst("homebrew.mxcl.".count)) }

        let temp = ["/private/tmp/", "/tmp/", "/private/var/folders/"].contains { (dir ?? "").hasPrefix($0) }
        let projectName = temp && !project.fromManifest ? (scriptName(d) ?? project.name) : project.name
        let name = appName ?? brew ?? projectName ?? framework?.name ?? Frameworks.basename(d.exe)
        let group = kind == .dev ? group(for: dir) : nil
        let launchSpec = kind == .dev && brew == nil ? LaunchSpec.capture(detail(top)) : nil
        return DevServer(
            rowID: nil,
            pid: root,
            start: rootProc.start,
            kind: kind,
            name: name,
            framework: kind == .dev ? framework : nil,
            ports: ports,
            cwd: dir,
            command: abbreviate(d.command),
            owner: owner,
            isOrphaned: orphaned,
            launchedVia: launchedVia(chain: chain, envs: envs),
            brewService: brew,
            dockerContainer: nil,
            chain: chain.map { ChainLink(pid: $0, label: label(for: $0)) },
            childCount: tree.count - chain.count,
            memory: includeMemory ? tree.reduce(0) { $0 + Sys.residentBytes($1) } : 0,
            cpuPercent: includeMemory ? cpuPercent(id: "\(root)-\(rootProc.start)", tree: tree) : nil,
            note: note,
            launchSpec: launchSpec,
            groupID: group?.id,
            groupName: group?.name,
            stopDisabledReason: kind == .system ? "macOS manages this process. Change its system setting instead." : nil,
            launchAncestors: ancestry(of: root)
        )
    }

    /// The project a server belongs to: its git root when there is one, else
    /// the folder it runs in. Drives grouping in the panel.
    func group(for dir: String?) -> (id: String, name: String)? {
        guard let dir, dir != "/", dir != home else { return nil }
        var cursor = dir
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: (cursor as NSString).appendingPathComponent(".git")) {
                return (cursor, (cursor as NSString).lastPathComponent)
            }
            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent == home || parent == "/" { break }
            cursor = parent
        }
        return (dir, (dir as NSString).lastPathComponent)
    }

    // MARK: - Docker containers

    /// One row per container behind a Docker/OrbStack port forwarder, so each
    /// container gets its own name, framework, and Stop button (`docker stop`).
    /// Signaling the forwarder itself would cut networking for every container,
    /// so unmatched ports render as a tool row with Stop disabled.
    func makeDockerServers(root: pid_t, members: [pid_t], listening: [pid_t: [SocketListener]], includeMemory: Bool) -> [DevServer] {
        guard let rootProc = table[root] else { return [] }
        let sockets = members.flatMap { listening[$0] ?? [] }
        let inventory = dockerContainers(executable: detail(root).exe, comm: rootProc.comm)
        var claimed: Set<SocketListener> = []
        var servers: [DevServer] = []
        for container in inventory.containers {
            let mine = sockets.filter { socket in
                let matches = inventory.containers.filter { $0.bindings.contains { $0.matches(socket) } }
                return matches.count == 1 && matches.first?.id == container.id
            }
            guard !mine.isEmpty else { continue }
            claimed.formUnion(mine)
            // Use the published addresses instead of an aggregate forwarder's wildcard.
            let bindings = container.bindings.filter { binding in mine.contains { binding.matches($0) } }
            let ports = PortBinding.collect(bindings.map {
                let host = $0.host.isEmpty ? "0.0.0.0" : $0.host
                return SocketListener(port: $0.port, address: host, isLoopback: PortBinding.isLoopback(host))
            })
            let imageBase = (container.image.split(separator: "/").last.map(String.init) ?? container.image).split(separator: ":").first.map(String.init) ?? container.image
            let aliases = ["redis": "redis-server", "valkey": "valkey-server", "postgresql": "postgres", "mysql": "mysqld", "mariadb": "mariadbd", "mongo": "mongod"]
            let framework = Frameworks.detect(commands: [[aliases[imageBase] ?? imageBase]], dependencies: [])
            servers.append(DevServer(
                rowID: "docker-" + LaunchSpec.digest(container.daemon.socketPath) + "-" + container.id,
                pid: root, start: rootProc.start, kind: .dev, name: container.name, framework: framework,
                ports: ports, cwd: nil, command: "Docker image: " + container.image,
                owner: Owner(id: "docker", name: "Docker", kind: .service, color: 0x1D63ED,
                             evidence: "Published by the local container \"\(container.name)\" (\(container.image))."),
                isOrphaned: false, launchedVia: nil, brewService: nil, dockerContainer: container.id,
                chain: [], childCount: 0, memory: 0, cpuPercent: nil,
                note: "Stop affects only this container. Activity for the shared forwarder is not container activity.",
                launchSpec: nil, groupID: nil, groupName: nil, stopDisabledReason: nil, dockerDaemon: container.daemon
            ))
        }
        let unclaimed = sockets.filter { !claimed.contains($0) }
        if !unclaimed.isEmpty {
            let reason = inventory.error ?? "These ports could not be matched to one local TCP container."
            servers.append(DevServer(
                rowID: "docker-forwarder-\(root)-\(rootProc.start)", pid: root, start: rootProc.start, kind: .tool,
                name: "Docker port forwarder", framework: nil, ports: PortBinding.collect(unclaimed), cwd: nil,
                command: "Shared Docker port forwarding",
                owner: Owner(id: "docker", name: "Docker", kind: .service, color: 0x1D63ED, evidence: reason),
                isOrphaned: false, launchedVia: nil, brewService: nil, dockerContainer: nil,
                chain: [], childCount: 0, memory: includeMemory ? Sys.residentBytes(root) : 0, cpuPercent: nil,
                note: reason, launchSpec: nil, groupID: nil, groupName: nil,
                stopDisabledReason: "This process serves multiple containers. Stop a container in Docker instead."
            ))
        }
        return servers
    }

    // MARK: - Who started it

    func attribute(top: pid_t, envs: [[String: String]]) -> (Owner, Bool) {
        // 1. The live process tree.
        var host: (OwnerDef, pid_t)?
        var cursor = table[top]?.ppid ?? 0
        var reachedLaunchd = false
        for _ in 0..<64 {
            if cursor <= 1 { reachedLaunchd = true; break }
            guard let p = table[cursor] else { reachedLaunchd = true; break }
            if let def = ownerDef(for: cursor) {
                if def.kind == .agent {
                    return (owner(def, "Started by \(def.name), which is still running (pid \(cursor))."), false)
                }
                host = (def, cursor)
                break
            }
            cursor = p.ppid
        }
        let orphaned = host == nil && reachedLaunchd

        // 2. Markers an agent left in the environment. These survive after the
        //    agent exits, which is how orphaned servers still get a name.
        for def in Catalog.owners where def.kind == .agent && !def.envKeys.isEmpty {
            if let key = def.envKeys.first(where: { key in envs.contains { $0[key] != nil } }) {
                let why = orphaned
                    ? "Whatever started it has exited. \(def.name) left \(key) in its environment."
                    : "\(def.name) left \(key) in its environment."
                return (owner(def, why), orphaned)
            }
        }
        if let raw = envs.lazy.compactMap({ $0["AI_AGENT"] }).first, !raw.isEmpty {
            let id = String(raw.split(separator: "_").first ?? Substring(raw))
            let def = Catalog.owners.first { $0.id == id }
            let name = def?.name ?? id.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
            return (Owner(id: def?.id ?? id, name: name, kind: .agent, color: def?.color ?? 0x8E8E93,
                          evidence: "The environment names its agent: AI_AGENT=\(raw)."), orphaned)
        }

        // 3. The terminal or app it is running in.
        if let (def, pid) = host {
            let why = def.kind == .terminal ? "Running in \(def.name) (pid \(pid))." : "Started from \(def.name) (pid \(pid))."
            return (owner(def, why), false)
        }

        // 4. A launchd job, such as `brew services start postgresql`.
        if let label = envs.lazy.compactMap({ $0["XPC_SERVICE_NAME"] }).first,
           label != "0", !label.isEmpty, !label.hasPrefix("application.") {
            let brew = label.hasPrefix("homebrew.mxcl.")
            return (Owner(id: brew ? "brew" : "launchd", name: brew ? "brew services" : "launchd", kind: .service,
                          color: brew ? 0xF9A03F : 0x8E8E93, evidence: "Managed by launchd as \(label)."), false)
        }

        // 5. The app it was originally launched from.
        let bundle = envs.lazy.compactMap { $0["__CFBundleIdentifier"] }.first
        let term = envs.lazy.compactMap { $0["TERM_PROGRAM"] }.first
        if let def = bundle.flatMap(Catalog.owner(forEnvBundleID:)) ?? term.flatMap(Catalog.owner(forTermProgram:)) {
            let why = orphaned
                ? "Whatever started it has exited. It was launched from \(def.name), but no agent left a marker."
                : "Launched from \(def.name)."
            return (owner(def, why), orphaned)
        }

        return (Owner(id: "unknown", name: "Unknown", kind: .unknown, color: 0x8E8E93,
                      evidence: "No agent, app or terminal could be traced."), orphaned)
    }

    private func owner(_ def: OwnerDef, _ evidence: String) -> Owner {
        Owner(id: def.id, name: def.name, kind: def.kind, color: def.color, evidence: evidence)
    }

    // MARK: - What it is

    func classify(_ pid: pid_t, _ d: ProcDetail, _ sockets: [SocketListener]) -> (ServerKind, String?, String?) {
        let exe = d.exe
        let command = d.command
        if (exe.hasPrefix("/System/") && !exe.hasPrefix("/System/Applications/"))
            || exe.hasPrefix("/usr/libexec/") || exe.hasPrefix("/usr/sbin/") || exe.hasPrefix("/sbin/") {
            let name = bundleName(exe) ?? table[pid]?.comm ?? "macOS"
            return (.system, name == "ControlCenter" ? "Control Center" : name, systemNote(name, sockets))
        }
        if let def = ownerDef(for: pid), def.kind == .agent {
            return (.tool, def.name, "The agent itself, not a server it started. Stopping it ends the session.")
        }
        if command.contains("GradleDaemon") || command.contains("org.gradle.launcher.daemon") {
            return (.tool, "Gradle daemon", "Restarts on the next build.")
        }
        if command.contains("KotlinCompileDaemon") || command.contains("kotlin-daemon") || (d.cwd ?? "").hasSuffix("kotlin/daemon") {
            return (.tool, "Kotlin daemon", "Restarts on the next build.")
        }
        // macOS Python and other CLI runtimes can live inside an app/framework.
        // Their server jobs are still development processes, not the owning IDE.
        if isCommandLineRuntime(d) { return (.dev, nil, nil) }
        if isAppBundle(exe) || exe.hasPrefix("/Library/") {
            return (.app, bundleName(exe) ?? table[pid]?.comm, nil)
        }
        return (.dev, nil, nil)
    }

    private func systemNote(_ name: String, _ sockets: [SocketListener]) -> String? {
        if name == "ControlCenter", sockets.contains(where: { $0.port == 5000 || $0.port == 7000 }) {
            return "AirPlay Receiver. To free ports 5000 and 7000, turn it off in System Settings › General › AirDrop & Handoff."
        }
        if name == "rapportd" { return "Continuity: Handoff and Universal Clipboard." }
        return "Part of macOS. launchd restarts it if it stops."
    }

    func bundleName(_ exe: String) -> String? {
        guard let range = exe.range(of: ".app/") else { return nil }
        return (String(exe[..<range.lowerBound]) as NSString).lastPathComponent
    }

    // MARK: - Where it runs

    /// The folder a server serves: its working directory, or the folder passed
    /// to `python -m http.server --directory`.
    func servedDirectory(_ d: ProcDetail) -> String? {
        guard let cwd = d.cwd else { return nil }
        if let i = d.args.firstIndex(where: { $0 == "--directory" || $0 == "-d" }), i + 1 < d.args.count,
           d.args.contains("http.server") {
            let dir = d.args[i + 1]
            return dir.hasPrefix("/") ? dir : (cwd as NSString).appendingPathComponent(dir)
        }
        return cwd
    }

    func projectInfo(_ dir: String?) -> ProjectInfo {
        guard let dir, dir != "/", dir != home else { return ProjectInfo() }
        if let cached = projectCache[dir], Date().timeIntervalSince(cached.at) < 30 { return cached.info }

        var info = ProjectInfo(name: folderName(dir))
        var cursor = dir
        for level in 0..<5 {
            let manifest = (cursor as NSString).appendingPathComponent("package.json")
            if let data = FileManager.default.contents(atPath: manifest),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for key in ["dependencies", "devDependencies"] {
                    if let deps = json[key] as? [String: Any] { info.dependencies.formUnion(deps.keys) }
                }
                // A package.json in the folder itself names the project. One
                // further up belongs to a parent, so the folder name is more specific.
                if level == 0, let name = json["name"] as? String, !name.isEmpty { info.name = name; info.fromManifest = true }
                break
            }
            if level == 0, let name = manifestName(in: cursor) { info.name = name; info.fromManifest = true; break }
            let parent = (cursor as NSString).deletingLastPathComponent
            if parent == cursor || parent == home || parent == "/" { break }
            cursor = parent
        }
        projectCache[dir] = (info, Date())
        return info
    }

    private func manifestName(in dir: String) -> String? {
        let patterns = [
            ("pyproject.toml", #"(?m)^name\s*=\s*["']([^"']+)["']"#),
            ("Cargo.toml", #"(?m)^name\s*=\s*["']([^"']+)["']"#),
            ("go.mod", #"(?m)^module\s+(\S+)"#),
        ]
        for (file, pattern) in patterns {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let line = String(text[match])
            if let value = line.range(of: #"["']([^"']+)["']|\S+$"#, options: .regularExpression) {
                let raw = line[value].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return (raw as NSString).lastPathComponent
            }
        }
        return nil
    }

    private func folderName(_ dir: String) -> String {
        let generic: Set<String> = ["dist", "build", "out", "public", "www", "site", "_site", "render", "static",
                                    "output", "tmp", "temp", "scratchpad", "src", "bin"]
        let base = (dir as NSString).lastPathComponent
        guard generic.contains(base.lowercased()) else { return base }
        let parent = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? base : "\(parent)/\(base)"
    }

    // MARK: - Labels

    func launchedVia(chain: [pid_t], envs: [[String: String]]) -> String? {
        for pid in chain {
            let title = detail(pid).args.first ?? ""
            if CommandPrivacy.isSensitive(title) { return "[redacted command]" }
            if title.hasPrefix("npm exec ") { return "npx " + title.dropFirst("npm exec ".count).trimmingCharacters(in: .whitespaces) }
        }
        if let event = envs.lazy.compactMap({ $0["npm_lifecycle_event"] }).first, event != "npx" {
            if CommandPrivacy.isSensitive(event) { return "[redacted command]" }
            let agent = envs.lazy.compactMap { $0["npm_config_user_agent"] }.first ?? "npm/"
            let pm = String(agent.split(separator: "/").first ?? "npm")
            return pm == "npm" || pm == "bun" ? "\(pm) run \(event)" : "\(pm) \(event)"
        }
        return nil
    }

    func label(for pid: pid_t) -> String {
        let d = detail(pid)
        guard let first = d.args.first else { return table[pid]?.comm ?? "?" }
        if CommandPrivacy.hasSecrets(d.args) { return Frameworks.basename(d.exe) + " [redacted arguments]" }
        if first.contains(" ") { return first.trimmingCharacters(in: .whitespaces) }
        let binary = Frameworks.basename(first)
        if binary == "java", let main = d.args.last(where: { $0.range(of: #"^[a-z]\w*(\.\w+)+$"#, options: .regularExpression) != nil }) {
            return "java " + (main.split(separator: ".").last.map(String.init) ?? main)
        }
        for arg in d.args.dropFirst() where !arg.isEmpty {
            if arg == "-c" { return "\(binary) -c" }
            if !arg.hasPrefix("-") { return "\(binary) \(Frameworks.basename(arg))" }
        }
        return binary
    }

    /// `node serve.js` -> "serve.js"
    func scriptName(_ d: ProcDetail) -> String? {
        let scripts = [".js", ".mjs", ".cjs", ".ts", ".mts", ".py", ".rb", ".php"]
        return d.args.dropFirst().first { arg in !arg.hasPrefix("-") && scripts.contains { arg.hasSuffix($0) } }
            .map { ($0 as NSString).lastPathComponent }
    }

    func abbreviate(_ text: String) -> String {
        text.replacingOccurrences(of: home, with: "~")
    }
}
