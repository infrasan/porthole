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
    static func stop(_ server: DevServer, force: Bool) async -> StopOutcome {
        if let formula = server.brewService, !force {
            return await stopBrewService(formula)
        }
        guard Sys.isAlive(server.pid, start: server.start) else { return .gone }

        // Rebuild the job from a fresh process table, so we signal exactly what
        // exists now and never a pid that has since been reused.
        let scanner = Scanner()
        scanner.load(Sys.processTable())
        let top = server.kind == .dev ? scanner.topOfJob(server.pid) : server.pid
        let targets: [(pid: pid_t, start: Int64)] = ([top] + scanner.descendants(of: top)).compactMap { pid in
            guard pid > 1, pid != getpid(), let p = scanner.table[pid] else { return nil }
            return (pid, p.start)
        }
        guard !targets.isEmpty else { return .gone }

        func alive() -> [(pid: pid_t, start: Int64)] { targets.filter { Sys.isAlive($0.pid, start: $0.start) } }

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

        _ = send(SIGTERM, to: alive())
        if await waitForExit(alive, seconds: 2) { return .stopped(forced: false) }

        _ = send(SIGKILL, to: alive())
        if await waitForExit(alive, seconds: 2) { return .stopped(forced: true) }
        return .failed("It is still running after SIGKILL.")
    }

    private static func send(_ signal: Int32, to targets: [(pid: pid_t, start: Int64)]) -> String? {
        for target in targets where Sys.isAlive(target.pid, start: target.start) {
            if kill(target.pid, signal) != 0, errno != ESRCH {
                return errno == EPERM ? "macOS did not allow Porthole to stop pid \(target.pid)." : String(cString: strerror(errno))
            }
        }
        return nil
    }

    private static func waitForExit(_ alive: () -> [(pid: pid_t, start: Int64)], seconds: Double) async -> Bool {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["services", "stop", formula]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { p in
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: p.terminationStatus == 0
                    ? .stopped(forced: false)
                    : .failed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }
}
