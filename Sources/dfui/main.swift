import AppKit
import DiskStats

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 30

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var loginItemMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        item.menu = buildMenu()
        statusItem = item

        refresh()
        syncLoginItemMenuItem()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            // Scheduled on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated { AppDelegate.shared?.refresh() }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // We drive `isEnabled` ourselves; automatic validation would fight
        // the disabled "needs installed app" state.
        menu.autoenablesItems = false

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        loginItemMenuItem = loginItem

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit dfui",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc private func refreshFromMenu() { refresh() }

    @objc private func toggleLoginItem() {
        switch LoginItem.state {
        case .requiresApproval:
            // Only the user can clear this, and only in System Settings.
            LoginItem.openSystemSettings()
        case .on, .off:
            do {
                try LoginItem.setEnabled(LoginItem.state == .off)
            } catch {
                presentError("Could not change the login item setting.", error)
            }
        case .unavailable:
            break
        }
        syncLoginItemMenuItem()
    }

    private func syncLoginItemMenuItem() {
        guard let item = loginItemMenuItem else { return }
        switch LoginItem.state {
        case .on:
            item.title = "Open at Login"
            item.state = .on
            item.isEnabled = true
        case .off:
            item.title = "Open at Login"
            item.state = .off
            item.isEnabled = true
        case .requiresApproval:
            item.title = "Open at Login (approve in System Settings…)"
            item.state = .mixed
            item.isEnabled = true
        case .unavailable:
            item.title = "Open at Login (needs installed app)"
            item.state = .off
            item.isEnabled = false
        }
    }

    private func presentError(_ message: String, _ error: Error) {
        FileHandle.standardError.write(Data("dfui: \(message) \(error)\n".utf8))
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "\(error.localizedDescription)"
        alert.alertStyle = .warning
        // An accessory app has no windows to key off, so bring it forward.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    fileprivate func refresh() {
        do {
            let usage = try diskUsage(ofVolumeContaining: "/")
            statusItem?.button?.title = formatUsage(usage)
        } catch {
            statusItem?.button?.title = "?/?TB"
            FileHandle.standardError.write(Data("dfui: \(error)\n".utf8))
        }
    }

    static var shared: AppDelegate?
}

extension AppDelegate: NSMenuDelegate {
    // Opening the menu is a good excuse for a fresh reading. The login item
    // state is re-read too: the user can change it in System Settings, and
    // approval can be granted while we are running.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        syncLoginItemMenuItem()
    }
}

// `dfui --login-item [status|enable|disable]` manages the login item without
// launching the UI, so it can be scripted and tested. Anything else falls
// through to the normal menu bar app.
if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    let command = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "status"
    switch command {
    case "status":
        break
    case "enable", "disable":
        do {
            try LoginItem.setEnabled(command == "enable")
        } catch {
            FileHandle.standardError.write(Data("dfui: \(error)\n".utf8))
            exit(1)
        }
    default:
        FileHandle.standardError.write(Data("usage: dfui --login-item [status|enable|disable]\n".utf8))
        exit(2)
    }
    let description: String
    switch LoginItem.state {
    case .on: description = "enabled"
    case .off: description = "disabled"
    case .requiresApproval: description = "requires approval in System Settings"
    case .unavailable: description = "unavailable (not running from an app bundle)"
    }
    print(description)
    exit(LoginItem.state == .unavailable ? 1 : 0)
}

let delegate = AppDelegate()
AppDelegate.shared = delegate

let app = NSApplication.shared
app.delegate = delegate
// Menu-bar-only: no Dock icon, no app menu. Also set via LSUIElement in the
// bundle's Info.plist, which is what matters when launched as a .app.
app.setActivationPolicy(.accessory)
app.run()
