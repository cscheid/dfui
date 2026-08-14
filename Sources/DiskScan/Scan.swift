import DiskStats
import Foundation

public struct SizedPath: Sendable, Equatable {
    public let path: String
    public let bytes: UInt64

    public init(path: String, bytes: UInt64) {
        self.path = path
        self.bytes = bytes
    }

    /// Last path component, or the whole path if there is none.
    public var name: String { (path as NSString).lastPathComponent }
}

/// A validated cargo build directory.
public struct CargoTarget: Sendable, Equatable {
    public let path: String
    public let bytes: UInt64
    /// The crate or workspace directory containing this `target/`.
    public let project: String
    public let modified: Date?

    public init(path: String, bytes: UInt64, project: String, modified: Date?) {
        self.path = path
        self.bytes = bytes
        self.project = project
        self.modified = modified
    }
}

public struct ScanResult: Sendable {
    public let root: String
    public let finishedAt: Date
    public let elapsed: TimeInterval
    public let usage: DiskUsage
    public let targets: [CargoTarget]
    public let directories: [SizedPath]
    /// Directories named `target` that failed cargo validation. Reported so a
    /// surprising omission is visible rather than silent.
    public let rejectedTargets: [String]
    public let summaryDepth: Int
    public let directoriesShown: Int

    public var reclaimable: UInt64 { targets.reduce(0) { $0 + $1.bytes } }
}

// MARK: - Parsing (pure, so it can be tested without touching the disk)

/// Parses one `du -k` line: a size in KiB, a tab, then a path.
public func parseDuLine(_ line: String) -> SizedPath? {
    guard let tab = line.firstIndex(of: "\t") else { return nil }
    guard let kb = UInt64(line[line.startIndex..<tab]) else { return nil }
    let path = String(line[line.index(after: tab)...])
    guard !path.isEmpty else { return nil }
    return SizedPath(path: path, bytes: kb * 1024)
}

/// How many path components `path` sits below `root`. Zero for the root
/// itself, nil when `path` is not under `root` at all.
public func relativeDepth(of path: String, under root: String) -> Int? {
    let root = root.hasSuffix("/") ? String(root.dropLast()) : root
    if path == root { return 0 }
    guard path.hasPrefix(root + "/") else { return nil }
    let rest = path.dropFirst(root.count + 1)
    return rest.split(separator: "/").count
}

/// Whether `path` lies inside `parent`. Compares whole components, so
/// `/a/bc` is not inside `/a/b`.
public func isDescendant(_ path: String, of parent: String) -> Bool {
    let parent = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
    return path.hasPrefix(parent + "/")
}

/// Drops paths contained in another path in the list, so a `target/` nested
/// inside another `target/` is not counted twice.
public func pruneNested(_ paths: [SizedPath]) -> [SizedPath] {
    let sorted = paths.sorted { $0.path.count < $1.path.count }
    var kept: [SizedPath] = []
    for candidate in sorted where !kept.contains(where: { isDescendant(candidate.path, of: $0.path) }) {
        kept.append(candidate)
    }
    return kept
}

/// Accumulates `du` output. Separate from running `du` so tests can feed it
/// lines directly.
public struct ScanCollector {
    public let root: String
    public let summaryDepth: Int

    public private(set) var targetCandidates: [SizedPath] = []
    public private(set) var directories: [SizedPath] = []

    public init(root: String, summaryDepth: Int = 2) {
        self.root = root
        self.summaryDepth = summaryDepth
    }

    public mutating func ingest(_ line: String) {
        guard let entry = parseDuLine(line) else { return }

        if entry.name == "target" {
            targetCandidates.append(entry)
        }
        // `du` emits a line per directory; the summary only wants the shallow
        // ones, which keeps this bounded no matter how deep the tree goes.
        if let depth = relativeDepth(of: entry.path, under: root), depth <= summaryDepth, depth > 0 {
            directories.append(entry)
        }
    }
}

