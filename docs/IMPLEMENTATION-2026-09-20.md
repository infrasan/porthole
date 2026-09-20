# Porthole fixes and upgrades — 20 September 2026

The 11 findings in [the production audit](PRODUCTION-AUDIT-2026-09-19.md) have been addressed in code. This work also adds reviewed launch recipes, service protection, service/project pins, per-port controls, bounded panel layouts, local diagnostics, regression tests and release checks. Existing uncommitted work was preserved; a before-change source backup is in `.build/before-upgrades/`.

## Audit fixes

| Finding | Result | Evidence |
| --- | --- | --- |
| Stop protection could be bypassed | Stopper enforces blocked/system/protected-service checks before signals or manager actions; UI, bulk, accessibility and CLI use the same capabilities. Descendant traversal prunes boundaries. | Stopper/StopPlan regressions, protected manager tests, live sibling-survival test |
| Captured argv became shell code | LaunchSpec keeps executable, argument boundaries and original cwd; Launcher executes directly. Renamed titles and sensitive argv require review. Old command strings cannot execute. | Literal metacharacter/empty-argument launch, renamed-title and legacy-history tests |
| Health followed external redirects | HTTP stops at the first response, uses an ephemeral session without proxies/cookies, and only probes numeric loopback hosts. | Redirect target receives zero requests; redirect loops and HTTP 500 still count as answering |
| Docker inherited remote context | Every operation explicitly selects a recognized local Unix socket and removes Docker environment overrides. Container identity includes that daemon. | Remote endpoint rejection, environment filtering and structured container fixtures; live Docker actions not exercised |
| PID reuse could target a replacement | StopPlan compares pid/start against the refreshed table; signals recheck identity. | Refreshed-table replacement and live mismatched-start tests |
| IPv6/LAN binding health was wrong | Bind addresses survive scanning; IPv4/IPv6 loopback selection is explicit. LAN-only bindings show unavailable. | Real IPv6 HTTP/TCP and LAN-only fixtures |
| Served directory replaced launch cwd | Display/served directory stays separate from LaunchSpec.directory. | Relative `http.server --directory` regression |
| Docker port parsing was ambiguous | Structured TCP bindings replace display-text parsing; host addresses and container ports are retained. Ambiguous forwarders remain protected. Manager actions invalidate cached inventory. | UDP exclusion, IPv6/address, shared-port ambiguity and Redis recognition fixtures |
| Manager output could deadlock | CommandRunner drains both pipes while running, bounds retained output, times out and reaps uncooperative children, and supports cancellation. | Large stdout/stderr, truncation, ignored-SIGTERM and cancellation tests |
| Same-process orphan transitions were missed | Lifecycle comparison detects an existing identity becoming orphaned once; intentional stops are suppressed. | Identity transition regression |
| Failed restart disappeared or falsely succeeded | Launch state survives row disappearance. Success requires all expected ports and ownership by the launched process/descendants or the same managed service. Failure keeps recipe, error and log. | Real recipe start → restart → stop test, durable failed-launch test, unrelated-owner and multi-port checks |

Other fixes include inert snapshots with nonzero error exits, scan errors that retain the last valid inventory, PID/address/protocol-keyed health results, hotkey/login-item error reporting, sensitive command-label redaction, private file permissions and bounded log-file retention. CPU accounting remains saturating when children disappear.

Integration checks found and fixed three additional issues during this implementation:

- A packaged app cannot open its own bundle identifier as a UserDefaults suite; it now uses standard defaults while the CLI accesses the shared app domain.
- File-protection classes made newly saved history unreadable while the Mac was locked. Persistence now uses atomic writes with private directory/file permissions, which passed reload checks in the same session.
- CLI runtimes bundled inside apps/frameworks, including Xcode's Python, were classified as apps. They now remain dev-server jobs, while editors and agents remain process-tree boundaries.

## Using the upgrades

