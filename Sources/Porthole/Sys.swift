import Darwin
import Foundation

/// One row of the kernel process table.
struct KProc {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let uid: uid_t
    /// Start time in microseconds since 1970. Together with the pid it identifies
    /// a process even after its pid has been reused.
    let start: Int64
    /// Short process name from the kernel (at most 16 characters).
    let comm: String
    /// Background jobs started with `&` ignore Ctrl-C, so SIGINT would do nothing.
    let ignoresInterrupt: Bool
}

struct SocketListener: Hashable {
    let port: Int
    let address: String
    let isLoopback: Bool
}

/// Thin wrappers over sysctl and libproc. Everything here only works for
/// processes owned by the current user, which is exactly the set we can stop.
enum Sys {
    static func processTable() -> [pid_t: KProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [:] }
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = buf.count * stride
            let rc = buf.withUnsafeMutableBytes { raw in
                sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
            }
            if rc != 0 {
                if errno == ENOMEM { continue }
                return [:]
            }
            var table: [pid_t: KProc] = [:]
            table.reserveCapacity(size / stride)
            for kp in buf.prefix(size / stride) where kp.kp_proc.p_pid > 0 {
                let t = kp.kp_proc.p_un.__p_starttime
                table[kp.kp_proc.p_pid] = KProc(
                    pid: kp.kp_proc.p_pid,
                    ppid: kp.kp_eproc.e_ppid,
                    pgid: kp.kp_eproc.e_pgid,
                    uid: kp.kp_eproc.e_ucred.cr_uid,
                    start: Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec),
                    comm: cString(kp.kp_proc.p_comm),
                    ignoresInterrupt: kp.kp_proc.p_sigignore & (1 << (UInt32(SIGINT) - 1)) != 0
                )
            }
            return table
        }
        return [:]
    }

    /// Start time of a live process, used to make sure a pid still means the same process.
    static func startTime(_ pid: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
    }

    static func isAlive(_ pid: pid_t, start: Int64) -> Bool {
        startTime(pid) == start
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = buf.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)), as: UTF8.self)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    static func residentBytes(_ pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_resident_size
    }

    /// Total CPU time (user + system) in nanoseconds, for diffing between scans.
    static func cpuNanoseconds(_ pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_total_user + info.pti_total_system
    }

    /// TCP sockets in LISTEN state owned by `pid`.
    static func listeners(_ pid: pid_t) -> [SocketListener] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return [] }

        var out: [SocketListener] = []
        for fd in fds.prefix(Int(got) / stride) where Int32(fd.proc_fdtype) == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  Int(si.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard Int(tcp.tcpsi_state) == Int(TSI_S_LISTEN) else { continue }

            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            let address: String
            if Int32(ini.insi_vflag) & INI_IPV4 != 0 {
                var a = ini.insi_laddr.ina_46.i46a_addr4
                address = ntop(AF_INET, &a, Int(INET_ADDRSTRLEN))
            } else {
                var a = ini.insi_laddr.ina_6
                address = ntop(AF_INET6, &a, Int(INET6_ADDRSTRLEN))
            }
            let loopback = address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.")
            out.append(SocketListener(port: port, address: address, isLoopback: loopback))
        }
        return out
    }

    /// argv and a filtered environment, read the same way `ps` does. A process
    /// that renames itself (process.title) keeps its environment after a run of
    /// zero bytes, so we skip empty strings instead of stopping at them.
    static func commandLine(_ pid: pid_t, buffer: inout [UInt8], keepEnv: (String) -> Bool) -> (args: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let rc = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard rc == 0, size > MemoryLayout<Int32>.size else { return nil }

        return buffer.withUnsafeBytes { raw in
            let argc = Int(raw.load(as: Int32.self))
            var i = MemoryLayout<Int32>.size
            while i < size && raw[i] != 0 { i += 1 }   // executable path
            while i < size && raw[i] == 0 { i += 1 }   // alignment padding

            var args: [String] = []
            var env: [String: String] = [:]
            var start = i
            while i < size {
                if raw[i] == 0 {
                    if args.count < argc {
                        args.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<i]), as: UTF8.self))
                    } else if i > start {
                        let entry = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<i]), as: UTF8.self)
                        if let eq = entry.firstIndex(of: "="), eq != entry.startIndex {
                            let key = String(entry[..<eq])
                            if keepEnv(key) { env[key] = String(entry[entry.index(after: eq)...]) }
                        }
                    }
                    start = i + 1
                }
                i += 1
            }
            return (args, env)
        }
    }

    static func argMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func ntop(_ family: Int32, _ addr: UnsafeRawPointer, _ length: Int) -> String {
        var buf = [CChar](repeating: 0, count: length)
        guard inet_ntop(family, addr, &buf, socklen_t(length)) != nil else { return "?" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
