// ContextDock Unity Editor bridge (optional).
//
// Copy this file into your project's Assets/Editor/ folder. It writes a small JSON heartbeat
// (project path, PID, process start time) every 5 seconds to
//   ~/Library/Application Support/ContextDock/Bridge/Unity/<pid>-<startUnixMs>.json
// so ContextDock can label this Editor window with the correct project name.
//
// It never touches scenes, assets or the network, and does nothing outside the macOS Editor.
// Remove the file (and its .meta) to uninstall.

#if UNITY_EDITOR && UNITY_EDITOR_OSX
using System;
using System.Diagnostics;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace ContextDock
{
    [InitializeOnLoad]
    internal static class ContextDockBridge
    {
        private const int SchemaVersion = 1;
        private const double HeartbeatSeconds = 5.0;
        private const string SessionKey = "ContextDock.EditorSessionId";

        private static readonly string BridgeDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Personal),
            "Library", "Application Support", "ContextDock", "Bridge", "Unity");

        private static double _lastWrite = double.NegativeInfinity;
        private static bool _warned;
        private static string _filePath;
        private static readonly int Pid = Process.GetCurrentProcess().Id;
        private static readonly long StartUnixMs = ToUnixMs(Process.GetCurrentProcess().StartTime.ToUniversalTime());

        [Serializable]
        private class Payload
        {
            public int schemaVersion;
            public int pid;
            public long processStartedAtUnixMs;
            public string editorSessionId;
            public string projectPath;
            public string projectName;
            public string unityVersion;
            public long updatedAtUnixMs;
        }

        static ContextDockBridge()
        {
            if (Application.platform != RuntimePlatform.OSXEditor)
            {
                return;
            }
            _filePath = Path.Combine(BridgeDirectory, Pid + "-" + StartUnixMs + ".json");
            EditorApplication.update += Tick;
            EditorApplication.quitting += DeleteOwnFile;
            Tick();
        }

        private static string SessionId
        {
            get
            {
                // SessionState survives domain reloads, so the id identifies this Editor process.
                var id = SessionState.GetString(SessionKey, string.Empty);
                if (string.IsNullOrEmpty(id))
                {
                    id = Guid.NewGuid().ToString();
                    SessionState.SetString(SessionKey, id);
                }
                return id;
            }
        }

        private static void Tick()
        {
            var now = EditorApplication.timeSinceStartup;
            if (now - _lastWrite < HeartbeatSeconds)
            {
                return;
            }
            _lastWrite = now;
            try
            {
                Write();
            }
            catch (Exception exception)
            {
                if (!_warned)
                {
                    _warned = true;
                    UnityEngine.Debug.LogWarning("ContextDock bridge could not write its heartbeat: " + exception.Message);
                }
            }
        }

        private static void Write()
        {
            var projectPath = Directory.GetParent(Application.dataPath).FullName;
            var payload = new Payload
            {
                schemaVersion = SchemaVersion,
                pid = Pid,
                processStartedAtUnixMs = StartUnixMs,
                editorSessionId = SessionId,
                projectPath = projectPath,
                projectName = Path.GetFileName(projectPath),
                unityVersion = Application.unityVersion,
                updatedAtUnixMs = ToUnixMs(DateTime.UtcNow),
            };
            var json = JsonUtility.ToJson(payload);
            if (json.Length > 4000)
            {
                return; // ContextDock ignores oversized files; do not write them.
            }

            Directory.CreateDirectory(BridgeDirectory);
            var temporary = _filePath + ".tmp";
            File.WriteAllText(temporary, json);
            if (File.Exists(_filePath))
            {
                File.Replace(temporary, _filePath, null);
            }
            else
            {
                File.Move(temporary, _filePath);
            }
        }

        private static void DeleteOwnFile()
        {
            try
            {
                if (_filePath != null && File.Exists(_filePath))
                {
                    File.Delete(_filePath);
                }
            }
            catch
            {
                // Best effort; ContextDock also ignores stale files whose PID is gone.
            }
        }

        private static long ToUnixMs(DateTime utc)
        {
            return (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        }
    }
}
#endif
