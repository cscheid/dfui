import DiskStats
import Foundation

public func htmlEscape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for character in text {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(character)
        }
    }
    return out
}

/// Human-readable byte size, e.g. `165.7 GB`. Decimal units, matching the
/// menu bar.
public func formatBytes(_ bytes: UInt64) -> String {
    let value = Double(bytes)
    switch value {
    case 1e12...: return String(format: "%.2f TB", value / 1e12)
    case 1e9...: return String(format: "%.1f GB", value / 1e9)
    case 1e6...: return String(format: "%.0f MB", value / 1e6)
    default: return String(format: "%.0f KB", value / 1e3)
    }
}

/// Coarse age, for spotting build directories nothing has touched in months.
public func formatAge(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "unknown" }
    let days = now.timeIntervalSince(date) / 86_400
    switch days {
    case ..<0: return "in the future"
    case ..<1: return "today"
    case ..<2: return "yesterday"
    case ..<31: return "\(Int(days)) days ago"
    case ..<365: return "\(Int(days / 30)) months ago"
    default:
        let years = days / 365
        return years < 2 ? "a year ago" : "\(Int(years)) years ago"
    }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func renderHTML(_ result: ScanResult, now: Date = Date()) -> String {
    let freeText = formatBytes(result.usage.free)
    let totalText = formatBytes(result.usage.total)
    let reclaimText = formatBytes(result.reclaimable)
    let reclaimShare = result.usage.total == 0 ? 0
        : Double(result.reclaimable) / Double(result.usage.total) * 100

    var html = """
    <title>dfui disk scan</title>
    <style>
      :root { color-scheme: light dark; --fg: #1a1a1a; --muted: #666; --bg: #fff;
              --line: #e2e2e2; --accent: #b3261e; --chip: #f4f4f5; }
      @media (prefers-color-scheme: dark) {
        :root { --fg: #e8e8e8; --muted: #9a9a9a; --bg: #17171a;
                --line: #33333a; --accent: #ff8a80; --chip: #222228; }
      }
      body { background: var(--bg); color: var(--fg); margin: 0 auto; padding: 2rem 1.5rem 4rem;
             max-width: 60rem; font: 15px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; }
      h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
      h2 { font-size: 1.05rem; margin: 2.5rem 0 .35rem; }
      .sub, .note { color: var(--muted); font-size: .85rem; }
      .note { margin: .35rem 0 .75rem; }
      .headline { margin: 1.25rem 0; padding: .9rem 1.1rem; background: var(--chip);
                  border-radius: 8px; border-left: 3px solid var(--accent); }
      .headline strong { font-size: 1.5rem; }
      table { border-collapse: collapse; width: 100%; font-size: .88rem; }
      th, td { text-align: left; padding: .4rem .5rem; border-bottom: 1px solid var(--line);
               vertical-align: top; }
      th { font-weight: 600; color: var(--muted); font-size: .78rem;
           text-transform: uppercase; letter-spacing: .04em; }
      td.size, th.size { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
      td.age { white-space: nowrap; color: var(--muted); }
      .path { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .82rem;
              word-break: break-all; }
      .dim { color: var(--muted); }
      pre { background: var(--chip); padding: .9rem 1.1rem; border-radius: 8px;
            overflow-x: auto; font-size: .82rem; line-height: 1.5; }
      .wrap { overflow-x: auto; }
    </style>

    <h1>Disk scan</h1>
    <div class="sub">\(htmlEscape(result.root)) &middot; \(formatAge(result.finishedAt, now: now)), \
    took \(String(format: "%.0f", result.elapsed))s &middot; \(freeText) free of \(totalText)</div>

    <div class="headline">
      <strong>\(reclaimText)</strong> in \(result.targets.count) cargo target \
    \(result.targets.count == 1 ? "directory" : "directories")
      <div class="sub">\(String(format: "%.0f%%", reclaimShare)) of the volume. \
    Rebuilding costs time, not data.</div>
    </div>

    """

    html += "<h2>Cargo target directories</h2>\n"
    if result.targets.isEmpty {
        html += "<p class=\"note\">None found under \(htmlEscape(result.root)).</p>\n"
    } else {
        html += """
        <p class="note">Sorted by size. &ldquo;Last built&rdquo; is the directory&rsquo;s own \
        modification time &mdash; the stale ones are the safe ones to reclaim.</p>
        <div class="wrap"><table>
        <tr><th class="size">Size</th><th>Project</th><th>Last built</th></tr>

        """
        for target in result.targets {
            let project = (target.project as NSString).lastPathComponent
            html += """
            <tr>
              <td class="size">\(formatBytes(target.bytes))</td>
              <td>\(htmlEscape(project))<div class="path dim">\(htmlEscape(target.path))</div></td>
              <td class="age">\(formatAge(target.modified, now: now))</td>
            </tr>

            """
        }
        html += "</table></div>\n"
    }

    if !result.rejectedTargets.isEmpty {
        html += """
        <p class="note">Skipped \(result.rejectedTargets.count) \
        \(result.rejectedTargets.count == 1 ? "directory" : "directories") named \
        <code>target</code> that \(result.rejectedTargets.count == 1 ? "is" : "are") not cargo \
        build output (no <code>CACHEDIR.TAG</code>, no sibling <code>Cargo.toml</code>) &mdash; \
        vendored sources and test fixtures live in some of these, so they are not yours to delete:</p>
        <div class="wrap"><table>

        """
        for path in result.rejectedTargets {
            html += "<tr><td class=\"path dim\">\(htmlEscape(path))</td></tr>\n"
        }
        html += "</table></div>\n"
    }

    html += "<h2>Largest directories</h2>\n"
    html += """
    <p class="note">Every directory within \(result.summaryDepth) \
    \(result.summaryDepth == 1 ? "level" : "levels") of the scan root, largest first &mdash; \
    the same view as <code>du | sort -n</code>. \

    """
    if result.directoriesShown > result.directories.count {
        html += "Showing the top \(result.directories.count) of \(result.directoriesShown)."
    }
    html += "</p>\n<div class=\"wrap\"><table>\n"
    html += "<tr><th class=\"size\">Size</th><th>Path</th></tr>\n"
    for directory in result.directories {
        html += """
        <tr><td class="size">\(formatBytes(directory.bytes))</td>\
        <td class="path">\(htmlEscape(directory.path))</td></tr>

        """
    }
    html += "</table></div>\n"

    if !result.targets.isEmpty {
        html += """
        <h2>Reclaiming</h2>
        <p class="note">dfui does not delete anything. These are the commands, largest first \
        &mdash; review before running. <code>cargo clean</code> is preferable to \
        <code>rm -rf</code>: it fails loudly if the directory is not what it looks like.</p>
        <pre>
        """
        for target in result.targets {
            html += "# \(formatBytes(target.bytes)), last built \(formatAge(target.modified, now: now))\n"
            html += "cargo clean --manifest-path \(htmlEscape(shellQuote(target.project + "/Cargo.toml")))\n"
        }
        html += "</pre>\n"
    }

    return html
}
