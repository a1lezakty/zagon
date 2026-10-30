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

    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var ended: Set<Bool> = []  // which pipes reached their end (true = stdout)
    }

    /// nil when the process did not exit within `timeout` (it is terminated then). Output still held open by
    /// something it left running (a background job of a shell rc file, a shared ssh connection) is taken as it is a
    /// moment after the exit. `env` entries replace inherited ones.
    public static func run(_ executable: String, _ arguments: [String], env: [String: String] = [:],
                           timeout: Double) throws -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
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
        let finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished { p.terminate() }
        _ = closed.wait(timeout: .now() + 1)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        guard finished else { return nil }
        return got.lock.withLock { Result(status: p.terminationStatus, out: got.out, err: got.err) }
    }
}
