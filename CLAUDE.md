# dfui

A macOS menu bar app showing free disk space on the volume holding `/`, as
`free/total` in decimal TB (e.g. `0.35/2TB`). Personal tool — not distributed,
not App Store bound. It exists because parallel LLM agent sessions writing Rust
accumulate cargo `target/` directories worth hundreds of GB.

## Build and run

```sh
swift build                 # library + executables
swift run selftest          # the test suite (see below)
./scripts/build-app.sh      # -> dist/dfui.app, ad-hoc signed
./scripts/install.sh        # -> ~/Applications/dfui.app (the real install)
```

`swift run dfui` also works and puts an item in the menu bar, but the `.app`
bundle is the real target: `LSUIElement` in its Info.plist is what keeps the
Dock icon away.

### ⚠️ Rebuilding does not update the installed app

`~/Applications/dfui.app` is a **copy**. `swift build` and `build-app.sh` only
touch `.build/` and `dist/` — the running menu bar item keeps executing the old
code until you re-run `./scripts/install.sh`.

This bites in a specific way: you change something, rebuild, look at the menu
bar, and conclude your change didn't work. It did; you're looking at the
previous install. **Any change you want to actually see must be followed by
`./scripts/install.sh`.**

This is not hypothetical — it cost a debugging cycle during the single-instance
work. `dist/` had the new code and `~/Applications` still had the old, so the
feature worked in one direction and appeared broken in the other. If behaviour
differs depending on *which copy* you launch, suspect a stale install before
suspecting the code.

The script handles the awkward parts: it quits the installed copy before
overwriting the bundle, and relaunches it afterwards if it had been running, so
a reinstall doesn't silently leave your menu bar empty.

## The low-space warning

Below `lowSpaceFraction` (5% — ~100 GB on a 2 TB disk) the indicator changes in
three redundant ways at once: **red**, **bold**, and a **unit switch** from the
TB ratio to plain GB (`0.11/2TB` → `98GB`).

The unit switch is the part that is easy to mistake for a flourish, so: in TB,
the entire danger zone collapses into leading zeros. `0.020/2TB` and
`0.0020/2TB` are a 10x difference in how much trouble you are in, distinguished
only by counting decimal places in an 11px menu bar font. Below the threshold
the denominator has stopped carrying information — you know how big your disk
is — and the absolute number is what matters. Not relying on color alone also
means the warning survives a colorblind reader or a bad monitor.

Inspect the warning without filling the disk:

```sh
swift run dfui --simulate-free-gb 50    # red, bold, "50GB"
swift run dfui --simulate-free-gb 110   # normal, "0.11/2TB"
```

Keep that flag working. An alarm nobody has ever seen fire is an alarm nobody
should trust, and the real condition is expensive to reproduce.

## Single instance

On launch, `SingleInstance.terminateOthers()` quits already-running copies with
the same bundle identifier, before adding our own status item. Policy is
**newest wins** — you launched it, you get it — which matches `install.sh`.

Two deliberate limits:

- **Unbundled instances are exempt.** `swift run dfui` has no bundle
  identifier, and matching nil-against-nil would match every unbundled process
  on the system. When probing this, `NSWorkspace` reported 16 node processes
  with a nil bundle identifier — a naive match would have terminated all of
  them. So an unbundled dev instance and the installed app *can* both sit in
  the menu bar. That is the safe failure.
- **Ordering falls back to process identifiers**, because
  `NSRunningApplication.current.launchDate` is nil for a directly exec'd
  process. See the comment on `supersedes` for the residual race.

## Login item

"Open at Login" in the menu drives `SMAppService.mainApp`, which registers with
Background Task Management. Notes worth keeping:

- It registers **the bundle at its current path**, which is why the app should
  be installed to `~/Applications` rather than run out of `dist/` in the working
  tree. A login item pointing into a build directory breaks the first time that
  directory is cleaned.
- Verified working with an **ad-hoc signature** from `~/Applications` — it needs
  neither a Developer ID nor `/Applications`, and registers as `.enabled`
  without a separate approval step.
- The registration **survives a reinstall** (`rm -rf` + `cp -R` of the bundle),
  so `install.sh` does not need to re-register.
- It does **not** appear in `launchctl list` — BTM registrations aren't user
  launchd agents. Check status with `dfui --login-item status`, or in System
  Settings › General › Login Items & Extensions.

