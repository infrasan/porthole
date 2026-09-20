import Foundation
import Network

enum Health: Equatable, Sendable {
    case unknown, checking, up(ms: Int), down, unavailable(String)
    var isUp: Bool { if case .up = self { return true }; return false }
}

struct ProbeKey: Hashable, Sendable {
    let serverID: String
    let port: Int
    let addresses: [String]
    let mode: ProbeProtocol
}
struct ProbeTarget: Sendable {
    let key: ProbeKey
    var hosts: [String] { PortBinding(port: key.port, isExposed: false, addresses: key.addresses).loopbackHosts }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor HealthChecker {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func probe(_ targets: [ProbeTarget]) async -> [ProbeKey: Health] {
        await withTaskGroup(of: (ProbeKey, Health).self) { group in
            var iterator = targets.makeIterator()
            func enqueue(_ target: ProbeTarget) {
                group.addTask { (target.key, await self.probeOne(target)) }
            }
            for _ in 0..<6 { if let target = iterator.next() { enqueue(target) } }
            var result: [ProbeKey: Health] = [:]
            for await (key, health) in group {
                result[key] = health
                if !Task.isCancelled, let target = iterator.next() { enqueue(target) }
            }
            return result
        }
    }
    func probeOne(_ target: ProbeTarget) async -> Health {
        guard !target.hosts.isEmpty else { return .unavailable("No loopback binding") }
        guard (1...65535).contains(target.key.port) else { return .unknown }
        var result: Health = .down
        for host in target.hosts {
            guard !Task.isCancelled else { return .unknown }
            if target.key.mode == .tcp {
                result = await TCPProbe(host: host, port: UInt16(target.key.port)).run()
            } else {
                result = await httpProbe(host: host, port: target.key.port, mode: target.key.mode)
            }
            if result.isUp { return result }
        }
        return result
    }
    private func httpProbe(host: String, port: Int, mode: ProbeProtocol) async -> Health {
        let binding = PortBinding(port: port, isExposed: false, addresses: [host])
        guard PortBinding.isLoopback(host), let url = binding.url(scheme: mode) else { return .unknown }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let (_, response) = try await session.data(for: request)
            guard response is HTTPURLResponse else { return .down }
            return .up(ms: Int((ProcessInfo.processInfo.systemUptime - began) * 1000))
        } catch let error as URLError where [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .secureConnectionFailed].contains(error.code) {
            return .unavailable("HTTPS could not be verified")
        } catch { return Task.isCancelled ? .unknown : .down }
    }
}

private final class TCPProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Health, Never>?
    private var result: Health?
    init(host: String, port: UInt16) { connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    func run() async -> Health {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(returning: result); return }
                self.continuation = continuation
                lock.unlock()
                let began = ProcessInfo.processInfo.systemUptime
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.finish(.up(ms: Int((ProcessInfo.processInfo.systemUptime - began) * 1000)))
                    case .failed, .cancelled: self?.finish(.down)
                    default: break
                    }
                }
                connection.start(queue: DispatchQueue.global(qos: .utility))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { self.finish(.down) }
            }
        }, onCancel: { self.finish(.unknown) })
    }
    private func finish(_ health: Health) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = health
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(returning: health)
    }
}
