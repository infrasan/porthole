import XCTest
import Darwin
@testable import Porthole

final class WorkflowTests: XCTestCase {
    @MainActor func testReviewedRecipeEnablesRestartAndSurvivesFreshCapture() {
        let history = History(persistent: false)
        let server = fixtureServer()
        let reviewed = LaunchSpec(executable: "/usr/bin/printf", arguments: ["reviewed"], directory: "/tmp")
        var recent = RecentServer(server: server)
        recent.saved = true; recent.launchSpec = reviewed
        history.upsert(recent)
        let store = Store(startTimer: false, history: history)
        XCTAssertFalse(server.canRestart)
        XCTAssertTrue(store.canRestart(server))
        let captured = LaunchSpec(executable: "/usr/bin/printf", arguments: ["captured"], directory: "/tmp")
        XCTAssertEqual(history.add(fixtureServer(spec: captured)).launchSpec, reviewed)
    }

    func testLiveStopLeavesSiblingProcessRunning() async throws {
        let sibling = Process(), target = Process()
        for child in [sibling, target] {
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["30"]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run()
        }
        defer {
            for child in [target, sibling] where child.isRunning { child.terminate(); child.waitUntilExit() }
        }
        let start = try XCTUnwrap(Sys.startTime(target.processIdentifier))
        let server = fixtureServer(pid: target.processIdentifier, start: start)
        let outcome = await Stopper.stop(server, force: false, protectedServices: [])
        XCTAssertEqual(outcome, .stopped(forced: false))
        XCTAssertFalse(target.isRunning)
        XCTAssertTrue(sibling.isRunning)
    }

