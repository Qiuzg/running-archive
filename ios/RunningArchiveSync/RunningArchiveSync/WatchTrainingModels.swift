import Foundation

enum RunStepGoal: String, Codable, CaseIterable {
    case time, distance
    var title: String { self == .time ? "按时间" : "按距离" }
}

enum RunStepPurpose: String, Codable, CaseIterable {
    case work, recovery
    var title: String { self == .work ? "跑步段" : "恢复段" }
}

/// Seconds for time goals, meters for distance goals. Distance estimates never become watch time goals.
struct RunWorkoutStep: Codable, Equatable {
    var goal: RunStepGoal = .time
    var value: Double = 300
    var estimated_seconds: Double? = nil
    var instructions: String = "轻松跑，保持自然呼吸"
    var pace_min: Double? = nil
    var pace_max: Double? = nil
    var heart_rate_min: Double? = nil
    var heart_rate_max: Double? = nil

    var seconds: Double { goal == .time ? value : (estimated_seconds ?? 0) }
    var goalText: String {
        goal == .time ? String(format: "%g 分钟", value / 60) : String(format: "%g 米", value)
    }
    var targetText: String? {
        if let a = pace_min, let b = pace_max {
            func pace(_ v: Double) -> String { let s = Int(v.rounded()); return String(format: "%d:%02d", s / 60, s % 60) }
            return "配速 \(pace(a))–\(pace(b)) /km"
        }
        if let a = heart_rate_min, let b = heart_rate_max { return "心率 \(Int(a))–\(Int(b)) 次/分" }
        return nil
    }

    func validate() throws {
        guard value.isFinite, value >= 1,
              value <= (goal == .time ? 28800 : 100000),
              seconds.isFinite, seconds > 0, seconds <= 28800,
              (goal == .distance || estimated_seconds == nil),
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.count <= 1000 else {
            throw AITrainingError.invalid("请填写有效分段目标；距离段还需要预计用时。")
        }
        func validRange(_ a: Double?, _ b: Double?, _ range: ClosedRange<Double>) -> Bool {
            guard let a else { return b == nil }
            guard let b else { return false }
            return a.isFinite && b.isFinite && range.contains(a) && range.contains(b) && a <= b
        }
        guard validRange(pace_min, pace_max, 120...1200),
              validRange(heart_rate_min, heart_rate_max, 40...240),
              pace_min == nil || heart_rate_min == nil else {
            throw AITrainingError.invalid("每段只能设置一种提醒，请填写有效的配速或心率上下限。")
        }
    }
}

struct RunWorkoutInterval: Codable, Equatable {
    var purpose: RunStepPurpose = .work
    var step = RunWorkoutStep()
}

struct RunWorkoutBlock: Codable, Equatable {
    var repetitions: Int = 1
    var steps: [RunWorkoutInterval] = [RunWorkoutInterval()]
    var seconds: Double { steps.reduce(0) { $0 + $1.step.seconds } * Double(repetitions) }
}

struct RunWorkoutStructure: Codable, Equatable {
    var warmup = RunWorkoutStep()
    var blocks = [RunWorkoutBlock()]
    var cooldown = RunWorkoutStep()
    var seconds: Double { warmup.seconds + blocks.reduce(0) { $0 + $1.seconds } + cooldown.seconds }
    var allSteps: [RunWorkoutStep] { [warmup] + blocks.flatMap { $0.steps.map(\.step) } + [cooldown] }
    var hasPace: Bool { allSteps.contains { $0.pace_min != nil } }

    func validate(kind: AITrainingKind) throws {
        guard kind != .rest, (1...20).contains(blocks.count),
              blocks.allSatisfy({ (1...50).contains($0.repetitions) && (1...20).contains($0.steps.count)
                  && $0.steps.contains(where: { $0.purpose == .work }) }),
              blocks.reduce(0, { $0 + $1.steps.count * $1.repetitions }) <= 200 else {
            throw AITrainingError.invalid("请设置有效训练组、分段和重复次数（展开后最多 200 段）。")
        }
        if kind == .intervals {
            guard blocks.reduce(0, { $0 + $1.repetitions * $1.steps.filter { $0.purpose == .work }.count }) >= 2,
                  blocks.contains(where: { $0.steps.contains(where: { $0.purpose == .recovery }) }) else {
                throw AITrainingError.invalid("间歇训练必须明确至少两个跑步段及段间恢复，不能只写文字说明。")
            }
        }
        try allSteps.forEach { try $0.validate() }
        guard seconds.isFinite, (60...28800).contains(seconds) else {
            throw AITrainingError.invalid("含重复次数的训练总用时需要在 1 分钟至 8 小时内。")
        }
    }

