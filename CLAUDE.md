# Bar

A macOS taskbar + lightweight tiling window manager. Personal project, one user (the author).

## Layout

- `Bar/` — main AppKit/SwiftUI app. Runs as a menu-bar `.accessory` (no Dock icon). A borderless taskbar window floats at the bottom of each non-fullscreen Space.
- `CLIHost/` — `bar` CLI (`main.swift`). Sends commands to the running app via `DistributedNotificationCenter` under the `com.bar.cli.*` namespace.
- `NativeMessagingHost/` — Firefox/Chrome native messaging host that pipes favicons into the app over a Unix socket.
- `FirefoxExtension/` — browser extension that feeds favicons to the host above.
- `Bar.xcodeproj` — single scheme `Bar`, targets `Bar` / `BarTests` / `BarUITests`. Signed with Apple Development (Personal Team, `U33G93KH8Y`).

## Key source files

- `BarApp.swift` — `AppDelegate`: status-bar item, permission gate, space reconciliation loop, CLI notification observers.
- `ContentView.swift` — the taskbar SwiftUI view + window buttons (drag-to-reorder, key hints).
- `WindowManager.swift` — window list, activation, close/minimize, auto-tiling to fullscreen on new windows.
- `WindowTiling.swift` — split-screen grouping math.
- `SpaceManager.swift` — uses private CGS/SLS APIs to track the active Space.
- `KeyboardSwitcher.swift` + `KeyAssignmentManager.swift` — `cmd`-based modal switcher (see README).
- `PrivateAPIs.swift` — declarations for the private Core Graphics / SkyLight symbols.
- `NativeDesktopBridge.swift` — socket server the native messaging host connects to.

## Build / run

One-shot: `./install.sh` at repo root. It builds Release with signing, kills any running Bar, copies to `/Applications/Bar.app`, installs the `bar` CLI to `~/.local/bin/bar`, and relaunches.

Direct build only:
```
xcodebuild -project Bar.xcodeproj -scheme Bar -configuration Release \
  -derivedDataPath build build
```

The app is at `build/Build/Products/Release/Bar.app` after a build.

## Signing / TCC

Signed with a stable Apple Development identity so Accessibility/Screen-Recording grants persist across rebuilds. If you see the permission prompt again after a rebuild, either the cert rotated or the bundle id / team id changed — check with `codesign -dvv /Applications/Bar.app`.

Do NOT switch to ad-hoc signing (`-`) for installed builds — cdhash changes every build and TCC drops the permission each time.

## Permissions required at runtime

Accessibility (AX APIs — reading window info, moving/resizing) and Input Monitoring (global `cmd` listener for the switcher). Screen Recording is sometimes needed for window titles on newer macOS. `PermissionGateView` handles the first-run flow.

## CLI

Installed as `~/.local/bin/bar`. Subcommands:
- `bar fullscreen` — tile the focused window.
- `bar name-window <name>` or `bar name-window <id> <name>` — rename a window in the taskbar.

CLI ↔ app is fire-and-forget via `DistributedNotificationCenter`; the app must already be running.

## Status bar menu

The menu-bar icon (from `BarApp.swift` `setupStatusBarItem`) has: Restart Bar, Settings…, Launch at Login (toggle), Quit. Restart spawns a detached `sh -c 'sleep 0.5 && open -n <bundle>'` then terminates.

## Known-broken areas (from README)

- Multi-screen has rough edges.
- Browser popup windows (Firefox/Chrome extension windows) sometimes get resized by the tiler.
- Occasionally fails to create a taskbar for a new Space; workaround is to move windows to a fresh Space and delete the old one.
