#!/bin/bash
# Works with Command Line Tools alone (no XCTest / full Xcode required).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
sources=()
for source in Sources/Kura/*.swift; do
  if [[ "$source" != "Sources/Kura/main.swift" ]]; then sources+=("$source"); fi
done
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx14.2" -parse-as-library "${sources[@]}" Tests/KuraTests/WorkspaceTests.swift -o .build/checks/KuraChecks
.build/checks/KuraChecks
python3 -B Tests/local_speech_test.py
