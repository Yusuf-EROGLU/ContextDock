#!/usr/bin/env bash
# Builds a Release ContextDock.app and copies it to ~/Applications/ContextDock.app.
# Run this yourself; it never touches other apps or system permissions.
#
# Optional: export CODE_SIGN_IDENTITY="ContextDock Dev" to sign with a self-signed
# identity so the Accessibility grant survives rebuilds (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$HOME/Applications/ContextDock.app"
SRC=".build/DerivedData/Build/Products/Release/ContextDock.app"

scripts/build.sh Release

if pgrep -x ContextDock >/dev/null 2>&1; then
  echo "ContextDock is running. Quit it from its menu bar icon, then re-run this script." >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
if [ -d "$DEST" ]; then
  echo "==> Replacing existing $DEST"
  rm -rf "$DEST"
fi
ditto "$SRC" "$DEST"

echo
echo "Installed: $DEST"
echo "Open it with:  open \"$DEST\""
echo
echo "Accessibility: on first launch, grant access in"
echo "  System Settings > Privacy & Security > Accessibility."
echo "With ad-hoc signing (the default) a rebuilt app may need the permission"
echo "to be re-granted (toggle ContextDock off and on in that list)."
