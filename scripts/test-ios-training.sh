#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/running-training-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/RuntimeSupport.swift" "$NATIVE_SOURCE/Models.swift" \
  "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/TrainingJournal.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/TrainingJournalTests.swift" \
  -o "$TEST_DIR/training-tests"
"$TEST_DIR/training-tests"
