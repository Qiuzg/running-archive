import Foundation

/// Association is evidence to review, never evidence that a planned workout was completed.
struct TrainingSessionAssociation: Codable, Equatable {
    var session: AITrainingSession
    var candidates: [String] = []
    var legacyActivityIDs: [String]? = nil
    var activityID: String? = nil
    var activitySignature: String? = nil
    var dismissed = false
}

extension AITrainingDiskState {
    func association(for session: AITrainingSession) -> TrainingSessionAssociation? {
        associations?.first { $0.session == session }
    }
    func isCompleted(_ session: AITrainingSession) -> Bool {
        completed.contains { $0.session == session && $0.confirmedAt != nil }
    }
    var completedCurrentDates: Set<String> {
        Set((effectiveRevision?.plan.sessions ?? []).filter { isCompleted($0) }.map(\.date))
    }
    /// Old date-only checkmarks become review candidates; retain their original plan snapshots.
    @discardableResult mutating func migrateCompletionEvidence() -> Bool {
        let legacy = completed.filter { $0.confirmedAt == nil }
        guard !legacy.isEmpty else { return false }
        var entries = associations ?? []
        for item in legacy {
            if let i = entries.firstIndex(where: { $0.session == item.session }) {
                entries[i].legacyActivityIDs = Array(Set((entries[i].legacyActivityIDs ?? []) + item.activityIDs)).sorted()
            } else {
                entries.append(TrainingSessionAssociation(session: item.session, candidates: item.activityIDs, legacyActivityIDs: item.activityIDs))
            }
        }
        associations = entries
        completed.removeAll { $0.confirmedAt == nil }
        return true
    }
    @discardableResult mutating func reconcileTraining(activities: [ArchiveActivity], calendar: Calendar) -> Bool {
        let migrated = migrateCompletionEvidence()
        let before = associations ?? []
        let completedBefore = completed.count
        var entries = before
        for session in effectiveRevision?.plan.sessions ?? [] where session.kind != .rest {
            if !entries.contains(where: { $0.session == session }) { entries.append(.init(session: session)) }
        }
        for i in entries.indices {
            if !entries[i].dismissed {
                let available = TrainingExecution.candidates(for: entries[i].session, activities: activities, calendar: calendar).map(\.id)
                // Keep migration evidence even when HealthKit is temporarily unreadable or the old run was deleted.
                entries[i].candidates = available + (entries[i].legacyActivityIDs ?? []).filter { !available.contains($0) }.sorted()
            }
            // A deletion or a changed HealthKit summary invalidates a previous human confirmation.
            let entry = entries[i]
            let current = activities.first { $0.id == entry.activityID }
            if current.map({ TrainingExecution.activitySignature($0) }) != entry.activitySignature || current == nil {
                completed.removeAll { $0.session == entry.session }
            }
        }
        if entries != before { associations = entries }
        return migrated || entries != before || completed.count != completedBefore
    }
    mutating func associate(_ session: AITrainingSession, activity: ArchiveActivity?) throws {
        guard session.kind != .rest else { throw AITrainingError.invalid("休息日无需关联跑步。") }
        if let activity, (associations ?? []).contains(where: { $0.session != session && $0.activityID == activity.id }) {
            throw AITrainingError.invalid("这次跑步已关联另一项训练，请先解除原关联。")
        }
        var entries = associations ?? []
        let i = entries.firstIndex { $0.session == session } ?? entries.count
        if i == entries.count { entries.append(.init(session: session)) }
        entries[i].activityID = activity?.id
        entries[i].activitySignature = activity.map { TrainingExecution.activitySignature($0) }
        entries[i].dismissed = activity == nil
        if activity == nil { entries[i].candidates = [] }
        associations = entries
        completed.removeAll { $0.session == session }
    }
    mutating func confirmCompletion(_ session: AITrainingSession, activity: ArchiveActivity, now: Date = .now) throws {
        guard let link = association(for: session), link.activityID == activity.id,
              link.activitySignature == TrainingExecution.activitySignature(activity) else {
            throw AITrainingError.invalid("跑步记录已变化，请重新关联并核对。")
        }
        guard !completed.contains(where: { $0.id == session.date && $0.session != session }) else {
            throw AITrainingError.invalid("当天已有另一版训练被确认完成，请先撤销原确认。")
        }
        completed.removeAll { $0.session == session }
        completed.append(AICompletedSession(session: session, activityIDs: [activity.id], confirmedAt: now))
    }
    mutating func undoCompletion(_ session: AITrainingSession) {
        completed.removeAll { $0.session == session }
    }
}

