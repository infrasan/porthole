import XCTest
import Darwin
@testable import Porthole

private final class HTTPFixture: @unchecked Sendable {
    let fd: Int32
    let port: Int
    let host: String
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var active = true
    private var requests = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }

    init(ipv6: Bool = false, response: @escaping (Int) -> String) throws {
        host = ipv6 ? "::1" : "127.0.0.1"
        fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let socketFD = fd
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        if ipv6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6(); address.sin6_family = sa_family_t(AF_INET6); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            _ = inet_pton(AF_INET6, "::1", &address.sin6_addr)
            let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            guard rc == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
            port = Int(UInt16(bigEndian: address.sin6_port))
        } else {
            var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard rc == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
            port = Int(UInt16(bigEndian: address.sin_port))
        }
        guard listen(fd, 8) == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                lock.lock(); let running = active; lock.unlock()
                if !running { close(client); return }
                var timeout = timeval(tv_sec: 1, tv_usec: 0), noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var bytes = [UInt8](repeating: 0, count: 8192)
                if read(client, &bytes, bytes.count) > 0 {
                    lock.lock(); requests += 1; lock.unlock()
                    let data = Data(response(port).utf8)
                    data.withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) }
                }
                close(client)
            }
        }
    }
    func stop() {
        lock.lock(); active = false; lock.unlock()
        shutdown(fd, SHUT_RDWR); close(fd)
        _ = group.wait(timeout: .now() + 2)
    }
    var target: ProbeTarget { ProbeTarget(key: ProbeKey(serverID: "fixture", port: port, addresses: [host], mode: .http)) }
}

final class HealthTests: XCTestCase {
    func testRedirectIsCountedWithoutVisitingDestination() async throws {
        let target = try HTTPFixture { _ in "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" }
        defer { target.stop() }
        let source = try HTTPFixture { _ in "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/must-not-visit\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { source.stop() }
        let result = await HealthChecker().probeOne(source.target)
        XCTAssertTrue(result.isUp); XCTAssertEqual(source.count, 1); XCTAssertEqual(target.count, 0)
    }
    func testRedirectLoopIsAnAnswerNotAnOutage() async throws {
        let source = try HTTPFixture { port in "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { source.stop() }
        let result = await HealthChecker().probeOne(source.target)
        XCTAssertTrue(result.isUp); XCTAssertEqual(source.count, 1)
    }
    func testIPv6OnlyHTTPAndTCPAreReachable() async throws {
        let source = try HTTPFixture(ipv6: true) { _ in "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" }
        defer { source.stop() }
        let checker = HealthChecker()
        let http = await checker.probeOne(source.target)
        let tcp = await checker.probeOne(ProbeTarget(key: ProbeKey(serverID: "fixture", port: source.port, addresses: ["::1"], mode: .tcp)))
        XCTAssertTrue(http.isUp); XCTAssertTrue(tcp.isUp)
    }
    func testHTTPErrorResponseStillMeansAnswering() async throws {
        let source = try HTTPFixture { _ in "HTTP/1.1 500 Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { source.stop() }
        let result = await HealthChecker().probeOne(source.target)
        XCTAssertTrue(result.isUp)
    }
    func testLANOnlyListenerIsNotProbed() async {
        let target = ProbeTarget(key: ProbeKey(serverID: "fixture", port: 8000, addresses: ["192.0.2.1"], mode: .http))
        let result = await HealthChecker().probeOne(target)
        XCTAssertEqual(result, .unavailable("No loopback binding"))
    }
}
