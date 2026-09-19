# Porthole

A menu bar app for macOS that shows every dev server running on your Mac, who started it, and lets you stop it.

Coding agents start servers and leave them running. After a week you have a Next.js app on 3000, three `http.server`s from some session you don't remember, and a Vite server whose terminal closed days ago. Porthole shows all of them, says which agent or terminal started each one, flags the orphans, and stops them cleanly.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img src="docs/screenshot-light.png" width="400" alt="Porthole's menu bar panel listing dev servers by port, each tagged with the agent that started it">
</picture>

## What it does

- **Lists every listening port you own**, grouped into servers: one row for Firebase emulators, not nine.
- **Says who started each one**: Claude Code, Codex, Gemini CLI, Kimi, OpenCode, Grok, Cursor, Copilot CLI, Amp, Aider and more, or which terminal or editor you ran it from.
- **Still knows after the agent is gone.** Agents leave markers in the environment of everything they run (`CLAUDECODE=1`, `CODEX_THREAD_ID`, `GEMINI_CLI=1`…), and those survive after the agent exits. That's how an orphaned server still gets a name.
- **Flags orphans**: servers whose terminal, agent or app no longer exists. One click stops them all.
- **Stops the whole job, like Ctrl-C would.** Stop on a Next.js row ends `npm run dev`, `next dev` and `next-server` together, so nothing respawns.
- **Knows the special cases.** `brew services` get `brew services stop` instead of a kill that launchd would undo. macOS's AirPlay Receiver on port 5000 comes with instructions for turning it off.
- **Shows what's reachable from your network**, with the LAN address for opening it on your phone.

It's a 3 MB native app. No Electron, no network access, no telemetry.

## Install

Download the DMG from [Releases](../../releases), open it and drag Porthole to Applications.

If the build isn't notarized yet, macOS will refuse to open it the first time. Open System Settings › Privacy & Security, scroll down and click **Open Anyway**.

Requires macOS 14 or later.

## Build from source

Open `Porthole.xcodeproj` in Xcode 16 or later and press ⌘R.

Or from the terminal:

```bash
git clone https://github.com/infrasan/porthole.git && cd porthole
scripts/build.sh
open build/Porthole.app
```

`scripts/build.sh` builds a universal (Apple silicon and Intel) app and a DMG in `build/` with SwiftPM, no Xcode project needed.

## How it works

Porthole reads the process table and every process's sockets through `sysctl` and `libproc`, the same kernel interfaces `ps` and `lsof` use, without launching either. A full scan takes about 5 ms. It runs every 5 seconds in the background and every 2 seconds while the panel is open.

### Who started it

For each server, Porthole checks in this order:

1. **The live process tree.** It walks up from the server, and the first agent, editor or terminal it meets is the answer.
2. **Environment markers.** If the parent is gone, it looks for the variables agents set on commands they run:

   | Agent | Marker |
   | --- | --- |
   | Claude Code | `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT` |
   | Codex | `CODEX_THREAD_ID`, `CODEX_SANDBOX`, `CODEX_MANAGED_BY_NPM` |
   | Gemini CLI | `GEMINI_CLI` |
   | OpenCode | `OPENCODE_CLIENT` |
   | Kimi | `KIMI_SESSION_ID` |
   | Grok | `GROK_SESSION_ID` |
   | Cursor Agent | `CURSOR_AGENT` |
   | Any agent | `AI_AGENT` |

3. **launchd.** `brew services` and other launchd jobs.
4. **The app it was launched from**, from `__CFBundleIdentifier` and `TERM_PROGRAM`.

Click a row to see the evidence for each answer.

### What Stop does

1. Walks up from the server through launchers that exist only for it (`npm run`, `npx`, `sh -c`) so the whole job ends. It never climbs into a shell you're typing in, a terminal, an editor or an agent.
2. Sends SIGINT to the job, like Ctrl-C. Processes started in the background with `&` ignore SIGINT, so they get SIGTERM straight away.
3. Sends SIGTERM to anything still running after 4 seconds, and SIGKILL after 2 more.

Before each signal it checks the process's start time, so a reused PID never gets signaled. Option-click Stop, or use **Force quit**, to send SIGKILL right away.

## Privacy

Everything stays on your Mac. Porthole makes no network requests.

To identify agents it reads the environment of your own processes, the same way `ps -E` does. Only the variable names listed in [`Catalog.swift`](Sources/Porthole/Catalog.swift) are kept. Everything else, API keys included, is discarded while parsing and never stored or displayed.

## Adding an agent

Agents, editors and terminals are one table in [`Sources/Porthole/Catalog.swift`](Sources/Porthole/Catalog.swift). Add an entry with the executable name and any environment variable the agent sets on commands it runs:

```swift
OwnerDef(id: "my-agent", name: "My Agent", kind: .agent, color: 0x7B61FF,
         executables: ["my-agent"], envKeys: ["MY_AGENT_SESSION"]),
```

Frameworks work the same way in [`Frameworks.swift`](Sources/Porthole/Frameworks.swift).

## Developer flags

```bash
.build/debug/Porthole --dump                  # print the scan as text
.build/debug/Porthole --stop 5173             # stop whatever is on a port
.build/debug/Porthole --snapshot out.png      # render the panel to an image
.build/debug/Porthole --snapshot out.png --demo --dark --expand 5173
```

`--demo` renders made-up servers, so screenshots don't publish your project names.

## Releasing

1. Bump **Version** (`MARKETING_VERSION`) in the project's General tab.
2. In Signing & Capabilities, choose your team.
3. Product › Archive, then Distribute App › **Direct Distribution**. Xcode signs the app with your Developer ID certificate (creating it if needed) and has Apple notarize it.
4. Export the app and wrap it in a DMG:

   ```bash
   scripts/make-dmg.sh ~/Desktop/Porthole/Porthole.app
   ```

5. Attach `build/Porthole-<version>.dmg` to a GitHub release.

Without Xcode, `scripts/build.sh` can sign and notarize too. Store notarization credentials once, then pass your identity:

```bash
xcrun notarytool store-credentials porthole --apple-id you@example.com --team-id TEAMID
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=porthole VERSION=0.1.0 scripts/build.sh
```

## License

MIT
