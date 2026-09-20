import XCTest
@testable import Porthole

func fixtureServer(pid: pid_t = 900001, start: Int64 = 10, kind: ServerKind = .dev, blocked: Bool = false,
                   orphaned: Bool = false, ports: [PortBinding] = [PortBinding(port: 8765, isExposed: false)],
                   spec: LaunchSpec? = nil, container: String? = nil, daemon: DockerDaemon? = nil,
                   ancestors: [ProcessIdentity] = []) -> DevServer {
    DevServer(rowID: container.map { "docker-" + $0 }, pid: pid, start: start, kind: kind, name: "Fixture",
              framework: Framework(name: "HTTP fixture", color: 0, speaksHTTP: true), ports: ports, cwd: "/tmp/fixture",
              command: spec?.display ?? "fixture", owner: Owner(id: "fixture", name: "Fixture", kind: .unknown, color: 0, evidence: "Test"),
              isOrphaned: orphaned, launchedVia: nil, brewService: nil, dockerContainer: container, chain: [], childCount: 0,
              memory: 0, cpuPercent: nil, note: nil, launchSpec: spec, groupID: "/tmp/fixture", groupName: "Fixture",
              stopDisabledReason: blocked ? "Protected fixture" : nil, dockerDaemon: daemon, launchAncestors: ancestors)
}
func temporaryDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
}
func process(_ pid: pid_t, parent: pid_t = 1, start: Int64 = 10, name: String = "fixture") -> KProc {
    KProc(pid: pid, ppid: parent, pgid: pid, uid: getuid(), start: start, comm: name, ignoresInterrupt: false)
}

