import Foundation

/// Capacity of a single mounted volume, in bytes.
public struct DiskUsage: Equatable, Sendable {
    /// Bytes available to an unprivileged process — this is `df`'s "Avail"
    /// column, not `f_bfree` (which includes the root-reserved slack).
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

/// The menu bar string: free with two significant digits over total with one,
/// both in decimal terabytes — e.g. `0.35/2TB`.
public func formatUsage(_ usage: DiskUsage) -> String {
    let terabyte = 1_000_000_000_000.0
    let free = formatSignificant(Double(usage.free) / terabyte, digits: 2)
    let total = formatSignificant(Double(usage.total) / terabyte, digits: 1)
    return "\(free)/\(total)TB"
}
