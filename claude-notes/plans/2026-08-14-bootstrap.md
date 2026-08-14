# dfui bootstrap

## Overview

`dfui` is a personal macOS menu bar app showing free disk space on the volume
holding `/`, so that runaway `target/` directories from parallel Rust agent
sessions become visible without running `df`.

Scope for this plan is the scaffolding plus the smallest useful indicator: a
text-only status item reading e.g. `0.35/2TB` — free space to two significant
digits over total capacity to one, in decimal terabytes.

Not in scope: App Store distribution, code signing beyond ad-hoc, icons.

## Work Items

- [x] `git init` and `.gitignore` (must exclude `.braid.toml` — bearer token)
- [x] `braid init`
- [x] Pick a language/toolchain that works with the installed tooling
- [x] `DiskStats` module: `statfs(2)` reader + significant-digit formatter
- [x] `dfui` executable: `NSStatusItem` with monospaced-digit title, 30s
      refresh timer, refresh-on-menu-open, Refresh and Quit menu items
- [x] `selftest` executable with assertions, including a `df -k` cross-check
- [x] `scripts/build-app.sh` producing an ad-hoc-signed `dist/dfui.app`
- [x] Extend CLAUDE.md with build/run/test instructions
- [x] Initial commit

## Design decisions

**Swift + SwiftPM, no Xcode project.** The machine has Command Line Tools only
(`xcode-select -p` → `/Library/Developer/CommandLineTools`; no `xcodebuild`).
AppKit compiles fine against the CLT SDK, so a plain SwiftPM executable plus a
hand-assembled `.app` bundle avoids depending on a full Xcode install. Verified
by building and running an `NSStatusBar` probe before committing to this.

**No `swift test`.** Neither swift-testing nor XCTest ships with the Command
Line Tools, so `.testTarget` cannot build. Tests live in a `selftest`
executable with a ~20-line assertion harness. If Xcode is ever installed this
should migrate to swift-testing (tracked as its own strand).

**`statfs(2)`, not `URLResourceValues`.** The user's reference point is
`df -h /`, and `df` reads the same `statfs` fields. `f_bavail` (not `f_bfree`)
is used, matching df's "Avail" column, which excludes root-reserved slack. The
alternative, `volumeAvailableCapacityForImportantUsageKey`, is what Finder
shows and counts purgeable space as available — a larger, more optimistic
number that disagrees with df. Tracked as a strand to reconsider.

**Decimal TB (10^12), not TiB (2^40).** The user wrote "TB" and "2TB" for a
drive that `df -h` reports as `1.8Ti`. Decimal matches how Apple labels the
hardware. At one significant digit the denominator reads `2` either way, but
the numerator differs (0.97 decimal vs 0.88 binary).

**`LSUIElement`.** Set in the bundle's Info.plist, with a matching
`setActivationPolicy(.accessory)` so the executable also behaves when run
directly from the terminal during development.