- **Protect / unprotect a service:** row context menu. Protected services cannot be stopped, force-quit or restarted, including through bulk and CLI actions.
- **Pin a service or project:** row or project menu. A project pin follows an available service in the project; its dot reports the selected endpoint, not aggregate project health.
- **Review launch recipe:** row menu or stopped-entry pencil. Supply an executable, one argument per line, the original working folder and expected ports. Recipes do not inherit the original shell environment or run login profiles.
- **Save/start project recipes:** project menu and saved-list group controls. Only runnable recipes can start; renamed commands need individual review first.
- **Per-port health/actions:** expanded details offer HTTP/HTTPS/TCP selection, Open, Copy and Pin. HTTPS certificate failures remain visible; verification is not bypassed.
- **Activity & diagnostics:** settings menu. The last 100 lifecycle events stay local; export is user initiated. `--json` provides the same redacted scan shape for local tooling.

The panel keeps the existing native visual style and typography. All inventory sections share a screen-bounded scroll area, keyboard selection scrolls into view, text fields keep their arrow keys, and motion respects Reduce Motion. Rendered light/dark and expanded multi-port snapshots were inspected; a native menu that ImageRenderer could not draw was replaced with a text equivalent in snapshot mode. Self-review: multi-port details remain dense, while project and safety controls live in menus to keep the scan list compact; native accessibility review remains necessary.

## Verification

Validated locally on Apple silicon, macOS 26.6.2, Swift 6.3.3, targeting macOS 14:

- **45 tests passed**, including disposable-process signaling, real recipe start/restart/stop, loopback HTTP/TCP fixtures, persistence and offscreen native layouts with 0, 1, 30 and 100 rows at 440/700-point heights.
- `scripts/verify.sh`: warning-free debug build and tests, valid local JSON, stable consecutive scans, light/dark/multi-port renders and a failing exit status for an invalid snapshot path.
- Latest recorded benchmark before final packaging: **7.32 ms full-scan CPU time for 1,002 processes; stable between scans: true**. This is a local observation, not a performance guarantee.
- Universal release compilation with warnings treated as errors; both `arm64` and `x86_64` slices are verified, and strict ad-hoc signature verification is required.
- `scripts/smoke-app.py` checks the actual packaged app for 10 seconds before the DMG is created. This caught the preferences crash that CLI-only checks missed.
- The corrected packaged app completed a **182.9-second final soak**, with **59 inventory checks and 19 disposable stop/relaunch cycles**. The sibling listener survived each stop. The final soak is recorded in `build/verification/soak/result.json`.

Build products: `build/Porthole.app` and `build/Porthole-0.1.0.dmg`. Version remains unchanged; no release was published. The DMG SHA-256 is `c9ca68b9d263e7ed8970898b4290aa05f46ca8b16c88dbc057009bb0213aa3c8`. Local evidence is in `build/verification/` and `.build/verify.log` / `.build/release-upgrade.log`; these are ignored build outputs.

## Remaining validation boundaries

The GitHub Actions workflow is configured but has not run remotely. It covers macOS 14, current macOS and an Intel runner, following the [hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners); action versions follow the official [checkout](https://github.com/actions/checkout) and [artifact upload](https://github.com/actions/upload-artifact) documentation. Uploaded artifacts are explicitly limited to synthetic demo screenshots. Real scans and logs are not uploaded.

Native UI automation timed out, so keyboard interaction, VoiceOver, multi-monitor placement and small-screen behavior have not been manually certified. Offscreen layout tests and screenshots do not replace those checks. Intel runtime behavior and macOS 14 runtime behavior still need their CI/device runs. Live Docker/OrbStack and Homebrew manager mutations were deliberately not used against existing services; their parsers, safety boundaries and shared command runner have fixture coverage.

The package is **ad-hoc signed**, not Developer ID signed or notarized. Gatekeeper distribution readiness is not claimed. No new dependencies, telemetry, cloud service or automatic updater were added.

Credential redaction is heuristic; inspect diagnostic files before sharing them. Launch logs are private and limited to the newest 40 files, but a running process's log is neither size-capped nor scrubbed. Startup readiness establishes port ownership, and HTTP health establishes that a response arrived; neither proves application-level correctness.
