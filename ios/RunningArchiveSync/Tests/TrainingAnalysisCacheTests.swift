import Combine
import Foundation

// The production store is compiled unchanged except for its UIKit import. Only OS/data access is faked.
@MainActor final class UIApplication {
    enum State { case active }
    static let shared = UIApplication()
    var applicationState: State = .active
}
@MainActor final class ArchiveStore {
    var activities: [ArchiveActivity] = []
    var exports = 0
    var profileReads = 0
    var newlyAuthorized = false
    var fail = false
    var onBackground: (() -> Void)?
    var exportDelay: CheckedContinuation<Void, Never>?
    var delayNextExport = false
    var accessRequests = 0
    var backgroundReads = 0
    func requestHeartRateProfileAccess() async throws -> Bool {
        defer { newlyAuthorized = false }
        return newlyAuthorized
    }
    @discardableResult func requestAIContextAccess() async throws -> Bool { accessRequests += 1; return accessRequests == 1 }
    func heartRateProfile() async -> AnalysisHeartRateProfile {
        profileReads += 1
        return AnalysisHeartRateProfile(age: 40, preferredZones: nil, ageStatus: "fixture", zoneStatus: "fixture", fetchedAt: .now)
    }
    func exportWorkout(id: String) async throws -> ExportWorkout {
        exports += 1
        if delayNextExport {
            delayNextExport = false
            await withCheckedContinuation { exportDelay = $0 }
        }
        if fail { throw CocoaError(.fileReadUnknown) }
        let activity = activities.first { $0.id == id }!
        let duration = MonthlyReport.seconds(activity.duration)!
        let sample = ExportRawSample(metric: "heart_rate", start: activity.date, end: activity.date.addingTimeInterval(duration), value: 120, unit: "bpm", source: "fixture", sourceBundle: "test", deviceKey: "test")
        return ExportWorkout(uuid: id, start: activity.date, end: activity.date.addingTimeInterval(duration), distanceKm: activity.distanceKm,
            duration: duration, heartRate: 120, maxHeartRate: 120, power: nil, cadence: nil, energyKcal: nil, elevationGain: nil,
            indoor: false, source: "fixture", sourceBundle: "test", device: "test", points: [], samples: [sample], intervals: [])
    }
    func trainingContext(now: Date, calendar: Calendar, days: Int) async -> AIRecoveryContext {
        backgroundReads += 1
        onBackground?()
        return AIRecoveryContext()
    }
    func exportReferences(start: Date, end: Date) async throws -> ExportReferenceData { ExportReferenceData() }
}

