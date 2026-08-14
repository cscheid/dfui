import Foundation

/// Capacity of a single mounted volume, in bytes.
public struct DiskUsage: Equatable, Sendable {
    /// Bytes available to an unprivileged process — `df`'s "Avail" column.
    ///
    /// This deliberately excludes *purgeable* space (Time Machine local
    /// snapshots, evictable caches), which Finder counts as free. The
    /// conservative number is the better alarm: it is what can be written
    /// without the OS first reclaiming anything. See
    /// `br-free-space-semantics-ogn2huun`.
    public let free: UInt64
    public let total: UInt64

    public init(free: UInt64, total: UInt64) {
        self.free = free
        self.total = total
    }
}

public enum DiskStatsError: Error, CustomStringConvertible {
    case statfsFailed(path: String, errno: Int32)

    public var description: String {
        switch self {
        case let .statfsFailed(path, code):
            return "statfs(\(path)) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Reads the capacity of the volume holding `path` via `statfs(2)`, the same
/// call `df` makes.
public func diskUsage(ofVolumeContaining path: String = "/") throws -> DiskUsage {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else {
        throw DiskStatsError.statfsFailed(path: path, errno: errno)
    }
    let blockSize = UInt64(fs.f_bsize)
    return DiskUsage(free: UInt64(fs.f_bavail) * blockSize,
                     total: UInt64(fs.f_blocks) * blockSize)
}

/// Formats `value` to exactly `digits` significant digits, without an exponent.
public func formatSignificant(_ value: Double, digits: Int) -> String {
    precondition(digits >= 1)
    guard value.isFinite, value > 0 else { return "0" }

    let scale = pow(10.0, Double(digits - 1 - Int(floor(log10(value)))))
    let rounded = (value * scale).rounded() / scale
    // Rounding can carry into the next decade (0.999 -> 1.0), so derive the
    // decimal count from the rounded value rather than the input.
    let decimals = max(0, digits - 1 - Int(floor(log10(rounded))))
    return String(format: "%.\(decimals)f", rounded)
}

/// How alarmed the indicator should look.
public enum DiskPressure: Equatable, Sendable {
    case normal
    case low
}

/// Free space below this fraction of the volume counts as low. On a 2 TB disk
/// that fires at ~100 GB — comfortably above the few GB where macOS itself
/// starts misbehaving, and above what a single cargo build can write.
public let lowSpaceFraction = 0.05

extension DiskUsage {
    public var fractionFree: Double {
        total == 0 ? 0 : Double(free) / Double(total)
    }

    /// A zero-capacity volume reads as `.low`: something is wrong, and the
    /// alarming answer is the safe one.
    public var pressure: DiskPressure {
        fractionFree < lowSpaceFraction ? .low : .normal
    }
}

private let gigabyte = 1_000_000_000.0
private let terabyte = 1_000_000_000_000.0

/// Free over total in decimal terabytes — e.g. `0.35/2TB`.
public func formatUsage(_ usage: DiskUsage) -> String {
    let free = formatSignificant(Double(usage.free) / terabyte, digits: 2)
    let total = formatSignificant(Double(usage.total) / terabyte, digits: 1)
    return "\(free)/\(total)TB"
}

/// Free space alone, in decimal gigabytes — e.g. `98GB`.
public func formatFreeGB(_ usage: DiskUsage) -> String {
    "\(formatSignificant(Double(usage.free) / gigabyte, digits: 2))GB"
}

/// What the menu bar shows.
///
/// Under pressure the format changes, not just the color. In TB the whole
/// danger zone collapses into a smear of leading zeros — `0.020/2TB` versus
/// `0.0020/2TB` is a 10x difference in trouble, distinguished only by counting
/// decimal places in an 11px font. Below the threshold the denominator stops
/// carrying information (you know how big your disk is) and the absolute
/// number starts mattering, so it switches to plain GB.
public func menuBarText(_ usage: DiskUsage) -> String {
    switch usage.pressure {
    case .normal: return formatUsage(usage)
    case .low: return formatFreeGB(usage)
    }
}

/// Precise figures for the tooltip, where there is room for them.
public func tooltipText(_ usage: DiskUsage) -> String {
    let free = String(format: "%.1f", Double(usage.free) / gigabyte)
    let total = String(format: "%.1f", Double(usage.total) / gigabyte)
    let percent = String(format: "%.1f", usage.fractionFree * 100)
    return "\(free) GB free of \(total) GB (\(percent)%)"
}
