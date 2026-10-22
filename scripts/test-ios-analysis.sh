#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-analysis-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/RuntimeSupport.swift" "$NATIVE_SOURCE/Models.swift" "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/MonthlyReport.swift" "$NATIVE_SOURCE/TrainingJournal.swift" \
  "$NATIVE_SOURCE/ExportFileWriter.swift" "$NATIVE_SOURCE/AnalysisExport.swift" \
  "$NATIVE_SOURCE/ExportAnalysisMath.swift" "$NATIVE_SOURCE/TrainingAnalysisMath.swift" "$NATIVE_SOURCE/TrainingDashboard.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/TrainingAnalysisTests.swift" \
  -o "$TEST_DIR/analysis-tests"
"$TEST_DIR/analysis-tests"
