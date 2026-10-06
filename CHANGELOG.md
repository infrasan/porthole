# Changelog

## Unreleased

### Fixed

- Only one Porthole runs per user. Launching it again — from another copy, a second login item, `open -n` or a debug build — opens the running copy's panel instead of adding a second menu bar icon that doubled scans and probes, lost the ⌃⌥P shortcut and overwrote saved recents. Reopening the running app from Finder or Spotlight also shows the panel.
- Servers started or restarted from Porthole are attributed to Porthole instead of being flagged as orphaned with an unknown owner, so they no longer trigger orphan notifications, the menu bar badge or **Stop orphaned**.
- Apps and system listeners no longer offer **Pin in menu bar**; such a pin could never be matched and showed the port as not listening.

## 0.2.0 — 2026-09-20

### Added

- Live loopback health checks with per-port HTTP, HTTPS and TCP selection.
- Reviewed launch recipes, saved project starts, restart progress, retry and log access.
- Persistent service protection and service/project pins.
- Local activity and diagnostics, optional lifecycle notifications and CLI JSON export.
- Global Control-Option-P shortcut, keyboard navigation and searchable saved/recent services.
- Screen-bounded scrolling for large inventories and expanded details.
- A horizontal Porthole logo asset in `docs/branding/`; the app icon remains unchanged.
- Regression coverage, multi-version macOS CI, packaged-app startup checks and a disposable-process soak harness.

### Fixed

- Stop, force quit and restart enforce protection in the execution layer, including bulk and CLI actions. Process identities are rechecked before signals, and protected process-tree boundaries are pruned.
- Restarts execute exact executable/argument/working-directory specifications without turning captured command text into shell code. Legacy command strings require review.
- Health probes refuse redirects, preserve IPv4/IPv6 bindings and stay on loopback. Stale probe results cannot migrate to a different process on the same port.
- Docker operations use explicit local daemons and structured TCP bindings; ambiguous shared forwarders remain protected.
- Manager subprocesses drain output without deadlock and have bounded output, timeouts and cancellation.
- Failed launches remain visible. Startup succeeds only when the launched job owns every expected port.
- Orphan transitions, scan errors, packaged-app preferences and CLI runtimes inside app bundles are handled correctly.
- Snapshots are inert and report failures through their exit status. Saved state and launch logs use private permissions.

### Upgrade notes

Requires macOS 14 or later; universal Apple silicon and Intel app. Quit the old instance before replacing it in Applications, then reopen Porthole. Existing preferences are retained. Saved legacy command text cannot execute until its recipe is reviewed. Launches do not inherit shell profiles or the original process environment.

## 0.1.0 — 2026-09-19

Initial release: native menu bar inventory, agent and terminal attribution, orphan detection, safe job stopping, project grouping and special handling for system/Homebrew services.
