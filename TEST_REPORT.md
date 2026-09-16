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
scripts/test.sh             # PASS — 84 tests in 16 suites, 0 failures (~1.3 s)
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

## Automated tests (84, all PASS)

| Suite | Covers |
|---|---|
| WindowTracker identity (8) | stable ids across scans and listing order, title change keeps id/sequence, identical titles stay distinct, failed scan → stale not removed, removal only after 2 missed scans + dead probe, not-responding probe keeps window, first-seen order, focus flag |
| ProcessInstanceKeyResolver (5) | same start → same key, PID reuse → new key + replaced report, generation fallback, launchDate fallback, real kernel start time readable |
| WindowFilter (5) | standard/missing/unknown subrole included, dialogs auxiliary, non-window roles excluded, matcher claims each element once |
| CardPresenter (6) | label priority (name > rule > project > title), rule needs trusted path, untitled label, git line variants (branch, detached, unborn, stale, not a repo, git missing, no access, unknown), structured title display, accessibility label |
| ContextResolver (5) | manual > bridge > args > structured > title, conflict note, unvalidated args ignored, git only on trusted paths, stale bridge |
| PathNormalizer and ContextKey (3) | trailing slash, NFC/NFD equality, symlink resolution, kind mismatch |
| StructuredTitleParser (4) | fields, version gate, control chars/oversize rejection, unknown keys |
| FocusService (7) | exact step order, unhide→unminimize→activate order, dead target refused, exactly one retry, abort on user switch, unverified fallback, raise failure |
| JSONStore (6) | round trip + atomic write, missing, corrupt preserved with defaults, newer schema read-only and untouched, service read-only/corrupt modes |
| GitOutputParsers (4) | `worktree list --porcelain -z`, failure classification, branch states, env scrubbing |
| GitService with temporary repositories (10) | real git: Unicode+space path, linked worktree (own branch, shared common dir, no cache bleed), detached HEAD, unborn branch, not a repo, missing folder, git missing, timeout keeps stale branch, runner timeout, runner output cap |
| SearchMatcher (4) | bar order on empty query, weighting + diacritics, subsequence fallback, multi-term |
| HotkeyConfig (3) | default ⌃⌥Space, Codable round trip + display, modifier requirement |
| Unity process arguments (4) | `KERN_PROCARGS2` layout parsing, `-projectPath` variants, reading own argv, Unity folder validation |
| Project rules in WindowStore (5) | rule needs verification (title similarity never matches), window name beats rule, kind mismatch, purge on PID reuse, process-instance scope |
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
| A09 | Unity main project + linked worktree | NOT_RUN (manual) | Automated: linked-worktree Git test. |
| A10 | Branch switched in a project | NOT_RUN (manual) | Automated: cache-per-worktree test. |
| A11 | Detached HEAD / no commits | NOT_RUN (manual) | Automated: Git tests. |
| A12 | Unicode + space paths | NOT_RUN (manual) | Automated: "Müzik Oyunu deneme" repo test. |
| A13 | Git missing / folder deleted / no access | NOT_RUN (manual) | Automated: gitMissing, missing folder, classification tests. |
| A14 | ContextDock relaunched | NOT_RUN | Rules persist via state.json (automated round trip); session names intentionally do not return. |
| A15 | Other Space / full screen / Stage Manager | NOT_RUN | Best effort; record real behaviour here. |
| A16 | External display removed | NOT_RUN | Relayout on `didChangeScreenParametersNotification` with fallback to the first screen. |
| A17 | AX or Git unresponsive | NOT_RUN (manual) | Automated: stale handling, runner timeout/cap tests. AX calls have 1 s messaging timeouts off the main thread. |
| A18 | Global shortcut conflict | NOT_RUN | `eventHotKeyExistsErr` → conflict message in Settings; menu item fallback. |
| A19 | Ghostty title fixed / overwritten | NOT_RUN | Manual names are independent of titles; README documents the config interaction. |
| A20 | Stale bridge / PID reused | NOT_RUN (manual) | Automated: bridge matching tests. |
| A21 | Corrupt settings file | NOT_RUN (manual) | Automated: JSONStore + PersistenceService tests; Settings shows the preserved file. |
| A22 | Typing right after clicking a card | **PASS** | User test 2026-09-16: keystrokes reach the target window. |
| M1 gate | Two Unity + two Ghostty windows: name each, switch to the right one | **PASS** | Reported by the user on 2026-09-16 after granting Accessibility to the `ContextDock Dev`-signed build. |

### How to run the M1 gate

1. `scripts/install-local.sh` then `open ~/Applications/ContextDock.app`.
2. Grant Accessibility (System Settings › Privacy & Security › Accessibility › ContextDock).
3. Open two Ghostty windows and two Unity Editor windows (different projects or one project with a
   linked worktree).
4. Confirm four separate cards. Rename each (right click › Rename…); confirm the name stays when
   the window title changes (e.g. `cd` in a terminal).
5. Click each card from another app and confirm the exact window comes to front (A03/A04/A05).
   Type immediately and confirm the keystrokes go to that window (A22).
6. Close one window and confirm its card disappears; its name does not reappear elsewhere (A07).
7. Attach the Unity project folders (A09) and check branch lines; switch a branch in one worktree
   and confirm only that card updates within ~5 s (A10).
8. Record PASS/FAIL per row above, including anything surprising about Unity tool windows.

## Performance

First measurement 2026-09-16 (9 cards, bar visible, idle): **~1.5 % CPU, 28 MB RSS** (`top -l 3 -s 10`).
Above the < 1 % target; planned fix: read window attributes only on notification and lengthen the
reconciliation scan for apps that deliver AX notifications reliably.

Earlier note: Targets from the spec: notified title
change ≈ 1 s, fallback discovery ≈ 3 s, idle CPU < 1 %. Reconciliation interval is 2.5 s while the
bar is visible and 10 s when hidden; AX notification debounce 150 ms; Git branch refresh 5 s / 30 s.
