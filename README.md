# ContextDock

ContextDock is a small native macOS taskbar for people who run several windows of the same
application at once, typically Unity Editor and Ghostty. Every **accessible top-level window**
gets its own card with the app icon, a name you choose, an optional badge and color, and the
Git branch of the project folder you attach. Clicking a card switches to **that window**, not
just to the application.

It runs entirely on your Mac: no accounts, no network, no AI at runtime, no private APIs.

## Requirements

| Item | Value |
|---|---|
| macOS | 14.0 or later (developed and verified on macOS 26.6, Apple Silicon) |
| Xcode | 26.3 (Swift 6.2.4). Older Xcode 16 may work but is untested. |
| xcodegen | 2.46 (optional; only needed after editing `project.yml`) |
| git | any recent git for the branch feature (Homebrew, Command Line Tools or Xcode) |
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
- **Right click** (or Control-click): *Rename…*, *Badge & Color…*, *Attach Project Folder…*,
  *Reset Customization*, *Details…*.
- **Rename scope**: *This window only* lives as long as the window and ContextDock run.
  *Remember for this project* is available once a project folder is attached and verified; it
  saves a project rule that is applied to every window verified to belong to that project (a
  window-level name still wins).
- **Attach Project Folder…**: choose the folder; Unity projects are recognized by their `Assets/`
  and `ProjectSettings/` folders (a warning is shown otherwise). For Unity you can apply the
  folder to this window or to all windows of that Unity process. The card then shows
  `folder · branch`, `detached · abc1234`, `branch · no commits`, or an explicit `not a Git
  repository` / `Git not found` / `no access` state. Stale values are marked `(stale)`.
- **Search**: `Control + Option + Space` (changeable in Settings, with conflict detection) or
  *Search Windows…* in the menu. Type to filter by name, app, title, project or branch; arrows
  move, Return switches, Escape closes, `⌘1`–`⌘9` jump to the first nine results.
- **Menu bar item**: Hide/Show Bar, Refresh, Search Windows…, Accessibility status, Settings…, Quit.
- **Settings**: display, bottom margin, show auxiliary windows (dialogs/tool windows), Unity
  `-projectPath` reading, saved project rules (delete individually), verbose logging, reset.

### Optional integrations

- **Unity Editor bridge** (`Integrations/Unity/`): a user-installed Editor script that reports
  the verified project path so branches appear without attaching folders by hand.
- **Ghostty labels** (`Integrations/Ghostty/`): a zsh snippet with `contextdock_label "Backend"`
  that names a terminal via its window title.

Both are optional, documented in their own READMEs, and never installed automatically.

## Data and privacy

- Settings and project rules: `~/Library/Application Support/ContextDock/state.json` (versioned
  JSON, written atomically; a corrupt file is preserved as `state.json.corrupt-<timestamp>`; a
  file from a newer version is never overwritten). Simple preferences use `UserDefaults`.
- Unity bridge heartbeats: `~/Library/Application Support/ContextDock/Bridge/Unity/`.
- Session names/badges live in memory and are gone when the window closes or ContextDock quits.
- Only window titles and metadata are read, never window contents, terminal output or
  keystrokes. Logs hide titles and paths unless *Verbose debug logging* is on. No telemetry.
- Git runs only in folders you attached (or the bridge verified), with an environment scrubbed of
  `GIT_DIR`-style variables, no prompts, a timeout and an output cap.

## Security notes

- App Sandbox is **off** for this first release because the Accessibility API and reading other
  processes' arguments do not work from a sandboxed app. This is not a way around TCC: the user
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
| Branch says `Git not found` | Install git (Homebrew or Xcode Command Line Tools). ContextDock avoids the `/usr/bin/git` stub when no tools are installed. |
| Shortcut does not work | Settings shows a conflict message if another app owns it; pick another combination. The menu item always works. |
| Names disappear after relaunch | Window names are session-only by design. Use *Remember for this project* for persistent rules. |

See `KNOWN_LIMITATIONS.md` and `TEST_REPORT.md` for verified behaviour and open limitations.
