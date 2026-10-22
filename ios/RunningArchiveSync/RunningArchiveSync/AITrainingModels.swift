import Foundation

struct AITrainingProfile: Codable, Equatable {
    var goal = "保持规律跑步，逐步提升耐力"
    var targetDistanceKm: Double? = nil
    var targetDate: Date? = nil
    var targetSeconds: Double? = nil
    // ISO weekday: Monday = 1, Sunday = 7.
    var availableDays = [2, 4, 6, 7]
    var minutesPerDay: Double = 60
    var longRunDay = 7
    var longRunMinutes: Double = 120

    mutating func useRaceGoal(_ race: RaceGoal) {
        goal = race.name
        targetDistanceKm = race.distanceKm
        targetDate = race.date
        targetSeconds = race.targetSeconds
    }

    func validate(now: Date = .now) throws {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.count <= 1000, !availableDays.isEmpty,
              Set(availableDays).count == availableDays.count,
              availableDays.allSatisfy({ (1...7).contains($0) }),
              availableDays.contains(longRunDay),
              minutesPerDay.isFinite, (10...300).contains(minutesPerDay),
              longRunMinutes.isFinite, (10...480).contains(longRunMinutes) else {
            throw AITrainingError.invalid("请填写目标、可训练日期及有效的训练时长。")
        }
        if let km = targetDistanceKm, !km.isFinite || !(0.1...300).contains(km) {
            throw AITrainingError.invalid("目标距离无效。")
        }
        if let seconds = targetSeconds, !seconds.isFinite || !(1...604800).contains(seconds) || targetDistanceKm == nil {
            throw AITrainingError.invalid("目标成绩需要同时设置目标距离。")
        }
        if let date = targetDate, Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: now) {
            throw AITrainingError.invalid("目标日期已过去，请更新目标。")
        }
    }

    static func targetTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.last! < 60, values[values.count - 2] < 60 else { return nil }
        let seconds = values.reduce(0) { $0 * 60 + $1 }
        return (1...604800).contains(seconds) ? seconds : nil
    }
}

struct AITrainingConfiguration: Codable, Equatable {
    static let defaultBaseURL = "https://api.deepseek.com"
    // Official API alias for DeepSeek-V4.1-Flash; not "deepseek-v4.1-flash".
    static let defaultModel = "deepseek-flash"
    var baseURL = defaultBaseURL
    var model = defaultModel
    var enabled = false
    var automatic = true

    var endpoint: URL? { apiBase?.appendingPathComponent("chat/completions") }
    var modelsEndpoint: URL? { apiBase?.appendingPathComponent("models") }

    private var apiBase: URL? {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { return nil }
        return base
    }
}

enum AITrainingError: LocalizedError {
    case invalid(String)
    case http(Int)
    case emptyResponse
    case responseFormat
    case truncatedResponse
    case filteredResponse
    case unreadable
    var errorDescription: String? {
        switch self {
        case .invalid(let text): text
        case .http(401), .http(403): "DeepSeek 鉴权失败，请检查 API Key 和账户权限。"
        case .http(402): "DeepSeek 账户余额不足，请充值后重试。"
        case .http(429): "DeepSeek 请求繁忙，请稍后重试。"
        case .http(let code): "DeepSeek 请求失败（HTTP \(code)），已保留原计划。"
        case .emptyResponse: "接口未返回完整的模型回复，请重试；原计划已保留。"
        case .responseFormat: "接口返回的数据不符合 Chat Completions 响应格式，无法读取模型回复。请重试或检查基础地址。"
        case .truncatedResponse: "模型回复达到输出长度上限，内容不完整，请重试；原计划已保留。"
        case .filteredResponse: "模型回复被服务端过滤，没有生成可用内容；原计划已保留。"
        case .unreadable: "本机 AI 计划无法读取，已保留原文件，请先备份并检查。"
        }
    }
}

enum AITrainingKind: String, Codable, CaseIterable {
    case rest, easy, recovery, long, tempo, intervals, race
    var title: String {
        switch self {
        case .rest: "休息"; case .easy: "轻松跑"; case .recovery: "恢复跑"
        case .long: "长距离"; case .tempo: "节奏跑"; case .intervals: "间歇跑"; case .race: "比赛"
        }
    }
}

struct AITrainingStep: Codable, Equatable {
    var phase: String
    var minutes: Double
    var instructions: String
}

struct AITrainingSession: Codable, Identifiable, Equatable {
    var date: String
    var kind: AITrainingKind
    var duration_minutes: Double
    var distance_km: Double?
    var pace_seconds_per_km_min: Double?
    var pace_seconds_per_km_max: Double?
    var intensity: String
    var purpose: String
    var steps: [AITrainingStep]
    var evidence_ids: [String]
    var workout: RunWorkoutStructure? = nil
    var id: String { date }
}

struct AITrainingAdjustment: Codable, Equatable {
    var date: String
    var change: String
    var reason: String
    var evidence_ids: [String]
}

struct AITrainingPlan: Codable, Equatable {
    var schema_version: Int
    var stage: String
    var summary: String
    var run_review: String
    var sessions: [AITrainingSession]
    var adjustments: [AITrainingAdjustment]
    var limitations: [String]
    var feedback_review: [AITrainingFeedbackReview]? = nil