    /// Only an unambiguous legacy continuous run can be migrated. Never guess interval repetitions.
    static func legacy(_ session: AITrainingSession) throws -> Self {
        guard session.kind != .intervals, session.kind != .rest,
              session.steps.map(\.phase) == ["热身", "主体", "放松"] else {
            throw AITrainingError.invalid("这份旧计划没有明确分段，请重新生成，或手动设置完整分段后再发送。")
        }
        func step(_ index: Int) -> RunWorkoutStep {
            RunWorkoutStep(value: session.steps[index].minutes * 60, instructions: session.steps[index].instructions)
        }
        return Self(warmup: step(0), blocks: [RunWorkoutBlock(steps: [RunWorkoutInterval(step: step(1))])], cooldown: step(2))
    }
}

struct AITrainingSessionOverride: Codable {
    var session: AITrainingSession
    var editedAt: Date
}

extension AITrainingDiskState {
    var effectiveRevision: AIPlanRevision? {
        guard var revision = revisions.last else { return nil }
        let overrides = (manualOverrides ?? []).reduce(into: [String: AITrainingSession]()) { $0[$1.session.date] = $1.session }
        revision.plan.sessions = revision.plan.sessions.map { overrides[$0.date] ?? $0 }
        return revision
    }

    mutating func editSession(originalDate: String, session: AITrainingSession, now: Date = .now,
                              calendar: Calendar = AIDate.localCalendar) throws {
        guard let revision = effectiveRevision,
              revision.plan.sessions.contains(where: { $0.date == originalDate }),
              revision.plan.sessions.contains(where: { $0.date == session.date }),
              let day = AIDate.parse(session.date, calendar: calendar), day >= calendar.startOfDay(for: now),
              let originalDay = AIDate.parse(originalDate, calendar: calendar), originalDay >= calendar.startOfDay(for: now),
              !completed.contains(where: { $0.id == originalDate || $0.id == session.date }),
              !session.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !session.intensity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITrainingError.invalid("只能修改本期尚未完成的训练，请检查日期、目的和强度。")
        }
        if session.date != originalDate,
           revision.plan.sessions.first(where: { $0.date == session.date })?.kind != .rest {
            throw AITrainingError.invalid("目标日期已有训练，请先调整该日安排。")
        }
        if session.kind == .rest {
            guard session.workout == nil, session.steps.isEmpty, session.duration_minutes == 0,
                  session.distance_km == nil, session.pace_seconds_per_km_min == nil, session.pace_seconds_per_km_max == nil else {
                throw AITrainingError.invalid("休息日不能包含训练分段。")
            }
        } else { _ = try session.resolvedWorkout() }
        var overrides = manualOverrides ?? []
        overrides.removeAll { $0.session.date == originalDate || $0.session.date == session.date }
        if session.date != originalDate { overrides.append(.init(session: .rest(on: originalDate), editedAt: now)) }
        overrides.append(.init(session: session, editedAt: now))
        manualOverrides = overrides
    }
}

extension AITrainingSession {
    var plannedDurationText: String {
        let estimated = workout?.allSteps.contains(where: { $0.goal == .distance }) == true
        return (estimated ? "预计 " : "") + String(format: "%g 分钟", duration_minutes)
    }

    func resolvedWorkout() throws -> RunWorkoutStructure {
        guard let result = workout else {
            throw AITrainingError.invalid("这份旧计划尚未确认可执行分段，请重新生成，或手动检查并保存分段后再发送。")
        }
        try result.validate(kind: kind)
        guard abs(result.seconds - duration_minutes * 60) <= 1 else {
            throw AITrainingError.invalid("分段乘以重复次数后的总用时与计划不一致，请修改后再发送。")
        }
        return result
    }

    mutating func applyWorkout(_ structure: RunWorkoutStructure) {
        workout = structure
        duration_minutes = structure.seconds / 60
        // The executable structure is authoritative. Old overview fields must not contradict it.
        pace_seconds_per_km_min = nil
        pace_seconds_per_km_max = nil
        distance_km = nil
        steps = []
    }

    static func rest(on day: String) -> Self {
        Self(date: day, kind: .rest, duration_minutes: 0, intensity: "休息", purpose: "恢复与休息", steps: [], evidence_ids: [])
    }
}
