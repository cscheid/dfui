import AppKit
import DiskStats

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 30

    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        item.menu = buildMenu()
        statusItem = item

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            // Scheduled on the main run loop, so main-actor isolation holds.
            MainActor.assumeIsolated { AppDelegate.shared?.refresh() }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit dfui",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc private func refreshFromMenu() { refresh() }

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
    // Opening the menu is a good excuse for a fresh reading.
    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

let delegate = AppDelegate()
AppDelegate.shared = delegate

let app = NSApplication.shared
app.delegate = delegate
// Menu-bar-only: no Dock icon, no app menu. Also set via LSUIElement in the
// bundle's Info.plist, which is what matters when launched as a .app.
app.setActivationPolicy(.accessory)
app.run()
