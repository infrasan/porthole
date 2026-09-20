import Foundation

enum StopOutcome: Equatable {
    case stopped(forced: Bool)
    /// It had already exited.
    case gone
    case failed(String)
}

enum Stopper {
    /// Ends a server the way Ctrl-C in its terminal would, then escalates:
    /// SIGINT to the job, SIGTERM to anything left after 4 s, SIGKILL after 2 s more.
    /// Docker containers and brew services go through their managers instead:
    /// signaling a Docker forwarder would cut networking for every container,
    /// and launchd would just restart a brew service after a kill.
    static func stop(_ server: DevServer, force: Bool, protectedServices: Set<String> = Preferences.protectedServices) async -> StopOutcome {
        if let reason = refusal(server, protectedServices: protectedServices) { return .failed(reason) }
        if let formula = server.brewService {
            return await stopBrewService(formula)
        }
        if let container = server.dockerContainer {
            return await Docker.action(force ? "kill" : "stop", container: container, daemon: server.dockerDaemon)
        }
        guard Sys.isAlive(server.pid, start: server.start) else { return .gone }

        // Rebuild the job from a fresh process table, so we signal exactly what
        // exists now and never a pid that has since been reused.
        let scanner = Scanner()
        let processes = Sys.processTable()
        guard !processes.isEmpty else { return .failed("Porthole could not read the process list. No signal was sent.") }
        scanner.load(processes)
        let targets: [ProcessIdentity]
        do { targets = try StopPlan.targets(for: server, scanner: scanner) }
        catch { return .failed(error.localizedDescription) }
        let top = targets.first?.pid ?? server.pid
        guard !targets.isEmpty else { return .gone }

        func alive() -> [ProcessIdentity] { targets.filter { Sys.isAlive($0.pid, start: $0.start) } }

        if force {
            if let error = send(SIGKILL, to: alive()) { return .failed(error) }
            return await waitForExit(alive, seconds: 2) ? .stopped(forced: true) : .failed("It is still running after SIGKILL.")
        }

        // Ctrl-C reaches every process in the terminal's foreground job, which
        // is the process group. Do the same, limited to this job.
        let group = scanner.table[top]?.pgid ?? 0
        let job = targets.filter { scanner.table[$0.pid]?.pgid == group }
        let first = job.isEmpty ? [targets[0]] : job
        let deaf = first.filter { scanner.table[$0.pid]?.ignoresInterrupt == true }
        let hearing = first.filter { scanner.table[$0.pid]?.ignoresInterrupt != true }
        if let error = send(SIGINT, to: hearing) ?? send(SIGTERM, to: deaf) { return .failed(error) }
        if await waitForExit(alive, seconds: 4) { return .stopped(forced: false) }

        if let error = send(SIGTERM, to: alive()) { return .failed(error) }
        if await waitForExit(alive, seconds: 2) { return .stopped(forced: false) }

        if let error = send(SIGKILL, to: alive()) { return .failed(error) }
        if await waitForExit(alive, seconds: 2) { return .stopped(forced: true) }
        return .failed("It is still running after SIGKILL.")
    }

    private static func send(_ signal: Int32, to targets: [ProcessIdentity]) -> String? {
        for target in targets where Sys.isAlive(target.pid, start: target.start) {
            if Docker.isForwarder(exe: Sys.executablePath(target.pid) ?? "", comm: "") {
                return "The target is now a shared Docker forwarder. Refresh before trying again."
            }
            if kill(target.pid, signal) != 0, errno != ESRCH {
                return errno == EPERM ? "macOS did not allow Porthole to stop pid \(target.pid)." : String(cString: strerror(errno))
            }
        }
        return nil
    }

    private static func waitForExit(_ alive: () -> [ProcessIdentity], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if alive().isEmpty { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return alive().isEmpty
    }

    /// `kill` would only make launchd restart a brew service, so ask brew.
    private static func stopBrewService(_ formula: String) async -> StopOutcome {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) else {
            return .failed("Homebrew was not found. Run: brew services stop \(formula)")
        }
        return await runBrew(brew, ["services", "stop", formula])
    }

    /// Starts a remembered server through its manager. Returns nil when it has
    /// no manager, meaning the caller should re-run its command instead.
    static func start(_ recent: RecentServer) async -> StopOutcome? {
        if let container = recent.dockerContainer {
            return await Docker.action("start", container: container, daemon: recent.dockerDaemon)
        }
        if let formula = recent.brewService {
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) else {
                return .failed("Homebrew was not found. Run: brew services start \(formula)")
            }
            return await runBrew(brew, ["services", "start", formula])
        }
        return nil
    }

    /// Restarts through the owning manager when there is one. Returns nil for
    /// plain processes, which the caller relaunches itself after stopping them.
    static func restart(_ server: DevServer, protectedServices: Set<String> = Preferences.protectedServices) async -> StopOutcome? {
        if let reason = refusal(server, protectedServices: protectedServices) { return .failed(reason) }
        if let container = server.dockerContainer {
            return await Docker.action("restart", container: container, daemon: server.dockerDaemon)
        }
        if let formula = server.brewService {
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) else {
                return .failed("Homebrew was not found. Run: brew services restart \(formula)")
            }
            return await runBrew(brew, ["services", "restart", formula])
        }
        return nil
    }

    private static func runBrew(_ brew: String, _ arguments: [String]) async -> StopOutcome {
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        let result = await CommandRunner.runAsync(brew, arguments, environment: environment, timeout: 30)
        return result.succeeded ? .stopped(forced: false) : .failed(result.failure)
    }

    static func refusal(_ server: DevServer, protectedServices: Set<String>) -> String? {
        if !server.canStop { return server.stopDisabledReason ?? "macOS manages this process." }
        if protectedServices.contains(server.serviceID) { return "This service is protected. Unprotect it before stopping or restarting it." }
        return nil
    }
}

/// Pure target planning against a refreshed table; every signal still rechecks identity.
enum StopPlan {
    static func targets(for server: DevServer, scanner: Scanner) throws -> [ProcessIdentity] {
        guard server.canStop, server.dockerContainer == nil else { throw LaunchError.message("This process cannot be signaled directly.") }
        guard let current = scanner.table[server.pid], current.start == server.start else { return [] }
        guard current.uid == getuid(), !scanner.selfAncestors.contains(server.pid), server.pid > 1 else {
            throw LaunchError.message("Porthole cannot stop its own ancestry or another user's process.")
        }
        let d = scanner.detail(server.pid)
        guard !Docker.isForwarder(exe: d.exe, comm: current.comm), !scanner.isInteractiveShell(d) else {
            throw LaunchError.message("This process is shared. Stop its server job instead.")
        }
        let top = server.kind == .dev ? scanner.topOfJob(server.pid) : server.pid
        return ([top] + scanner.descendants(of: top, respectingBoundaries: true)).compactMap { pid in
            guard let p = scanner.table[pid], p.uid == getuid(), pid > 1, !scanner.selfAncestors.contains(pid) else { return nil }
            return ProcessIdentity(pid: pid, start: p.start)
        }
    }
}
