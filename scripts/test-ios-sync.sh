#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/running-sync-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
NATIVE_SOURCE="$PROJECT_ROOT/ios/RunningArchiveSync/RunningArchiveSync"
cp "$NATIVE_SOURCE/HealthSyncStore.swift" "$TEST_DIR/HealthSyncStore.swift"
cat >> "$TEST_DIR/HealthSyncStore.swift" <<'SWIFT'
extension HealthSyncViewModel {
    var hasWakeForTest: Bool { wakeTask != nil }
    func finishForTest() async { while let automaticTask { await automaticTask.value } }
}
SWIFT
xcrun swiftc -module-cache-path "$TEST_DIR/cache" \
  "$NATIVE_SOURCE/Models.swift" "$NATIVE_SOURCE/SyncAPI.swift" "$TEST_DIR/HealthSyncStore.swift" \
  "$PROJECT_ROOT/ios/RunningArchiveSync/Tests/HealthSyncTests.swift" -o "$TEST_DIR/sync-tests"
"$TEST_DIR/sync-tests"
