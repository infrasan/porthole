# Porthole production audit and upgrade plan

> Implementation follow-up: [fixes, upgrades and validation](IMPLEMENTATION-2026-09-20.md). The findings below describe the pre-fix audit.

Reviewed 19 September 2026. Baseline: working tree at `f426998`, including the existing modified and untracked Swift files. This is an audit of the current files, not just the committed revision. Application source was not changed.

**Assessment: keep the native architecture, but hold a public release until the four P1 findings below are fixed.** The app builds, packages and scans quickly. The main risks are in the new control paths: deciding what may be stopped, reconstructing launch commands, and keeping probes and Docker operations local.

P1 means fix before release. P2 means a concrete correctness or reliability defect to address next. “Reproduced” describes a disposable local fixture; “source-confirmed” describes a reachable code path whose full external scenario was not exercised.

## Verification performed

| Check | Result and limit |
| --- | --- |
| `swift build` | Passed without compiler warnings after allowing access to the normal compiler caches. The initial sandbox failure was an environment restriction. |
| `--bench` | `stable between scans: true`; process table 0.89 ms CPU, socket scan 3.63 ms, full scan 4.20 ms across 919 processes. This is one machine/load, not a universal performance guarantee. |
| `--dump` | Detected the running Homebrew PostgreSQL service and macOS listeners; brew attribution was correct in this sample. |
| `scripts/build.sh` | Passed with Developer ID and notarization variables explicitly removed. Generated a 2.1 MB DMG. |
| Architecture/signature | Binary contains `x86_64 arm64`; local ad-hoc signature passes `codesign --verify --deep --strict`. Developer ID signing/notarization was not tested. |
| Demo snapshots | Light and dark/expanded screenshots rendered and were visually inspected. Snapshot mode bypasses live scrolling, so it cannot validate live panel sizing. |
| Scanner soak | 60 scans with memory/CPU sampling across roughly 30 seconds; no crash. |
| Release smoke test | Newly built menu bar app remained alive for 45 seconds, then the test instance was terminated. This is not a long-duration soak. |
| Focused fixtures | Reproduced disabled-stop bypass, shell reinterpretation, redirect following, redirect-loop false negative, IPv6 false negatives, Docker parser errors and wrong relaunch directory. |

Fixtures compiled the current Scanner, Stopper, Health, Docker and model sources into an isolated harness. The stop test targeted only a newly created `sleep` child. HTTP fixtures listened only on loopback. No existing dev server, database or Docker container was stopped.

Native UI automation timed out. Hotkey behavior, keyboard navigation, VoiceOver, multi-monitor placement and long-session UI stability remain unverified. Runtime verification was on macOS 26.6.2; macOS 14 and Intel execution remain unverified despite the universal build. No live Docker daemon or Homebrew stop/restart operation was exercised.

## Release blockers

### 1. [P1] Enforce stop protection below the UI

