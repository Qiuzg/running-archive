#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-analysis-cache-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
# Keep the actual store logic, replacing only the unavailable macOS UIKit dependency.
sed '/^import UIKit$/d' "$NATIVE_SOURCE/TrainingAnalysisStore.swift" > "$TEST_DIR/TrainingAnalysisStore.swift"
cat >> "$TEST_DIR/TrainingAnalysisStore.swift" <<'SWIFT'
extension TrainingAnalysisStore {
    func finishForTest() async { while let task { await task.value }; await waitForPersistence() }
}
SWIFT
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/RuntimeSupport.swift" "$NATIVE_SOURCE/Models.swift" "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/MonthlyReport.swift" "$NATIVE_SOURCE/YearlyReport.swift" "$NATIVE_SOURCE/TrainingJournal.swift" \
  "$NATIVE_SOURCE/ExportFileWriter.swift" "$NATIVE_SOURCE/AnalysisExport.swift" \
  "$NATIVE_SOURCE/ExportAnalysisMath.swift" "$NATIVE_SOURCE/TrainingAnalysisMath.swift" \
  "$NATIVE_SOURCE/WatchTrainingModels.swift" "$NATIVE_SOURCE/AITrainingModels.swift" "$NATIVE_SOURCE/TrainingFeedback.swift" "$NATIVE_SOURCE/TrainingExecution.swift" "$NATIVE_SOURCE/AITrainingService.swift" \
  "$TEST_DIR/TrainingAnalysisStore.swift" "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/TrainingAnalysisCacheTests.swift" \
  -o "$TEST_DIR/cache-tests"
"$TEST_DIR/cache-tests"
