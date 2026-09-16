#!/usr/bin/env bash
# Runs the automated test suite.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null 2>&1; then
  if [ ! -d ContextDock.xcodeproj ] || [ project.yml -nt ContextDock.xcodeproj/project.pbxproj ]; then
    echo "==> xcodegen generate"
    xcodegen generate --quiet
  fi
fi

rm -rf .build/TestResults.xcresult
echo "==> xcodebuild test"
xcodebuild \
  -project ContextDock.xcodeproj \
  -scheme ContextDock \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -resultBundlePath .build/TestResults.xcresult \
  test
