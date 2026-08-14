// Minimal assertion harness. See Package.swift for why this is an executable
// rather than a proper test target.
import DiskScan
import DiskStats
import Foundation

var failures = 0
var checks = 0

@MainActor func expect(_ actual: String, _ expected: String, _ label: String,
            file: StaticString = #file, line: UInt = #line) {
    checks += 1
    guard actual != expected else { return }
    failures += 1
    print("FAIL \(label): expected \"\(expected)\", got \"\(actual)\" (\(file):\(line))")
}

@MainActor func expect(_ condition: Bool, _ label: String,
            file: StaticString = #file, line: UInt = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    print("FAIL \(label) (\(file):\(line))")
}

// MARK: significant-digit formatting

expect(formatSignificant(0.35, digits: 2), "0.35", "0.35 to 2sf")
expect(formatSignificant(0.9702, digits: 2), "0.97", "0.9702 to 2sf")
expect(formatSignificant(0.354, digits: 2), "0.35", "round down")
expect(formatSignificant(0.356, digits: 2), "0.36", "round up")

// Rounding that carries into the next decade must shed a decimal place.
expect(formatSignificant(0.999, digits: 2), "1.0", "0.999 carries to 1.0")
expect(formatSignificant(9.99, digits: 1), "10", "9.99 carries to 10")

expect(formatSignificant(1.995, digits: 1), "2", "1.995 to 1sf")
expect(formatSignificant(1.24, digits: 2), "1.2", "1.24 to 2sf")
expect(formatSignificant(12.4, digits: 2), "12", "12.4 to 2sf")
expect(formatSignificant(4.0, digits: 1), "4", "4.0 to 1sf")

expect(formatSignificant(0, digits: 2), "0", "zero")
expect(formatSignificant(-1, digits: 2), "0", "negative")
expect(formatSignificant(.nan, digits: 2), "0", "nan")
expect(formatSignificant(.infinity, digits: 2), "0", "infinity")

// MARK: menu bar string

expect(formatUsage(DiskUsage(free: 350_000_000_000, total: 1_995_165_736_960)),
       "0.35/2TB", "spec example")
expect(formatUsage(DiskUsage(free: 970_168_455_168, total: 1_995_165_736_960)),
       "0.97/2TB", "2TB machine, mostly free")
expect(formatUsage(DiskUsage(free: 12_000_000_000, total: 499_000_000_000)),
       "0.012/0.5TB", "half-TB machine, nearly full")

// MARK: low-space threshold

// The author's 2 TB disk: the threshold should land near 100 GB.
let disk = 1_995_165_736_960 as UInt64
func atGB(_ gb: Double) -> DiskUsage { DiskUsage(free: UInt64(gb * 1e9), total: disk) }

expect(atGB(200).pressure == .normal, "200 GB free is normal")
expect(atGB(110).pressure == .normal, "110 GB free is normal")
expect(atGB(90).pressure == .low, "90 GB free is low")
expect(atGB(20).pressure == .low, "20 GB free is low")

// Exactly at the boundary counts as normal; just under it does not.
let boundary = UInt64(Double(disk) * lowSpaceFraction)
expect(DiskUsage(free: boundary, total: disk).pressure == .normal, "at threshold is normal")
expect(DiskUsage(free: boundary - 1, total: disk).pressure == .low, "just under threshold is low")

// A broken reading should look alarming rather than reassuring.
expect(DiskUsage(free: 0, total: 0).pressure == .low, "zero-capacity volume reads as low")

// MARK: unit switch under pressure

expect(menuBarText(atGB(900)), "0.90/2TB", "normal shows the TB ratio")
expect(menuBarText(atGB(110)), "0.11/2TB", "just above threshold still TB")
expect(menuBarText(atGB(98)), "98GB", "below threshold switches to GB")
expect(menuBarText(atGB(20)), "20GB", "20 GB free")
expect(menuBarText(atGB(5)), "5.0GB", "5 GB free")
expect(menuBarText(atGB(0.5)), "0.50GB", "half a GB free")

// The point of the switch: these are visually distinct, where the TB forms
// (0.020/2TB vs 0.0020/2TB) are not.
expect(menuBarText(atGB(20)) != menuBarText(atGB(2)), "20GB and 2GB read differently")

// MARK: tooltip

expect(tooltipText(DiskUsage(free: 98_000_000_000, total: 1_995_165_736_960)),
       "98.0 GB free of 1995.2 GB (4.9%)", "tooltip carries the precise figures")

// MARK: du output parsing

expect(parseDuLine("12345\t/Users/x/foo")?.bytes == 12345 * 1024, "du line size is KiB")
expect(parseDuLine("12345\t/Users/x/foo")?.path == "/Users/x/foo", "du line path")
expect(parseDuLine("0\t/tmp")?.bytes == 0, "zero size parses")
expect(parseDuLine("nonsense") == nil, "line without a tab is ignored")
expect(parseDuLine("abc\t/tmp") == nil, "non-numeric size is ignored")
expect(parseDuLine("12\t") == nil, "empty path is ignored")
// Paths containing spaces and tabs-in-name are common enough to matter.
expect(parseDuLine("99\t/Users/x/My Project/target")?.path == "/Users/x/My Project/target",
       "spaces in path survive")

// MARK: depth

expect(relativeDepth(of: "/Users/x", under: "/Users/x") == 0, "root is depth 0")
expect(relativeDepth(of: "/Users/x/a", under: "/Users/x") == 1, "one level")
expect(relativeDepth(of: "/Users/x/a/b", under: "/Users/x") == 2, "two levels")
expect(relativeDepth(of: "/Users/x/", under: "/Users/x/") == 0, "trailing slashes tolerated")
expect(relativeDepth(of: "/Users/other", under: "/Users/x") == nil, "outside the root")
// A sibling with a shared prefix must not read as a descendant.
expect(relativeDepth(of: "/Users/xyz/a", under: "/Users/x") == nil, "prefix is not containment")

