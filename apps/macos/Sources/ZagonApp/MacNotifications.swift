import AppKit
import UserNotifications

/// macOS notifications (only inside Zagon.app: the notification center needs a bundle).
enum MacNotifications {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private static let delegate = ShowWhileActive()
    /// A click on one of Zagon's notifications (`ZagonCommands` sets it).
    @MainActor static var onOpen: (@MainActor () -> Void)?

    /// Shows banners even while the app is active and opens "Sessions" on a click. Asks nothing: the permission is
    /// asked when notifications are first wanted (`ask`), not at launch.
    static func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// macOS shows its prompt while the user has not decided (later calls only answer); then whether it is denied.
    static func ask(_ done: (@MainActor (Bool) -> Void)? = nil) {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in denied(done) }
    }

    /// Whether macOS has Zagon's notifications turned off.
    static func denied(_ done: (@MainActor (Bool) -> Void)?) {
        guard available, let done else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let off = s.authorizationStatus == .denied
            Task { @MainActor in done(off) }
        }
    }

    /// System Settings → Notifications, at Zagon where macOS takes the id.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier.map { "?id=" + $0 } ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension" + id) {
            NSWorkspace.shared.open(url)
        }
    }

    /// The first notification found the permission undecided and asked (the store's write queue only).
    private static var asked = false

    /// Called on the store's write queue. Denied = dropped, not retried: the user said no, and a retry every pass would
    /// only fill the log. Not decided yet: asked once, and retried until the user answers (the first warning is kept).
    static func deliver(title: String, text: String, loud: Bool) -> Bool {
        let center = UNUserNotificationCenter.current()
        let done = DispatchSemaphore(value: 0)
        var status = UNAuthorizationStatus.notDetermined
        center.getNotificationSettings { status = $0.authorizationStatus; done.signal() }
        guard done.wait(timeout: .now() + 5) == .success else { return false }
        if status == .notDetermined {
            if !asked { asked = true; ask() }
            return false
        }
        guard status == .authorized || status == .provisional else { return true }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        if loud { content.sound = .default }
        var ok = false
        // The same text gets the same id: a retry after a slow delivery replaces the banner instead of adding one.
        let id = "zagon-" + String(UInt(bitPattern: (title + "\n" + text).hashValue), radix: 16)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            ok = error == nil
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success && ok
    }

    final class ShowWhileActive: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
            handler([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler handler: @escaping () -> Void) {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in MacNotifications.onOpen?() }
            }
            handler()
        }
    }
}