```sh
~/Applications/dfui.app/Contents/MacOS/dfui --login-item status
~/Applications/dfui.app/Contents/MacOS/dfui --login-item enable
~/Applications/dfui.app/Contents/MacOS/dfui --login-item disable
```

That CLI exists mostly so the login item is testable without clicking a menu —
`SMAppService` state is otherwise hard to inspect from a script.

## Toolchain constraints — read before adding tests or Xcode-isms

This machine has **Command Line Tools only, no Xcode** (`xcode-select -p` →
`/Library/Developer/CommandLineTools`; there is no `xcodebuild`). Two
consequences:

- **No `swift test`.** Neither swift-testing nor XCTest ships with the CLT, so
  a `.testTarget` will not build. Tests live in `Sources/selftest`, a plain
  executable with a small assertion harness, run via `swift run selftest`. Add
  new checks there. (Strand `br-swift-testing-smyvlq7o` tracks migrating if
  Xcode ever arrives.)
- **No Xcode project.** AppKit compiles fine against the CLT SDK, so the app is
  a SwiftPM executable plus a hand-assembled bundle in `scripts/build-app.sh`.
  Keep it that way unless there's a reason not to.

## Layout

| path | what |
|---|---|
| `Sources/DiskStats/` | `statfs(2)` reader and the number formatting — all the logic worth testing |
| `Sources/dfui/` | `NSStatusItem` wiring; deliberately thin |
| `Sources/dfui/LoginItem.swift` | `SMAppService` wrapper behind a small state enum |
| `Sources/selftest/` | assertions, including a cross-check against `df -k` |
| `scripts/build-app.sh` | builds and signs `dist/dfui.app` |
| `scripts/install.sh` | copies that bundle to `~/Applications`, restarting it |
| `resources/Info.plist` | bundle metadata; `LSUIElement` lives here |

## Conventions

- Free space comes from `statfs`'s `f_bavail`, matching `df`'s "Avail" column
  rather than Finder's more optimistic purgeable-inclusive number. This is a
  deliberate choice under review — see strand `br-free-space-semantics-ogn2huun`.
- Sizes are decimal TB (10^12), not TiB.
- Keep display logic in `DiskStats` as pure functions so `selftest` can reach
  it; `Sources/dfui/` should stay close to pure AppKit glue.

## **WORK TRACKING**

We use **braid** for issue tracking instead of Markdown TODOs or external tools.
braid stores all issues for the project in a **skein** (a single
[automerge](https://automerge.org) CRDT document); a single issue is a
**strand**. The skein — synced through a sync server — is the **source of
truth**. There is no git involvement and no `.beads/`-style JSONL to commit:
edits converge through the CRDT, not through merge tooling. (We migrated off
beads_rust on 2026-06-08; see `claude-notes/plans/2026-06-08-braid-migration.md`.)

**`braid` is non-invasive and never executes git commands.** Unlike the old
`br sync --flush-only; git add .beads/` dance, there is **nothing to commit**
after issue work — the skein syncs itself. (A `.braid/snapshot.jsonl` backup
*is* committed periodically, but it is **backup-only and one-directional** —
see the snapshot policy below. Never `braid import` it back.)

For the authoritative, version-matched command guide, run `braid agents-info`
(or invoke the `/braid` skill). The quick reference below is a convenience
summary, not the contract.

We use plans for additional context and bookkeeping. Write plans to
`claude-notes/plans/YYYY-MM-DD-<description>.md`, and reference the plan file
in the strands.

### File Structure
Plan files should include:

1. **Overview**: Brief description of the plan's goals and context
2. **Checklist**: A markdown checklist of all work items using `- [ ]` syntax
3. **Details**: Additional context, design decisions, or implementation notes as needed

### Maintaining Progress
As you work through a plan:

1. **Update the plan file** after completing each work item
2. **Check off items** by changing `- [ ]` to `- [x]`
3. **Keep the plan file current** - it serves as both a roadmap and progress tracker
4. **Add new items** if you discover additional work during implementation

### Excerpt from a simple Plan File

```markdown
...

## Work Items

- [x] Review current runtime service implementations
- [x] Identify common patterns
- [ ] Update StandalonePlatform to use shared base
- [ ] Update tests
- [ ] Update documentation
```

### When to Use Plan Files

Create plan files for:
- Multi-step features spanning multiple packages
- Complex refactoring that requires coordination
- Tasks where tracking progress helps ensure nothing is missed

Complex plans can have phases, and work items are then split into multiple lists, one for each phase.

For simple tasks (single file changes, bug fixes), the TodoWrite tool is sufficient.
