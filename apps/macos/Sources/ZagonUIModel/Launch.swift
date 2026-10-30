import Foundation

public enum Launch {
    /// Whether opening Zagon shows the main window: not when macOS opens it at login, known by the login item's mark
    /// in the open event or, where that mark is missing, by a launch within 120 s of the user's login to this GUI
    /// session (`sinceLogin`, nil: not known); the very first launch shows it anyway.
    public static func showsWindow(first: Bool, loginItem: Bool, sinceLogin: TimeInterval?) -> Bool {
        if loginItem { return false }
        if first { return true }
        return sinceLogin.map { abs($0) >= 120 } ?? true
    }
}
