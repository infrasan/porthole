import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") || args.contains("--json") {
            let result = Scanner().scan()
            if args.contains("--json") {
                do { FileHandle.standardOutput.write(try Diagnostics.data(result)); print("") }
                catch { fputs("Could not encode the scan.\n", stderr); exit(1) }
            } else { dump(result) }
            if result.error != nil { exit(1) }
            return
        }
        if let i = args.firstIndex(of: "--stop"), i + 1 < args.count, let port = Int(args[i + 1]) {
            let result = Scanner().scan()
            if let error = result.error { print(error); exit(1) }
            let matches = (result.servers + result.others).filter { $0.ports.contains { $0.port == port } }
            guard matches.count <= 1 else { print("Multiple listeners share this port. Select the exact service in the panel."); exit(1) }
            guard let server = (result.servers + result.others).first(where: { $0.ports.contains { $0.port == port } }) else {
                print("Nothing is listening on \(port)."); exit(1)
            }
            print("Stopping \(server.name): \(server.chain.map { "\($0.label) (\($0.pid))" }.joined(separator: " → "))")
            guard server.canStop else { print(server.stopDisabledReason ?? "This process cannot be stopped."); exit(1) }
            let began = Date()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let outcome = await Stopper.stop(server, force: args.contains("--force"))
                print("\(outcome) in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
                if case .failed = outcome { exit(1) }
                done.signal()
            }
            done.wait()
            return
        }
        if args.contains("--bench") {
            let scanner = Scanner()
            func cpu() -> Double {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            }
            _ = scanner.scan()
            let runs = 20
            var t0 = cpu()
            let table = Sys.processTable()
            for _ in 0..<runs { _ = Sys.processTable() }
            print(String(format: "process table: %.2f ms CPU", (cpu() - t0) * 1000 / Double(runs)))
            t0 = cpu()
            for _ in 0..<runs { for p in table.values where p.uid == getuid() { _ = Sys.listeners(p.pid) } }
            print(String(format: "socket scan:   %.2f ms CPU", (cpu() - t0) * 1000 / Double(runs)))
            t0 = cpu()
            for _ in 0..<runs { _ = scanner.scan() }
            print(String(format: "full scan:     %.2f ms CPU (%d processes)", (cpu() - t0) * 1000 / Double(runs), table.count))
            let a = scanner.scan(includeMemory: false), b = scanner.scan(includeMemory: false)
            let stable = a.error == nil && b.error == nil && a.servers == b.servers && a.others == b.others
            print("stable between scans:", stable)
            if !stable { exit(1) }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let expand = args.firstIndex(of: "--expand").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            do {
                try MainActor.assumeIsolated {
                    try Snapshot.render(to: args[i + 1], dark: args.contains("--dark"), expand: expand, demo: args.contains("--demo"))
                }
            } catch { fputs("Snapshot failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--stop") || args.contains("--snapshot") { fputs("Provide a valid port or snapshot path.\n", stderr); exit(2) }
        PortholeApp.main()
    }

    static func dump(_ result: ScanResult) {
        if let error = result.error { print(error); return }
        func line(_ s: DevServer) -> String {
            let ports = s.ports.map { "\($0.port)\($0.isExposed ? "*" : "")" }.joined(separator: ",")
            let flags = [s.isOrphaned ? "orphaned" : nil, s.brewService.map { "brew:\($0)" }].compactMap { $0 }.joined(separator: " ")
            return "\(ports.padding(toLength: 18, withPad: " ", startingAt: 0)) \(s.name.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                + "\((s.framework?.name ?? "-").padding(toLength: 18, withPad: " ", startingAt: 0)) \(s.owner.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(flags)\n"
                + "      stop: \(s.chain.map { "\($0.label) (\($0.pid))" }.joined(separator: " → "))\(s.childCount > 0 ? " +\(s.childCount)" : "")"
                + "  via: \(s.launchedVia ?? "-")  mem: \(s.memory / 1_048_576) MB\n      why: \(s.owner.evidence)"
        }
        print("DEV SERVERS (\(result.servers.count)) — scanned in \(Int(result.duration * 1000)) ms")
        result.servers.forEach { print(line($0)) }
        print("\nOTHER (\(result.others.count))")
        result.others.forEach { print(line($0) + ($0.note.map { "\n      note: \($0)" } ?? "")) }
    }
}
