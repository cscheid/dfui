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
open dist/dfui.app          # quit from the menu bar item's Quit entry
```

`swift run dfui` also works and puts an item in the menu bar, but the `.app`
bundle is the real target: `LSUIElement` in its Info.plist is what keeps the
Dock icon away.

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
| `Sources/selftest/` | assertions, including a cross-check against `df -k` |
| `scripts/build-app.sh` | builds and signs `dist/dfui.app` |
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