**Evidence:** [Stopper.swift:16](../Sources/Porthole/Stopper.swift#L16), [Store.swift:265](../Sources/Porthole/Store.swift#L265), [Scanner.swift:94](../Sources/Porthole/Scanner.swift#L94), [PanelView.swift:413](../Sources/Porthole/Views/PanelView.swift#L413), [ServerRow.swift:74](../Sources/Porthole/Views/ServerRow.swift#L74).

Unmatched Docker forwarders have `stopDisabledReason`, but all Docker rows are inserted into `result.servers`, including unmatched tool rows. The individual button respects `canStop`; bulk “Stop all,” the accessibility Stop action and the CLI do not. Neither `Store.stop` nor `Stopper.stop` rejects the protected row. That path can signal a shared forwarder and interrupt networking for every container.

**Reproduced:** a fixture with `canStop=false` returned `stopped(forced: true)` and its disposable child exited from SIGKILL (`-9`). No real forwarder was signaled.

**Fix:** reject protected targets at the first line of the execution layer for both normal and forced stop. Filter bulk actions to eligible targets and report how many will stop. Apply the same capability policy to accessibility and CLI entry points. Recheck that a direct signal target is not a recognized forwarder; UI visibility must not be the safety mechanism.

### 2. [P1] Never turn captured argv into executable shell syntax

**Evidence:** [Scanner.swift:23](../Sources/Porthole/Scanner.swift#L23), [Attribution.swift:44](../Sources/Porthole/Attribution.swift#L44), [Launcher.swift:35](../Sources/Porthole/Launcher.swift#L35).

`ProcDetail.command` removes empty arguments and joins everything with spaces. The result is later interpolated into `exec <command>` and passed to a login shell. Literal spaces, quotes, dollar signs and shell operators become syntax. Ordinary directory names can break restart; an argument containing a shell substitution can execute an additional command. Process titles also are not necessarily executable launch specifications.

**Reproduced:** the current command serialization plus the same `exec` shell expression changed one argument `two words` into two arguments. A literal `$(/usr/bin/touch <temporary marker>)` argument created the marker. The fixture used `zsh -f` to avoid executing user login configuration; it did not call Launcher or write application logs.

**Fix:** separate display text from a typed launch specification containing executable, argv and launch cwd. Pass arguments as data. If a login environment is needed, obtain it through a narrowly defined mechanism rather than interpolating captured arguments into shell code. Disable automatic restart when only a renamed process title or incomplete command is available; offer a user-reviewed launch recipe.

### 3. [P1] Stop HTTP redirects at the first response

**Evidence:** [Health.swift:23](../Sources/Porthole/Health.swift#L23), [Health.swift:53](../Sources/Porthole/Health.swift#L53).

The initial URL is loopback, but the default URLSession follows redirects and has no redirect delegate. A local dev server redirecting to an external login/canonical URL therefore takes the probe outside the app's promised loopback boundary. It also measures the redirect destination rather than the local listener.

**Reproduced:** a local 302 caused a second fixture server to receive `/redirect-followed`. An answering server that redirects to itself was reported `down`. Off-machine requests were deliberately not used; the external-destination risk follows from the unrestricted redirect path.

**Fix:** refuse every redirect and count the first HTTP response, including 3xx, as answering. Disable proxy use for these local probes, use a total probe deadline, and tie completion to the current endpoint identity. Apple's delegate supports returning `nil` to refuse the redirect: [URLSession redirection API](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:)).

### 4. [P1] Bind Docker operations to a verified local daemon

**Evidence:** [Docker.swift:49](../Sources/Porthole/Docker.swift#L49), [Docker.swift:86](../Sources/Porthole/Docker.swift#L86), [Attribution.swift:110](../Sources/Porthole/Attribution.swift#L110).

Docker commands use the active context and inherited environment. There is no endpoint validation or explicit local host/context. If the active context is remote, scanning contacts that daemon. A remote container publishing the same port as a local forwarder can be labeled as the local server; clicking Stop then targets the remote container. Discovery and later actions can also resolve different contexts if the user switches context between them.

**Source-confirmed; no remote daemon was contacted.** Docker documents that commands use the active context unless overridden, including by `DOCKER_HOST` or `DOCKER_CONTEXT`: [Docker contexts](https://docs.docker.com/engine/manage-resources/contexts/).

**Fix:** resolve an allowlisted local Unix socket for the detected runtime, make it explicit for every invocation, and remove conflicting Docker endpoint environment overrides. Keep daemon identity with the container ID in rows and recents. If the runtime cannot be established safely, show an unavailable/protected row and the reason.

## Correctness and production reliability

### 5. [P2] Revalidate the selected identity after refreshing the process table

**Evidence:** [Stopper.swift:24](../Sources/Porthole/Stopper.swift#L24).

The selected `(pid, start)` is checked before loading a fresh table. If that PID exits and is reused between those steps, the fresh table supplies the replacement process's start time to `targets`. Later `isAlive` checks then correctly validate the wrong identity. The original row identity is never compared to the refreshed table entry.

**Source-confirmed race; not triggered live.** Compare the refreshed root entry against `server.start` before constructing the job. Validate the root relationship before climbing. Add an injected process-table test for replacement between the initial check and refresh. This closes this specific widening of the race; it does not make separate kernel lookup/signal calls atomic.

### 6. [P2] Preserve bind addresses and address families for health

**Evidence:** [Sys.swift:124](../Sources/Porthole/Sys.swift#L124), [Attribution.swift:22](../Sources/Porthole/Attribution.swift#L22), [Health.swift:54](../Sources/Porthole/Health.swift#L54), [Health.swift:74](../Sources/Porthole/Health.swift#L74).

Sys reads IPv4/IPv6 addresses, but attribution collapses them into port plus exposure. HTTP and TCP probes always use `127.0.0.1`. An IPv6-only listener on `::1`, or a listener bound to another loopback address, appears broken. A listener bound only to a LAN interface cannot be tested through loopback and should not be described as hung.

**Reproduced:** a server on `::1` returned HTTP 204 to a direct IPv6 request; both Porthole HTTP and TCP probes reported `down`.

**Fix:** model endpoints as address, family, transport and port. Select a compatible loopback endpoint; report “not probeable through loopback” for LAN-only bindings. Use endpoint identity plus process/container identity for health results, rather than just the integer port. Do not bypass the local-only policy to make the health dot green.

### 7. [P2] Separate launch cwd from the directory being served

**Evidence:** [Attribution.swift:33](../Sources/Porthole/Attribution.swift#L33), [Attribution.swift:294](../Sources/Porthole/Attribution.swift#L294), [Store.swift:307](../Sources/Porthole/Store.swift#L307), [History.swift:27](../Sources/Porthole/History.swift#L27).

The row's `cwd` is a served directory, but restart uses it as the original launch directory. For `python -m http.server --directory site`, launched in `/project`, the stored cwd becomes `/project/site`; replay now serves `/project/site/site`. The top launcher and listening child can also have different working directories.

**Reproduced:** a Homebrew Python fixture launched in a temporary parent folder was captured with cwd ending in `/site` while its relaunch command still contained `--directory site`.

**Fix:** keep `launchCWD` from the process supplying the command and a separate `servedDirectory` for display. Carry both through history. Also represent restart confidence: discarded environment variables, virtual environments and shell initialization can make replay incomplete. Do not solve this by collecting all process environments.

### 8. [P2] Match Docker bindings structurally, including protocol and host IP

**Evidence:** [Docker.swift:70](../Sources/Porthole/Docker.swift#L70), [Docker.swift:89](../Sources/Porthole/Docker.swift#L89), [Attribution.swift:110](../Sources/Porthole/Attribution.swift#L110).

The regex parses the human-readable `.Ports` field and merges TCP and UDP into a set of port numbers. Port ranges are lost, and host addresses disappear. A UDP container can therefore claim a TCP listener with the same number; separate bindings on different host addresses are also ambiguous. This can associate a Stop action with the wrong container.

**Reproduced parser output:**

```text
127.0.0.1:8000-8002->8000-8002/tcp => []
127.0.0.1:8000-8002->80/tcp        => [8002]
127.0.0.1:9000->9000/udp          => [9000]
```

**Fix:** consume structured binding data from the verified local daemon. Keep host IP, TCP/UDP, host port and container port; match only compatible TCP endpoints. Reject ambiguous ownership and deduplicate container rows across multiple forwarders. Test standard database images too: `redis:7` becomes token `redis`, but the current detector recognizes `redis-server`; the demo supplies Redis manually and conceals that mismatch.

### 9. [P2] Drain subprocess output while the subprocess is running

**Evidence:** [Stopper.swift:120](../Sources/Porthole/Stopper.swift#L120), [Docker.swift:54](../Sources/Porthole/Docker.swift#L54).

Both runners wait for process termination before reading output. A child that fills its pipe blocks writing and cannot terminate. The brew runner has no deadline, so the operation can remain pending indefinitely. Docker eventually times out, discards stderr, and sends SIGTERM without ensuring the child exits, making diagnosis and cleanup unreliable.

**Source-confirmed; pipe saturation was not reproduced with the user's managers.** Introduce one bounded asynchronous runner that drains stdout/stderr concurrently, limits retained output, has a deadline and cancellation, terminates then reaps timed-out children, and returns useful stderr. Exercise it with a fixture producing more than pipe capacity and a fixture ignoring SIGTERM.

### 10. [P2] Notify when an existing server becomes orphaned

**Evidence:** [Store.swift:170](../Sources/Porthole/Store.swift#L170).

Orphan notifications only inspect rows whose IDs are new. The normal event is that a terminal/agent exits while the same server PID and start time keep running. The server becomes orphaned with an unchanged ID, so “Notify about orphans” never reports that transition.

**Source-confirmed.** Diff `isOrphaned` for matching identities, notify once on false → true, and test startup baseline suppression and repeated scans.

### 11. [P2] Keep failed restarts visible until recovered or dismissed

**Evidence:** [Launcher.swift:41](../Sources/Porthole/Launcher.swift#L41), [Store.swift:301](../Sources/Porthole/Store.swift#L301), [Store.swift:120](../Sources/Porthole/Store.swift#L120), [Store.swift:345](../Sources/Porthole/Store.swift#L345).

`Process.run()` only confirms that a shell launched. A command that immediately fails can still make Restart appear successful. The old row is removed without entering recents or keeping its log URL. Synchronous failure messages are attached to the now-dead row and removed on refresh. The separate recent-start flow relies on fixed sleeps and accepts any process on the old port as success.

**Source-confirmed.** Represent launch operations separately from scan rows: starting → listening/responding → failed/exited. Preserve a retryable recipe and log link even after the old process disappears. Track the launched process and its descendants; do not treat an unrelated port occupant as successful startup. Use an observable deadline, not a fixed 2.5-second assumption.

## Additional gaps worth addressing

- **Panel height and navigation:** only the main list scrolls, capped at 470 points; recents and all other listeners add unbounded height. `PanelController` constrains only horizontal placement. Large inventories can push the footer below the display. Arrow selection has no scroll-to-selection behavior. Cap total height to the current screen and make every selected row reachable. These are source-level findings; dense live layouts were not exercised.
- **Stop tree boundaries:** `descendants(of:)` does not consult `isBoundary`; it excludes Porthole's ancestry but can include nested shells/editors/agents or forwarders. Define a separate safe signal traversal, rather than assuming every descendant is eligible. Test protected descendants and respawning workers.
- **Health result lifetime:** health and probe cadence are keyed by port; in-flight results can overwrite state for a different server that reused the port. Secondary ports have no independent status, and only the smallest port is probed. Add identity/generation checks and clear stale work on inventory changes.
- **Snapshot purity and failure reporting:** `Store(startTimer:false)` still constructs `History()`, whose default path creates a real Application Support directory. Snapshot writes also swallow errors and print “Wrote” unconditionally. Inject an in-memory history/defaults implementation and return a nonzero status when rendering or writing fails.
- **Diagnostics and permissions:** an empty process table and a failed scan are indistinguishable, which can falsely show “No dev servers” and emit stopped notifications. Surface scan errors and retain the previous valid inventory. Report hotkey registration/login-item errors in the UI instead of silently failing.
- **Sensitive command text and logs:** environment filtering is a good boundary, but argv can still contain tokens/passwords and is persisted in recents. Use redacted display/export text and a safe recipe policy for sensitive commands. Set private storage permissions, rotate logs, use unique log filenames, and surface persistence errors.
- **Release automation:** there is no test target or CI workflow. `--bench` prints instability without failing the process, so a naive CI command can pass an unstable scan. CLI stop failures similarly do not set a failing exit status. Make checks machine-verifiable and keep compiler warnings fatal in the release gate.

## Recommended upgrade sequence

| Order | Work | User benefit | Completion criterion |
| --- | --- | --- | --- |
| 1 — release safety | Fix P1 findings 1–4; add the refreshed-identity check and protected-descendant tests. | Stop affects only eligible local targets; restart cannot reinterpret arguments. | UI, CLI, bulk and accessibility actions all use the same tested execution policy. |
| 2 — trustworthy operations | Typed launch recipes, separate launch/served directories, bounded process runner, durable launch-operation state and logs. | A failed restart is understandable and recoverable. | Quoted paths, empty args, dead commands, slow boot, occupied ports and manager timeouts produce correct visible outcomes. |
| 3 — endpoint accuracy | Structured bindings; IPv4/IPv6; explicit HTTP/TCP/HTTPS capability; per-port health and identity-aware results. | Users can trust health and select the right URL for multi-port jobs. | IPv6-only, mixed-protocol and multi-port fixtures pass; unknown protocols do not automatically imply HTTP. |
| 4 — daily workflow | Pin a project/service identity, protect important services from bulk stop, remember reviewed project launch recipes, offer per-port actions. | Fewer accidental actions and less repeated terminal work. | Protection survives restarts; project Start reports each service's readiness; conflicting ports explain the owner before any stop. |
| 5 — panel polish | Screen-bounded panel, keyboard auto-scroll, searchable recents, clear scanning/empty/failure states, accessible restart/log actions. | Large inventories remain fast to operate on laptops and with a keyboard. | Test 0, 1, 30 and 100 rows, six recents, expanded details, VoiceOver and multiple screen sizes. |
| 6 — local troubleshooting | JSON scan export, opt-in diagnostic bundle, small local lifecycle history, scan/probe timing in diagnostics. | Better bug reports and agent integration without telemetry. | Exports redact sensitive command fields and never include full environments. |

Keep SwiftPM, AppKit/SwiftUI, the custom panel, dependency-free scanning, pid-plus-start identities and the environment allowlist. The highest-value upgrade is making the existing promises dependable; a wholesale rewrite or cloud service would add risk without solving these findings.

## Suggested implementation boundaries and release gate

Introduce small types and interfaces rather than a framework rewrite:

- `ProcessIdentity` and a testable `StopPlan` separate safe target selection from signal execution.
- `LaunchSpec` stores executable, argv, launch cwd and provenance; display strings stay separate.
- `Endpoint` and `DockerIdentity` retain address/protocol and daemon/container identity.
- A bounded command runner handles both brew and Docker.
- Scanner, signal sender, command runner and health transport accept injectable dependencies so race/error scenarios can be tested without touching user services.

Add focused regression coverage for the findings above, then gate a release on warning-free debug/release builds, nonzero failure statuses, stable scan fixtures, demo renders, live scan/stop/restart smoke tests against disposable jobs, and a substantially longer soak with process churn. Validate macOS 14 plus current macOS and Intel plus Apple silicon. Verify Developer ID signing, notarization and Gatekeeper separately; the ad-hoc package produced during this audit does not establish distribution readiness.

Temporary audit evidence is in `.build/audit/`: `AuditHarness.swift`, `run-fixtures.py`, `fixture-results.json`, the two demo PNGs and `live-soak.log`. These are ignored build artifacts and may be removed by a clean; the findings and observed outputs are preserved in this report.
