# Known limitations

Honest list of what the first release does not (or cannot) do. Items marked *by design* follow
the specification; items marked *verify* need confirmation on a real Mac (see `TEST_REPORT.md`).

## Window discovery and identity

- **Session-only names and groups.** Names, badges, colors, groups and manual card order live in
  memory for this ContextDock run and die with the window or the app. Nothing is restored after a
  relaunch, and title similarity is never used to guess a window's identity. *(by design, chosen by
  the user on 2026-09-16 over a "remember and re-match" mode)*
- **Group open is sequential.** Opening a group raises members one by one through the target apps'
  activation; with many members this takes a few hundred milliseconds and macOS may decline an
  activation. The focus target is verified; the other members are raised best effort. *(verify)*
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
- **Unity Hub** is a different application and is never treated as an Editor.
- Bridge C# was compiled against Unity 6000.0.58f1 assemblies with the Editor's Roslyn; it has
  not yet been exercised inside a running Editor. *(verify)*

## Removed on purpose

- **Project folder binding and Git branch display** were built (M2) and then removed on
  2026-09-16 at the user's request: the context of a window is the set of windows it works with,
  expressed as a group, not a directory. The Unity bridge still shows the project *name*; the
  Ghostty structured title can still carry a branch string as display-only text.

## Permissions, signing, distribution

- Ad-hoc signing means a rebuilt binary may need the Accessibility grant re-enabled. See README
  for the self-signed identity workaround. TCC is never reset or bypassed.
- App Sandbox is off (required for the Accessibility API).
- No auto-update, no App Store build, no launch-at-login in this release. *(by design)*

## Performance targets not yet measured

- Idle CPU (< 1 % target), notification latency (~1 s target) and fallback discovery (~3 s target)
  have not been measured on the real machine yet; see `TEST_REPORT.md`.
