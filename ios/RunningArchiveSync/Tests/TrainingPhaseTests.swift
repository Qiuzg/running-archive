import Foundation

@main struct TrainingPhaseTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ text: String) {
        precondition(value(), text); checks += 1
    }
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ key: String) -> Date { AIDate.parse(key, calendar: calendar)! }
        let start = date("2026-10-21"), now = date("2026-10-23").addingTimeInterval(12 * 3600)
        func activity(_ id: String, day: String = "2026-10-21", hour: Double = 7, minutes: Double = 30) -> ArchiveActivity {
            let begin = date(day).addingTimeInterval(hour * 3600)
            return ArchiveActivity(preview: WorkoutPreview(id: id, date: begin, distanceKm: minutes / 6,
                duration: minutes * 60, avgHeartRate: 150, maxHeartRate: 160, avgPower: nil,
                endDate: begin.addingTimeInterval(minutes * 60)))
        }
        var state = AITrainingDiskState()
        let sessions = (0..<7).map { offset in
            AITrainingSession(date: AIDate.key(calendar.date(byAdding: .day, value: offset, to: start)!, calendar: calendar),
                kind: offset == 1 ? .rest : .easy, duration_minutes: offset == 1 ? 0 : 30,
                distance_km: offset == 0 ? 5 : nil, intensity: "轻松", purpose: "耐力", steps: [], evidence_ids: [])
        }
        state.revisions = [.init(createdAt: start, model: "test", promptVersion: "test", inputFingerprint: "test",
            plan: .init(schema_version: 2, stage: "基础耐力", summary: "维持规律训练", run_review: "", sessions: sessions, adjustments: [], limitations: []),
            profileContext: state.profile)]
        let run = activity("run"), extra = activity("extra", hour: 18), restRun = activity("rest-run", day: "2026-10-22")
        func overview(_ activities: [ArchiveActivity] = [], _ source: AITrainingDiskState? = nil,
                      window: TrainingPhaseOverview.Window = .plan, time: Date? = nil) -> TrainingPhaseOverview {
            TrainingPhaseOverview(state: source ?? state, activities: activities, window: window, now: time ?? now, calendar: calendar)
        }
        let empty = overview()
        check(empty.days.count == 7 && empty.days.first!.id == "2026-10-21" && empty.days.last!.id == "2026-10-27", "seven calendar days match plan")
        check(empty.plannedCount == 6 && empty.plannedMinutes == 180, "rest excluded from course count")
        check(empty.specifiedDistanceCount == 1 && empty.plannedDistance == 5, "partial planned distance not extrapolated")
        check(empty.actual.isEmpty && empty.actualMinutes == 0 && empty.confirmedCount == 0, "missing actual is not completion")
        check(empty.days[0].status == .noRecord && empty.days[1].status == .rest && empty.days[2].status == .scheduled, "past/today/rest distinct")
        check(!empty.expired && !empty.profileUnknown && !empty.profileChanged, "snapshot current")
        let actual = overview([run, extra, restRun, run])
        check(actual.actual.count == 3 && actual.actualDistance == 15 && actual.actualMinutes == 90, "actual deduplicated by ID")
        check(actual.days[0].actual.count == 2 && actual.days[0].status == .candidate, "two runs do not auto complete")
        check(actual.days[1].actual.count == 1 && actual.days[1].status == .rest, "rest-day run visible without inventing course")
        check(actual.confirmedCount == 0, "all actual still unconfirmed")
        try state.associate(sessions[0], activity: run)
        check(overview([run]).days[0].status == .linked, "linked not complete")
        try state.confirmCompletion(sessions[0], activity: run, now: now)
        check(overview([run]).confirmedCount == 1 && overview([run]).days[0].status == .confirmed, "exact confirmed session")
        check(state.completedCurrentDates == [sessions[0].date], "Watch receives same completion evidence")
        check(overview().days[0].status == .missing && overview().confirmedCount == 0, "unreadable linked activity never green")
        let changed = activity("run", minutes: 54)
        check(overview([changed]).days[0].status == .changed && overview([changed]).confirmedCount == 0, "changed record invalidates visual checkmark")
        state.undoCompletion(sessions[0])
        check(overview([run]).days[0].status == .linked && state.completedCurrentDates.isEmpty, "undo returns pending and Watch course")
        try state.associate(sessions[0], activity: nil)
        check(overview([run]).days[0].status == .unlinked, "dismissed association not automatically reselected")
        check(overview([run]).days[0].actual.count == 1, "dismissal never hides actual")

        let crossing = activity("cross", day: "2026-10-20", hour: 23.75, minutes: 30)
        var crossState = state; crossState.associations = nil
        check(overview([crossing], crossState).days[0].status == .candidate, "cross-midnight candidate")
        try crossState.associate(sessions[0], activity: crossing)
        try crossState.confirmCompletion(sessions[0], activity: crossing, now: now)
        let cross = overview([crossing], crossState)
        check(cross.days[0].linked?.id == "cross" && cross.days[0].actual.isEmpty, "cross-day linked run visible separately")
        check(cross.actual.isEmpty && cross.confirmedCount == 1, "cross-day confirmation not added to incorrect actual date")
        let recentCross = overview([crossing], crossState, window: .recent)
        check(recentCross.actual.count == 1 && recentCross.actualDistance == 5, "cross-day counted once in correct window")

        var editState = state
        editState.associations = nil
        var edited = sessions[2]
        edited.kind = .long; edited.duration_minutes = 60; edited.distance_km = 10
        editState.manualOverrides = [.init(session: edited, editedAt: now)]
        let edit = overview([], editState)
        check(edit.days[2].session == edited && edit.days[2].manuallyEdited, "manual course takes precedence")
        check(edit.plannedMinutes == 210 && edit.plannedDistance == 15 && edit.specifiedDistanceCount == 2, "manual quantities reflected")
        check(editState.revisions[0].plan.sessions[2] == sessions[2], "phase summary snapshot unchanged")
        var replacement = sessions[0]; replacement.purpose = "不同的课"
        editState.associations = [.init(session: sessions[0], activityID: run.id, activitySignature: TrainingExecution.activitySignature(run))]
        editState.completed = [.init(session: sessions[0], activityIDs: [run.id], confirmedAt: now)]
        editState.manualOverrides!.append(.init(session: replacement, editedAt: now))
        check(overview([run], editState).days[0].status == .candidate && overview([run], editState).confirmedCount == 0, "old snapshot completion not applied to new course")

        let future = activity("future", day: "2026-10-24")
        let ongoing = activity("ongoing", day: "2026-10-23", hour: 11.9)
        check(overview([future, ongoing]).actual.isEmpty, "exclude future and unfinished workouts")
        let past = overview([], time: date("2026-10-28"))
        check(past.expired && past.days.first!.id == "2026-10-21", "expired plan remains reviewable")
        let next = overview([], window: .upcoming, time: date("2026-10-28"))
        check(next.days.allSatisfy { $0.status == .unplanned } && next.plannedCount == 0, "no synthetic rest for missing future plan")
        check(overview([], time: date("2026-10-27").addingTimeInterval(86399)).expired == false, "last plan day inclusive")
        check(overview([], window: .recent).days.first!.id == "2026-10-17", "recent includes today and six prior dates")
        check(overview([], window: .upcoming).days.first!.id == "2026-10-23", "future starts local today")
        var noPlan = AITrainingDiskState()
        check(overview([run], noPlan).days.allSatisfy { $0.session == nil } && !overview([], noPlan).expired, "empty state safe")
        noPlan.revisions = state.revisions; noPlan.revisions[0].profileContext = nil
        check(overview([], noPlan).profileUnknown && !overview([], noPlan).profileChanged, "legacy target unknown, not fabricated")
        let decoded = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONEncoder().encode(noPlan))
        check(decoded.revisions[0].profileContext == nil, "legacy optional snapshot decodes")
        let roundtrip = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONEncoder().encode(state))
        check(roundtrip.revisions[0].profileContext == state.profile, "new snapshot persists")
        var goalState = state; goalState.profile.goal = "新的比赛"
        check(overview([], goalState).profileChanged, "target edits mark old phase stale")
        goalState = state; goalState.profile.minutesPerDay += 5
        check(overview([], goalState).profileChanged, "availability edits mark phase stale")
        var profile = state.profile
        let race = RaceGoal(name: "秋季半马", date: date("2026-11-15"), distanceKm: 21.0975, targetSeconds: 6300)
        profile.useRaceGoal(race)
        check(profile.goal == race.name && profile.targetDate == race.date && profile.targetDistanceKm == race.distanceKm && profile.targetSeconds == 6300, "race choice copies exact goal")
        check(profile.availableDays == state.profile.availableDays && profile.minutesPerDay == state.profile.minutesPerDay && profile.longRunDay == state.profile.longRunDay, "race choice preserves available times")
        var untimed = race; untimed.targetSeconds = nil; profile.useRaceGoal(untimed)
        check(profile.targetSeconds == nil, "untimed goal clears old target time")
        check(profile.goal == race.name, "journal race edits do not silently mutate active profile")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(editState)
        _ = overview([run], editState)
        let after = try encoder.encode(editState)
        check(before == after, "overview never mutates completion/plan/Watch state")

        var dst = Calendar(identifier: .gregorian); dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = AIDate.parse("2026-11-01", calendar: dst)!.addingTimeInterval(12 * 3600)
        let dstView = TrainingPhaseOverview(state: .init(), activities: [], window: .upcoming, now: dstNow, calendar: dst)
        check(dstView.days.map(\.id) == (1...7).map { String(format: "2026-11-%02d", $0) }, "DST calendar addition, not seconds")
        check(dstView.days[1].date.timeIntervalSince(dstView.days[0].date) == 90000, "DST 25-hour day respected")
        let boundary = activity("boundary", day: "2026-10-21", hour: 0)
        check(overview([boundary]).days[0].actual.count == 1, "local midnight belongs to starting day")
        print("Training phase tests passed (\(checks) checks)")
    }
}
