# ContextDock Unity Editor bridge (optional)

The bridge lets ContextDock label a Unity Editor window with its **verified project path**
automatically, so the Git branch appears without attaching the folder by hand. It is
optional: without it, use *Attach Project Folder…* on the card.

## What it does

`ContextDockBridge.cs` is an Editor-only script. Every 5 seconds it writes a small JSON file:

```
~/Library/Application Support/ContextDock/Bridge/Unity/<pid>-<processStartUnixMs>.json
```

```json
{
  "schemaVersion": 1,
  "pid": 12345,
  "processStartedAtUnixMs": 1789458000123,
  "editorSessionId": "113f5b82-f932-4660-8231-7c805bb9d64a",
  "projectPath": "/Users/me/Worktrees/music-game-audio",
  "projectName": "music-game-audio",
  "unityVersion": "6000.0.58f1",
  "updatedAtUnixMs": 1789458005123
}
```

ContextDock matches the file to a running Editor by **PID and process start time** (2 s
tolerance, because Mono reports start times at second precision). A file older than 20 s is
shown as stale; a file whose PID now belongs to a different process is ignored, so a reused
PID never inherits an old project. Files older than a day are deleted by ContextDock.

The script reads no scene, asset or user data, opens no network port, and does nothing on
non-macOS platforms. Writes are atomic (temp file + replace). It stops when the Editor quits
and deletes its own file.

## Install

1. Copy `ContextDockBridge.cs` into `Assets/Editor/` of the project (create the folder if needed).
2. Let Unity compile. No further setup.

Unity creates a `ContextDockBridge.cs.meta` file next to it. **Both files show up as changes in
your version control.** Either commit them (the script is harmless for teammates; it only runs
on macOS Editors) or add them to your ignore file. ContextDock never copies this file into a
project itself.

Tested API surface: `InitializeOnLoad`, `EditorApplication.update`, `EditorApplication.quitting`,
`SessionState`, `Application.dataPath`, `JsonUtility`. These exist in Unity 2021.3 through
Unity 6; re-check on newer Editor versions.

## Uninstall

Delete `Assets/Editor/ContextDockBridge.cs` and its `.meta`. Optionally remove
`~/Library/Application Support/ContextDock/Bridge/Unity/`.

## Notes

- Domain reloads keep the same `editorSessionId` (stored in `SessionState`).
- If the bridge reports a project that differs from a folder you attached manually, ContextDock
  keeps your manual choice and shows a small note in the card tooltip and details.
- Unity Hub is not an Editor and is never matched.