// MARK: nesting

expect(isDescendant("/a/b/c", of: "/a/b"), "plain descendant")
expect(!isDescendant("/a/bc", of: "/a/b"), "shared prefix is not a descendant")
expect(!isDescendant("/a/b", of: "/a/b"), "a path is not its own descendant")

let nested = pruneNested([
    SizedPath(path: "/p/target", bytes: 100),
    SizedPath(path: "/p/target/debug/x/target", bytes: 10),
    SizedPath(path: "/q/target", bytes: 50),
])
expect(nested.count == 2, "nested target is dropped, siblings kept")
expect(nested.contains { $0.path == "/p/target" }, "outer target kept")
expect(nested.contains { $0.path == "/q/target" }, "unrelated target kept")
expect(!nested.contains { $0.path.hasSuffix("debug/x/target") }, "inner target dropped")

// MARK: collector

var collector = ScanCollector(root: "/r", summaryDepth: 2)
for line in ["10\t/r", "20\t/r/a", "30\t/r/a/b", "40\t/r/a/b/c", "50\t/r/p/target",
             "60\t/elsewhere/x"] {
    collector.ingest(line)
}
// /r/a, /r/a/b and /r/p/target — the last is a real directory at depth 2 and
// belongs in the summary as well as the target list.
expect(collector.directories.count == 3, "summary keeps depth 1 and 2 only, excluding the root")
expect(!collector.directories.contains { $0.path == "/r" }, "root excluded from summary")
expect(!collector.directories.contains { $0.path == "/r/a/b/c" }, "depth 3 excluded")
expect(!collector.directories.contains { $0.path == "/elsewhere/x" }, "outside root excluded")
expect(collector.targetCandidates.count == 1, "target found at any depth")
expect(collector.targetCandidates.first?.bytes == 50 * 1024, "target size carried through")

// MARK: cargo validation

// The real hazard: .cargo/registry/src/<crate>/src/target is a source
// directory, not build output, and must never be offered up for deletion.
let scratch = NSTemporaryDirectory() + "/dfui-selftest-\(getpid())"
let fm = FileManager.default
try? fm.createDirectory(atPath: scratch + "/real/target", withIntermediateDirectories: true)
fm.createFile(atPath: scratch + "/real/target/CACHEDIR.TAG", contents: Data())
try? fm.createDirectory(atPath: scratch + "/sibling/target", withIntermediateDirectories: true)
fm.createFile(atPath: scratch + "/sibling/Cargo.toml", contents: Data())
try? fm.createDirectory(atPath: scratch + "/impostor/src/target", withIntermediateDirectories: true)

expect(isCargoTarget(scratch + "/real/target"), "CACHEDIR.TAG identifies a cargo target")
expect(isCargoTarget(scratch + "/sibling/target"), "sibling Cargo.toml identifies a cargo target")
expect(!isCargoTarget(scratch + "/impostor/src/target"), "a directory merely named target is rejected")
try? fm.removeItem(atPath: scratch)

// MARK: report formatting

expect(formatBytes(165_700_000_000), "165.7 GB", "GB size")
expect(formatBytes(1_500_000_000_000), "1.50 TB", "TB size")
expect(formatBytes(5_000_000), "5 MB", "MB size")

let now = Date(timeIntervalSince1970: 1_800_000_000)
expect(formatAge(now, now: now), "today", "same instant is today")
expect(formatAge(now.addingTimeInterval(-86_400 * 5), now: now), "5 days ago", "days")
expect(formatAge(now.addingTimeInterval(-86_400 * 90), now: now), "3 months ago", "months")
expect(formatAge(nil, now: now), "unknown", "missing date")

expect(htmlEscape("<a href=\"x\">&</a>"), "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;",
       "html escaping covers the injection characters")

// MARK: statfs

do {
    let usage = try diskUsage(ofVolumeContaining: "/")
    expect(usage.total > 0, "root volume has nonzero size")
    expect(usage.free <= usage.total, "free does not exceed total")

    // Cross-check against df, which reads the same statfs fields.
    let df = Process()
    df.executableURL = URL(fileURLWithPath: "/bin/sh")
    df.arguments = ["-c", "df -k / | tail -1 | awk '{print $2, $4}'"]
    let pipe = Pipe()
    df.standardOutput = pipe
    try df.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    df.waitUntilExit()

    let fields = out.split(separator: " ").compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if fields.count == 2 {
        // Capacity is stable, so it must match exactly.
        expect(usage.total == fields[0] * 1024, "total matches df -k (\(usage.total) vs \(fields[0] * 1024))")

        // Free space is not: the disk is live and moves between our statfs and
        // df's, so this is a 1% band rather than an equality. That is still
        // tight enough to catch the failure this guards against — reading the
        // wrong field, or a 1024x unit slip.
        let ours = Double(usage.free)
        let theirs = Double(fields[1] * 1024)
        let drift = abs(ours - theirs) / max(theirs, 1)
        expect(drift < 0.01,
               "free agrees with df -k within 1% (\(usage.free) vs \(fields[1] * 1024), \(String(format: "%.4f%%", drift * 100)) apart)")
    } else {
        print("SKIP df cross-check: could not parse \"\(out)\"")
    }
} catch {
    failures += 1
    print("FAIL reading root volume: \(error)")
}

do {
    _ = try diskUsage(ofVolumeContaining: "/nonexistent-path-\(UInt64.max)")
    failures += 1
    checks += 1
    print("FAIL missing path should throw")
} catch {
    checks += 1
}

print(failures == 0 ? "ok — \(checks) checks passed" : "\(failures)/\(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
