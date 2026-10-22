#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-runtime-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync/RuntimeSupport.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/RuntimeSupportTests.swift" \
  -o "$TEST_DIR/runtime-tests"
"$TEST_DIR/runtime-tests"
