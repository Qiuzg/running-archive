import Foundation
import WorkoutKit

@MainActor
private final class FakeWatchTransport: WatchWorkoutTransport {
    var isSupported = true
    var maximumCount = 15
    var authorized = true
    var items: [WatchScheduledEntry] = []
    var schedules = 0
    var removals = 0
    var ignoreRemovals = false
    var failSchedule = false
    var beforeSchedule: (() async -> Void)?
    var beforeAuthorize: (() async -> Void)?
    var delayVisibility = 0
    var pendingVisibility = 0
    func authorize(request: Bool) async -> Bool {
        if let beforeAuthorize { self.beforeAuthorize = nil; await beforeAuthorize() }
        return authorized
    }
    func entries() async -> [WatchScheduledEntry] {
        if pendingVisibility > 0 { pendingVisibility -= 1; return [] }
        return items
    }
    func prepare(_ session: AITrainingSession, id: UUID) throws -> Data {
        _ = try session.resolvedWorkout()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(session)
    }
    func equivalent(_ lhs: Data, _ rhs: Data) throws -> Bool { lhs == rhs }
    func schedule(data: Data, date: DateComponents) async throws {
        if let beforeSchedule { self.beforeSchedule = nil; await beforeSchedule() }
        if failSchedule { failSchedule = false; throw AITrainingError.invalid("模拟系统提交失败") }
        let session = try JSONDecoder().decode(AITrainingSession.self, from: data)
        items.append(.init(id: WatchPlanSyncStore.identifier(for: session.date), date: date, complete: false, data: data))
        schedules += 1
        pendingVisibility = delayVisibility
    }
    func remove(_ entry: WatchScheduledEntry) async throws {
        removals += 1
        if !ignoreRemovals { items.removeAll { $0.id == entry.id && $0.date == entry.date } }
    }
}

