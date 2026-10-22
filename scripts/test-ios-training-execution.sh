#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-execution-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/RuntimeSupport.swift" "$NATIVE_SOURCE/Models.swift" \
  "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/MonthlyReport.swift" \
  "$NATIVE_SOURCE/YearlyReport.swift" \
  "$NATIVE_SOURCE/TrainingJournal.swift" \
  "$NATIVE_SOURCE/ExportFileWriter.swift" \
  "$NATIVE_SOURCE/AnalysisExport.swift" \
  "$NATIVE_SOURCE/ExportAnalysisMath.swift" \
  "$NATIVE_SOURCE/TrainingAnalysisMath.swift" \
  "$NATIVE_SOURCE/WatchTrainingModels.swift" "$NATIVE_SOURCE/AITrainingModels.swift" "$NATIVE_SOURCE/TrainingFeedback.swift" "$NATIVE_SOURCE/TrainingExecution.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/TrainingExecutionTests.swift" \
  -o "$TEST_DIR/execution-tests"
"$TEST_DIR/execution-tests"
