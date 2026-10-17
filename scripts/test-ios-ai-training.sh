#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-ai-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/Models.swift" \
  "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/MonthlyReport.swift" \
  "$NATIVE_SOURCE/YearlyReport.swift" \
  "$NATIVE_SOURCE/TrainingJournal.swift" \
  "$NATIVE_SOURCE/AITrainingModels.swift" \
  "$NATIVE_SOURCE/AITrainingService.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/AITrainingTests.swift" \
  -o "$TEST_DIR/ai-tests"
"$TEST_DIR/ai-tests"
