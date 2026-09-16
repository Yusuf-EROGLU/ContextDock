# Known limitations

Honest list of what the first release does not (or cannot) do. Items marked *by design* follow
the specification; items marked *verify* need confirmation on a real Mac (see `TEST_REPORT.md`).

## Window discovery and identity

- **Session-only names.** A name/badge given to a window lives in memory for that window's lifetime
  and this ContextDock run. It is not restored after a relaunch. Persistent labelling works only
  through *project rules*, which apply after a window is verified (attached folder, Unity bridge or
  validated `-projectPath`). Title similarity is never used to restore a name. *(by design)*
- **Card order resets on relaunch.** Cards are ordered by first appearance in the current run.
  Drag-reordering is not implemented. *(by design)*
- **Windows on other Spaces / full screen.** Discovery relies on `kAXWindowsAttribute`. Most apps
  list windows on every Space; some do not, and full-screen windows may be reported differently.
  Windows that disappear from the list but still answer probes are kept with an "unlisted"
  flag rather than deleted. *(verify)*
- **Auxiliary windows.** Dialogs, floating tool windows and similar subroles are hidden unless
  *Show auxiliary windows* is on. Windows without a subrole are treated as standard windows so
  that custom toolkits (Unity) are not dropped. How Unity classifies its Inspector/Console/
  Project tool windows on your Editor version must be checked with *Details…*; adjust the
  toggle accordingly. *(verify)*
- **Untitled windows** are listed as "Untitled window". *(by design)*
- **Start time fallback.** If the kernel start time of a process cannot be read, ContextDock uses a
  per-run generation counter; PID reuse inside one scan interval (2.5 s) would then be undetectable.
  On macOS 26 the kernel start time is readable for user processes (tested).

## Focus switching

- **Cooperative activation.** macOS 14+ lets the target app or the system decline an activation.
  ContextDock uses `NSRunningApplication.activate(from:options:)`, `kAXRaiseAction`,
  `kAXMainAttribute`/`kAXFocusedWindowAttribute` and `kAXFrontmostAttribute`, then verifies the
  frontmost PID and the focused AX window. Unverified results are reported, not hidden. Apps with
  modal sheets or custom window handling may refuse to raise a specific window. *(verify)*
- **Different Space / Stage Manager.** Switching to a window on another Space or in another
  Stage Manager set is best effort through the public APIs above; macOS decides whether to switch
  Spaces. No private CGS/SkyLight calls, no synthetic input. *(verify)*
- **One retry only.** If the user activates a third app during the attempt, the request is aborted
  instead of stealing focus back. *(by design)*

## Ghostty

- **One card per window.** Tabs and splits are not separate cards; the card title follows whatever
  Ghostty reports as the window title. *(by design)*
- **Title precedence.** A fixed `title` in the Ghostty config or the shell-integration title
  feature can override the optional `CDOCK:v1` title. Manual card names always work regardless.
- **Structured titles are display-only.** Nothing from a title is treated as a path or executed.

## Unity

- **Bridge is optional and user-installed.** ContextDock never copies `ContextDockBridge.cs` into a
  project. The file (and its `.meta`) shows up in the project's version control.
- **Bridge start-time tolerance** is 2 s because Mono reports process start times at second
  precision; PID equality alone is never sufficient.
- **`-projectPath` reading** only works when Unity was launched with that argument (Unity Hub
  usually does); otherwise attach the folder manually. The value is validated as a Unity project
  before it is trusted and it never overrides a manual binding (a conflict note is shown instead).
- **Unity Hub** is a different application and is never treated as an Editor.
- Bridge C# was compiled against Unity 6000.0.58f1 assemblies with the Editor's Roslyn; it has
  not yet been exercised inside a running Editor. *(verify)*

## Git

- Runs only in user-attached or bridge-verified folders; never searches the disk.
- No dirty/untracked status in this release. *(by design)*
- `safe.directory`/dubious-ownership situations are reported as *no access*, not bypassed.
- Structure (worktree root, common dir) refreshes every 60 s, branches every 5 s while the bar is
  visible and every 30 s when hidden. Branch changes therefore appear within about one interval.

## Permissions, signing, distribution

- Ad-hoc signing means a rebuilt binary may need the Accessibility grant re-enabled. See README
  for the self-signed identity workaround. TCC is never reset or bypassed.
- App Sandbox is off (required for the Accessibility API and `KERN_PROCARGS2`).
- No auto-update, no App Store build, no launch-at-login in this release. *(by design)*

## Performance targets not yet measured

- Idle CPU (< 1 % target), notification latency (~1 s target) and fallback discovery (~3 s target)
  have not been measured on the real machine yet; see `TEST_REPORT.md`.
