import Foundation

@main @MainActor struct HealthSyncTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAIL: " + message) }
    }
    static func main() async throws {
        let suite = "sync-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        // The isolated suite never reads or writes the real credentials/ledger.
        defer { defaults.removePersistentDomain(forName: suite) }
        var time = Date(timeIntervalSince1970: 1_790_000_000)
        func preview(_ id: String, age: Double) -> WorkoutPreview {
            WorkoutPreview(id: id, date: time.addingTimeInterval(-age), distanceKm: 5, duration: 1800, avgHeartRate: 140, maxHeartRate: 160, avgPower: nil)
        }
        var all = [preview("old", age: 8*86400), preview("recent", age: 2*86400), preview("done", age: 3*86400)]
        defaults.set("https://example.test/run", forKey: "serverURL")
        defaults.set(["done"], forKey: "syncedWorkoutIDs")
        defaults.set(true, forKey: "heartRateCondensedSeriesResyncV2")
        var uploads: [String] = [], reads = 0, concurrent = 0, maxConcurrent = 0
        var fail = false, wrongAck = false, missing = false, tokenSaved = "", failSave = false
        var hook: (() -> Void)?
        var held: CheckedContinuation<Void, Never>?
        var holdNext = false
        let deps = HealthSyncDependencies(authorize: {}, previews: { reads += 1; return all }, payload: { id in
            if missing { return nil }
            return WorkoutPayload(id: id, name: "run", startDate: time, distanceKm: 5, durationSeconds: 1800, city: "", avgHeartRate: 140, maxHeartRate: 160, avgCadence: nil, avgPower: nil, routePoints: [], heartRateSamples: [], runningSpeedSamples: nil, intervals: nil)
        }, upload: { payload, url, token in
            concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent)
            defer { concurrent -= 1 }
            if holdNext { holdNext = false; await withCheckedContinuation { held = $0 } }
            if fail { throw URLError(.notConnectedToInternet) }
            uploads.append(payload.id)
            hook?()
            return SyncResponse(synced: [SyncResult(id: wrongAck ? "unrelated" : payload.id, status: "created", routePoints: 0)])
        }, saveToken: { if failSave { throw CocoaError(.fileWriteNoPermission) }; tokenSaved = $0 })
        let store = HealthSyncViewModel(defaults: defaults, token: "test-only", dependencies: deps, now: { time })
        store.requestAutomaticCheck()
        await store.finishForTest()
        check(reads == 0, "no automatic work in background")
        store.setForeground(true)
        await store.finishForTest()
        check(uploads == ["recent"], "first automatic pass uploads only unsynced last seven days")
        check(store.previews.map(\.id) == ["old"], "older history remains available manually")
        check(store.lastSuccess == time, "successful acknowledgement publishes persisted timestamp")
        let before = reads
        store.requestAutomaticCheck()
        await store.finishForTest()
        check(reads == before, "foreground checks throttled")
        await store.authorizeAndRefresh()
        await store.syncSelected()
        check(uploads == ["recent", "old"], "manual history backfill preserved")
        check(tokenSaved == "test-only", "credentials saved through injected keychain writer")
        store.setForeground(false)
        // New workout exists while app offline; start date is fixed, not a sliding lookback.
        all.append(preview("offline", age: 3600))
        time.addTimeInterval(10 * 86400)
        let relaunched = HealthSyncViewModel(defaults: defaults, token: "test-only", dependencies: deps, now: { time })
        relaunched.setForeground(true)
        await relaunched.finishForTest()
        check(uploads.last == "offline", "fixed initial cutoff survives restart and ten days offline")
        check(uploads.filter { $0 == "recent" }.count == 1, "durable ledger skips already acknowledged workouts")
        all.append(preview("fresh", age: 1800))
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(!uploads.contains("fresh"), "finished workout waits for HealthKit samples")
        relaunched.setForeground(false)
        check(!relaunched.hasWakeForTest, "background stops foreground timer")
        relaunched.setForeground(true)
        await relaunched.finishForTest()
        check(relaunched.hasWakeForTest, "quick foreground return restores settling timer even inside throttle window")
        time.addTimeInterval(121)
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(uploads.last == "fresh", "settled workout uploads without manual selection")
        time.addTimeInterval(901)
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(uploads.filter { $0 == "fresh" }.count == 2, "one delayed finalization rereads recent samples/routes")
        time.addTimeInterval(901)
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(uploads.filter { $0 == "fresh" }.count == 2, "finalization is bounded, not an endless reupload")
        all.append(preview("retry", age: 2*86400))
        fail = true
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(relaunched.errorDetails != nil && relaunched.previews.contains { $0.id == "retry" }, "failed upload stays pending")
        let failureReads = reads
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(reads == failureReads, "HealthKit notifications respect failure backoff")
        fail = false; wrongAck = true
        relaunched.networkRecovered()
        await relaunched.finishForTest()
        check(relaunched.previews.contains { $0.id == "retry" }, "unrelated server acknowledgement cannot mark workout synced")
        wrongAck = false; missing = true
        relaunched.networkRecovered()
        await relaunched.finishForTest()
        check(relaunched.previews.contains { $0.id == "retry" }, "unreadable workout remains retryable")
        missing = false
        relaunched.networkRecovered()
        await relaunched.finishForTest()
        check(!relaunched.previews.contains { $0.id == "retry" }, "network recovery retries pending failure")
        all.append(preview("held", age: 3*86400))
        holdNext = true
        relaunched.requestAutomaticCheck(changed: true)
        while held == nil { await Task.yield() }
        for _ in 0..<10 { relaunched.requestAutomaticCheck(changed: true) }
        await relaunched.syncSelected()
        held?.resume(); held = nil
        await relaunched.finishForTest()
        check(maxConcurrent == 1 && uploads.filter { $0 == "held" }.count == 1, "automatic/manual races share one upload lane")
        all += [preview("stop-a", age: 2*86400), preview("stop-b", age: 3*86400)]
        hook = { relaunched.setAutomaticEnabled(false) }
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(uploads.contains("stop-a") && !uploads.contains("stop-b"), "disable stops next record, commits current acknowledgement")
        hook = nil
        relaunched.setAutomaticEnabled(true)
        await relaunched.finishForTest()
        check(uploads.contains("stop-b"), "reenable resumes backlog")
        let previousUploads = uploads.count
        relaunched.serverURL = "https://different.test/run"
        relaunched.requestAutomaticCheck(changed: true)
        await relaunched.finishForTest()
        check(uploads.count == previousUploads, "editing settings does not change active server")
        check(relaunched.saveSettings(), "valid new endpoint saves")
        await relaunched.finishForTest()
        check(uploads.count > previousUploads, "new server receives its own seven-day backlog, independent ledger")
        relaunched.setAutomaticEnabled(false)
        check(defaults.object(forKey: "automaticWorkoutSync") as? Bool == false, "automatic switch persists across launches")
        let confirmedURL = defaults.string(forKey: "serverURL")
        failSave = true
        relaunched.serverURL = "https://unsaved.test"
        check(!relaunched.saveSettings() && defaults.string(forKey: "serverURL") == confirmedURL, "keychain failure leaves active server unchanged")
        failSave = false
        relaunched.serverURL = "http://public.test"
        check(!relaunched.saveSettings() && defaults.string(forKey: "serverURL") == confirmedURL, "invalid endpoint cannot replace saved configuration")
        let emptySuite = "sync-empty-\(UUID())"
        let emptyDefaults = UserDefaults(suiteName: emptySuite)!
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        let unconfigured = HealthSyncViewModel(defaults: emptyDefaults, token: "", dependencies: deps, now: { time })
        let noConfigReads = reads
        unconfigured.setForeground(true)
        await unconfigured.finishForTest()
        check(reads == noConfigReads && !unconfigured.configured, "new install without token does not start upload queries")
        store.setAutomaticEnabled(false)
        let endpoints = ["http://example.test", "ftp://localhost", "https://a:b@example.test", "https://example.test/?token=x", "https://example.test/#fragment"]
        for endpoint in endpoints { check((try? SyncAPI.endpoint(baseURL: endpoint)) == nil, "reject unsafe/ambiguous endpoint \(endpoint)") }
        check((try? SyncAPI.endpoint(baseURL: "https://example.test/run/"))?.path == "/run/api/sync/apple-workouts", "base path retained")
        check((try? SyncAPI.endpoint(baseURL: "http://localhost:8000"))?.scheme == "http", "localhost development supported")
        print("PASS: \(checks) automatic sync checks; no live server requests")
    }
}
