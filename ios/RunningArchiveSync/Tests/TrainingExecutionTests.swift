import Foundation

@main struct TrainingExecutionTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ text: String) {
        precondition(value(), text); checks += 1
    }
    static func near(_ actual: Double?, _ expected: Double, _ text: String) {
        check(actual.map { abs($0 - expected) < 0.0001 } == true, text + " got \(String(describing: actual))")
    }
    static func rejects(_ text: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(text) } catch { checks += 1 }
    }
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = AIDate.parse("2026-10-21", calendar: calendar)!
        var session = AITrainingSession(date: "2026-10-21", kind: .intervals, duration_minutes: 7,
            intensity: "快慢交替", purpose: "测试", steps: [], evidence_ids: [])
        let structure = RunWorkoutStructure(warmup: .init(value: 60, instructions: "热身"),
            blocks: [.init(repetitions: 2, steps: [
                .init(step: .init(value: 120, instructions: "快跑", pace_min: 280, pace_max: 320)),
                .init(purpose: .recovery, step: .init(value: 30, instructions: "恢复"))])],
            cooldown: .init(value: 60, instructions: "放松"))
        session.applyWorkout(structure)
        func activity(_ id: String = "run", start: Date? = nil, seconds: Double = 420) -> ArchiveActivity {
            ArchiveActivity(preview: WorkoutPreview(id: id, date: start ?? day.addingTimeInterval(6 * 3600),
                distanceKm: seconds / 300, duration: seconds, avgHeartRate: 150, maxHeartRate: 160, avgPower: nil,
                endDate: (start ?? day.addingTimeInterval(6 * 3600)).addingTimeInterval(seconds)))
        }
        func workout(seconds: Double = 420, active: Double? = nil, speed: Double = 10 / 3,
                     missingAfter: Double? = nil, pauses: [(Double, Double)] = [], intervals: [WorkoutIntervalPayload] = [],
                     extra: [ExportRawSample] = []) -> ExportWorkout {
            var samples = extra
            for t in stride(from: 0.0, to: missingAfter ?? seconds, by: 5) {
                samples.append(.init(metric: "running_speed", start: day.addingTimeInterval(t), end: day.addingTimeInterval(min(t + 5, seconds)),
                    value: speed, unit: "m/s", source: "watch", sourceBundle: "watch", sourcePriority: 2))
                samples.append(.init(metric: "heart_rate", start: day.addingTimeInterval(t), end: day.addingTimeInterval(min(t + 5, seconds)),
                    value: 150, unit: "bpm", source: "watch", sourceBundle: "watch", sourcePriority: 2))
            }
            return ExportWorkout(uuid: "run", start: day, end: day.addingTimeInterval(seconds), distanceKm: seconds * speed / 1000,
                duration: active ?? seconds, heartRate: 150, maxHeartRate: 150, power: nil, cadence: nil,
                energyKcal: nil, elevationGain: nil, indoor: false, source: "watch", sourceBundle: "watch", device: "watch",
                points: [], samples: samples, intervals: intervals,
                pauses: pauses.map { DateInterval(start: day.addingTimeInterval($0.0), end: day.addingTimeInterval($0.1)) })
        }
        let steps = TrainingExecution.steps(session)
        check(steps.count == 6 && steps.filter { $0.phase == .work }.count == 2, "expand all repetitions including recoveries")
        func intervals(kind: String = "activity", event: String? = nil, distances: [Double?]? = nil) -> [WorkoutIntervalPayload] {
            var cursor = 0.0
            return steps.enumerated().map { i, step in
                let start = cursor; cursor += step.goal.value
                return .init(index: i, kind: kind, activityType: nil, startElapsedSeconds: start, endElapsedSeconds: cursor,
                    durationSeconds: step.goal.value, distanceKm: distances?[i], paceSecondsPerKm: nil,
                    avgHeartRate: nil, maxHeartRate: nil, avgCadence: nil, avgPower: nil, eventType: event, label: nil)
            }
        }
        let a = activity(), other = activity("other")
        let plan = AITrainingPlan(schema_version: 2, stage: "测试", summary: "测试", run_review: "", sessions: [session], adjustments: [], limitations: [])
        var state = AITrainingDiskState()
        state.revisions = [.init(createdAt: day, model: "test", promptVersion: "test", inputFingerprint: "", plan: plan)]
        check(state.reconcileTraining(activities: [a, other], calendar: calendar), "new candidates persisted")
        check(state.completed.isEmpty && state.completedCurrentDates.isEmpty, "same-day runs never mark done or remove Watch workout")
        check(state.association(for: session)?.candidates == ["other", "run"], "multiple runs remain separate deterministic candidates")
        check(state.association(for: session)?.activityID == nil, "no implicit association even with candidates")
        check(!state.reconcileTraining(activities: [other, a], calendar: calendar), "unchanged refresh is idempotent")
        try state.associate(session, activity: a)
        check(!state.isCompleted(session), "manual association alone is not completion")
        try state.confirmCompletion(session, activity: a, now: day)
        check(state.isCompleted(session) && state.completedCurrentDates == [session.date], "only explicit confirmation affects Watch current plan")
        let saved = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONEncoder().encode(state))
        check(saved.isCompleted(session), "confirmation survives disk round-trip")
        state.undoCompletion(session)
        check(!state.isCompleted(session) && state.association(for: session)?.activityID == a.id, "undo retains linked evidence")
        try state.confirmCompletion(session, activity: a)
        try state.associate(session, activity: other)
        check(!state.isCompleted(session), "changing run revokes confirmation")
        rejects("cannot confirm stale linked run") { try state.confirmCompletion(session, activity: a) }
        try state.associate(session, activity: a)
        try state.confirmCompletion(session, activity: a)
        _ = state.reconcileTraining(activities: [activity(seconds: 300)], calendar: calendar)
        check(!state.isCompleted(session), "changed HealthKit summary requires review")
        rejects("cannot confirm old signature") { try state.confirmCompletion(session, activity: activity(seconds: 300)) }
        try state.associate(session, activity: a)
        try state.confirmCompletion(session, activity: a)
        _ = state.reconcileTraining(activities: [], calendar: calendar)
        check(!state.isCompleted(session), "deleted run revokes completion")
        try state.associate(session, activity: nil)
        _ = state.reconcileTraining(activities: [a], calendar: calendar)
        check(state.association(for: session)?.candidates.isEmpty == true, "unlink stays dismissed after refresh")
        try state.associate(session, activity: a)
        var edited = session; edited.workout?.blocks[0].repetitions = 3
        rejects("same activity cannot satisfy two sessions") { try state.associate(edited, activity: a) }
        try state.confirmCompletion(session, activity: a)
        state.revisions[0].plan.sessions = [edited]
        check(state.completedCurrentDates.isEmpty && !state.isCompleted(edited), "same-date edited/new plan does not inherit completion")
        var legacy = AITrainingDiskState()
        legacy.completed = [.init(session: session, activityIDs: [a.id, other.id])]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "associations")
        legacy = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONSerialization.data(withJSONObject: object))
        check(legacy.migrateCompletionEvidence(), "legacy date-only checkmarks migrate")
        check(legacy.completed.isEmpty && legacy.association(for: session)?.candidates.count == 2, "legacy plan and all evidence retained without false completion")
        check(!legacy.migrateCompletionEvidence(), "migration idempotent")
        _ = legacy.reconcileTraining(activities: [], calendar: calendar)
        check(Set(legacy.association(for: session)?.candidates ?? []) == [a.id, other.id], "legacy evidence survives an empty HealthKit refresh")
        let migratedAgain = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONEncoder().encode(legacy))
        check(migratedAgain.association(for: session)?.legacyActivityIDs == [a.id, other.id], "original migration evidence survives persistence")
        let midnight = activity("overnight", start: day.addingTimeInterval(-600), seconds: 1200)
        let endsAtMidnight = activity("previous", start: day.addingTimeInterval(-600), seconds: 600)
        check(TrainingExecution.candidates(for: session, activities: [midnight, endsAtMidnight], calendar: calendar).map(\.id) == ["overnight"], "cross-midnight overlap and exact midnight boundary")
        check(TrainingExecution.candidates(for: .rest(on: session.date), activities: [a], calendar: calendar).isEmpty, "rest day never gets run candidates")
        rejects("rest association rejected") { try state.associate(.rest(on: session.date), activity: a) }
        let full = TrainingExecution.compare(session: session, workout: workout())
        check(!full.recordedBoundaries, "elapsed match alone is a reference window, not detected intervals")
        near(full.mainRows[0].seconds, 120, "planned window active seconds")
        near(full.mainRows[0].pace, 300, "duration-weighted pace")
        near(full.mainRows[0].targetSeconds, 120, "target support uses raw points")
        near(full.mainRows[0].coverage, 1, "full target data coverage")
        check(full.mainRows.allSatisfy { $0.quantityReached == true }, "full quantity visible but not automatic completion")
        let easy = TrainingExecution.compare(session: session, workout: workout(speed: 2))
        near(easy.mainRows[0].targetSeconds, 0, "easy run same duration does not achieve interval intensity")
        let partial = TrainingExecution.compare(session: session, workout: workout(seconds: 240))
        near(partial.mainRows[1].seconds, 30, "unfinished second work interval remains partial")
        check(partial.mainRows[1].quantityReached == false, "partial quantity not done")
        let native = TrainingExecution.compare(session: session, workout: workout(intervals: intervals()))
        check(native.recordedBoundaries, "complete contiguous native boundaries available for review")
        let laps = TrainingExecution.compare(session: session, workout: workout(intervals: intervals(kind: "event", event: "lap")))
        check(!laps.recordedBoundaries, "even matching auto lap count cannot become structured workout")
        let segments = TrainingExecution.compare(session: session, workout: workout(intervals: intervals(kind: "event", event: "segment")))
        check(segments.recordedBoundaries, "explicit nonzero segment events can supply boundaries")
        let mismatch = TrainingExecution.compare(session: session, workout: workout(intervals: Array(intervals().dropLast())))
        check(!mismatch.recordedBoundaries, "incomplete native segments use labelled fallback")
        let gap = TrainingExecution.compare(session: session, workout: workout(missingAfter: 120))
        near(gap.mainRows[0].coverage, 0.5, "missing HR/speed time remains uncovered")
        near(gap.mainRows[0].targetSeconds, 60, "missing time never filled with total average")
        check(gap.mainRows[0].meters == nil, "incomplete speed cannot imply full distance")
        check(gap.pacePoints.allSatisfy { $0.end <= 120 }, "chart never bridges missing support")
        let paused = TrainingExecution.compare(session: session, workout: workout(seconds: 480, active: 420, pauses: [(100, 160)]))
        near(paused.mainRows[0].end, 240, "time window advances across pause")
        near(paused.mainRows[0].seconds, 120, "pause excluded from quantity")
        near(paused.mainRows[0].targetSeconds, 120, "pause excluded from target adherence")
        check(paused.pacePoints.allSatisfy { $0.end <= 100 || $0.start >= 160 }, "chart keeps partial-bin pause blank")
        let unknownPause = TrainingExecution.compare(session: session, workout: workout(seconds: 480, active: 420))
        check(unknownPause.mainRows.allSatisfy { $0.seconds == nil && $0.coverage == nil }, "unknown pause timing suppresses step verdicts")
        var distanceSession = session
        var distanceStructure = structure
        distanceStructure.blocks[0].steps[0].step = .init(goal: .distance, value: 400, estimated_seconds: 120, instructions: "400米", pace_min: 280, pace_max: 320)
        distanceSession.applyWorkout(distanceStructure)
        let distance = TrainingExecution.compare(session: distanceSession, workout: workout())
        near(distance.mainRows[0].end, 180, "distance uses speed integral rather than estimated duration")
        near(distance.mainRows[0].meters, 400, "distance goal actual quantity")
        let slowDistance = TrainingExecution.compare(session: distanceSession, workout: workout(speed: 2))
        near(slowDistance.mainRows[0].end, 260, "slow distance interval takes longer than plan estimate")
        check(slowDistance.mainRows[1].quantityReached == false, "remaining distance interval partial")
        let missingDistance = TrainingExecution.compare(session: distanceSession, workout: workout(missingAfter: 120))
        check(missingDistance.rows.dropFirst().allSatisfy { $0.start == nil }, "missing distance boundary does not shift subsequent steps by guessed duration")
        let nativeDistance = TrainingExecution.compare(session: distanceSession, workout: workout(intervals: intervals(distances: [nil,0.2,nil,0.4,nil,nil])))
        near(nativeDistance.mainRows[0].meters, 200, "native step distance preferred to velocity estimate")
        check(nativeDistance.mainRows[0].quantityReached == false, "native partial distance stays partial")
        var hrSession = session; var hrStructure = structure
        hrStructure.blocks[0].steps[0].step = .init(value: 120, instructions: "心率", heart_rate_min: 140, heart_rate_max: 150)
        hrSession.applyWorkout(hrStructure)
        let hr = TrainingExecution.compare(session: hrSession, workout: workout())
        near(hr.mainRows[0].targetSeconds, 120, "inclusive heart target edge")
        check(full.rows[0].targetSeconds == nil, "no target produces no intensity claim")
        var failedRead = workout(); failedRead.readIssues["running_speed"] = "failed"
        let failed = TrainingExecution.compare(session: session, workout: failedRead)
        near(failed.mainRows[0].coverage, 0, "read failure must not use partial sensor data for target judgment")
        check(failed.mainRows[0].pace == nil, "read failure does not expose a misleading speed average")
        var endChanged = a; endChanged.workoutEndDate = a.workoutEndDate?.addingTimeInterval(30)
        check(TrainingExecution.activitySignature(a) != TrainingExecution.activitySignature(endChanged), "pause/end correction invalidates execution evidence")
        var sourceMissing = workout(missingAfter: 0)
        sourceMissing.readIssues = [:]
        let missing = TrainingExecution.compare(session: session, workout: sourceMissing)
        near(missing.mainRows[0].seconds, 120, "quantity and unavailable intensity remain separate")
        near(missing.mainRows[0].coverage, 0, "no samples do not inherit summary HR/pace")
        let malformed = WorkoutIntervalPayload(index: 0, kind: "activity", activityType: nil,
            startElapsedSeconds: 0, endElapsedSeconds: 0, durationSeconds: 0, distanceKm: nil,
            paceSecondsPerKm: nil, avgHeartRate: nil, maxHeartRate: nil, avgCadence: nil, avgPower: nil, eventType: nil, label: nil)
        var invalidIntervals = intervals(); invalidIntervals[0] = malformed
        check(!TrainingExecution.compare(session: session, workout: workout(intervals: invalidIntervals)).recordedBoundaries, "zero-length native markers cannot masquerade as completed steps")
        let otherSource = ExportRawSample(metric: "heart_rate", start: day, end: day.addingTimeInterval(420), value: 220,
            unit: "bpm", source: "other", sourceBundle: "other", sourcePriority: 1)
        near(TrainingExecution.compare(session: hrSession, workout: workout(extra: [otherSource])).mainRows[0].heartRate, 150, "existing single-source selection retained")
        var legacySession = session; legacySession.workout = nil
        check(TrainingExecution.compare(session: legacySession, workout: workout()).rows.isEmpty, "old textual plan remains readable, no invented segment structure")
        // Chart bins at step boundaries cannot contain data from adjacent steps.
        var odd = session; var oddStructure = structure
        oddStructure.warmup.value = 65; odd.applyWorkout(oddStructure)
        let oddResult = TrainingExecution.compare(session: odd, workout: workout(seconds: 425))
        check(oddResult.pacePoints.allSatisfy { $0.end <= 65 || $0.start >= 65 }, "chart splits exactly at selected step boundary")
        print("PASS: \(checks) training execution checks (association/migration/confirmation, plan identity, Watch completion set, cross-midnight, repeated/partial steps, target coverage, pauses, sources, distance and chart gaps)")
    }
}
