import Foundation

/// Presentation only: reuse the saved phase, effective courses and explicit completion evidence.
/// No inferred phase boundaries, performance forecast, or new training-load calculation.
struct TrainingPhaseOverview {
    enum Window: String, CaseIterable, Identifiable {
        case plan = "本期七天", recent = "最近七天", upcoming = "未来七天"
        var id: String { rawValue }
    }
    enum Status: String {
        case unplanned = "本期未安排", rest = "计划休息", scheduled = "待执行"
        case noRecord = "未见跑步记录", unlinked = "跑步未关联", candidate = "有跑步待核对", linked = "已关联 · 待确认"
        case missing = "关联记录不可用", changed = "记录变化 · 待核对", confirmed = "已确认完成"
    }
    struct Day: Identifiable {
        var date: Date
        var id: String
        var session: AITrainingSession?
        var actual: [ArchiveActivity]
        var linked: ArchiveActivity?
        var status: Status
        var manuallyEdited: Bool
    }
    var days: [Day]
    var planStart: Date?
    var planEnd: Date?
    var expired: Bool
    var profileChanged: Bool
    var profileUnknown: Bool
    var plannedCount: Int { days.filter { $0.session.map { $0.kind != .rest } == true }.count }
    var confirmedCount: Int { days.filter { $0.status == .confirmed }.count }
    var plannedMinutes: Double { days.compactMap(\.session).reduce(0) { $0 + $1.duration_minutes } }
    var specifiedDistanceCount: Int { days.filter { $0.session?.kind != .rest && $0.session?.distance_km != nil }.count }
    var plannedDistance: Double { days.compactMap { $0.session?.distance_km }.reduce(0, +) }
    var actual: [ArchiveActivity] { days.flatMap(\.actual) }
    var actualDistance: Double { actual.reduce(0) { $0 + $1.distanceKm } }
    var actualMinutes: Double { actual.reduce(0) { $0 + TrainingFormat.seconds($1.duration) / 60 } }

    init(state: AITrainingDiskState, activities: [ArchiveActivity], window: Window = .plan,
         now: Date = .now, calendar: Calendar = AIDate.localCalendar) {
        let revision = state.effectiveRevision
        let sessions = revision?.plan.sessions ?? []
        let dates = sessions.compactMap { AIDate.parse($0.date, calendar: calendar) }.sorted()
        planStart = dates.first
        planEnd = dates.last
        let today = calendar.startOfDay(for: now)
        expired = dates.last.map { $0 < today } ?? false
        profileChanged = revision?.profileContext.map { $0 != state.profile } ?? false
        profileUnknown = revision != nil && revision?.profileContext == nil
        let start: Date
        switch window {
        case .plan: start = dates.first ?? today
        case .recent: start = calendar.date(byAdding: .day, value: -6, to: today)!
        case .upcoming: start = today
        }
        // A HealthKit workout belongs to the calendar day on which it started, even if linked across midnight.
        var seen = Set<String>()
        let finished = activities.filter { TrainingFeedback.finished($0, now: now) && seen.insert($0.id).inserted }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let byDay = Dictionary(grouping: finished) { AIDate.key($0.date, calendar: calendar) }
        let byID = Dictionary(uniqueKeysWithValues: finished.map { ($0.id, $0) })
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = AIDate.key(date, calendar: calendar)
            let session = sessions.first { $0.date == key }
            let actual = byDay[key] ?? []
            let association = session.flatMap { state.association(for: $0) }
            let linked = association?.activityID.flatMap { byID[$0] }
            let status: Status
            if let session, session.kind != .rest {
                if let association, association.activityID != nil {
                    if let linked {
                        if association.activitySignature != TrainingExecution.activitySignature(linked) { status = .changed }
                        else { status = state.isCompleted(session) ? .confirmed : .linked }
                    } else { status = .missing }
                } else if association?.dismissed != true && !TrainingExecution.candidates(for: session, activities: finished, calendar: calendar).isEmpty {
                    status = .candidate
                } else if !actual.isEmpty { status = .unlinked }
                else { status = date < today ? .noRecord : .scheduled }
            } else { status = session == nil ? .unplanned : .rest }
            return Day(date: date, id: key, session: session, actual: actual, linked: linked, status: status,
                manuallyEdited: session.map { s in state.manualOverrides?.contains { $0.session == s } == true } ?? false)
        }
    }
}
