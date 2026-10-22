#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-feedback-store-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
# Compile the production store; replace only iOS runtime and OS collaborators in the test fixture.
python3 - "$NATIVE_SOURCE/AITrainingStore.swift" "$TEST_DIR/AITrainingStore.swift" <<'PYCODE'
import sys
source=open(sys.argv[1]).read().split('/// One runtime is shared')[0]
source=source.replace('import UIKit\n','')
open(sys.argv[2],'w').write(source)
PYCODE
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
  "$NATIVE_SOURCE/AITrainingService.swift" \
  "$TEST_DIR/AITrainingStore.swift" "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/TrainingFeedbackStoreTests.swift" \
  -o "$TEST_DIR/feedback-tests"
"$TEST_DIR/feedback-tests"