struct TrainingExecutionStep: Identifiable {
    enum Phase { case warmup, work, recovery, cooldown }
    var id: Int
    var title: String
    var phase: Phase
    var goal: RunWorkoutStep
}
struct TrainingExecutionRow: Identifiable {
    var step: TrainingExecutionStep
    var start: Double?
    var end: Double?
    var seconds: Double?
    var meters: Double?
    var pace: Double?
    var heartRate: Double?
    var paceCoverage: Double?
    var heartCoverage: Double?
    var targetSeconds: Double?
    var supportedSeconds: Double = 0
    var coverage: Double?
    var id: Int { step.id }
    var quantity: Double? { step.goal.goal == .time ? seconds : meters }
    var quantityReached: Bool? { quantity.map { $0 + 0.001 >= step.goal.value } }
}
struct TrainingExecutionPoint: Identifiable {
    var id: Int
    var start: Double
    var end: Double
    var value: Double
}
struct TrainingExecutionComparison {
    var rows: [TrainingExecutionRow]
    var recordedBoundaries: Bool
    var note: String
    var pacePoints: [TrainingExecutionPoint]
    var heartPoints: [TrainingExecutionPoint]
    var duration: Double
    var distanceKm: Double?
    var mainRows: [TrainingExecutionRow] { rows.filter { $0.step.phase == .work } }
    var quantityText: String {
        guard !mainRows.isEmpty else { return "缺少可对照的训练段" }
        if mainRows.contains(where: { $0.quantityReached == nil }) { return "主体训练量：数据不足" }
        let n = mainRows.filter { $0.quantityReached == true }.count
        return "\(recordedBoundaries ? "主体训练量" : "推算窗口训练量")：\(n)/\(mainRows.count) 段达到目标"
    }
}

