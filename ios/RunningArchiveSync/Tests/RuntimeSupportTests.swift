import Foundation

@MainActor final class TestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting = false
    func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
    func release() { continuation?.resume(); continuation = nil }
}

@main @MainActor struct RuntimeSupportTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    static func until(_ condition: () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() { precondition(Date.now < deadline, "async test timed out"); await Task.yield() }
    }
    struct BackgroundValue: Codable {
        var number: Int
        init(_ number: Int) { self.number = number }
        init(from decoder: Decoder) throws {
            precondition(!Thread.isMainThread, "JSON decode ran on main thread")
            number = try decoder.singleValueContainer().decode(Int.self)
        }
        func encode(to encoder: Encoder) throws {
            precondition(!Thread.isMainThread, "JSON encode ran on main thread")
            var container = encoder.singleValueContainer(); try container.encode(number)
        }
    }
    static func main() async throws {
        var now = Date.now
        let gate = ArchiveRefreshGate(now: { now })
        let latch = TestLatch()
        var requests: [ArchiveRefreshRequest] = []
        let operation: @MainActor (ArchiveRefreshRequest) async -> Bool = { request in
            requests.append(request)
            if requests.count == 1 { await latch.wait() }
            return true
        }
        let initial = ArchiveRefreshRequest(authorize: true, scanRoutes: true)
        let first = Task { await gate.refresh(initial, operation: operation) }
        await until { latch.waiting }
        var joinedFinished = false, secondStarted = false, manualStarted = false
        let second = Task { secondStarted = true; await gate.refresh(initial, operation: operation); joinedFinished = true }
        let manual = Task { manualStarted = true; await gate.refresh(ArchiveRefreshRequest(authorize: true, scanRoutes: true, force: true), operation: operation) }
        await until { secondStarted && manualStarted }
        check(requests.count == 1 && !joinedFinished, "duplicates and manual requests join the actual in-flight refresh")
        latch.release(); await first.value; await second.value; await manual.value
        await gate.refresh(initial, operation: operation)
        check(requests.count == 1, "ordinary foreground refresh is throttled after success")
        now = now.addingTimeInterval(61)
        await gate.refresh(initial, operation: operation)
        check(requests.count == 2, "expired summaries refresh")
        await gate.refresh(ArchiveRefreshRequest(authorize: true, scanRoutes: true, force: true), operation: operation)
        check(requests.count == 3, "manual refresh bypasses throttle")

        let dirtyGate = ArchiveRefreshGate(), dirtyLatch = TestLatch()
        var dirtyCalls = 0
        var finalCapabilities: ArchiveRefreshRequest?
        let dirtyOperation: @MainActor (ArchiveRefreshRequest) async -> Bool = { request in
            dirtyCalls += 1; finalCapabilities = request
            if dirtyCalls == 1 { await dirtyLatch.wait() }
            return true
        }
        let background = Task { await dirtyGate.refresh(ArchiveRefreshRequest(authorize: false, scanRoutes: false), operation: dirtyOperation) }
        await until { dirtyLatch.waiting }
        var changeStarted = false, foregroundStarted = false
        let changed = Task { changeStarted = true; await dirtyGate.refresh(ArchiveRefreshRequest(authorize: false, scanRoutes: false, changed: true), operation: dirtyOperation) }
        let foreground = Task { foregroundStarted = true; await dirtyGate.refresh(initial, operation: dirtyOperation) }
        await until { changeStarted && foregroundStarted }
        dirtyLatch.release()
        await background.value; await changed.value; await foreground.value
        check(dirtyCalls == 2, "health changes and permission upgrades coalesce into one trailing refresh")
        check(finalCapabilities?.authorize == true && finalCapabilities?.scanRoutes == true, "foreground permissions and route scan are preserved")
        let failed = ArchiveRefreshGate()
        var attempts = 0
        for _ in 0..<2 { await failed.refresh(initial) { _ in attempts += 1; return false } }
        check(attempts == 2, "failed reads do not suppress the next retry")
        let upgrade = ArchiveRefreshGate()
        var upgrades = 0
        await upgrade.refresh(ArchiveRefreshRequest(authorize: false, scanRoutes: false)) { _ in upgrades += 1; return true }
        await upgrade.refresh(initial) { _ in upgrades += 1; return true }
        check(upgrades == 2, "recent background success cannot suppress foreground authorization")

        let folder = FileManager.default.temporaryDirectory.appending(path: "runtime-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "state.json"), io = ArchiveFileIO()
        try await io.write(BackgroundValue(42), to: file)
        let loaded = try await io.read(BackgroundValue.self, from: file)
        check(loaded?.number == 42, "background JSON coding round trips")
        try await io.backup(file)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        check(files.count == 2, "corrupt-file recovery can retain original bytes")
        let cancelled = ArchiveQueryContinuation<Int>()
        cancelled.cancel()
        var started = false
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                cancelled.start(continuation, execute: { started = true }, stop: {})
            }
            preconditionFailure("cancelled query returned a value")
        } catch is CancellationError { check(!started, "cancel before registration prevents query execution") }
        let query = ArchiveQueryContinuation<Int>()
        var stopped = 0, queryStarted = false
        let queryTask = Task { () throws -> Int in
            try await withCheckedThrowingContinuation { continuation in
                query.start(continuation, execute: { queryStarted = true }, stop: { stopped += 1 })
            }
        }
        await until { queryStarted }
        query.cancel(); query.cancel(); query.resume(returning: 10)
        do { _ = try await queryTask.value; preconditionFailure("query did not cancel") }
        catch is CancellationError { check(stopped == 1, "cancel stops one query and ignores late callbacks") }
        let completed = ArchiveQueryContinuation<Int>()
        let result: Int = try await withCheckedThrowingContinuation { continuation in
            completed.start(continuation, execute: { completed.resume(returning: 7) }, stop: { stopped += 1 })
        }
        completed.cancel()
        check(result == 7 && stopped == 1, "successful completion is not cancelled or resumed twice")
        print("PASS: \(checks) refresh scheduling and background file checks")
    }
}
