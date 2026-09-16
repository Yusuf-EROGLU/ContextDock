# ContextDock

ContextDock is a small native macOS taskbar for people who run several windows of the same
application at once, typically Unity Editor, Rider and Ghostty. Every **accessible top-level
window** gets its own card with the app icon, a name you choose and an optional badge and
color. Cards that belong to one task can be **stacked into a group** by drag and drop; one
click on the group brings all of its windows forward. Clicking a card switches to **that
window**, not just to the application.

It runs entirely on your Mac: no accounts, no network, no AI at runtime, no private APIs.

## Requirements

| Item | Value |
|---|---|
| macOS | 14.0 or later (developed and verified on macOS 26.6, Apple Silicon) |
| Xcode | 26.3 (Swift 6.2.4). Older Xcode 16 may work but is untested. |
| xcodegen | 2.46 (optional; only needed after editing `project.yml`) |
| Permission | **Accessibility** (System Settings › Privacy & Security › Accessibility) |

No third-party runtime dependencies. The app is not sandboxed (see *Security notes*).

## Build

```bash
scripts/build.sh            # Debug build into .build/DerivedData
scripts/build.sh Release
scripts/test.sh             # automated tests (Swift Testing)
```

Equivalent raw commands:

```bash
xcodebuild -project ContextDock.xcodeproj -scheme ContextDock -configuration Debug \
  -derivedDataPath .build/DerivedData build
xcodebuild -project ContextDock.xcodeproj -scheme ContextDock -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData test
```

The Xcode project is generated from `project.yml` with xcodegen and committed; `scripts/build.sh`
regenerates it automatically when `project.yml` is newer and xcodegen is installed.

## Install locally

```bash
scripts/install-local.sh    # builds Release and copies to ~/Applications/ContextDock.app
open ~/Applications/ContextDock.app
```

The script refuses to replace a running ContextDock, never touches other apps, and never
changes permissions.

### Accessibility permission

On first launch ContextDock explains why it needs Accessibility access and offers **Request
Access**. Enable *ContextDock* in System Settings › Privacy & Security › Accessibility. The
system prompt is asynchronous; ContextDock re-checks on its own and via **Check Again**.

Without the permission the menu bar item and Settings still work, and the bar shows the
permission state instead of any windows. If the permission is removed while running, discovery
pauses and the bar says so.

**Signing and re-granting.** Without a signing identity the build is ad-hoc signed. macOS ties
the Accessibility grant to the signed code, so a *rebuilt* ad-hoc app loses the grant; remove and
re-add ContextDock in the Accessibility list (or `tccutil reset Accessibility
com.yusuferoglu.ContextDock`) to grant it again. For a stable grant, create a self-signed
code-signing certificate named `ContextDock Dev` (Keychain Access › Certificate Assistant ›
Create a Certificate, type *Code Signing*, or the OpenSSL + `security import` route). The build
scripts pick that identity up automatically; `CODE_SIGN_IDENTITY` overrides it.

## Usage

- **Bar**: bottom-center of the chosen display, one card per window, ordered by first
  appearance. Scrolls horizontally when there are many cards. Hover, active window and keyboard
  selection have distinct looks. The full title and project path are in the tooltip.
- **Left click**: switch to that window (unhides/unminimizes first if needed). If the switch cannot
  be verified you get a short message in the bar, never a dialog.
- **Drag and drop**: drag a card onto the middle of another card to **stack them into a group**;
  drag onto the left or right edge of a card to **reorder**. Drag a member icon out of a group
  (or use *Remove from Group*) to detach it. Groups with one member dissolve automatically.
- **Group card**: shows member app icons plus a name (yours, or "Unity + Ghostty"). Clicking the
  card raises every member in order and focuses the one you used last; clicking a member icon
  switches to that window only. Right click: *Open All Windows*, the member list, *Rename Group…*,
  *Badge & Color…*, *Ungroup*.
- **Right click on a window card**: *Rename…*, *Badge & Color…*, *Add to Group* / *Remove from
  Group*, *Reset Customization*, *Details…*.
- **Session scope**: names, badges, colors, groups and card order live as long as the windows and
  ContextDock run. Window identities cannot be restored reliably after a relaunch, so nothing is
  guessed back from titles.
- **Search**: `Control + Option + Space` (changeable in Settings, with conflict detection) or
  *Search Windows…* in the menu. Type to filter by name, app, title or group; arrows move, Return
  switches (a group entry opens the whole group), Escape closes, `⌘1`–`⌘9` jump to the first nine
  results.
- **Menu bar item**: Hide/Show Bar, Refresh, Search Windows…, Accessibility status, Settings…, Quit.
- **Settings**: display, bottom margin, shortcut, show auxiliary windows (dialogs/tool windows),
  verbose logging, reset all names/badges/groups.

### Optional integrations

- **Unity Editor bridge** (`Integrations/Unity/`): a user-installed Editor script that reports
  the project name so a Unity card shows which project it is without renaming it.
- **Ghostty labels** (`Integrations/Ghostty/`): a zsh snippet with `contextdock_label "Backend"`
  that names a terminal via its window title.

Both are optional, documented in their own READMEs, and never installed automatically.

## Data and privacy

- Settings (currently the search shortcut): `~/Library/Application Support/ContextDock/state.json`
  (versioned JSON, written atomically; a corrupt file is preserved as `state.json.corrupt-<timestamp>`;
  a file from a newer version is never overwritten). Simple preferences use `UserDefaults`.
- Unity bridge heartbeats: `~/Library/Application Support/ContextDock/Bridge/Unity/`.
- Session names, badges and groups live in memory and are gone when the window closes or ContextDock quits.
- Only window titles and metadata are read, never window contents, terminal output or
  keystrokes. Logs hide titles and paths unless *Verbose debug logging* is on. No telemetry.
- ContextDock runs no subprocesses and reads no files outside its own support directory.

## Security notes

- App Sandbox is **off** for this first release because the Accessibility API does not work from
  a sandboxed app. This is not a way around TCC: the user
  must still grant Accessibility access explicitly.
- Required permission: Accessibility only. No screen recording, full disk access, Automation,
  input monitoring or root.
- The global shortcut uses Carbon `RegisterEventHotKey`, which delivers only the registered
  combination. There is no key logging or event tap.

## Uninstall

Quit ContextDock, delete `~/Applications/ContextDock.app`, optionally delete
`~/Library/Application Support/ContextDock/` and remove ContextDock from the Accessibility list.
Remove the Unity/Ghostty integration files if you installed them.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Bar shows "Accessibility permission required" although you granted it | The grant belongs to a previous build. Toggle ContextDock off/on in the Accessibility list (see *Signing*). |
| A window is missing | Auxiliary windows (dialogs, floating tool windows) are hidden by default; enable *Show auxiliary windows*. Some apps do not expose windows on other Spaces. Use Details… to see role/subrole. |
| Click activates the app but not the window | The app rejected the raise (modal sheet, unsupported attribute). ContextDock shows a message; try again once the dialog is closed. |
| A drag does not start | Move at least 5 pt before releasing; a short press is a click. Drop on the middle of a card to group, on its edge to reorder. |
| Shortcut does not work | Settings shows a conflict message if another app owns it; pick another combination. The menu item always works. |
| Names or groups disappear after relaunch | Names, badges and groups are session-only by design; window identities cannot be restored safely across launches. |

See `KNOWN_LIMITATIONS.md` and `TEST_REPORT.md` for verified behaviour and open limitations.
