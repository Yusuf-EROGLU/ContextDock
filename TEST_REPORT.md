# Test report

Status legend: **PASS** verified as described · **FAIL** · **NOT_RUN** not executed yet (needs a
person at the Mac, usually because the Accessibility grant is a user action).

## Environment

| Item | Value |
|---|---|
| Date | 2026-09-16 |
| Machine | Apple Silicon Mac, macOS 26.6.2 (25G83) |
| Xcode / Swift | Xcode 26.3 (17C529), Swift 6.2.4, SDK MacOSX26.2 |
| Deployment target | macOS 14.0 |
| xcodegen | 2.46.0 |
| git | 2.50.1 (Apple Git-155) |
| Ghostty | 1.3.1 (`com.mitchellh.ghostty`) |
| Unity | Editors 2021.3–6000.3 via Unity Hub (`com.unity3d.UnityEditor5.x`) |
| Signing | ad-hoc until 2026-09-16 15:30, then self-signed identity `ContextDock Dev` (stable TCC grant); sandbox off |

## Commands

```bash
scripts/build.sh            # Debug build — PASS (BUILD SUCCEEDED, no warnings)
scripts/build.sh Release    # PASS (BUILD SUCCEEDED; ad-hoc signature, identifier com.yusuferoglu.ContextDock)
scripts/test.sh             # PASS — 67 tests in 13 suites, 0 failures (~0.1 s) after the grouping pivot
```

Unity bridge compile check (not part of the Xcode build):

```bash
"$U/NetCoreRuntime/dotnet" exec "$U/DotNetSdkRoslyn/csc.dll" -target:library \
  -define:UNITY_EDITOR -define:UNITY_EDITOR_OSX -nostdlib \
  -r:"$U/NetStandard/ref/2.1.0/netstandard.dll" -r:"$U/Managed/UnityEngine/UnityEngine.CoreModule.dll" \
  -r:"$U/Managed/UnityEngine/UnityEditor.CoreModule.dll" -r:"$U/Managed/UnityEngine/UnityEngine.JSONSerializeModule.dll" \
  Integrations/Unity/ContextDockBridge.cs     # U=/Applications/Unity/Hub/Editor/6000.0.58f1/Unity.app/Contents — PASS
zsh -n Integrations/Ghostty/contextdock.zsh   # PASS; label with '|', '=', ESC and ünïcode encoded as expected
```

## Automated tests (67, all PASS)

| Suite | Covers |
|---|---|
| WindowTracker identity (8) | stable ids across scans and listing order, title change keeps id/sequence, identical titles stay distinct, failed scan → stale not removed, removal only after 2 missed scans + dead probe, not-responding probe keeps window, first-seen order, focus flag |
| ProcessInstanceKeyResolver (5) | same start → same key, PID reuse → new key + replaced report, generation fallback, launchDate fallback, real kernel start time readable |
| WindowFilter (5) | standard/missing/unknown subrole included, dialogs auxiliary, non-window roles excluded, matcher claims each element once |
| CardPresenter (6) | label priority (name > structured label > project > title), untitled label, stale subtitle, badge/color, group title/subtitle, accessibility label |
| ContextResolver (2) | bridge > structured title > plain title, stale bridge |
| PathNormalizer and ContextKey (3) | trailing slash, NFC/NFD equality, symlink resolution, kind mismatch |
| StructuredTitleParser (4) | fields, version gate, control chars/oversize rejection, unknown keys |
| FocusService (7) | exact step order, unhide→unminimize→activate order, dead target refused, exactly one retry, abort on user switch, unverified fallback, raise failure |
| JSONStore (6) | hotkey round trip + atomic write, missing, corrupt preserved with defaults, newer schema read-only and untouched, service read-only/corrupt modes |
| SearchMatcher (4) | bar order on empty query, weighting + diacritics, subsequence fallback, multi-term |
| HotkeyConfig (3) | default ⌃⌥Space, Codable round trip + display, modifier requirement |
| BarArrangement (9) | first-seen order and removal, stack creates/extends groups in place, no-op stacking, dissolve at one member, remove-from-group and ungroup placement, move/reorder pulls out of groups, group merge, group onto window, focus target |
| Unity bridge matching (5) | pid + start tolerance, PID reuse ignored, stale flag, newest report wins, parser/size/purge rules |

## Manual acceptance matrix (spec §15.2)