/// Separate presentation analysis. Existing load, HR zones and performance calculations are unchanged.
/// Raw source selection, point support (<=10s), and pause subtraction reuse the existing export analysis.
enum TrainingExecution {
    static func activitySignature(_ activity: ArchiveActivity) -> String {
        TrainingAnalysisMath.signature(activity) + "|end:" + (activity.workoutEndDate.map { String($0.timeIntervalSince1970) } ?? "unknown")
    }
    static func candidates(for session: AITrainingSession, activities: [ArchiveActivity], calendar: Calendar) -> [ArchiveActivity] {
        guard session.kind != .rest, let day = AIDate.parse(session.date, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        return activities.filter {
            let finish = $0.workoutEndDate ?? $0.date.addingTimeInterval(MonthlyReport.seconds($0.duration) ?? 0)
            return $0.date < end && finish > day
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    static func steps(_ session: AITrainingSession) -> [TrainingExecutionStep] {
        guard let w = try? session.resolvedWorkout() else { return [] }
        var result: [TrainingExecutionStep] = [.init(id: 0, title: "热身", phase: .warmup, goal: w.warmup)]
        var work = 0, recovery = 0
        for block in w.blocks {
            for _ in 0..<block.repetitions {
                for item in block.steps {
                    if item.purpose == .work { work += 1 } else { recovery += 1 }
                    result.append(.init(id: result.count, title: item.purpose == .work ? "主体 \(work)" : "恢复 \(recovery)",
                        phase: item.purpose == .work ? .work : .recovery, goal: item.step))
                }
            }
        }
        result.append(.init(id: result.count, title: "放松", phase: .cooldown, goal: w.cooldown))
        return result
    }
    static func compare(session: AITrainingSession, workout: ExportWorkout) -> TrainingExecutionComparison {
        let steps = steps(session), analysis = ExportObjectiveAnalysis(workout: workout)
        let timerKnown = analysis.pauseTimingKnown && workout.duration.isFinite && workout.duration > 0
        let active = timerKnown ? TrainingAnalysisMath.subtractPauses([
            ExportMetricInterval(start: 0, end: analysis.elapsed, value: 1)
        ], pauses: analysis.pauses) : []
        func spans(_ metric: ExportMetric) -> [TrainingAnalysisMath.Span] {
            guard timerKnown, workout.readIssues[metric.rawValue] == nil else { return [] }
            return TrainingAnalysisMath.subtractPauses(analysis.series[metric]?.intervals ?? [], pauses: analysis.pauses).filter {
                metric == .heartRate ? (20...260).contains($0.value) : $0.value.isFinite && $0.value >= 0
            }
        }
        let speed = spans(.speed), heart = spans(.heartRate)
        // Laps, including auto-kilometre laps, are deliberately excluded. Even matching counts
        // only provide recorded boundaries, not proof of association or correct step purpose.
        let recorded = workout.intervals.filter { $0.kind == "activity" || $0.eventType == "segment" }
            .sorted { $0.startElapsedSeconds < $1.startElapsedSeconds }
        var previous = 0.0
        let validRecorded = !steps.isEmpty && recorded.count == steps.count && recorded.allSatisfy { item in
            defer { previous = item.endElapsedSeconds }
            return item.startElapsedSeconds.isFinite && item.endElapsedSeconds.isFinite &&
                abs(item.startElapsedSeconds - previous) <= 0.001 && item.endElapsedSeconds > item.startElapsedSeconds &&
                item.endElapsedSeconds <= analysis.elapsed + 0.001
        } && abs(previous - analysis.elapsed) <= 0.001 && timerKnown
        func activeSeconds(_ start: Double, _ end: Double) -> Double {
            active.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
        }
        func weighted(_ spans: [TrainingAnalysisMath.Span], _ start: Double, _ end: Double) -> (seconds: Double, sum: Double) {
            spans.reduce((0.0, 0.0)) { result, span in
                let seconds = max(0, min(end, span.end) - max(start, span.start))
                return (result.0 + seconds, result.1 + seconds * span.value)
            }
        }
        func timeEnd(_ start: Double, _ amount: Double) -> Double {
            var remaining = amount
            for span in active where span.end > start {
                let a = max(start, span.start), seconds = span.end - a
                if seconds >= remaining { return a + remaining }
                remaining -= seconds
            }
            return analysis.elapsed
        }
        func distanceEnd(_ start: Double, _ amount: Double) -> Double? {
            var remaining = amount, cursor = start
            for span in speed where span.end > start {
                let a = max(start, span.start)
                // Missing speed over any active time makes the distance boundary unknown.
                guard activeSeconds(cursor, a) <= 0.001 else { return nil }
                let meters = (span.end - a) * span.value
                if span.value > 0 && meters >= remaining { return a + remaining / span.value }
                remaining -= meters; cursor = span.end
            }
            return activeSeconds(cursor, analysis.elapsed) <= 0.001 ? analysis.elapsed : nil
        }
        var cursor: Double? = timerKnown ? 0 : nil
        var rows: [TrainingExecutionRow] = []
        for (i, step) in steps.enumerated() {
            var row = TrainingExecutionRow(step: step)
            let start = validRecorded ? recorded[i].startElapsedSeconds : cursor
            let end: Double?
            if validRecorded { end = recorded[i].endElapsedSeconds }
            else if let start { end = step.goal.goal == .time ? timeEnd(start, step.goal.value) : distanceEnd(start, step.goal.value) }
            else { end = nil }
            cursor = end
            if let start, let end {
                row.start = start; row.end = end
                let seconds = activeSeconds(start, end)
                row.seconds = seconds
                let s = weighted(speed, start, end), h = weighted(heart, start, end)
                row.paceCoverage = seconds > 0 ? min(1, s.seconds / seconds) : nil
                row.heartCoverage = seconds > 0 ? min(1, h.seconds / seconds) : nil
                if s.seconds > 0, s.sum > 0 { row.pace = 1000 * s.seconds / s.sum }
                if h.seconds > 0 { row.heartRate = h.sum / h.seconds }
                let nativeDistance = validRecorded ? recorded[i].distanceKm : nil
                if let nativeDistance, nativeDistance.isFinite, nativeDistance >= 0 { row.meters = nativeDistance * 1000 }
                else if s.seconds + 0.001 >= seconds { row.meters = s.sum }
                let useHeart = step.goal.heart_rate_min != nil
                let target = useHeart ? heart : speed
                if step.goal.heart_rate_min != nil || step.goal.pace_min != nil {
                    row.supportedSeconds = useHeart ? h.seconds : s.seconds
                    row.coverage = seconds > 0 ? min(1, row.supportedSeconds / seconds) : nil
                    row.targetSeconds = target.reduce(0) { sum, span in
                        let seconds = max(0, min(end, span.end) - max(start, span.start))
                        let inRange: Bool
                        if useHeart { inRange = span.value >= step.goal.heart_rate_min! && span.value <= step.goal.heart_rate_max! }
                        else { inRange = span.value > 0 && 1000 / span.value >= step.goal.pace_min! && 1000 / span.value <= step.goal.pace_max! }
                        return sum + (inRange ? seconds : 0)
                    }
                }
            }
            rows.append(row)
        }
        func points(_ spans: [TrainingAnalysisMath.Span], pace: Bool) -> [TrainingExecutionPoint] {
            // Split at both chart bins and step edges: a selected step never borrows a neighbour's
            // samples. Merge only contiguous support, so pauses and missing samples stay blank.
            let boundaries = Set(Array(stride(from: 0.0, through: analysis.elapsed, by: 30)) +
                rows.flatMap { [$0.start, $0.end].compactMap { $0 } } + [analysis.elapsed]).sorted()
            var result: [TrainingExecutionPoint] = [], bin = 0
            for span in spans where !pace || span.value > 0 {
                var cursor = span.start
                while cursor < span.end, bin + 1 < boundaries.count {
                    if boundaries[bin + 1] <= cursor { bin += 1; continue }
                    let end = min(span.end, boundaries[bin + 1])
                    if let last = result.last, abs(last.end - cursor) < 0.000001, last.start >= boundaries[bin] {
                        let seconds = last.end - last.start
                        result[result.count - 1].value = (last.value * seconds + span.value * (end - cursor)) / (end - last.start)
                        result[result.count - 1].end = end
                    } else { result.append(.init(id: result.count, start: cursor, end: end, value: span.value)) }
                    cursor = end
                }
            }
            if pace { for i in result.indices { result[i].value = 1000 / result[i].value } }
            return result
        }
        let note: String
        if steps.isEmpty { note = "这版计划没有可执行分段，请查看原计划并人工核对。" }
        else if !timerKnown { note = "暂停记录与运动计时未对齐，无法可靠对照训练段。" }
        else if validRecorded { note = "使用记录中的分段边界，按顺序对照计划；分段用途仍需你核对。自动公里圈不参与匹配。" }
        else { note = "未获得与计划对应的完整分段，按计划从起跑顺序推算窗口，并扣除暂停。距离窗口使用完整速度数据推算；数据缺失时停止定位。这不代表已识别实际执行的训练段。" }
        return .init(rows: rows, recordedBoundaries: validRecorded, note: note,
            pacePoints: points(speed, pace: true), heartPoints: points(heart, pace: false), duration: workout.duration, distanceKm: workout.distanceKm)
    }
}

actor TrainingExecutionBuilder {
    func compare(session: AITrainingSession, workout: ExportWorkout) -> TrainingExecutionComparison {
        TrainingExecution.compare(session: session, workout: workout)
    }
}
