#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/running-export-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
EXPORT_FIXTURES="${1:-$TEST_DIR/output}"
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/RuntimeSupport.swift" "$NATIVE_SOURCE/Models.swift" "$NATIVE_SOURCE/ArchiveModels.swift" \
  "$NATIVE_SOURCE/TrainingJournal.swift" "$NATIVE_SOURCE/MonthlyReport.swift" "$NATIVE_SOURCE/TrainingAnalysisMath.swift" "$NATIVE_SOURCE/ExportFileWriter.swift" \
  "$NATIVE_SOURCE/AnalysisExport.swift" "$NATIVE_SOURCE/ExportAnalysisMath.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/AnalysisExportTests.swift" \
  -o "$TEST_DIR/export-tests"
"$TEST_DIR/export-tests" "$EXPORT_FIXTURES"
python3 "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/verify-analysis-export.py" "$EXPORT_FIXTURES"