// MARK: - Filesystem validation

/// Whether a directory named `target` is really a cargo build directory.
///
/// This matters more than it looks. Scanning one home directory turned up 33
/// directories named `target`, of which 8 were not build output — five were
/// `.cargo/registry/src/cc-*/src/target`, source directories inside cached
/// crates. Listing those as reclaimable would invite someone to corrupt their
/// own registry cache.
public func isCargoTarget(_ path: String, fileManager: FileManager = .default) -> Bool {
    // Cargo writes CACHEDIR.TAG into target/. A sibling Cargo.toml is the
    // corroborating signal; on the sample above the two agreed on all 33.
    if fileManager.fileExists(atPath: path + "/CACHEDIR.TAG") { return true }
    let parent = (path as NSString).deletingLastPathComponent
    return fileManager.fileExists(atPath: parent + "/Cargo.toml")
}

// MARK: - Running the scan

public enum ScanError: Error, CustomStringConvertible {
    case duFailed(status: Int32)

    public var description: String {
        switch self {
        case let .duFailed(status): return "du exited with status \(status)"
        }
    }
}

/// Walks `root` with `du` and returns the largest directories plus every
/// validated cargo build directory.
///
/// One `du` pass does both jobs: its output already contains a line for every
/// directory, so the `target/` entries and the shallow summary come from the
/// same traversal rather than two.
public func runScan(
    root: String,
    summaryDepth: Int = 2,
    maxDirectories: Int = 40,
    fileManager: FileManager = .default
) throws -> ScanResult {
    let started = Date()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    // -k: KiB. -x: stay on one filesystem, so an attached volume or a network
    // mount under the home directory is not dragged into the scan.
    process.arguments = ["-k", "-x", root]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    var collector = ScanCollector(root: root, summaryDepth: summaryDepth)

    try process.run()

    // Read incrementally. A full home directory produces a line per directory
    // — easily hundreds of megabytes of text — and only a few hundred lines
    // are worth keeping, so nothing is buffered whole.
    var buffer: [UInt8] = []
    while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffer.append(contentsOf: chunk)

        var start = 0
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            collector.ingest(String(decoding: buffer[start..<newline], as: UTF8.self))
            start = newline + 1
        }
        if start > 0 { buffer.removeFirst(start) }
    }
    if !buffer.isEmpty {
        collector.ingest(String(decoding: buffer, as: UTF8.self))
    }

    process.waitUntilExit()
    // du exits non-zero when it could not read some directory, which is normal
    // in a home directory and not a reason to discard everything it did read.
    guard process.terminationStatus == 0 || !collector.directories.isEmpty else {
        throw ScanError.duFailed(status: process.terminationStatus)
    }

    var targets: [CargoTarget] = []
    var rejected: [String] = []
    for candidate in pruneNested(collector.targetCandidates) {
        guard isCargoTarget(candidate.path, fileManager: fileManager) else {
            rejected.append(candidate.path)
            continue
        }
        let attributes = try? fileManager.attributesOfItem(atPath: candidate.path)
        targets.append(CargoTarget(
            path: candidate.path,
            bytes: candidate.bytes,
            project: (candidate.path as NSString).deletingLastPathComponent,
            modified: attributes?[.modificationDate] as? Date
        ))
    }
    targets.sort { $0.bytes > $1.bytes }

    let allDirectories = collector.directories.sorted { $0.bytes > $1.bytes }

    return ScanResult(
        root: root,
        finishedAt: Date(),
        elapsed: Date().timeIntervalSince(started),
        usage: (try? diskUsage(ofVolumeContaining: "/")) ?? DiskUsage(free: 0, total: 0),
        targets: targets,
        directories: Array(allDirectories.prefix(maxDirectories)),
        rejectedTargets: rejected,
        summaryDepth: summaryDepth,
        directoriesShown: allDirectories.count
    )
}
