# AGENTS.md

Porthole is a native macOS 14+ menu bar app that lists every dev server on the Mac, says who started it (which AI agent, terminal, or app), checks that it answers, and stops or restarts it cleanly. No Electron, no telemetry, no network requests beyond loopback health probes.

## Commands

```bash
swift build -Xswiftc -warnings-as-errors  # debug build
swift test -Xswiftc -warnings-as-errors   # regression and disposable-process tests
scripts/verify.sh                    # builds, tests, stability, inert snapshots
scripts/build.sh                     # universal release .app + DMG; startup smoke gate
python3 scripts/soak.py               # three-minute live soak with disposable loopback jobs
.build/debug/Porthole --dump         # print the scan as text (attribution sanity check)
.build/debug/Porthole --bench        # scan timing; must stay "stable between scans: true"
.build/debug/Porthole --snapshot out.png --demo --dark   # render the panel to an image
PORTHOLE_OPEN_PANEL=1 /path/to/Porthole.app/Contents/MacOS/Porthole   # DEBUG-only: open the panel at launch for screenshot tests
```

Regression tests live in `Tests/PortholeTests/`. Verification is the commands above plus a live run; process tests must only signal jobs they created. Never ship a change that fails `--bench`'s stability check or crashes a live soak.

## Architecture

SwiftPM executable, no third-party dependencies, app target in `Sources/Porthole/` plus a regression test target.

- `Sys.swift` — thin wrappers over `sysctl`/`libproc`: process table, listening TCP sockets per pid, argv+env, cwd, memory, CPU. Everything only works for the current user's processes.
- `Scanner.swift` — turns the process table into server groups; owns the boundary rules and the detail/docker/cpu caches.
- `Attribution.swift` — `makeServer` builds a `DevServer`: classification, owner attribution, project naming, grouping, docker split. `makeDockerServers` turns port forwarders into per-container rows.
- `Catalog.swift` — the table of known agents/editors/terminals and their env markers. Adding support for a new agent = one entry here.
- `Frameworks.swift` — command-line tokens → framework name/color (`Frameworks.detect`).
- `Stopper.swift` — SIGINT→SIGTERM→SIGKILL escalation for plain processes; `docker stop/kill/restart` for containers; `brew services` for Homebrew. Rechecks pid+start-time before every signal.
- `Health.swift` — loopback probes: HTTP HEAD for web servers (any response = up), TCP connect for the rest.
- `Store.swift` — `@MainActor` state hub: scan timer, health/notification fan-out, restart/start/recents, service/project pins, protection, reviewed recipes, editor/terminal openers.
- `LaunchSpec.swift` / `Launcher.swift` — exact executable, argv and original cwd; direct exec with a minimal environment, private logs and retention. Never rebuild shell syntax from a display string.
- `CommandRunner.swift` — bounded subprocess output, concurrent pipe draining, timeout and cancellation for managers.
- `Docker.swift` — explicit local Unix-socket daemon identities and structured TCP bindings; no active-context inheritance.
- `Lifecycle.swift` / `Diagnostics.swift` — identity-aware startup readiness, local activity and redacted opt-in exports.
- `History.swift` — the Recently stopped list, persisted as JSON in `~/Library/Application Support/Porthole/`.
- `App.swift` — `AppDelegate` + custom `NSStatusItem`/`NSPanel` (PanelController), menu bar icon states, `Snapshot` renderer.
- `Views/` — `PanelView` (header/filters/list/recents/others/footer + keyboard nav), `ServerRow` (+details, +context menu), `Components` (icon, buttons, chips, formats).
- `DemoData.swift` — fake servers/health/recents for `--demo` snapshots. Keep it current when the UI changes.

## Invariants — do not break these

1. **Process identity is pid + start time.** Pids get reused; the pair doesn't. Every cache key, row id, and signal target uses it. Docker rows use local-daemon plus container identity because containers share their forwarder's pid. Persistent preferences use `serviceID`, never a PID or a bare port.
2. **Never unsigned-subtract CPU or memory totals.** A child dying between scans lowers the tree's sum; plain `UInt64` subtraction underflows and *traps the whole app*. This exact crash (SIGTRAP in `cpuPercent`) shipped once — use the saturating pattern already there.
3. **Never signal a Docker/OrbStack port forwarder** — it would cut networking for every container. Containers are stopped via the docker CLI; an unmatched forwarder row must keep Stop disabled (`stopDisabledReason`).
4. **No `hidesOnDeactivate` on the panel.** When the app is activated from the background (hotkey), it isn't genuinely frontmost, and the flag hides the panel instantly. Closing is explicit: `applicationDidResignActive` + resign-key check, keeping the panel open while its own menus/alerts hold key status.
5. **The panel is a custom NSPanel, not MenuBarExtra.** MenuBarExtra can't be opened programmatically, which the ⌃⌥P hotkey (Carbon `RegisterEventHotKey`, no Accessibility permission) requires. Panel height follows `NSHostingController.preferredContentSize` via KVO — don't reintroduce GeometryReader measuring; it races the layout.
6. **Env parsing keeps only `Catalog.envKeysOfInterest`.** Everything else (API keys included) is discarded mid-parse. Never widen the set casually, never store full environments.
7. **Probes are loopback-only and panel-gated.** All servers probe while the panel is open; in the background only the selected port of the pinned service is probed, so Porthole never spams a dev server's request log.
8. **Stop never climbs into a shell, terminal, editor, agent, or Porthole's own ancestry** (`Scanner.isBoundary`). `sh -c "…"` wrappers are walked through; interactive shells are not.
9. **Snapshot mode is inert.** `Store(startTimer: false)` sets `live = false`: no probes, no notifications, no history writes. Keep it that way — screenshots must never touch user state.

10. **Protection is enforced at execution.** `Stopper.refusal` runs before every stop/restart manager action. Bulk, accessibility and CLI paths must not bypass it.
11. **Launch success requires ownership.** Every expected port must belong to the launched pid/start or its descendant, or the same managed service. Preserve failed recipes and logs.
12. **Probes never follow redirects.** Only numeric loopback addresses; HTTPS verifies certificates, and health keys include process identity, address, port and protocol.

## Adding things

- **New agent/terminal/editor**: one `OwnerDef` in `Catalog.swift` (see README § Adding an agent).
- **New framework**: one `Def` in `Frameworks.swift`; the first matching token wins, so specific tools go before runtimes.
- **New DevServer field**: update `makeServer`, `makeDockerServers`, and `DemoData` together, or snapshots and `--dump` lie.