    func testForceStopCannotAffectReusedIdentity() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let start = try XCTUnwrap(Sys.startTime(child.processIdentifier))
        let outcome = await Stopper.stop(fixtureServer(pid: child.processIdentifier, start: start - 1), force: true, protectedServices: [])
        XCTAssertEqual(outcome, .gone)
        XCTAssertTrue(child.isRunning)
    }

    @MainActor func testFailedLaunchKeepsRecipeErrorAndLog() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = History(file: directory.appendingPathComponent("state/recents.json"))
        let spec = LaunchSpec(executable: "/usr/bin/false", arguments: [], directory: directory.path)
        let recent = history.add(fixtureServer(ports: [PortBinding(port: 65413, isExposed: false)], spec: spec))
        let store = Store(history: history, defaults: UserDefaults(suiteName: "PortholeTests-" + UUID().uuidString),
                          stateDirectory: directory.appendingPathComponent("state"), launchLogDirectory: directory.appendingPathComponent("logs"))
        defer { store.shutdown() }
        store.start(recent)
        let deadline = Date().addingTimeInterval(8)
        while store.starting.contains(recent.id) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(store.starting.contains(recent.id))
        XCTAssertTrue(store.recentErrors[recent.id]?.contains("command exited") == true)
        let persisted = try XCTUnwrap(History(file: directory.appendingPathComponent("state/recents.json")).recents.first)
        XCTAssertEqual(persisted.launchSpec, spec)
        XCTAssertNotNil(persisted.failure)
        XCTAssertNotNil(persisted.logPath)
    }

    func testProcessChainAndLauncherLabelsDoNotLeakCredentialArguments() {
        let scanner = Scanner(); scanner.load([900001: process(900001)])
        scanner.detailProvider = { _ in ProcDetail(exe: "/opt/node", args: ["npm exec server --token private-value"], env: [:], cwd: "/tmp") }
        XCTAssertFalse(scanner.label(for: 900001).contains("private-value"))
        XCTAssertFalse(scanner.launchedVia(chain: [900001], envs: [])?.contains("private-value") == true)
    }

    @MainActor func testLiveRecipeStartRestartAndStop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        close(fd)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let history = History(file: directory.appendingPathComponent("state/recents.json"))
        let spec = LaunchSpec(executable: "/usr/bin/python3", arguments: ["-m", "http.server", String(port), "--bind", "127.0.0.1"], directory: directory.path)
        var recent = RecentServer(server: fixtureServer(ports: [PortBinding(port: port, isExposed: false)], spec: spec)); recent.saved = true
        history.upsert(recent)
        let store = Store(history: history, defaults: UserDefaults(suiteName: "PortholeTests-" + UUID().uuidString),
                          stateDirectory: directory.appendingPathComponent("state"), launchLogDirectory: directory.appendingPathComponent("logs"))
        defer {
            store.shutdown()
            // Even a failed assertion cleans only this fixture's listener.
            let remaining = Scanner().scan()
            for row in remaining.servers + remaining.others where row.ports.contains(where: { $0.port == port }) {
                if let cwd = row.cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(), Sys.isAlive(row.pid, start: row.start) {
                    kill(row.pid, SIGTERM)
                }
            }
        }
        func waitForLaunch() async throws {
            let deadline = Date().addingTimeInterval(12)
            while store.starting.contains(recent.id) && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            if store.starting.contains(recent.id) {
                print("Launch status:", store.launchStatus[recent.id] ?? "none", "error:", store.actionError ?? "none")
                if let path = store.recentLogs[recent.id] { print("Fixture output:", (try? String(contentsOf: path)) ?? "unreadable") }
                print("Scan rows:", (store.servers + store.others).filter { $0.ports.contains { $0.port == port } }.map { ($0.pid, $0.start, $0.kind, $0.launchAncestors) })
            }
            XCTAssertFalse(store.starting.contains(recent.id))
            XCTAssertNil(store.recentErrors[recent.id])
        }
        store.start(recent); try await waitForLaunch()
        let first = try XCTUnwrap(store.servers.first { $0.primaryPort == port })
        XCTAssertEqual(history.recents.first?.serviceID, first.serviceID)
        XCTAssertTrue(store.canRestart(first))
        store.restart(first); try await waitForLaunch()
        let second = try XCTUnwrap(store.servers.first { $0.primaryPort == port && $0.identity != first.identity })
        XCTAssertFalse(Sys.isAlive(first.pid, start: first.start))
        let outcome = await Stopper.stop(second, force: false, protectedServices: [])
        XCTAssertEqual(outcome, .stopped(forced: false))
    }

    func testCPUAccountingSurvivesBusyChildExit() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "while True: pass"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        try await Task.sleep(nanoseconds: 200_000_000)
        let scanner = Scanner()
        XCTAssertNil(scanner.cpuPercent(id: "fixture", tree: [child.processIdentifier]))
        child.terminate(); child.waitUntilExit()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(scanner.cpuPercent(id: "fixture", tree: []), 0)
    }

    func testPackagedAppUsesStandardPreferencesRatherThanItsOwnSuite() {
        XCTAssertTrue(Preferences.defaults(for: Preferences.domain) === UserDefaults.standard)
        XCTAssertFalse(Preferences.defaults(for: nil) === UserDefaults.standard)
    }

    func testBundledPythonIsADevServerWithoutUnprotectingEditors() {
        let scanner = Scanner(); scanner.load([900001: process(900001)])
        let python = ProcDetail(exe: "/Applications/Xcode.app/Contents/SharedFrameworks/Python3.framework/Resources/Python.app/Contents/MacOS/Python", args: ["python3", "-m", "http.server"], env: [:], cwd: "/tmp")
        scanner.detailProvider = { _ in python }
        XCTAssertEqual(scanner.classify(900001, python, []).0, .dev)
        XCTAssertFalse(scanner.isBoundary(900001))
        scanner.detailProvider = { _ in ProcDetail(exe: "/Applications/Example.app/Contents/MacOS/Example", args: ["Example"], env: [:], cwd: "/tmp") }
        XCTAssertTrue(scanner.isBoundary(900001))
    }

    func testStartupWaitsForEveryExpectedPort() {
        let server = fixtureServer()
        var recent = RecentServer(server: server); recent.ports = [8765, 8766]
        XCTAssertFalse(LaunchReadiness.matches(server, recent: recent, identity: server.identity))
        var ready = server; ready.ports.append(PortBinding(port: 8766, isExposed: false))
        XCTAssertTrue(LaunchReadiness.matches(ready, recent: recent, identity: ready.identity))
    }

    func testDiagnosticsRedactCommandsWithoutCapturingEnvironments() throws {
        let detail = ProcDetail(exe: "/bin/echo", args: ["echo", "--token", "private-value"], env: [:], cwd: "/tmp")
        let json = try Diagnostics.data(ScanResult(servers: [fixtureServer(spec: nil)]))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("environment"))
        XCTAssertFalse(detail.command.contains("private-value"))
    }
}
