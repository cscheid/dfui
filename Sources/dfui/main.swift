import AppKit
import DiskScan
import DiskStats

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 30

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var loginItemMenuItem: NSMenuItem?
    private var scanMenuItem: NSMenuItem?
    private var isScanning = false

    private let scanIdleTitle = "Scan for Large Directories…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before adding our own status item, so there is never a moment with
        // two indicators visible.
        SingleInstance.terminateOthers()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

        let scanItem = NSMenuItem(title: scanIdleTitle, action: #selector(startScan), keyEquivalent: "s")
        scanItem.target = self
        menu.addItem(scanItem)
        scanMenuItem = scanItem

        menu.addItem(.separator())

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

    @objc private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        scanMenuItem?.title = "Scanning…"
        scanMenuItem?.isEnabled = false

        let root = NSHomeDirectory()
        Task.detached(priority: .utility) {
            let outcome = Result { try runScan(root: root) }
            await MainActor.run { AppDelegate.shared?.finishScan(outcome) }
        }
    }

    private func finishScan(_ outcome: Result<ScanResult, Error>) {
        isScanning = false
        scanMenuItem?.title = scanIdleTitle
        scanMenuItem?.isEnabled = true

        switch outcome {
        case let .success(result):
            do {
                NSWorkspace.shared.open(try writeReport(result))
            } catch {
                presentError("Could not write the scan report.", error)
            }
        case let .failure(error):
            presentError("The scan failed.", error)
        }
    }

    /// Writes the report somewhere disposable. A tool about disk space should
    /// not quietly accumulate files, and the temporary directory is cleaned by
    /// the system.
    private func writeReport(_ result: ScanResult) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dfui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "scan-\(stamp.string(from: result.finishedAt).replacingOccurrences(of: ":", with: "")).html"

        let url = directory.appendingPathComponent(name)
        try renderHTML(result).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

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

    /// Set by `--simulate-free-gb`. The low-space appearance is otherwise
    /// unobservable until the disk is actually in trouble, which is a bad time
    /// to discover the warning does not work.
    static var simulatedFreeBytes: UInt64?

    fileprivate func refresh() {
        guard let button = statusItem?.button else { return }
        do {
            var usage = try diskUsage(ofVolumeContaining: "/")
            if let simulated = Self.simulatedFreeBytes {
                usage = DiskUsage(free: simulated, total: usage.total)
            }
            button.attributedTitle = title(menuBarText(usage), pressure: usage.pressure)
            button.toolTip = tooltipText(usage)
        } catch {
            button.attributedTitle = title("?", pressure: .low)
            button.toolTip = "dfui: \(error)"
            FileHandle.standardError.write(Data("dfui: \(error)\n".utf8))
        }
    }

    /// Low space is signalled three redundant ways — color, weight, and the
    /// unit switch in `menuBarText` — so it does not depend on noticing a hue.
    private func title(_ text: String, pressure: DiskPressure) -> NSAttributedString {
        let size = NSFont.systemFontSize
        switch pressure {
        case .normal:
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            ])
        case .low:
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ])
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

// `dfui --scan [root]` runs the scan headlessly and prints the report path,
// so the scan is testable without clicking a menu (and usable from a shell).
if let index = CommandLine.arguments.firstIndex(of: "--scan") {
    let root = CommandLine.arguments.count > index + 1
        && !CommandLine.arguments[index + 1].hasPrefix("--")
        ? CommandLine.arguments[index + 1] : NSHomeDirectory()
    do {
        let result = try runScan(root: root)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dfui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("scan.html")
        try renderHTML(result).write(to: url, atomically: true, encoding: .utf8)

        FileHandle.standardError.write(Data("""
        scanned \(root) in \(String(format: "%.1f", result.elapsed))s
        \(result.targets.count) cargo targets, \(formatBytes(result.reclaimable)) reclaimable
        \(result.rejectedTargets.count) rejected as not-cargo

        """.utf8))
        print(url.path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("dfui: \(error)\n".utf8))
        exit(1)
    }
}

// `dfui --simulate-free-gb 50` pretends the disk has that much free, so the
// low-space appearance can be inspected without filling the disk.
if let index = CommandLine.arguments.firstIndex(of: "--simulate-free-gb") {
    guard CommandLine.arguments.count > index + 1,
          let gb = Double(CommandLine.arguments[index + 1]), gb >= 0 else {
        FileHandle.standardError.write(Data("usage: dfui --simulate-free-gb <number>\n".utf8))
        exit(2)
    }
    AppDelegate.simulatedFreeBytes = UInt64(gb * 1_000_000_000)
}

let delegate = AppDelegate()
AppDelegate.shared = delegate

let app = NSApplication.shared
app.delegate = delegate
// Menu-bar-only: no Dock icon, no app menu. Also set via LSUIElement in the
// bundle's Info.plist, which is what matters when launched as a .app.
app.setActivationPolicy(.accessory)
app.run()