final class RegressionTests: XCTestCase {
    func testDisabledStopAndRestartAreRejectedBeforeAnyProcessLookup() async {
        for force in [false, true] {
            let outcome = await Stopper.stop(fixtureServer(blocked: true), force: force, protectedServices: [])
            XCTAssertEqual(outcome, .failed("Protected fixture"))
        }
        let restart = await Stopper.restart(fixtureServer(blocked: true), protectedServices: [])
        XCTAssertEqual(restart, .failed("Protected fixture"))
    }
    func testUserProtectionAlsoBlocksContainerManager() async {
        let server = fixtureServer(container: "abcdef123456", daemon: DockerDaemon(socketPath: "/var/run/docker.sock"))
        let stopped = await Stopper.stop(server, force: true, protectedServices: [server.serviceID])
        let restarted = await Stopper.restart(server, protectedServices: [server.serviceID])
        XCTAssertEqual(stopped, .failed("This service is protected. Unprotect it before stopping or restarting it."))
        XCTAssertEqual(restarted, stopped)
    }
    func testSystemRowsCannotBeStoppedThroughContextMenuOrCLI() {
        XCTAssertFalse(fixtureServer(kind: .system).canStop)
    }
    func testRefreshedPIDReplacementIsNotTargeted() throws {
        let scanner = Scanner(); scanner.load([900001: process(900001, start: 99)])
        XCTAssertEqual(try StopPlan.targets(for: fixtureServer(), scanner: scanner), [])
    }
    func testProtectedDescendantSubtreesArePruned() throws {
        let scanner = Scanner()
        scanner.load([
            900001: process(900001), 900002: process(900002, parent: 900001),
            900003: process(900003, parent: 900001, name: "zsh"), 900004: process(900004, parent: 900003),
            900005: process(900005, parent: 900001, name: "codex"), 900006: process(900006, parent: 900005),
            900007: process(900007, parent: 900001, name: "vpnkit"), 900008: process(900008, parent: 900007)
        ])
        scanner.detailProvider = { pid in
            let name = [900003: "zsh", 900005: "codex", 900007: "vpnkit"][pid] ?? "node"
            return ProcDetail(exe: "/opt/homebrew/bin/" + name, args: [name], env: [:], cwd: "/tmp")
        }
        XCTAssertEqual(Set(try StopPlan.targets(for: fixtureServer(), scanner: scanner).map(\.pid)), [900001, 900002])
    }
    func testSharedParentAndSiblingAreNotStopped() throws {
        let scanner = Scanner()
        scanner.load([900000: process(900000), 900001: process(900001, parent: 900000), 900002: process(900002, parent: 900000)])
        scanner.detailProvider = { _ in ProcDetail(exe: "/opt/node", args: ["node"], env: [:], cwd: "/tmp") }
        XCTAssertEqual(try StopPlan.targets(for: fixtureServer(), scanner: scanner).map(\.pid), [900001])
    }
    func testForwarderRootCannotBeSignaledEvenWithIncorrectRowCapability() {
        let scanner = Scanner(); scanner.load([900001: process(900001, name: "vpnkit")])
        scanner.detailProvider = { _ in ProcDetail(exe: "/tmp/vpnkit", args: ["vpnkit"], env: [:], cwd: "/tmp") }
        XCTAssertThrowsError(try StopPlan.targets(for: fixtureServer(), scanner: scanner))
    }
    func testCaptureKeepsArgumentBoundariesAndRejectsRenamedTitles() {
        let detail = ProcDetail(exe: "/usr/bin/printf", args: ["/usr/bin/printf", "%s", "two words", "", "$(literal)"], env: [:], cwd: "/tmp")
        XCTAssertEqual(LaunchSpec.capture(detail)?.arguments, ["%s", "two words", "", "$(literal)"])
        XCTAssertNil(LaunchSpec.capture(ProcDetail(exe: "/usr/local/bin/node", args: ["npm run dev", ""], env: [:], cwd: "/tmp")))
    }
    func testDirectLaunchDoesNotExpandShellSyntax() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("should-not-exist")
        let literal = "$(/usr/bin/touch \(marker.path))"
        let spec = LaunchSpec(executable: "/usr/bin/printf", arguments: ["%s\n", "two words", "", literal, "semi;colon"], directory: directory.path)
        let handle = try Launcher.launch(spec, logDirectory: directory.appendingPathComponent("logs"))
        handle.process.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: handle.log), "two words\n\n\(literal)\nsemi;colon\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testWorkingDirectoryIsSeparateFromServedDirectory() {
        let detail = ProcDetail(exe: "/usr/bin/python3", args: ["/usr/bin/python3", "-m", "http.server", "--directory", "site"], env: [:], cwd: "/tmp/project")
        XCTAssertEqual(Scanner().servedDirectory(detail), "/tmp/project/site")
        XCTAssertEqual(LaunchSpec.capture(detail)?.directory, "/tmp/project")
    }
    func testSecretsAreRedactedAndCannotBecomePersistedRecipes() throws {
        for args in [["--token", "private-value"], ["--api-key=private-value"], ["https://person:private-value@example.test"], ["API_KEY=private-value run"]] {
            XCTAssertTrue(CommandPrivacy.hasSecrets(args))
            XCTAssertFalse(CommandPrivacy.display(args).contains("private-value"))
        }
        let history = History(persistent: false)
        history.add(fixtureServer(spec: LaunchSpec(executable: "/bin/echo", arguments: ["--password=private-value"], directory: "/tmp")))
        XCTAssertNil(history.recents.first?.launchSpec)
    }
    func testLegacyCommandIsMetadataNotExecutableCode() throws {
        let json: [String: Any] = ["id": UUID().uuidString, "name": "old", "ports": [8000], "command": "echo $(touch /tmp/no)", "speaksHTTP": true, "stoppedAt": 0]
        let recent = try JSONDecoder().decode(RecentServer.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(recent.canStart); XCTAssertNil(recent.launchSpec)
    }
    func testPreviewHistoryNeverCreatesUserState() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("not-created/history.json")
        let history = History(file: path, persistent: false)
        history.add(fixtureServer())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }
    func testSavedRecipeAndFailedLaunchSurviveReloadWithPrivatePermissions() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state/history.json")
        let history = History(file: path)
        var recent = RecentServer(server: fixtureServer(spec: LaunchSpec(executable: "/bin/echo", arguments: ["ok"], directory: "/tmp")))
        recent.saved = true; recent.failure = "Fixture failure"; recent.logPath = "/tmp/example.log"
        history.upsert(recent)
        XCTAssertNil(history.error)
        let data = try Data(contentsOf: path)
        _ = try JSONDecoder().decode([RecentServer].self, from: data)
        let restored = History(file: path)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.recents, [recent])
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testUnreadableHistoryIsNotOverwritten() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json"); try Data("broken".utf8).write(to: file)
        let history = History(file: file); history.add(fixtureServer())
        XCTAssertNotNil(history.error); XCTAssertEqual(try String(contentsOf: file), "broken")
    }
    func testStructuredDockerBindingsIgnoreUDPAndPreserveHostAddresses() throws {
        let json = #"{"id":"abcdef123456","name":"/cache","image":"redis:7","ports":{"8000/tcp":[{"HostIp":"127.0.0.1","HostPort":"8000"}],"8001/tcp":[{"HostIp":"::1","HostPort":"8001"}],"9000/udp":[{"HostIp":"0.0.0.0","HostPort":"9000"}]}}"#
        let containers = try Docker.parse(json, daemon: DockerDaemon(socketPath: "/var/run/docker.sock"))
        XCTAssertEqual(containers[0].bindings.map(\.port), [8000, 8001])
        XCTAssertEqual(containers[0].bindings.map(\.host), ["127.0.0.1", "::1"])
        XCTAssertFalse(containers[0].bindings[0].matches(SocketListener(port: 8000, address: "127.0.0.2", isLoopback: true)))
    }
    func testAmbiguousContainerOwnershipLeavesProtectedForwarder() {
        let daemon = DockerDaemon(socketPath: "/var/run/docker.sock")
        let scanner = Scanner(); scanner.load([900001: process(900001, name: "vpnkit")])
        scanner.detailProvider = { _ in ProcDetail(exe: "/tmp/vpnkit", args: ["vpnkit"], env: [:], cwd: nil) }
        scanner.dockerInventoryProvider = { _, _ in
            DockerInventory(containers: ["abcdef123456", "abcdef123457"].enumerated().map { i, id in
                DockerContainer(id: id, name: id, image: "redis:7", bindings: [DockerBinding(host: "127.0.0.\(i+1)", port: 8000, containerPort: 6379, transport: "tcp")], daemon: daemon)
            })
        }
        let rows = scanner.makeDockerServers(root: 900001, members: [900001], listening: [900001: [SocketListener(port: 8000, address: "0.0.0.0", isLoopback: false)]], includeMemory: false)
        XCTAssertEqual(rows.count, 1); XCTAssertFalse(rows[0].canStop); XCTAssertNil(rows[0].dockerContainer)
    }
    func testDockerRemoteHostsAreRejectedAndOverridesRemoved() {
        let result = Docker.run(["ps"], daemon: DockerDaemon(socketPath: "tcp://example.invalid:2375"))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(Docker.environment(["DOCKER_HOST": "remote", "DOCKER_CONTEXT": "remote", "DOCKER_TLS_VERIFY": "1", "PATH": "/bin"]), ["PATH": "/bin"])
    }
    func testDockerRowsUseLocalDaemonAndDetectRedisWithoutDemoOverride() {
        let daemon = DockerDaemon(socketPath: "/var/run/docker.sock")
        let scanner = Scanner(); scanner.load([900001: process(900001, name: "vpnkit")])
        scanner.detailProvider = { _ in ProcDetail(exe: "/tmp/vpnkit", args: ["vpnkit"], env: [:], cwd: nil) }
        scanner.dockerInventoryProvider = { _, _ in DockerInventory(containers: [DockerContainer(id: "abcdef123456", name: "cache", image: "redis:7", bindings: [DockerBinding(host: "127.0.0.1", port: 6379, containerPort: 6379, transport: "tcp")], daemon: daemon)]) }
        let rows = scanner.makeDockerServers(root: 900001, members: [900001], listening: [900001: [SocketListener(port: 6379, address: "0.0.0.0", isLoopback: false)]], includeMemory: false)
        XCTAssertEqual(rows[0].framework?.name, "Redis"); XCTAssertFalse(rows[0].canOpen)
        XCTAssertFalse(rows[0].isExposed); XCTAssertEqual(rows[0].dockerDaemon, daemon)
    }
    func testLoopbackBindingSelectionAndIPv6URL() {
        XCTAssertEqual(PortBinding(port: 80, isExposed: true, addresses: ["::", "0.0.0.0"]).loopbackHosts, ["127.0.0.1", "::1"])
        let v6 = PortBinding(port: 8000, isExposed: false, addresses: ["::1"])
        XCTAssertEqual(v6.url(scheme: .http)?.absoluteString, "http://[::1]:8000")
        XCTAssertTrue(PortBinding(port: 8000, isExposed: true, addresses: ["192.0.2.1"]).loopbackHosts.isEmpty)
        XCTAssertFalse(PortBinding.isLoopback("127.evil.example"))
    }
    func testOrphanTransitionNotifiesExactlyOnceForSameIdentity() {
        let original = fixtureServer(), orphan = fixtureServer(orphaned: true)
        XCTAssertEqual(LifecycleEvent.changes(from: [original], to: [orphan]).map(\.kind), ["orphaned"])
        XCTAssertTrue(LifecycleEvent.changes(from: [orphan], to: [orphan]).isEmpty)
        XCTAssertTrue(LifecycleEvent.changes(from: [original], to: [], intentionallyStopped: [original.id]).isEmpty)
    }
    func testStartupRequiresProcessOwnershipNotJustPort() {
        let identity = ProcessIdentity(pid: 900009, start: 22)
        let recent = RecentServer(server: fixtureServer())
        XCTAssertFalse(LaunchReadiness.matches(fixtureServer(), recent: recent, identity: identity))
        XCTAssertTrue(LaunchReadiness.matches(fixtureServer(ancestors: [identity]), recent: recent, identity: identity))
        XCTAssertFalse(LaunchReadiness.matches(fixtureServer(ancestors: [ProcessIdentity(pid: 900009, start: 23)]), recent: recent, identity: identity))
    }
    @MainActor func testPreviewStoreIsInertAndRecycledPortLosesHealth() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state/history.json")
        let store = Store(startTimer: false, history: History(file: file))
        let original = fixtureServer()
        store.show(ScanResult(servers: [original])); store.preview(health: [8765: .up(ms: 1)], recents: [])
        XCTAssertTrue(store.healthFor(original).isUp)
        let replacement = fixtureServer(start: 99)
        store.show(ScanResult(servers: [replacement]))
        XCTAssertEqual(store.healthFor(replacement), .unknown)
        store.stop(replacement); store.pin(replacement); store.isPanelOpen = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertNil(store.pinned)
    }
    @MainActor func testFailedScanPreservesLastValidInventory() {
        let store = Store(startTimer: false)
        store.show(ScanResult(servers: [fixtureServer()]))
        store.show(ScanResult(error: "Fixture permission error"))
        XCTAssertEqual(store.servers.count, 1); XCTAssertNotNil(store.scanError)
    }
    func testCommandRunnerDrainsLargeStdoutAndStderr() {
        let result = CommandRunner.run("/usr/bin/python3", ["-c", "import sys; sys.stdout.write('x'*300000); sys.stderr.write('y'*300000)"], timeout: 5)
        XCTAssertTrue(result.succeeded, result.failure)
        XCTAssertEqual(result.output.count, 300000); XCTAssertEqual(result.error.count, 300000)
    }
    func testCommandRunnerTimeoutReapsAnUncooperativeChild() {
        let began = Date()
        let result = CommandRunner.run("/usr/bin/python3", ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"], timeout: 0.4)
        XCTAssertTrue(result.timedOut); XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }
    func testCommandRunnerRetainedOutputIsBounded() {
        let result = CommandRunner.run("/usr/bin/python3", ["-c", "print('x'*200000)"], timeout: 5, outputLimit: 1000)
        XCTAssertTrue(result.truncated); XCTAssertEqual(result.output.utf8.count, 1000); XCTAssertFalse(result.succeeded)
    }
    func testCommandRunnerCancellationStopsChild() async {
        let task = Task { await CommandRunner.runAsync("/bin/sleep", ["30"], timeout: 30) }
        try? await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled); XCTAssertFalse(result.succeeded)
    }
}
