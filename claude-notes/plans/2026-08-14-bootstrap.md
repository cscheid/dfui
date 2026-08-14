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

## Follow-up: run at login (br-login-item-g0o3k6la)

- [x] `scripts/install.sh` installing to `~/Applications`, stopping and
      relaunching a running instance
- [x] "Open at Login" menu item backed by `SMAppService.mainApp`
- [x] `dfui --login-item [status|enable|disable]` so the registration is
      testable without clicking a menu
- [x] Document that rebuilds require a reinstall
- [x] Verify registration end to end

### What the verification established

Registration works with an **ad-hoc signature** from **`~/Applications`** —
neither a Developer ID nor `/Applications` is required, and it lands in
`.enabled` rather than `.requiresApproval`, so there is no separate approval
step. macOS confirmed with its own "Login Item Added" notification.

The registration **survives replacing the bundle** (`rm -rf` + `cp -R`), so
`install.sh` does not need to re-register after an update.

BTM registrations are **not** visible in `launchctl list`; that lookup returns
nothing even when the item is enabled. Use `--login-item status` instead.

Not verifiable here: that it actually launches on boot. That needs a reboot.

## Follow-up: low-space warning (br-low-space-warning-u3c8slzu)

- [x] `pressure` on `DiskUsage`, thresholded at `lowSpaceFraction` = 5%
- [x] Red + bold + unit switch to GB below the threshold
- [x] Tooltip with precise figures
- [x] `--simulate-free-gb` to make the alarm state observable
- [x] Verified both states visually

### Why 5%

The user's ask: a fixed proportion landing near 100 GB on their 2 TB disk. 5%
gives 99.8 GB. That is comfortably above the few GB where macOS itself becomes
unstable, and above what a single cargo build can write, so the warning arrives
with room to act rather than as a postmortem.

Eventually worth making configurable; deliberately fixed for now.

### The free-space semantics question, settled

Measured on the user's machine: `statfs` f_bavail 969.6 GB vs
`volumeAvailableCapacityForImportantUsage` 969.7 GB — a 0.1 GB gap. They agree
because Time Machine has no destination configured, so there are no local
snapshots and nothing meaningful is purgeable.

The two numbers differ only by purgeable space. `statfs` is the conservative
one (what can be written right now); the Finder number is a promise that
depends on macOS reclaiming space under pressure, which happens late and under
exactly the write pressure you are trying to survive. For an alarm the
conservative number is correct, and it keeps `df -h /` a valid cross-check.
Decision: keep `statfs`, revisit only if Time Machine is ever enabled.

Also measured: `volumeAvailableCapacityForOpportunisticUsage` reads ~12 GB
below plain available — macOS's own estimate of the headroom it wants. A useful
sanity check that "the system is unhappy" starts well above zero bytes.

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
