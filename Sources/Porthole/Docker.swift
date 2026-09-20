import Foundation

struct DockerDaemon: Codable, Hashable, Sendable {
    let socketPath: String
    var isAllowed: Bool { Self.allowedPaths.contains(socketPath) }
    static var allowedPaths: [String] {
        let home = NSHomeDirectory()
        return [home + "/.docker/run/docker.sock", home + "/.orbstack/run/docker.sock", "/var/run/docker.sock"]
    }
    static func resolve(executable: String, comm: String) -> DockerDaemon? {
        let orbital = (executable + comm).lowercased().contains("orbstack")
        let paths = orbital ? [NSHomeDirectory() + "/.orbstack/run/docker.sock"] : [NSHomeDirectory() + "/.docker/run/docker.sock", "/var/run/docker.sock"]
        return paths.first(where: isSocket).map { DockerDaemon(socketPath: $0) }
    }
    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }
}

struct DockerBinding: Codable, Hashable {
    let host: String
    let port: Int
    let containerPort: Int
    let transport: String
    func matches(_ socket: SocketListener) -> Bool {
        guard transport == "tcp", socket.port == port else { return false }
        let host = host.isEmpty ? "0.0.0.0" : host
        if host == socket.address { return true }
        // Some forwarders aggregate distinct bind addresses into one wildcard listener.
        return socket.address == "0.0.0.0" && !host.contains(":") || socket.address == "::" && host.contains(":")
    }
}

struct DockerContainer: Equatable {
    let id: String
    let name: String
    let image: String
    let bindings: [DockerBinding]
    let daemon: DockerDaemon
}

struct DockerInventory {
    var containers: [DockerContainer] = []
    var error: String? = nil
}

enum Docker {
    private static let forwarderNames: Set<String> = ["com.docker.vpnkit", "vpnkit", "vpnkit-bridge", "docker-proxy", "docker"]
    static func isForwarder(exe: String, comm: String) -> Bool {
        forwarderNames.contains(comm.lowercased()) || forwarderNames.contains(Frameworks.basename(exe).lowercased()) || exe.lowercased().contains("com.docker")
            || exe.lowercased().contains("/orbstack.app/") || exe.lowercased().contains("vpnkit")
    }
    static var cliPath: String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", NSHomeDirectory() + "/.docker/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func environment(_ source: [String: String]) -> [String: String] {
        source.filter { !$0.key.hasPrefix("DOCKER_") }
    }
    static func run(_ arguments: [String], daemon: DockerDaemon, timeout: TimeInterval = 4) -> CommandResult {
        guard daemon.isAllowed, DockerDaemon.isSocket(daemon.socketPath) else {
            return CommandResult(status: -1, output: "", error: "The local Docker socket is unavailable. Open Docker Desktop or OrbStack and try again.", timedOut: false, truncated: false)
        }
        guard let cli = cliPath else {
            return CommandResult(status: -1, output: "", error: "Docker's command-line tool was not found.", timedOut: false, truncated: false)
        }
        return CommandRunner.run(cli, ["--host", "unix://" + daemon.socketPath] + arguments,
                                 environment: environment(ProcessInfo.processInfo.environment), timeout: timeout)
    }
    static func containers(daemon: DockerDaemon) -> DockerInventory {
        let listed = run(["ps", "--quiet", "--no-trunc"], daemon: daemon)
        guard listed.succeeded else { return DockerInventory(error: listed.failure) }
        let ids = listed.output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !ids.isEmpty else { return DockerInventory() }
        guard ids.allSatisfy(validID) else { return DockerInventory(error: "Docker returned an unreadable container list.") }
        // Explicit fields avoid reading container environments and credentials.
        let format = #"{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"ports":{{json .NetworkSettings.Ports}}}"#
        let inspected = run(["inspect", "--type", "container", "--format", format] + ids, daemon: daemon)
        guard inspected.succeeded else { return DockerInventory(error: inspected.failure) }
        do { return DockerInventory(containers: try parse(inspected.output, daemon: daemon)) }
        catch { return DockerInventory(error: "Docker returned unreadable port bindings. Refresh to try again.") }
    }
    static func validID(_ id: String) -> Bool { (12...64).contains(id.count) && id.allSatisfy(\.isHexDigit) }
    static func parse(_ text: String, daemon: DockerDaemon) throws -> [DockerContainer] {
        struct Entry: Decodable {
            struct Host: Decodable { let HostIp: String; let HostPort: String }
            let id: String; let name: String; let image: String; let ports: [String: [Host]?]?
        }
        return try text.split(separator: "\n").map { line in
            let entry = try JSONDecoder().decode(Entry.self, from: Data(line.utf8))
            guard validID(entry.id) else { throw LaunchError.message("Invalid container identity") }
            var bindings: [DockerBinding] = []
            for (key, hosts) in entry.ports ?? [:] {
                let parts = key.split(separator: "/")
                guard parts.count == 2, parts[1] == "tcp", let inner = Int(parts[0]) else { continue }
                for host in hosts ?? [] {
                    guard let port = Int(host.HostPort), (1...65535).contains(port) else { continue }
                    bindings.append(DockerBinding(host: host.HostIp, port: port, containerPort: inner, transport: "tcp"))
                }
            }
            bindings.sort { ($0.port, $0.host, $0.containerPort) < ($1.port, $1.host, $1.containerPort) }
            return DockerContainer(id: entry.id, name: String(entry.name.drop(while: { $0 == "/" })), image: entry.image, bindings: bindings, daemon: daemon)
        }
    }
    static func action(_ action: String, container: String, daemon: DockerDaemon?) async -> StopOutcome {
        guard validID(container), let daemon, daemon.isAllowed else {
            return .failed("This container has no verified local Docker connection. Refresh it before trying again.")
        }
        guard let cli = cliPath, DockerDaemon.isSocket(daemon.socketPath) else {
            return .failed("The local container manager is unavailable. Open it and try again.")
        }
        let result = await CommandRunner.runAsync(cli, ["--host", "unix://" + daemon.socketPath, action, container],
                                                environment: environment(ProcessInfo.processInfo.environment), timeout: 25)
        return result.succeeded ? .stopped(forced: action == "kill") : .failed(result.failure)
    }
}
