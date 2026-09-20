import Foundation
import Darwin

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let error: String
    let timedOut: Bool
    let truncated: Bool
    var cancelled = false
    var succeeded: Bool { status == 0 && !timedOut && !truncated && !cancelled }
    var failure: String {
        if cancelled { return "The command was cancelled." }
        if timedOut { return "The command took too long and was stopped. Try again after checking the service manager." }
        if truncated { return "The command returned too much output. No partial result was used." }
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "The command exited with status \(status)." : String(message.prefix(2000))
    }
}

/// Blocking only on dedicated utility queues. Pipes are drained throughout the
/// child's lifetime, even after the retained-output limit has been reached.
enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 15, outputLimit: Int = 2_000_000, cancellation: CommandCancellation? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let out = Capture(limit: outputLimit), err = Capture(limit: outputLimit)
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription, timedOut: false, truncated: false)
        }
        // Nonblocking reads avoid waiting for EOF held open by an inherited fd.
        let handles = [(stdout.fileHandleForReading, out), (stderr.fileHandleForReading, err)]
        for (handle, _) in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        var cancelled = false
        while true {
            for (handle, capture) in handles { capture.drain(handle.fileDescriptor) }
            if done.wait(timeout: .now() + 0.01) == .success { break }
            if ProcessInfo.processInfo.systemUptime >= deadline || cancellation?.isCancelled == true {
                cancelled = cancellation?.isCancelled == true
                timedOut = !cancelled
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.3
                while ProcessInfo.processInfo.systemUptime < grace {
                    for (handle, capture) in handles { capture.drain(handle.fileDescriptor) }
                    if done.wait(timeout: .now() + 0.01) == .success { break }
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                break
            }
        }
        for (handle, capture) in handles { capture.drain(handle.fileDescriptor); try? handle.close() }
        return CommandResult(status: process.terminationStatus, output: out.text, error: err.text,
                             timedOut: timedOut, truncated: out.truncated || err.truncated, cancelled: cancelled)
    }

    static func runAsync(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                         timeout: TimeInterval = 15) async -> CommandResult {
        let cancellation = CommandCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: run(executable, arguments, environment: environment, timeout: timeout, cancellation: cancellation))
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private final class Capture {
        let limit: Int
        var data = Data()
        var truncated = false
        init(limit: Int) { self.limit = max(0, limit) }
        var text: String { String(decoding: data, as: UTF8.self) }
        func drain(_ fd: Int32) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            // Bound each pass so a continuously writing process cannot postpone its timeout.
            for _ in 0..<32 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                let keep = min(count, max(0, limit - data.count))
                data.append(contentsOf: buffer.prefix(keep))
                if keep < count { truncated = true }
            }
        }
    }
}

final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
