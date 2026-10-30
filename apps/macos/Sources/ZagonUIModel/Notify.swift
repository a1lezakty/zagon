import Foundation
import ZagonCore

/// How the app delivers notifications and which of them it wants.
public struct NotifyHook: Sendable {
    /// Shows one notification (title, text, loud); false = not delivered, retried on the next pass.
    public var deliver: @Sendable (String, String, Bool) -> Bool
    /// System notifications on this Mac are on.
    public var enabled: @Sendable () -> Bool
    /// Also send through the Telegram / ntfy settings of config.toml (off by default: the servers send those).
    public var remote: @Sendable () -> Bool
    public var configPath: String

    public init(deliver: @escaping @Sendable (String, String, Bool) -> Bool, enabled: @escaping @Sendable () -> Bool,
                remote: @escaping @Sendable () -> Bool, configPath: String = NotifySettings.configPath) {
        self.deliver = deliver; self.enabled = enabled; self.remote = remote; self.configPath = configPath
    }
}

/// Telegram / ntfy from this Mac: sent on their own queue, so a slow or offline network (curl waits up to 35 s) never
/// holds up the scans on the write queue. ponytail: accepted = handed over, no retry; the servers send these anyway.
final class Background: Channel, @unchecked Sendable {
    static let queue = DispatchQueue(label: "dev.zagon.notify.remote")
    let channel: any Channel
    var name: String { channel.name }
    init(_ channel: any Channel) { self.channel = channel }
    func send(_ m: Message) -> Bool {
        Self.queue.async { _ = self.channel.send(m) }
        return true
    }
}

/// The Mac's own channel for the core's `Notifier`.
struct Deliver: Channel {
    let name = "macos"
    let deliver: @Sendable (String, String, Bool) -> Bool
    init(_ deliver: @escaping @Sendable (String, String, Bool) -> Bool) { self.deliver = deliver }
    func send(_ m: Message) -> Bool { deliver(m.title, m.text, m.priority >= 4) }
}
