#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-watch-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
WATCH_TEST_ARCH="$(uname -m)"
xcrun swiftc -target "$WATCH_TEST_ARCH-apple-macos15.0" -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/RuntimeSupport.swift" "$NATIVE_SOURCE/Models.swift" "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/MonthlyReport.swift" "$NATIVE_SOURCE/YearlyReport.swift" "$NATIVE_SOURCE/TrainingJournal.swift" \
  "$NATIVE_SOURCE/ExportFileWriter.swift" "$NATIVE_SOURCE/AnalysisExport.swift" \
  "$NATIVE_SOURCE/ExportAnalysisMath.swift" "$NATIVE_SOURCE/TrainingAnalysisMath.swift" \
  "$NATIVE_SOURCE/WatchTrainingModels.swift" "$NATIVE_SOURCE/AITrainingModels.swift" "$NATIVE_SOURCE/TrainingFeedback.swift" "$NATIVE_SOURCE/TrainingExecution.swift" \
  "$NATIVE_SOURCE/WatchPlanSync.swift" "$NATIVE_SOURCE/WatchWorkoutBridge.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/WatchTrainingTests.swift" \
  -o "$TEST_DIR/watch-tests"
"$TEST_DIR/watch-tests"
