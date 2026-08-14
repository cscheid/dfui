import Foundation
import ServiceManagement

/// "Open at Login" backed by `SMAppService`, which registers the app with
/// launchd and surfaces it in System Settings › General › Login Items.
enum LoginItem {
    enum State {
        case on
        case off
        /// Registered, but the user has not yet approved it in System Settings.
        case requiresApproval
        /// Not running from an app bundle — `swift run dfui` during development.
        case unavailable
    }

    /// `SMAppService` identifies the app by its bundle; a bare SwiftPM binary
    /// has none, and registering would fail with a confusing error.
    private static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static var state: State {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isBundled else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens the Login Items pane so the user can approve a pending
    /// registration — there is no way to grant that approval from within the app.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