| ID | Scenario | Status | Notes |
|---|---|---|---|
| A01 | Accessibility not granted | **PASS** | Launched the Debug build without the grant: permission window and the bar's "Accessibility permission required" state appeared (confirmed via the CoreGraphics window list), no crash, no fake windows. |
| A02 | Permission granted later / revoked | **PASS** (grant) | Granting while running started discovery without a relaunch (2026-09-16). Revoke path NOT_RUN. |
| A03 | Same app, different PIDs | **PASS** | User test 2026-09-16: two Unity Editors shown as separate cards, each switches to its own window. |
| A04 | Two Ghostty windows under one PID | **PASS** | User test 2026-09-16. |
| A05 | Two windows with identical titles | **PASS** | User test 2026-09-16 (M1 gate); automated: WindowTracker/ProjectRule tests. |
| A06 | Title changes keep name and order | **PASS** | User test 2026-09-16; automated: WindowTracker title tests. |
| A07 | Action on a closed window's card | **PASS** | User test 2026-09-16: card removed, name not migrated. A crash on app quit found during this test was fixed (AX refcon lifetime, commit 37623f2). |
| A08 | Hidden app / minimized window | **PASS** | User test 2026-09-16. |
| A09 | Unity main project + linked worktree | N/A | Folder binding and Git display removed 2026-09-16 (replaced by groups). |
| A10 | Branch switched in a project | N/A | Removed with the Git feature. |
| A11 | Detached HEAD / no commits | N/A | Removed with the Git feature. |
| A12 | Unicode + space paths | N/A | No paths are processed any more (bridge project path is display-only). |
| A13 | Git missing / folder deleted / no access | N/A | Removed with the Git feature. |
| A14 | ContextDock relaunched | NOT_RUN | Shortcut persists via state.json (automated round trip); names, badges and groups intentionally do not return. |
| A15 | Other Space / full screen / Stage Manager | NOT_RUN | Best effort; record real behaviour here. |
| A16 | External display removed | NOT_RUN | Relayout on `didChangeScreenParametersNotification` with fallback to the first screen. |
| A17 | AX or Git unresponsive | NOT_RUN (manual) | Automated: stale handling, runner timeout/cap tests. AX calls have 1 s messaging timeouts off the main thread. |
| A18 | Global shortcut conflict | NOT_RUN | `eventHotKeyExistsErr` → conflict message in Settings; menu item fallback. |
| A19 | Ghostty title fixed / overwritten | NOT_RUN | Manual names are independent of titles; README documents the config interaction. |
| A20 | Stale bridge / PID reused | NOT_RUN (manual) | Automated: bridge matching tests. |
| A21 | Corrupt settings file | NOT_RUN (manual) | Automated: JSONStore + PersistenceService tests; Settings shows the preserved file. |
| A22 | Typing right after clicking a card | **PASS** | User test 2026-09-16: keystrokes reach the target window. |
| G01 | Drag a card onto another → group card with both icons; drag onto edge → reorder | NOT_RUN | Added 2026-09-16 with the grouping feature. |
| G02 | Click group → all members forward, last-used member focused; click member icon → only that window | NOT_RUN | |
| G03 | Remove from group / ungroup / group dissolves when a member closes | NOT_RUN | Automated: BarArrangement tests. |
| G04 | Group in search (⌃⌥Space) opens all members | NOT_RUN | |
| M1 gate | Two Unity + two Ghostty windows: name each, switch to the right one | **PASS** | Reported by the user on 2026-09-16 after granting Accessibility to the `ContextDock Dev`-signed build. |

### How to test grouping (G01–G04)

1. Drag a Ghostty card onto the middle of a Unity card: a group card appears in the Unity card's
   slot with both icons. Drag a Rider card onto the group to add it.
2. Click the group's empty area from another app: all three windows come forward and the last one
   you used is focused. Click one member icon: only that window comes forward.
3. Right click the group: rename it, give it a badge, use *Remove from Group* on a member, then
   *Ungroup*. Close one of two remaining members: the group dissolves into a plain card.
4. Drag a card onto the left/right edge of another: a blue insertion line shows and the card moves.
5. Press ⌃⌥Space, type the group name, press Return: the whole group opens.

## Performance

Measured 2026-09-16 on the Release build (`top -l 2 -s 20/30/60`, machine in normal use, so the
numbers include real title changes and app switches):

| State | Before | After |
|---|---|---|
| Bar visible, idle-ish | ~0.9–1.5 % CPU, ~500 mach msgs/s, ~700 context switches/s | ~0.6–0.7 % CPU, ~250–300 mach msgs/s, ~230 context switches/s |
| Bar hidden | not measured | ~0.3 % CPU, ~140 mach msgs/s |
| Memory | 28 MB RSS | 28 MB RSS |

What changed: one AX call per window instead of five; notification-backed apps re-scanned every
10 s instead of 2.5 s (frontmost app and apps without an observer still every 2.5 s); trust check
every 10 s; and the card strip no longer forces a SwiftUI measurement inside `layout()`, which had
kept AppKit laying out at display refresh rate. Remaining cost is dominated by real events (title
changes from terminals, app switches) and the 2.5 s scan of the frontmost app. The < 1 % target is
met in these conditions; a fully idle measurement (no user activity) is still to be recorded.

Spec targets: notified title change ≈ 1 s (debounce 100 ms + AX read); fallback discovery ≈ 3 s for
apps without notifications (2.5 s scan); idle CPU < 1 %.
