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
        expect(usage.total == fields[0] * 1024, "total matches df -k (\(usage.total) vs \(fields[0] * 1024))")
        expect(usage.free == fields[1] * 1024, "free matches df -k (\(usage.free) vs \(fields[1] * 1024))")
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
