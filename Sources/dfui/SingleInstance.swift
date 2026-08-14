import AppKit
import Foundation

/// Keeps exactly one indicator in the menu bar.
///
/// Policy is **newest wins**: a launching instance terminates older ones,
/// rather than deferring to them. That matches what you mean when you launch a
/// freshly built copy — you want to see the new one — and it matches what
/// `scripts/install.sh` already does.
enum SingleInstance {
    /// Terminates already-running copies of this app. Returns how many were
    /// asked to quit.
    @discardableResult
    static func terminateOthers() -> Int {
        // A bare `swift run dfui` has no bundle identifier. Matching on nil
        // would match every other unbundled process on the system, so the
        // un-bundled case deliberately does nothing.
        guard let identifier = Bundle.main.bundleIdentifier else { return 0 }

        let me = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier
                && $0.processIdentifier != me.processIdentifier
                && supersedes(me, $0)
        }

        for other in others {
            FileHandle.standardError.write(
                Data("dfui: replacing instance \(other.processIdentifier)\n".utf8))
            // Graceful quit; these are our own processes with nothing to save.
            other.terminate()
        }
        return others.count
    }

    /// Whether `newer` should replace `older`.
    ///
    /// Ties fall through to process identifiers, which cannot compare equal,
    /// so two instances can never both conclude they supersede the other and
    /// leave the menu bar empty. Note `NSRunningApplication.current.launchDate`
    /// is nil for a process exec'd directly rather than through
    /// LaunchServices, so the identifier branch is the common one during
    /// development, not a rare fallback.
    ///
    /// Not airtight: if one instance reports a launch date and a concurrently
    /// launching one does not, the two could disagree. That needs both to
    /// start within the same few milliseconds, and the worst case — both quit
    /// — is fixed by launching again. A real lock file would be overkill here.
    static func supersedes(_ newer: NSRunningApplication, _ older: NSRunningApplication) -> Bool {
        if let newerDate = newer.launchDate, let olderDate = older.launchDate,
           newerDate != olderDate {
            return olderDate < newerDate
        }
        return older.processIdentifier < newer.processIdentifier
    }
}
