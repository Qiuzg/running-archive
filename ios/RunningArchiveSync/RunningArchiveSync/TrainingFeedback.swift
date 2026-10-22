import Foundation

/// Explicitly shared subjective evidence; never modifies objective physiology or training load.
struct RunSubjectiveFeedback: Codable, Equatable, Identifiable {
    var id: String
    var activity_id: String
    var workout_start: Date
    var effort_1_to_10: Int?
    var feeling: RunFeeling?
    var post_run_fatigue: RunFatigue?
    var ratings_recorded_at: Date?
    var ratings_updated_at: Date?
    var note: String?
    var note_updated_at: Date?
}
struct AITrainingFeedbackReview: Codable, Equatable {
    var evidence_ids: [String]
    var observation: String
    var plan_response: String
}

enum TrainingFeedback {
    static func finished(_ activity: ArchiveActivity, now: Date) -> Bool {
        activity.date <= now && (activity.workoutEndDate ?? activity.date.addingTimeInterval(TrainingFormat.seconds(activity.duration))) <= now
    }
    static func recentActivities(_ activities: [ArchiveActivity], now: Date, calendar: Calendar, days: Int = 42) -> [ArchiveActivity] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return activities.filter { $0.date >= cutoff && finished($0, now: now) }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    static func shared(activities: [ArchiveActivity], journal: JournalData, now: Date, calendar: Calendar) -> [RunSubjectiveFeedback] {
        recentActivities(activities, now: now, calendar: calendar).compactMap { activity in
            guard let a = journal.annotations[activity.id], a.sharing != .localOnly else { return nil }
            let effort = a.effort.flatMap { (1...10).contains($0) ? $0 : nil }
            let note = a.sharing == .ratingsAndNote ? String(a.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)) : ""
            guard effort != nil || a.feeling != nil || a.fatigue != nil || !note.isEmpty,
                  [a.feedbackRecordedAt, a.feedbackUpdatedAt, note.isEmpty ? nil : a.noteUpdatedAt].compactMap({ $0 }).allSatisfy({ $0 <= now }) else { return nil }
            return RunSubjectiveFeedback(id: "feedback:" + activity.id, activity_id: activity.id, workout_start: activity.date,
                effort_1_to_10: effort, feeling: a.feeling, post_run_fatigue: a.fatigue,
                ratings_recorded_at: a.hasRatings ? a.feedbackRecordedAt : nil,
                ratings_updated_at: a.hasRatings ? a.feedbackUpdatedAt : nil,
                note: note.isEmpty ? nil : note, note_updated_at: note.isEmpty ? nil : a.noteUpdatedAt)
        }
    }
    static func stale(snapshot: [RunSubjectiveFeedback]?, activities: [ArchiveActivity], journal: JournalData, now: Date, calendar: Calendar) -> Bool {
        (snapshot ?? []) != shared(activities: activities, journal: journal, now: now, calendar: calendar)
    }
}

extension AITrainingPlan {
    func validateFeedback(_ feedback: [RunSubjectiveFeedback]) throws {
        let allowed = Set(feedback.map(\.id)), reviews = feedback_review ?? []
        guard reviews.count <= max(1, feedback.count), reviews.allSatisfy({ review in
            !review.evidence_ids.isEmpty && Set(review.evidence_ids).isSubset(of: allowed) &&
                !review.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && review.observation.count <= 2000 &&
                !review.plan_response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && review.plan_response.count <= 2000
        }) else { throw AITrainingError.invalid("主观反馈的引用或调整说明不完整，原计划已保留。") }
        // At minimum the latest reported run must be explicitly discussed. Older reports may be grouped.
        if let latest = feedback.last, !reviews.contains(where: { $0.evidence_ids.contains(latest.id) }) {
            throw AITrainingError.invalid("新计划未解释最新跑后反馈的影响，原计划已保留，请重试。")
        }
    }
}