@main @MainActor struct TrainingAnalysisCacheTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError("FAIL: " + message) }
    }
    static func activity(_ id: String, date: Date, seconds: Double = 20) -> ArchiveActivity {
        ArchiveActivity(preview: WorkoutPreview(id: id, date: date, distanceKm: 0.1, duration: seconds, avgHeartRate: 120, maxHeartRate: 120, avgPower: nil))
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "analysis-cache-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "analysis.json")
        let archive = ArchiveStore(), now = Date.now
        let first = activity("first", date: now.addingTimeInterval(-3600))
        archive.activities = [first]
        let store = TrainingAnalysisStore(fileURL: file)
        var busy: [Bool] = []
        let watch = store.$isWorking.sink { busy.append($0) }
        archive.onBackground = { check(!store.isWorking, "recovery reads must not keep run-processing spinner active") }
        store.start(archive: archive)
        await store.finishForTest()
        check(archive.exports == 1, "first visit reads raw data once")
        check(store.record(id: first.id) != nil, "first result is available")
        check(busy.contains(true), "actual new raw read shows work status")
        check(archive.profileReads == 1, "one profile read shared by preparation and calculation")
        busy = []
        store.start(archive: archive)
        store.start(archive: archive)
        await store.finishForTest()
        check(archive.exports == 1, "repeated navigation does not reread raw samples")
        check(!busy.contains(true), "cached-only visits never show processing")
        await store.prepareHeartRateProfile(archive: archive, authorize: true)
        check(archive.profileReads == 1, "already-authorized page entry reuses the profile")
        archive.newlyAuthorized = true
        await store.prepareHeartRateProfile(archive: archive, authorize: true)
        check(archive.profileReads == 2, "new permission explicitly rereads profile")
        let cold = TrainingAnalysisStore(fileURL: file)
        cold.start(archive: archive)
        await cold.finishForTest()
        check(archive.exports == 1 && cold.record(id: first.id) != nil, "cold launch reuses persisted derived results")
        let second = activity("second", date: now.addingTimeInterval(-1800))
        archive.activities.append(second)
        cold.start(archive: archive)
        await cold.finishForTest()
        check(archive.exports == 2, "new workout updates only that workout")
        archive.activities[0] = activity("first", date: first.date, seconds: 25)
        cold.start(archive: archive)
        await cold.finishForTest()
        check(archive.exports == 3, "edited summary invalidates only its own result")
        cold.start(archive: archive, force: true)
        await cold.finishForTest()
        check(archive.exports == 5, "explicit refresh bypasses cache for the two workouts")
        archive.activities.append(activity("third", date: now.addingTimeInterval(-900)))
        cold.start(archive: archive)
        cold.start(archive: archive, force: true)
        await cold.finishForTest()
        check(archive.exports == 9, "force refresh arriving during an existing pass is queued, not dropped")
        let snapshotTime = Date.now
        let sharedTimeline = cold.loadTimeline(now: snapshotTime)
        let modelContext = cold.context(activities: archive.activities, now: snapshotTime)
        check(modelContext.load_days.last?.shortLoad == sharedTimeline.last?.shortLoad && modelContext.load_days.last?.longLoad == sharedTimeline.last?.longLoad, "AI and UI consume exactly the same daily load values")
        check(Set(modelContext.evidence.first { $0.id == "analysis:load-trend" }!.activity_ids) == Set(archive.activities.map(\.id)), "load evidence names the full history used for initialization")
        let failedFile = folder.appending(path: "failure.json")
        let unavailable = ArchiveStore()
        unavailable.activities = [activity("unavailable", date: now.addingTimeInterval(-3600))]
        unavailable.fail = true
        let failedStore = TrainingAnalysisStore(fileURL: failedFile)
        failedStore.start(archive: unavailable)
        await failedStore.finishForTest()
        check(unavailable.exports == 1, "unreadable data attempted once")
        failedStore.start(archive: unavailable)
        await failedStore.finishForTest()
        check(unavailable.exports == 1, "unreadable data is not retried on every visit")
        let coldFailure = TrainingAnalysisStore(fileURL: failedFile)
        coldFailure.start(archive: unavailable)
        await coldFailure.finishForTest()
        check(unavailable.exports == 1, "retry backoff survives app relaunch")
        coldFailure.start(archive: unavailable, force: true)
        await coldFailure.finishForTest()
        check(unavailable.exports == 2, "manual retry bypasses persisted failure backoff")
        // The one-shot failures field is optional for previously saved caches.
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        legacy.removeValue(forKey: "failedReads")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let legacyStore = TrainingAnalysisStore(fileURL: file)
        await legacyStore.restore()
        legacyStore.updateSummaries(archive.activities)
        check(legacyStore.record(id: second.id) != nil && legacyStore.errorMessage == nil, "old disk cache remains readable")
        // Presentation caching changes no numerical values, including across a day boundary.
        let cacheTime = Date.now
        let builds = cold.timelineBuildCount
        let cachedTimeline = cold.loadTimeline(now: cacheTime)
        let afterFirst = cold.timelineBuildCount
        _ = cold.loadTimeline(now: cacheTime.addingTimeInterval(0.01))
        check(cold.timelineBuildCount == afterFirst, "repeated labels/chart selection reuse daily timeline")
        cold.updateSummaries(archive.activities)
        _ = cold.loadTimeline(now: cacheTime.addingTimeInterval(0.02))
        check(cold.timelineBuildCount == afterFirst, "unchanged summary refresh preserves timeline")
        let tomorrow = cold.calendar.date(byAdding: .day, value: 1, to: cacheTime)!
        let nextDay = cold.loadTimeline(now: tomorrow)
        let exactNextDay = TrainingAnalysisMath.loadTimeline(cold.summaries, analyses: cold.validRecords, now: tomorrow, calendar: cold.calendar)
        check(nextDay.last?.shortLoad == exactNextDay.last?.shortLoad && cold.timelineBuildCount > afterFirst, "day rollover invalidates cache without changing EWMA")
        check(!cachedTimeline.isEmpty && afterFirst >= builds, "cached timeline contains history")
        let beforeEdit = cold.timelineBuildCount
        archive.activities[0] = activity("first", date: first.date, seconds: 35)
        cold.updateSummaries(archive.activities)
        _ = cold.loadTimeline(now: .now)
        check(cold.timelineBuildCount > beforeEdit && cold.record(id: "first") == nil, "edited summary invalidates cached presentation and its result")

        let exportsBeforePause = archive.exports
        cold.stop()
        await cold.waitForPersistence()
        cold.start(archive: archive)
        await cold.finishForTest()
        check(cold.isPaused && archive.exports == exportsBeforePause, "navigation and automatic refresh preserve user pause")
        let paused = TrainingAnalysisStore(fileURL: file)
        await paused.restore()
        paused.start(archive: archive)
        await paused.finishForTest()
        check(paused.isPaused && archive.exports == exportsBeforePause, "user pause survives cold launch")
        paused.resume(archive: archive)
        await paused.finishForTest()
        check(!paused.isPaused && archive.exports == exportsBeforePause + 1, "resume reads only pending workouts")

        // Manual refresh awaits its queued pass and disk save, instead of ending immediately.
        archive.delayNextExport = true
        var refreshFinished = false
        let manual = Task { await paused.refresh(archive: archive); refreshFinished = true }
        while archive.exportDelay == nil { await Task.yield() }
        check(!refreshFinished && paused.isWorking, "manual refresh remains active while raw queries are pending")
        archive.exportDelay?.resume(); archive.exportDelay = nil
        await manual.value
        check(refreshFinished && !paused.isWorking, "manual refresh completes with its work")

        // Cancellation of an older pass cannot publish a result or clear a later pause.
        archive.delayNextExport = true
        paused.start(archive: archive, force: true)
        while archive.exportDelay == nil { await Task.yield() }
        paused.stop()
        archive.exportDelay?.resume(); archive.exportDelay = nil
        for _ in 0..<30 { await Task.yield() }
        await paused.waitForPersistence()
        check(paused.isPaused && !paused.isWorking && paused.progress.contains("暂停"), "late completion cannot overwrite paused status")
        // Old data remains readable even though persistence now runs on a background actor.
        let persisted = TrainingAnalysisStore(fileURL: file)
        await persisted.restore()
        persisted.updateSummaries(archive.activities)
        check(persisted.isPaused && persisted.record(id: second.id) != nil, "ordered writes retain latest pause and completed results")

        let beforeCalibration = persisted.timelineBuildCount
        try await persisted.saveCalibration(maximum: 190, source: "fixture", performanceID: nil)
        _ = persisted.loadTimeline(now: .now)
        check(persisted.validRecords.isEmpty && persisted.timelineBuildCount > beforeCalibration, "calibration change invalidates all derived presentation")
        check(persisted.isPaused, "changing settings does not silently resume a user pause")
        let corruptFile = folder.appending(path: "corrupt.json")
        let corruptBytes = Data("{broken".utf8)
        try corruptBytes.write(to: corruptFile)
        let corruptStore = TrainingAnalysisStore(fileURL: corruptFile)
        await corruptStore.restore()
        corruptStore.start(archive: archive)
        await corruptStore.finishForTest()
        check(corruptStore.errorMessage != nil, "failed asynchronous restore is reported")
        let unchangedBytes = try Data(contentsOf: corruptFile)
        check(unchangedBytes == corruptBytes, "failed restore never overwrites original bytes")
        try await corruptStore.rebuild()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("corrupt.backup-") }
        check(backups.count == 1 && corruptStore.errorMessage == nil, "explicit rebuild backs up unreadable cache off the main actor")
        let permissionsArchive = ArchiveStore()
        permissionsArchive.activities = [first]
        permissionsArchive.delayNextExport = true
        let permissionsStore = TrainingAnalysisStore(fileURL: folder.appending(path: "permissions.json"))
        permissionsStore.start(archive: permissionsArchive)
        while permissionsArchive.exportDelay == nil { await Task.yield() }
        permissionsStore.start(archive: permissionsArchive, recoveryAccess: true)
        permissionsArchive.exportDelay?.resume(); permissionsArchive.exportDelay = nil
        await permissionsStore.finishForTest()
        check(permissionsArchive.accessRequests == 1 && permissionsArchive.exports == 1, "foreground permission request survives in-flight automatic analysis without rereading runs")
        check(permissionsArchive.backgroundReads == 2, "new recovery permission invalidates pre-authorization background cache")
        withExtendedLifetime(watch) {}
        print("PASS: \(checks) store integration checks — navigation, coalescing, permissions, cold cache, incremental updates, force queue, failure persistence and recovery status")
    }
}
