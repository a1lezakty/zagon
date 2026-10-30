import AppKit
import UserNotifications

/// macOS notifications (only inside Zagon.app: the notification center needs a bundle).
enum MacNotifications {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private static let delegate = ShowWhileActive()
    /// A click on one of Zagon's notifications (`AppDelegate` sets it).
    @MainActor static var onOpen: (@MainActor () -> Void)?

    /// CI (`launch-check.sh`, with the `ciChecks` default): distributed notifications close the main window and do
    /// what a click on a notification does; the runner cannot post and click a real one.
    @MainActor static func listenForCI() {
        guard UserDefaults.standard.bool(forKey: "ciChecks") else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("dev.zagon.ci.closeWindow"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.filter { $0.isVisible && $0.title == "Zagon" }.forEach { $0.performClose(nil) } }
        }
        center.addObserver(forName: .init("dev.zagon.ci.notificationClick"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onOpen?() }
        }
    }

    /// Asks for permission once and shows banners even while the app is active.
    static func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Called on the store's write queue. Not allowed (denied, or not decided yet) = dropped, not retried: the user has
    /// not opted in, and a retry every pass would only fill the log.
    static func deliver(title: String, text: String, loud: Bool) -> Bool {
        let center = UNUserNotificationCenter.current()
        let done = DispatchSemaphore(value: 0)
        var status = UNAuthorizationStatus.notDetermined
        center.getNotificationSettings { status = $0.authorizationStatus; done.signal() }
        guard done.wait(timeout: .now() + 5) == .success else { return false }
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
