import Foundation

/// A child process with both pipes read as data arrives and a time limit on the process itself.
public enum Proc {
    public struct Result: Sendable, Equatable {
        public var status: Int32
        public var out: Data
        public var err: Data
        public var errLastLine: String {
            String(decoding: err, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        }
    }

    /// How a process stops when the task waiting for it is cancelled.
    public enum Stop: Sendable {
        /// Its stdin, kept open, is closed: a command under `Remote.stopScript` ends on that (across ssh too). It is
        /// terminated if still there 5 s later.
        case closeInput
        /// SIGKILL to it and what it started: its process group when it leads one (as `Process` starts it), else it alone.
        case kill
    }

    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var ended: Set<Bool> = []  // which pipes reached their end (true = stdout)
    }

    /// nil when the process did not exit within `timeout` (it is terminated then). Output still held open by
    /// something it left running (a background job of a shell rc file, a shared ssh connection) is taken as it is a
    /// moment after the exit. `env` entries replace inherited ones.
    ///
    /// With `stop`, a cancelled calling task stops the process that way and gets `CancellationError`.
    public static func run(_ executable: String, _ arguments: [String], env: [String: String] = [:],
                           timeout: Double, stop: Stop? = nil) throws -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(), err = Pipe(), input = stop == .closeInput ? Pipe() : nil
        p.standardOutput = out; p.standardError = err; p.standardInput = input ?? FileHandle.nullDevice
        let got = Collected(), closed = DispatchGroup(), exited = DispatchSemaphore(value: 0)
        for (handle, isOut) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            closed.enter()
            handle.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else {
                    h.readabilityHandler = nil
                    // A late second call at the end must not leave the group twice.
                    if got.lock.withLock({ got.ended.insert(isOut).inserted }) { closed.leave() }
                    return
                }
                got.lock.withLock { if isOut { got.out.append(d) } else { got.err.append(d) } }
            }
        }
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        let deadline = DispatchTime.now() + timeout
        var finished = false, cancelled = false
        repeat {
            finished = exited.wait(timeout: stop == nil ? deadline : min(deadline, .now() + 0.2)) == .success
            cancelled = stop != nil && !finished && Task.isCancelled
        } while !finished && !cancelled && DispatchTime.now() < deadline
        try? input?.fileHandleForWriting.close()
        if cancelled {
            if stop == .kill {
                let pid = p.processIdentifier
                kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
            finished = exited.wait(timeout: .now() + 5) == .success
        }
        if !finished { p.terminate() }
        _ = closed.wait(timeout: .now() + 1)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if cancelled { throw CancellationError() }
        guard finished else { return nil }
        return got.lock.withLock { Result(status: p.terminationStatus, out: got.out, err: got.err) }
    }
}