    func validate(profile: AITrainingProfile, start: Date, evidenceIDs: Set<String>, calendar: Calendar) throws {
        guard (1...2).contains(schema_version), !stage.isEmpty, !summary.isEmpty, sessions.count == 7 else {
            throw AITrainingError.invalid("模型返回的计划结构不完整，原计划已保留。")
        }
        let expected = (0..<7).map { AIDate.key(calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar) }
        guard sessions.map(\.date).sorted() == expected.sorted() else {
            throw AITrainingError.invalid("模型返回的日期不符合未来七天窗口，原计划已保留。")
        }
        for session in sessions {
            guard let date = AIDate.parse(session.date, calendar: calendar),
                  session.duration_minutes.isFinite, session.duration_minutes >= 0,
                  !session.purpose.isEmpty, !session.intensity.isEmpty,
                  Set(session.evidence_ids).isSubset(of: evidenceIDs) else {
                throw AITrainingError.invalid("模型返回的训练字段或依据无效，原计划已保留。")
            }
            if let km = session.distance_km, !km.isFinite || km < 0 || km > 300 {
                throw AITrainingError.invalid("模型返回的距离无效。")
            }
            let paces = [session.pace_seconds_per_km_min, session.pace_seconds_per_km_max]
            guard paces.allSatisfy({ $0 == nil || ($0!.isFinite && (120...1200).contains($0!)) }),
                  (paces[0] == nil) == (paces[1] == nil),
                  paces[0] == nil || paces[0]! <= paces[1]! else {
                throw AITrainingError.invalid("模型返回的配速区间无效。")
            }
            if session.kind == .rest {
                guard session.duration_minutes == 0, (session.distance_km ?? 0) == 0,
                      session.steps.isEmpty, session.workout == nil, paces[0] == nil else {
                    throw AITrainingError.invalid("休息日包含了训练内容，原计划已保留。")
                }
            } else {
                let day = AIDate.weekday(date, calendar: calendar)
                let limit = day == profile.longRunDay ? profile.longRunMinutes : profile.minutesPerDay
                guard profile.availableDays.contains(day), session.duration_minutes > 0,
                      session.duration_minutes <= limit else {
                    throw AITrainingError.invalid("训练日期或时长不符合你的设置，原计划已保留。")
                }
                if schema_version == 2 || session.workout != nil {
                    guard session.workout != nil, session.steps.isEmpty, paces[0] == nil else {
                        throw AITrainingError.invalid("新计划必须使用明确分段，不能同时提供另一套步骤或配速。")
                    }
                    _ = try session.resolvedWorkout()
                } else {
                    guard !session.steps.isEmpty,
                      session.steps.allSatisfy({ $0.minutes.isFinite && $0.minutes > 0 && !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      Set(["热身", "主体", "放松"]).isSubset(of: Set(session.steps.map(\.phase))),
                      abs(session.steps.reduce(0) { $0 + $1.minutes } - session.duration_minutes) <= 1 else {
                    throw AITrainingError.invalid("训练日期、时长或步骤不符合你的设置，原计划已保留。")
                    }
                }
            }
        }
        guard adjustments.allSatisfy({
            expected.contains($0.date) && !$0.change.isEmpty && !$0.reason.isEmpty &&
            Set($0.evidence_ids).isSubset(of: evidenceIDs)
        }) else { throw AITrainingError.invalid("计划调整的日期或依据无效。") }
    }
}

// Decode saved v1/v2 revisions while accepting fresh plans without the legacy adjustments field.
extension AITrainingPlan {
    private enum CodingKeys: String, CodingKey {
        case schema_version, stage, summary, run_review, sessions, adjustments, limitations, feedback_review
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try values.decode(Int.self, forKey: .schema_version)
        stage = try values.decode(String.self, forKey: .stage)
        summary = try values.decode(String.self, forKey: .summary)
        run_review = try values.decode(String.self, forKey: .run_review)
        sessions = try values.decode([AITrainingSession].self, forKey: .sessions)
        adjustments = try values.decodeIfPresent([AITrainingAdjustment].self, forKey: .adjustments) ?? []
        limitations = try values.decode([String].self, forKey: .limitations)
        feedback_review = try values.decodeIfPresent([AITrainingFeedbackReview].self, forKey: .feedback_review)
    }
}

enum AIDate {
    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func parse(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              self.key(date, calendar: calendar) == key else { return nil }
        return date
    }
    static func weekday(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }
}

struct AICompletedSession: Codable, Identifiable {
    var session: AITrainingSession
    var activityIDs: [String]
    var confirmedAt: Date? = nil
    var id: String { session.date }
}

struct AIPlanRevision: Codable, Identifiable {
    var id = UUID().uuidString
    var createdAt: Date
    var model: String
    var promptVersion: String
    var inputFingerprint: String
    var plan: AITrainingPlan
    var analysisContext: TrainingAnalysisContext? = nil
    var feedbackContext: [RunSubjectiveFeedback]? = nil
    var profileContext: AITrainingProfile? = nil
}

struct AITrainingDiskState: Codable {
    var version = 1
    var profile = AITrainingProfile()
    var configuration = AITrainingConfiguration()
    var revisions: [AIPlanRevision] = []
    var completed: [AICompletedSession] = []
    var lastFingerprint = ""
    var lastSuccess: Date? = nil
    var nextRetry: Date? = nil
    var lastError: String? = nil
    var manualOverrides: [AITrainingSessionOverride]? = nil
    var associations: [TrainingSessionAssociation]? = nil
}

extension AITrainingPlan {
    func validateAnalysis(_ context: TrainingAnalysisContext?) throws {
        if context?.hasPaceCalibration != true,
           sessions.contains(where: { $0.pace_seconds_per_km_min != nil || $0.pace_seconds_per_km_max != nil || $0.workout?.hasPace == true }) {
            throw AITrainingError.invalid("缺少近期能力标定，模型仍返回精确配速；原计划已保留，请重试。")
        }
        if sessions.contains(where: { $0.workout?.allSteps.contains(where: { $0.heart_rate_min != nil || $0.heart_rate_max != nil }) == true }) {
            throw AITrainingError.invalid("模型返回了尚未支持自动标定的精确心率目标，原计划已保留；如有需要可手动设置提醒。")
        }
    }
}
