#!/usr/bin/env bash
# Builds ContextDock (Debug by default) into .build/DerivedData.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"

# Regenerate the Xcode project when project.yml is newer and xcodegen is available.
if command -v xcodegen >/dev/null 2>&1; then
  if [ ! -d ContextDock.xcodeproj ] || [ project.yml -nt ContextDock.xcodeproj/project.pbxproj ]; then
    echo "==> xcodegen generate"
    xcodegen generate --quiet
  fi
fi

echo "==> xcodebuild build ($CONFIG)"
xcodebuild \
  -project ContextDock.xcodeproj \
  -scheme ContextDock \
  -configuration "$CONFIG" \
  -derivedDataPath .build/DerivedData \
  ${CODE_SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"} \
  build

echo "==> App: .build/DerivedData/Build/Products/$CONFIG/ContextDock.app"