@main
struct WatchTrainingTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func rejects(_ message: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(message) } catch { checks += 1 }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = AIDate.parse("2026-10-19", calendar: calendar)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = RunWorkoutStep(value: 180, instructions: "快跑")
        let recovery = RunWorkoutStep(value: 120, instructions: "慢跑恢复")
        let structure = RunWorkoutStructure(warmup: .init(value: 600, instructions: "热身"),
            blocks: [.init(repetitions: 6, steps: [.init(step: work), .init(purpose: .recovery, step: recovery)])],
            cooldown: .init(value: 600, instructions: "放松"))
        try structure.validate(kind: .intervals)
        check(structure.seconds == 3000, "6 x (3+2) + 10+10 must equal exactly 50 minutes")
        var noLastRecovery = structure
        noLastRecovery.blocks[0].repetitions = 5
        noLastRecovery.blocks.append(.init(steps: [.init(step: work)]))
        check(noLastRecovery.seconds == 2880, "Omitting final recovery must equal exactly 48 minutes")
        try noLastRecovery.validate(kind: .intervals)
        var distance = structure
        distance.blocks[0].steps[0].step = .init(goal: .distance, value: 800, estimated_seconds: 240, instructions: "800米")
        try distance.validate(kind: .intervals)
        check(distance.blocks[0].steps[0].step.value == 800 && distance.seconds == 3360, "Distance goals retain meters; estimates affect only budget")
        for repetitions in [0, -1, 51] {
            var bad = structure; bad.blocks[0].repetitions = repetitions
            rejects("Bad repetitions accepted") { try bad.validate(kind: .intervals) }
        }
        var bad = structure; bad.blocks[0].steps = []
        rejects("Empty block accepted") { try bad.validate(kind: .intervals) }
        bad = structure; bad.blocks[0].steps.removeLast()
        rejects("Missing recovery accepted") { try bad.validate(kind: .intervals) }
        bad = distance; bad.blocks[0].steps[0].step.estimated_seconds = nil
        rejects("Distance without estimate accepted") { try bad.validate(kind: .intervals) }
        bad = structure; bad.warmup.value = .nan
        rejects("NaN goal accepted") { try bad.validate(kind: .intervals) }
        bad = structure; bad.warmup.pace_min = 400; bad.warmup.pace_max = 300
        rejects("Reversed pace accepted") { try bad.validate(kind: .intervals) }
        bad = structure; bad.warmup.pace_min = 300; bad.warmup.pace_max = 400; bad.warmup.heart_rate_min = 130; bad.warmup.heart_rate_max = 150
        rejects("Two alerts accepted") { try bad.validate(kind: .intervals) }
        bad = structure; bad.warmup.heart_rate_min = 130
        rejects("Incomplete HR alert accepted") { try bad.validate(kind: .intervals) }
        bad = structure; bad.blocks = Array(repeating: bad.blocks[0], count: 20)
        rejects("Too many expanded steps accepted") { try bad.validate(kind: .intervals) }

        func session(_ day: String = "2026-10-19", structure: RunWorkoutStructure? = nil) -> AITrainingSession {
            var value = AITrainingSession(date: day, kind: .intervals, duration_minutes: 50,
                intensity: "主观较用力", purpose: "测试分段", steps: [], evidence_ids: [])
            value.applyWorkout(structure ?? selfStructure)
            return value
        }
        let selfStructure = structure
        let run = session()
        _ = try run.resolvedWorkout()
        let native = try AppleWatchWorkoutTransport.plan(run, id: WatchPlanSyncStore.identifier(for: run.date))
        guard case .custom(let nativeWorkout) = native.workout else { fatalError("Not a native custom workout") }
        check(nativeWorkout.blocks.count == 1 && nativeWorkout.blocks[0].iterations == 6 && nativeWorkout.blocks[0].steps.count == 2,
              "Native WorkoutKit repetitions changed")
        check(nativeWorkout.blocks[0].steps[1].purpose == .recovery, "Native recovery purpose lost")
        check(nativeWorkout.warmup!.goal == .time(600, .seconds) && nativeWorkout.cooldown!.goal == .time(600, .seconds), "Native warmup/cooldown changed")
        let encodedNative = try native.dataRepresentation
        let decodedNative = try WorkoutPlan(from: encodedNative)
        check(decodedNative == native, "Actual WorkoutKit binary roundtrip changed plan")
        var targetedStructure = distance
        targetedStructure.blocks[0].steps[0].step.pace_min = 300
        targetedStructure.blocks[0].steps[0].step.pace_max = 360
        targetedStructure.blocks[0].steps[1].step.heart_rate_min = 130
        targetedStructure.blocks[0].steps[1].step.heart_rate_max = 150
        let targeted = try AppleWatchWorkoutTransport.plan(session(structure: targetedStructure), id: UUID())
        guard case .custom(let nativeTargeted) = targeted.workout else { fatalError("Not custom") }
        check(nativeTargeted.blocks[0].steps[0].step.goal == .distance(800, .meters), "Distance estimate accidentally became watch time goal")
        let nativePace = nativeTargeted.blocks[0].steps[0].step.alert as! SpeedRangeAlert
        check(abs(nativePace.target.lowerBound.converted(to: .metersPerSecond).value - 1000 / 360) < 1e-9
            && abs(nativePace.target.upperBound.converted(to: .metersPerSecond).value - 1000 / 300) < 1e-9, "Pace-to-speed limits reversed")
        let nativeHR = nativeTargeted.blocks[0].steps[1].step.alert as! HeartRateRangeAlert
        check(nativeHR.target.lowerBound.value == 130 && nativeHR.target.upperBound.value == 150, "Heart-rate units changed")
        _ = try targeted.dataRepresentation
        var mismatch = run; mismatch.duration_minutes += 1
        rejects("Inconsistent duration accepted") { _ = try mismatch.resolvedWorkout() }
        var old = run; old.workout = nil
        rejects("Legacy intervals guessed") { _ = try old.resolvedWorkout() }
        let original = AITrainingPlan(schema_version: 2, stage: "测试", summary: "测试", run_review: "测试",
            sessions: [run] + (1..<7).map { .rest(on: AIDate.key(calendar.date(byAdding: .day, value: $0, to: now)!, calendar: calendar)) },
            adjustments: [], limitations: [])
        var profile = AITrainingProfile(); profile.availableDays = [1,2,3,4,5,6,7]
        try original.validate(profile: profile, start: now, evidenceIDs: [], calendar: calendar)
        var state = AITrainingDiskState()
        state.revisions = [.init(createdAt: now, model: "test", promptVersion: "v7", inputFingerprint: "test", plan: original)]
        var edited = run; var editedStructure = structure; editedStructure.blocks[0].repetitions = 4
        edited.applyWorkout(editedStructure)
        try state.editSession(originalDate: run.date, session: edited, now: now, calendar: calendar)
        check(state.effectiveRevision!.plan.sessions[0].duration_minutes == 40, "Manual repeated duration not applied")
        state.revisions[0].plan.sessions[0].purpose = "新AI安排"
        check(state.effectiveRevision!.plan.sessions[0].purpose == edited.purpose, "New AI plan overwrote manual changes")
        let disk = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONEncoder().encode(state))
        check(disk.effectiveRevision!.plan.sessions[0] == edited, "Manual changes did not survive disk roundtrip")
        var moved = edited; moved.date = "2026-10-20"
        try state.editSession(originalDate: run.date, session: moved, now: now, calendar: calendar)
        check(state.effectiveRevision!.plan.sessions[0].kind == .rest && state.effectiveRevision!.plan.sessions[1] == moved, "Move did not clear original date")
        var collision = moved; collision.date = "2026-10-19"
        state.revisions[0].plan.sessions[0] = run
        state.manualOverrides?.removeAll { $0.session.date == run.date }
        rejects("Move onto existing run accepted") { try state.editSession(originalDate: moved.date, session: collision, now: now, calendar: calendar) }
        state.completed.append(.init(session: moved, activityIDs: ["actual"]))
        rejects("Completed session edited") { try state.editSession(originalDate: moved.date, session: moved, now: now, calendar: calendar) }
        state.completed = []
        rejects("Past session edited") { try state.editSession(originalDate: moved.date, session: moved, now: now.addingTimeInterval(3 * 86400), calendar: calendar) }
        state.manualOverrides = []
        check(state.effectiveRevision!.plan.sessions[0] == run, "Restoring AI did not reveal saved AI session")

        func store(_ name: String, _ transport: FakeWatchTransport) -> WatchPlanSyncStore {
            WatchPlanSyncStore(transport: transport, fileURL: root.appendingPathComponent(name + ".json"))
        }
        let fake = FakeWatchTransport(), sync = store("normal", fake)
        await sync.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(sync.errorMessage == nil && fake.schedules == 1 && fake.items.count == 1, "Initial sync failed")
        let identifier = fake.items[0].id
        await sync.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(fake.schedules == 1 && fake.removals == 0, "Repeated send added duplicate")
        await sync.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(fake.schedules == 2 && fake.removals == 1 && fake.items.count == 1 && fake.items[0].id == identifier, "Editing did not replace stable ID")
        let reopened = store("normal", fake)
        check(reopened.automaticUpdates, "Auto-update preference not durable")
        await reopened.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(fake.schedules == 2, "Relaunch duplicated workout")
        fake.items.append(fake.items[0])
        await sync.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(fake.items.count == 1, "Identical existing duplicates not repaired")
        let foreignID = UUID()
        var foreign = fake.items[0]; foreign.id = foreignID; fake.items.append(foreign)
        var past = fake.items[0]; past.date.day = 18; past.id = WatchPlanSyncStore.identifier(for: "2026-10-18"); fake.items.append(past)
        await sync.sync(sessions: [.rest(on: run.date)], completed: [], now: now, calendar: calendar)
        check(fake.items.count == 2 && fake.items.contains { $0.id == foreignID } && fake.items.contains { $0.id == past.id }, "Rest removed foreign or historical entry")
        await sync.sync(sessions: [run], completed: [], now: now, calendar: calendar)
        fake.items[fake.items.firstIndex { $0.id == identifier }!].complete = true
        let before = fake.schedules
        await sync.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(fake.items.contains { $0.id == identifier && $0.complete } && fake.schedules == before, "Completed workout replaced")

        let invalidTransport = FakeWatchTransport(), invalidStore = store("invalid", invalidTransport)
        await invalidStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        var invalidSession = edited; invalidSession.date = "2026-10-20"; invalidSession.workout!.blocks[0].repetitions = 0
        await invalidStore.sync(sessions: [edited, invalidSession], completed: [], now: now, calendar: calendar)
        check(invalidStore.errorMessage != nil && invalidTransport.removals == 0 && invalidTransport.schedules == 1, "Invalid plan mutated existing schedule")
        invalidTransport.ignoreRemovals = true
        await invalidStore.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(invalidTransport.schedules == 1 && invalidTransport.items.count == 1, "Unconfirmed removal caused duplicate")
        invalidTransport.ignoreRemovals = false; invalidTransport.failSchedule = true
        await invalidStore.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(invalidStore.errorMessage != nil && invalidTransport.items.isEmpty, "Partial failure not surfaced")
        await invalidStore.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        check(invalidStore.errorMessage == nil && invalidTransport.items.count == 1, "Retry failed to recover partial sync")
        var invalidDate = edited; invalidDate.date = "2026-02-30"
        let unchangedRemovals = invalidTransport.removals
        await invalidStore.sync(sessions: [invalidDate], completed: [], now: now, calendar: calendar)
        check(invalidStore.errorMessage != nil && invalidTransport.removals == unchangedRemovals && invalidTransport.items.count == 1, "Malformed date removed existing workouts")
        await invalidStore.sync(sessions: [edited, edited], completed: [], now: now, calendar: calendar)
        check(invalidStore.errorMessage != nil && invalidTransport.removals == unchangedRemovals, "Duplicate dates mutated schedule")

        let delayed = FakeWatchTransport(), delayedStore = store("delayed", delayed)
        delayed.delayVisibility = 2
        await delayedStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(delayedStore.errorMessage == nil && delayed.items.count == 1 && delayed.schedules == 1, "Delayed system confirmation was not awaited")

        let limited = FakeWatchTransport(), limitedStore = store("limited", limited)
        limited.items = [foreign]; limited.maximumCount = 1
        await limitedStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(limitedStore.errorMessage != nil && limited.schedules == 0 && limited.removals == 0, "Capacity preflight failed")
        let denied = FakeWatchTransport(), deniedStore = store("denied", denied)
        denied.authorized = false
        await deniedStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(denied.schedules == 0 && !deniedStore.automaticUpdates && deniedStore.errorMessage != nil, "Denied permission mutated schedule")
        denied.isSupported = false; denied.authorized = true
        await deniedStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(denied.schedules == 0 && deniedStore.errorMessage != nil, "Unsupported device scheduled workouts")
        let localCompleted = FakeWatchTransport(), completedStore = store("completed", localCompleted)
        await completedStore.sync(sessions: [run], completed: [run.date], requestAuthorization: true, now: now, calendar: calendar)
        check(localCompleted.schedules == 0, "Known completed run resent")
        try completedStore.setAutomaticUpdates(false)
        await completedStore.sync(sessions: [run], completed: [], now: now, calendar: calendar)
        check(localCompleted.schedules == 0, "Disabled automatic sync still ran")
        await completedStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        check(localCompleted.schedules == 1 && !completedStore.automaticUpdates, "Manual send re-enabled explicitly disabled automatic updates")

        let evidenceTransport = FakeWatchTransport(), evidenceStore = store("evidence", evidenceTransport)
        var evidence = AITrainingDiskState()
        evidence.revisions = [.init(createdAt: now, model: "test", promptVersion: "test", inputFingerprint: "",
            plan: .init(schema_version: 2, stage: "test", summary: "test", run_review: "", sessions: [run], adjustments: [], limitations: []))]
        let easyRun = ArchiveActivity(preview: WorkoutPreview(id: "easy-run", date: now, distanceKm: 2,
            duration: 900, avgHeartRate: 120, maxHeartRate: 130, avgPower: nil))
        _ = evidence.reconcileTraining(activities: [easyRun], calendar: calendar)
        await evidenceStore.sync(sessions: [run], completed: evidence.completedCurrentDates, requestAuthorization: true, now: now, calendar: calendar)
        check(evidenceTransport.items.count == 1, "Same-day easy run must not remove planned intervals")
        try evidence.associate(run, activity: easyRun)
        await evidenceStore.sync(sessions: [run], completed: evidence.completedCurrentDates, now: now, calendar: calendar)
        check(evidenceTransport.items.count == 1 && evidenceTransport.removals == 0, "Link alone must not remove Watch course")
        try evidence.confirmCompletion(run, activity: easyRun, now: now)
        await evidenceStore.sync(sessions: [run], completed: evidence.completedCurrentDates, now: now, calendar: calendar)
        check(evidenceTransport.items.isEmpty && evidenceTransport.removals == 1, "Human confirmation removes the pending course")
        evidence.undoCompletion(run)
        await evidenceStore.sync(sessions: [run], completed: evidence.completedCurrentDates, now: now, calendar: calendar)
        check(evidenceTransport.items.count == 1 && evidenceTransport.schedules == 2, "Undo restores current pending course without duplication")

        let racing = FakeWatchTransport(), racingStore = store("race", racing)
        var started = false
        var gate: CheckedContinuation<Void, Never>?
        racing.beforeSchedule = { started = true; await withCheckedContinuation { gate = $0 } }
        let first = Task { await racingStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar) }
        while !started { await Task.yield() }
        await racingStore.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        gate!.resume()
        await first.value
        let latest = try JSONDecoder().decode(AITrainingSession.self, from: racing.items[0].data)
        check(latest == edited && racing.items.count == 1 && !racingStore.isWorking, "In-flight older plan won over latest edit")

        let authorizing = FakeWatchTransport(), authorizingStore = store("authorizing", authorizing)
        started = false; gate = nil
        authorizing.beforeAuthorize = { started = true; await withCheckedContinuation { gate = $0 } }
        let permissionTask = Task { await authorizingStore.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar) }
        while !started { await Task.yield() }
        check(!authorizingStore.automaticUpdates, "Auto enabled before authorization/preflight")
        await authorizingStore.sync(sessions: [edited], completed: [], now: now, calendar: calendar)
        gate!.resume(); await permissionTask.value
        let afterAuthorization = try JSONDecoder().decode(AITrainingSession.self, from: authorizing.items[0].data)
        check(afterAuthorization == edited && authorizing.items.count == 1 && authorizingStore.automaticUpdates, "Edit while first permission prompt was open was lost")

        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: corruptURL)
        let corrupt = WatchPlanSyncStore(transport: FakeWatchTransport(), fileURL: corruptURL)
        await corrupt.sync(sessions: [run], completed: [], requestAuthorization: true, now: now, calendar: calendar)
        let corruptData = try Data(contentsOf: corruptURL)
        check(corrupt.errorMessage != nil && String(decoding: corruptData, as: UTF8.self) == "invalid", "Corrupt preferences overwritten")
        print("PASS: \(checks) Watch plan checks: exact repetitions/final recovery, distance estimates, schema/targets, manual edits/moves/persistence/AI overrides, deterministic IDs, retries, replacements, duplicate repair, rest removal, completed/history/foreign preservation, preflight/capacity/authorization, concurrent latest-plan reconciliation")
    }
}
