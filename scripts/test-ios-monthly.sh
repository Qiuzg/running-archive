#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/running-monthly-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/Models.swift" \
  "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/MonthlyReport.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/MonthlyReportTests.swift" \
  -o "$TEST_DIR/monthly-tests"
"$TEST_DIR/monthly-tests"
