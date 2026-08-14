// Minimal assertion harness. See Package.swift for why this is an executable
// rather than a proper test target.
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
