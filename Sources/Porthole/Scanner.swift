import Foundation

/// Command line, environment and working directory of one process.
struct ProcDetail {
    let exe: String
    let args: [String]
    let env: [String: String]
    let cwd: String?

    /// Lowercased names this process goes by: the binary, a renamed title
    /// ("npm run dev" counts as npm) and the script it runs.
    var names: Set<String> {
        var out: Set<String> = []
        if !exe.isEmpty { out.insert(Frameworks.basename(exe)) }
        if let first = args.first {
            let word = first.split(separator: " ").first.map(String.init) ?? first
            out.insert(Frameworks.basename(word.hasPrefix("-") ? String(word.dropFirst()) : word))
        }
        if args.count > 1, !args[1].hasPrefix("-") { out.insert(Frameworks.basename(args[1])) }
        return out
    }

    var command: String { args.filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Finds listening sockets and turns them into servers. Not thread-safe:
/// each instance is only ever used from one serial queue.
final class Scanner: @unchecked Sendable {
    let me = getuid()
    let selfPID = getpid()
    let home = NSHomeDirectory()

    var table: [pid_t: KProc] = [:]
    var children: [pid_t: [pid_t]] = [:]
    var selfAncestors: Set<pid_t> = []

    private var detailCache: [String: ProcDetail] = [:]
    var projectCache: [String: (info: ProjectInfo, at: Date)] = [:]
    private var argBuffer = [UInt8](repeating: 0, count: Sys.argMax())

    /// Memory is only measured while someone is looking; it changes on every
    /// scan and would otherwise force a redraw each time.
    func scan(includeMemory: Bool = true) -> ScanResult {
        let began = Date()
        load(Sys.processTable())

        var listening: [pid_t: [SocketListener]] = [:]
        for p in table.values where p.uid == me && p.pid != selfPID {
            let sockets = Sys.listeners(p.pid)
            if !sockets.isEmpty { listening[p.pid] = sockets }
        }

        // A server that spawns listening workers (Firebase emulators, Next.js)
        // shows up once, under its topmost listening process.
        var members: [pid_t: [pid_t]] = [:]
        for pid in listening.keys {
            var root = pid
            var cursor = table[pid]?.ppid ?? 0
            while !isBoundary(cursor) {
                if listening[cursor] != nil { root = cursor }
                cursor = table[cursor]?.ppid ?? 0
            }
            members[root, default: []].append(pid)
        }

        var result = ScanResult()
        for (root, group) in members {
            guard let server = makeServer(root: root, members: group, listening: listening, includeMemory: includeMemory) else { continue }
            if server.kind == .dev { result.servers.append(server) } else { result.others.append(server) }
        }
        result.servers.sort { ($0.primaryPort, $0.pid) < ($1.primaryPort, $1.pid) }
        result.others.sort { ($0.primaryPort, $0.pid) < ($1.primaryPort, $1.pid) }

        let live = Set(table.values.map { "\($0.pid)-\($0.start)" })
        detailCache = detailCache.filter { live.contains($0.key) }
        result.duration = Date().timeIntervalSince(began)
        return result
    }

    func load(_ newTable: [pid_t: KProc]) {
        table = newTable
        children = [:]
        for p in table.values { children[p.ppid, default: []].append(p.pid) }
        selfAncestors = []
        var cursor = selfPID
        while cursor > 1, let p = table[cursor], !selfAncestors.contains(cursor) {
            selfAncestors.insert(cursor)
            cursor = p.ppid
        }
    }

    func detail(_ pid: pid_t) -> ProcDetail {
        guard let p = table[pid] else { return ProcDetail(exe: "", args: [], env: [:], cwd: nil) }
        let key = "\(pid)-\(p.start)"
        if let cached = detailCache[key] { return cached }

        let mine = p.uid == me
        let cmd = mine ? Sys.commandLine(pid, buffer: &argBuffer, keepEnv: { Catalog.envKeysOfInterest.contains($0) }) : nil
        let d = ProcDetail(
            exe: Sys.executablePath(pid) ?? "",
            args: cmd?.args ?? [p.comm],
            env: cmd?.env ?? [:],
            cwd: mine ? Sys.cwd(pid) : nil
        )
        // Young processes may still rename themselves (process.title), so only
        // cache once they have settled.
        let age = Date().timeIntervalSince1970 - TimeInterval(p.start) / 1_000_000
        if age > 5 { detailCache[key] = d }
        return d
    }

    // MARK: - Process tree

    /// Processes Porthole never walks through or signals: launchd, other
    /// users' processes, apps, agents, terminals, interactive shells and
    /// Porthole's own ancestors.
    func isBoundary(_ pid: pid_t) -> Bool {
        guard pid > 1, let p = table[pid], p.uid == me, !selfAncestors.contains(pid) else { return true }
        let d = detail(pid)
        if ownerDef(for: pid) != nil || isAppBundle(d.exe) { return true }
        return isInteractiveShell(d)
    }

    func isInteractiveShell(_ d: ProcDetail) -> Bool {
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "pwsh"]
        guard !d.names.isDisjoint(with: shells) else { return false }
        // `sh -c "vite"` exists only to run one command, so it is not a boundary.
        let runsCommand = d.args.dropFirst().contains { $0.range(of: #"^-[a-zA-Z]*c[a-zA-Z]*$"#, options: .regularExpression) != nil }
        return !runsCommand
    }

    func isAppBundle(_ exe: String) -> Bool {
        exe.hasPrefix("/Applications/") || exe.hasPrefix("/System/") || exe.hasPrefix(home + "/Applications/")
            || (exe.contains("/Library/Application Support/") && exe.contains(".app/Contents/"))
    }

    func ownerDef(for pid: pid_t) -> OwnerDef? {
        guard let p = table[pid] else { return nil }
        let d = detail(pid)
        var names = d.names
        names.insert(p.comm.lowercased())
        let paths = [d.exe] + d.args.prefix(2)
        return Catalog.owners.first { def in
            def.executables.contains { names.contains($0.lowercased()) }
                || def.paths.contains { fragment in paths.contains { $0.contains(fragment) } }
        }
    }

    /// Walks up from the listening process through launchers that exist only
    /// for it (npm, `sh -c`, `npx`, a CLI that forked the real server) so Stop
    /// ends the whole job, the way Ctrl-C would. Stops at anything shared.
    func topOfJob(_ root: pid_t) -> pid_t {
        var top = root
        while let parent = table[top]?.ppid, !isBoundary(parent), (children[parent] ?? []).count == 1 {
            top = parent
        }
        return top
    }

    func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var stack = children[pid] ?? []
        while let next = stack.popLast() {
            guard next != selfPID, !selfAncestors.contains(next), !out.contains(next) else { continue }
            out.append(next)
            stack.append(contentsOf: children[next] ?? [])
        }
        return out
    }

    /// `top`, then each process down to `root`.
    func path(from top: pid_t, to root: pid_t) -> [pid_t] {
        var chain: [pid_t] = [root]
        var cursor = root
        while cursor != top, let parent = table[cursor]?.ppid, parent > 1 {
            chain.insert(parent, at: 0)
            cursor = parent
        }
        return chain
    }
}
