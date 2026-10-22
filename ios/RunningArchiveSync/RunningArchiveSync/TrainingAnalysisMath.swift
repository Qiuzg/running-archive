import Foundation

/// Public models plus explicitly versioned application eligibility rules. No chart downsampling is used.
enum AnalysisMethod {
    static let version = "running-analysis-v2-apple-zones"
    static let coverage = 0.90
    static let sources: [(String, String, String)] = [
        ("Apple 心率区间", "优先采用运动保存的区间与时长；缺失时用当前系统区间重新分类，并标明来源。Apple区间不用于Edwards权重。", "https://developer.apple.com/documentation/healthkit/accessing-workout-zone-data"),
        ("自动最大心率 · Tanaka", "成人年龄估计：208 − 0.7 × 年龄。人群回归估计，不代表实测最大心率；原始出生日期不离开本机。", "https://pubmed.ncbi.nlm.nih.gov/11153730/"),
        ("心率负荷 · Edwards TRIMP", "50–60/60–70/70–80/80–90/90–100% 最大心率，每分钟权重为 1/2/3/4/5。单位 AU，不与厂商分数通用。", "https://www.jssm.org/volume20/iss1/cap/jssm-20-101.pdf"),
        ("7 / 42 天指数加权", "α = 1 − exp(−1/天数)。本 App 使用 Edwards 负荷作为输入，并非复刻任何厂商评分。", "https://blog.runalyze.com/tutorial/runalyze-understanding-the-calculations/"),
        ("速度 / 心率与漂移", "稳定片段内的平均速度除以平均心率；前后等时两半比较。本 App 未使用 TrainingPeaks 的标准化坡度配速。", "https://help.trainingpeaks.com/hc/en-us/articles/204071724-Aerobic-Decoupling-Pw-Hr-and-Pa-HR-and-Efficiency-Factor-EF"),
        ("经典 Daniels / Gilbert 成绩模型", "采用公开历史实现中的 0.182253 版本系数。成绩换算不等于系统 VO₂ max，也不是当前商业产品的动态跑力算法。", "https://github.com/Runalyze/Runalyze/blob/support/4.3.x/inc/core/Sports/Running/VO2max/Estimation/DanielsGilbertFormula.php"),
        ("Apple HRV · SDNN", "同来源、同采样时段比较；不与 RMSSD 混合，不据此生成恢复评分。", "https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn")
    ]
    static let eligibility = "工程规则 v1：完整指标覆盖≥90%；点测量最多支持其后10秒；稳定段剔除前10分钟及末5分钟，连续≥20分钟，30秒速度桶变异系数≤5%，桶平均速度均≥1 m/s；GPS精度合格时，坡度按约100米片段审核，绝对坡度≤2%的距离占比≥90%。断点、来源和地形条件不足时不输出确定的有氧结论。这些门槛是应用筛选规则，不是医学或行业统一标准。"
}

struct AnalysisCalibration: Codable, Equatable {
    var maximumHeartRate: Double? = nil
    var source = ""
    var confirmedAt: Date? = nil
    var performanceActivityID: String? = nil
    var performanceConfirmedAt: Date? = nil
    var automaticAge: Int? = nil
    var automaticAgeDate: Date? = nil
    var appleZoneConfigurationKey: String? = nil
    var key: String {
        [AnalysisMethod.version, maximumHeartRate.map(String.init(describing:)) ?? "none", source,
         confirmedAt.map { String($0.timeIntervalSince1970) } ?? "", performanceActivityID ?? "",
         performanceConfirmedAt.map { String($0.timeIntervalSince1970) } ?? "",
         maximumHeartRate == nil ? automaticAge.map(String.init) ?? "no-age" : "manual",
         appleZoneConfigurationKey ?? "no-apple-zones"].joined(separator: "|")
    }
    func validMaximum(at date: Date) -> Double? {
        reference(at: date).bpm
    }
    func reference(at date: Date) -> AnalysisHeartRateReference {
        if let hr = maximumHeartRate, hr.isFinite, (80...240).contains(hr),
           let confirmedAt, confirmedAt <= date, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AnalysisHeartRateReference(bpm: hr, method: "user_confirmed_reference", estimated: false, date: confirmedAt)
        }
        if maximumHeartRate == nil, let age = automaticAge, (18...100).contains(age),
           let measured = automaticAgeDate, measured <= date, date.timeIntervalSince(measured) < 366 * 86400 {
            return AnalysisHeartRateReference(bpm: 208 - 0.7 * Double(age), method: "tanaka_208_minus_0_7_age", estimated: true, date: measured, ageYears: age)
        }
        return AnalysisHeartRateReference(bpm: nil, method: "unavailable", estimated: false, date: nil)
    }
}
struct AnalysisHeartRateReference: Codable, Equatable {
    var bpm: Double?
    var method: String
    var estimated: Bool
    var date: Date?
    var ageYears: Int? = nil
    var explanation: String {
        if estimated, let ageYears { return "Tanaka：208 − 0.7 × \(ageYears)岁（Apple健康年龄），属于人群公式估计，存在个体误差。" }
        return bpm == nil ? "未获得可用于自动估算的成人年龄；仍可展示Apple区间。" : "采用你设置的最大心率参考值。"
    }
}
struct AnalysisAppleHeartRateZone: Codable, Equatable, Identifiable {
    var index: Int
    var lowerBPM: Double?
    var upperBPM: Double?
    var seconds: Double? = nil
    var id: Int { index }
}
struct AnalysisAppleHeartRateZones: Codable, Equatable {
    var source: String // system / user / app, exactly as reported by HealthKit
    var scope: String // recorded_workout / current_preference / current_preference_reclassified
    var zones: [AnalysisAppleHeartRateZone]
    var coverage: Double? = nil
    var reason: String? = nil
    var configurationKey: String { source + "|" + zones.map { "\($0.index):\($0.lowerBPM.map(String.init(describing:)) ?? "none"):\($0.upperBPM.map(String.init(describing:)) ?? "none")" }.joined(separator: "|") }
}
struct AnalysisAppleZoneEvidence: Codable {
    var activity_id: String
    var zones: AnalysisAppleHeartRateZones
}
struct AnalysisHeartRateProfile: Codable, Equatable {
    var age: Int?
    var preferredZones: AnalysisAppleHeartRateZones?
    var ageStatus: String
    var zoneStatus: String
    var fetchedAt: Date
}

struct AnalysisValue: Codable, Equatable {
    var value: Double? = nil
    var unit: String
    var method: String
    var coverage: Double = 0
    var reason: String? = nil
    var complete = false
    var estimated: Bool? = nil
    var usable: Bool { complete && value?.isFinite == true }
}
struct AnalysisZone: Codable, Identifiable {
    var index: Int
    var seconds: Double
    var id: Int { index }
}
struct AnalysisLoadPart: Codable {
    var date: Date
    var value: Double
}
struct AnalysisSplit: Codable, Identifiable {
    var index: Int
    var kilometers: Double
    var elapsedSeconds: Double
    var activeSeconds: Double?
    var heartRate: Double?
    var id: Int { index }
}
struct AnalysisFormValue: Codable, Identifiable {
    var metric: String
    var value: AnalysisValue
    var sourceGroup: String
    var id: String { metric }
}
struct AnalysisPerformance: Codable, Identifiable {
    var activityID: String
    var date: Date
    var distanceKm: Double
    var elapsedSeconds: Double
    var index: Double
    var fullEffortConfirmed: Bool
    var id: String { activityID }
}
struct RunTrainingAnalysis: Codable, Identifiable {
    var id: String
    var date: Date
    var end: Date
    var distanceKm: Double
    var activeSeconds: Double
    var elapsedSeconds: Double
    var calculatedAt: Date
    var version: String
    var calibrationKey: String
    var timeZone: String
    var inputSignature: String
    var sources: [String: String]
    var sourceGroups: [String: String]
    var load: AnalysisValue
    var loadParts: [AnalysisLoadPart]
    var zones: [AnalysisZone]
    var efficiency: AnalysisValue
    var drift: AnalysisValue
    var speedVariation: AnalysisValue
    var stableStart: Double?
    var stableEnd: Double?
    var stableHeartRate: Double?
    var stableSpeed: Double?
    var recordedIntervals: [WorkoutIntervalPayload]
    var form: [AnalysisFormValue]
    var stableForm: [AnalysisFormValue]
    var splits: [AnalysisSplit]
    var structure: String
    var performance: AnalysisPerformance?
    var notes: [String]
    var heartRateReference: AnalysisHeartRateReference? = nil
    var appleHeartRateZones: AnalysisAppleHeartRateZones? = nil
}
struct AnalysisRunSummary: Codable, Identifiable {
    var id: String
    var date: Date
    var kilometers: Double
    var seconds: Double
    init(_ activity: ArchiveActivity) {
        id = activity.id; date = activity.date; kilometers = max(0, activity.distanceKm)
        seconds = max(0, MonthlyReport.seconds(activity.duration) ?? 0)
    }
}
struct AnalysisLoadCoverage {
    var expected: Int
    var processed: Int
    var calculated: Int
    var complete: Int
    var reasons: [AnalysisLoadIssue]
    var pending: Int { max(0, expected - processed) }
}
struct AnalysisLoadIssue {
    var reason: String
    var count: Int
}
struct AnalysisWeek: Codable, Identifiable {
    var start: Date
    var kilometers: Double
    var seconds: Double
    var count: Int
    var longestKm: Double
    var longestShare: Double?
    var zoneSeconds: [Double]
    var classifiedSeconds: Double
    var expectedSeconds: Double
    var activityIDs: [String]
    var id: Date { start }
}
struct AnalysisLoadDay: Codable, Identifiable {
    var date: Date
    var observedLoad: Double
    var shortLoad: Double
    var longLoad: Double
    var balance: Double { longLoad - shortLoad }
    var completeHistory: Bool
    var warmedUp: Bool
    var id: Date { date }
}
struct AnalysisTrend: Codable, Identifiable {
    var metric: String
    var unit: String
    var recent: Double?
    var baseline: Double?
    var recentCount: Int
    var baselineCount: Int
    var recentIDs: [String]
    var baselineIDs: [String]
    var reason: String?
    var id: String { metric }
    var percent: Double? { guard let recent, let baseline, baseline > 0 else { return nil }; return (recent / baseline - 1) * 100 }
}
struct AnalysisObservation {
    var metric: String
    var date: Date
    var value: Double
    var sourceGroup: String
    var context: String
    var complete: Bool = true
}
struct AnalysisEvidence: Codable, Identifiable {
    var id: String
    var metric: String
    var value: AnalysisValue
    var activity_ids: [String]
    var start: Date
    var end: Date
}
struct TrainingAnalysisContext: Codable {
    var version: String
    var as_of: Date
    var maximum_heart_rate_bpm: Double?
    var heart_rate_calibration_date: Date?
    var calibration_method: String
    var evidence: [AnalysisEvidence]
    var weeks: [AnalysisWeek]
    var load_days: [AnalysisLoadDay]
    var recovery: [AnalysisTrend]
    var aerobic: [AnalysisTrend]
    var form: [AnalysisTrend]
    var performances: [AnalysisPerformance]
    var limitations: [String]
    var heart_rate_reference: AnalysisHeartRateReference? = nil
    var apple_heart_rate_zones: [AnalysisAppleZoneEvidence]? = nil
    var preferred_apple_heart_rate_zones: AnalysisAppleHeartRateZones? = nil
    var evidenceIDs: Set<String> { Set(evidence.map(\.id)) }
    var hasPaceCalibration: Bool { performances.contains(where: \.fullEffortConfirmed) }
}

/// Pure, deterministic math. Duration is always weighted on supported, non-overlapping intervals.
enum TrainingAnalysisMath {
    static func ageYears(healthBirth: DateComponents, now: Date, timeZone: TimeZone) -> Int? {
        // HealthKit returns Gregorian components even when the user's display calendar differs.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard let year = healthBirth.year, let month = healthBirth.month, let day = healthBirth.day,
              (1...12).contains(month), (1...31).contains(day),
              let birth = calendar.date(from: DateComponents(year: year, month: month, day: day)), birth <= now else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: birth)
        guard normalized.year == year, normalized.month == month, normalized.day == day else { return nil }
        return calendar.dateComponents([.year], from: birth, to: now).year
    }
    struct Span {
        var start: Double
        var end: Double
        var value: Double
        var seconds: Double { end - start }
    }
    struct Pair {
        var start: Double
        var end: Double
        var speed: Double
        var heart: Double
        var seconds: Double { end - start }
    }
    static func median(_ values: [Double]) -> Double? {
        let a = values.filter(\.isFinite).sorted(); guard !a.isEmpty else { return nil }
        let i = a.count / 2
        return a.count.isMultiple(of: 2) ? (a[i - 1] + a[i]) / 2 : a[i]
    }
    static func edwardsZone(_ heart: Double, maximum: Double) -> Int? {
        guard heart.isFinite, maximum.isFinite, maximum > 0, heart > 0, heart <= maximum else { return nil }
        let ratio = heart / maximum
        if ratio < 0.5 { return 0 }
        // Multiplication avoids rounding 70% into an adjacent band through repeated division.
        if heart < maximum * 0.6 { return 1 }
        if heart < maximum * 0.7 { return 2 }
        if heart < maximum * 0.8 { return 3 }
        if heart < maximum * 0.9 { return 4 }
        return 5
    }
    static func danielsIndex(distanceKm: Double, seconds: Double) -> Double? {
        guard distanceKm.isFinite, seconds.isFinite, (0.8...42.3).contains(distanceKm), seconds >= 180 else { return nil }
        let t = seconds / 60, v = distanceKm * 1000 / t
        guard (50...500).contains(v) else { return nil }
        let c = -4.6 + 0.182253 * v + 0.000104 * v * v
        let fraction = 0.8 + 0.1894393 * exp(-0.012778 * t) + 0.2989558 * exp(-0.1932605 * t)
        let result = c / fraction
        return result.isFinite && result > 0 ? result : nil
    }
    static func equivalentSeconds(index: Double, distanceKm: Double) -> Double? {
        guard index.isFinite, (10...90).contains(index), [5.0, 10.0, 21.0975, 42.195].contains(distanceKm) else { return nil }
        var lo = distanceKm * 1000 / 500 * 60, hi = distanceKm * 1000 / 50 * 60
        guard let slow = danielsIndex(distanceKm: distanceKm, seconds: hi),
              let fast = danielsIndex(distanceKm: distanceKm, seconds: lo), slow <= index, fast >= index else { return nil }
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            guard let value = danielsIndex(distanceKm: distanceKm, seconds: mid) else { return nil }
            if value > index { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
    static func subtractPauses(_ intervals: [ExportMetricInterval], pauses: [ExportMetricInterval]) -> [Span] {
        intervals.flatMap { interval -> [Span] in
            var cursor = interval.start
            var result: [Span] = []
            for pause in pauses where pause.end > cursor && pause.start < interval.end {
                if pause.start > cursor { result.append(Span(start: cursor, end: min(pause.start, interval.end), value: interval.value)) }
                cursor = max(cursor, pause.end)
                if cursor >= interval.end { break }
            }
            if cursor < interval.end { result.append(Span(start: cursor, end: interval.end, value: interval.value)) }
            return result
        }
    }
    static func paired(_ speed: [Span], _ heart: [Span]) -> [Pair] {
        var i = 0, j = 0, pairs: [Pair] = []
        while i < speed.count && j < heart.count {
            let a = speed[i], b = heart[j]
            let start = max(a.start, b.start), end = min(a.end, b.end)
            if end > start && a.value > 0 && b.value > 0 {
                pairs.append(Pair(start: start, end: end, speed: a.value, heart: b.value))
            }
            if a.end <= b.end { i += 1 } else { j += 1 }
        }
        return pairs
    }
    static func clip(_ pairs: [Pair], start: Double, end: Double) -> [Pair] {
        pairs.compactMap { p in
            let a = max(start, p.start), b = min(end, p.end)
            return b > a ? Pair(start: a, end: b, speed: p.speed, heart: p.heart) : nil
        }
    }
    static func pairStatistics(_ pairs: [Pair]) -> (seconds: Double, speed: Double?, heart: Double?, efficiency: Double?) {
        let seconds = pairs.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return (0, nil, nil, nil) }
        let speed = pairs.reduce(0) { $0 + $1.speed * $1.seconds } / seconds
        let heart = pairs.reduce(0) { $0 + $1.heart * $1.seconds } / seconds
        return (seconds, speed, heart, heart > 0 ? speed * 60 / heart : nil)
    }
    /// Linear sweep over disjoint source intervals; never re-scan an entire long run for each bucket.
    static func pairBins(_ pairs: [Pair], start: Double, end: Double) -> [(start: Double, end: Double, seconds: Double, speed: Double?)] {
        var index = 0
        var result: [(Double, Double, Double, Double?)] = []
        guard end > start else { return result }
        for t in stride(from: start, to: end, by: 30) {
            let stop = min(t + 30, end)
            while index < pairs.count && pairs[index].end <= t { index += 1 }
            var j = index, duration = 0.0, weighted = 0.0
            while j < pairs.count && pairs[j].start < stop {
                let overlap = min(stop, pairs[j].end) - max(t, pairs[j].start)
                if overlap > 0 { duration += overlap; weighted += pairs[j].speed * overlap }
                j += 1
            }
            result.append((t, stop, duration, duration > 0 ? weighted / duration : nil))
        }
        return result
    }
    static func variation(_ spans: [Span]) -> Double? {
        let duration = spans.reduce(0) { $0 + $1.seconds }
        guard duration > 0 else { return nil }
        let average = spans.reduce(0) { $0 + $1.value * $1.seconds } / duration
        guard average > 0 else { return nil }
        return sqrt(spans.reduce(0) { $0 + pow($1.value - average, 2) * $1.seconds } / duration) / average * 100
    }
    static func sourceGroup(_ source: ExportMetricSeries?) -> String {
        // This local grouping key never enters the AI payload.
        source?.sourceIdentity ?? ""
    }
    static func signature(_ activity: ArchiveActivity) -> String {
        activity.workoutSummarySignature ?? "\(activity.id)|\(activity.date.timeIntervalSince1970)|\(activity.distanceKm)|\(activity.duration)|\(activity.avgHeartRate ?? 0)|\(activity.maxHeartRate ?? 0)|\(activity.avgPower ?? 0)|\(activity.avgCadence ?? 0)"
    }
    static func loadCoverage(_ summaries: [AnalysisRunSummary], analyses: [RunTrainingAnalysis]) -> AnalysisLoadCoverage {
        let ids = Set(summaries.map(\.id))
        let records = Dictionary(analyses.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.calculatedAt > b.calculatedAt ? a : b }).values
        var counts: [String: Int] = [:]
        for record in records where record.load.value == nil {
            counts[record.load.reason ?? "未获得可计算的心率采样", default: 0] += 1
        }
        var reasons: [AnalysisLoadIssue] = []
        for (reason, count) in counts { reasons.append(AnalysisLoadIssue(reason: reason, count: count)) }
        reasons.sort { (a: AnalysisLoadIssue, b: AnalysisLoadIssue) -> Bool in
            if a.count != b.count { return a.count > b.count }
            return a.reason < b.reason
        }
        return AnalysisLoadCoverage(expected: ids.count, processed: records.count,
            calculated: records.filter { $0.load.value != nil }.count,
            complete: records.filter { $0.load.usable }.count, reasons: reasons)
    }
    static func validAppleZones(_ configuration: AnalysisAppleHeartRateZones) -> Bool {
        let zones = configuration.zones
        guard (3...9).contains(zones.count), Set(zones.map(\.index)).count == zones.count,
              zones.first?.lowerBPM == nil || zones.first?.lowerBPM == 0,
              zones.last?.upperBPM == nil else { return false }
        for (i, zone) in zones.enumerated() {
            if let lo = zone.lowerBPM, !lo.isFinite || lo < 0 { return false }
            if let hi = zone.upperBPM, !hi.isFinite || hi <= 0 { return false }
            if let lo = zone.lowerBPM, let hi = zone.upperBPM, hi <= lo { return false }
            if i > 0 {
                guard let previous = zones[i - 1].upperBPM, let lower = zone.lowerBPM,
                      abs(previous - lower) < 0.000001, zones[i - 1].index < zone.index else { return false }
            }
        }
        return true
    }
    static func appleZones(recorded: AnalysisAppleHeartRateZones?, preferred: AnalysisAppleHeartRateZones?,
                           heart: [Span], elapsed: Double, active: Double, validTimer: Bool) -> AnalysisAppleHeartRateZones? {
        if var recorded, validAppleZones(recorded), recorded.scope == "recorded_workout",
           recorded.zones.allSatisfy({ $0.seconds.map { $0.isFinite && $0 >= 0 } == true }) {
            let seconds = recorded.zones.reduce(0) { $0 + ($1.seconds ?? 0) }
            if elapsed.isFinite, elapsed > 0, seconds.isFinite, seconds <= elapsed + max(2, elapsed * 0.005) {
                recorded.coverage = min(1, seconds / elapsed)
                recorded.reason = "Apple保存的原始区间时长，保留系统计时口径；不与Edwards分区混用。"
                return recorded
            }
        }
        guard var preferred, validAppleZones(preferred) else { return nil }
        preferred.scope = "current_preference_reclassified"
        preferred.zones = preferred.zones.map { zone in var z = zone; z.seconds = nil; return z }
        guard validTimer, active > 0, !heart.isEmpty, !heart.contains(where: { $0.seconds > 30 }) else {
            preferred.coverage = 0
            preferred.reason = "当前Apple区间；原记录无区间时长，且有效心率或暂停计时不足，未重新分类。"
            return preferred
        }
        for i in preferred.zones.indices { preferred.zones[i].seconds = 0 }
        for point in heart {
            if let index = preferred.zones.firstIndex(where: { zone in
                (zone.lowerBPM.map { point.value >= $0 } ?? true) && (zone.upperBPM.map { point.value < $0 } ?? true)
            }) { preferred.zones[index].seconds! += point.seconds }
        }
        preferred.coverage = min(1, heart.reduce(0) { $0 + $1.seconds } / active)
        preferred.reason = "原运动未保存Apple区间；按当前Apple区间对有效运动心率重新分类（左闭右开），不代表当时设置。"
        return preferred
    }

    static func calculate(_ workout: ExportWorkout, activity: ArchiveActivity, calibration: AnalysisCalibration,
                          now: Date, calendar: Calendar) -> RunTrainingAnalysis {
        let a = ExportObjectiveAnalysis(workout: workout)
        let validTimer = workout.duration.isFinite && workout.duration > 0 && a.elapsed > 0 && a.pauseTimingKnown
        let pauses = a.pauseTimingKnown ? a.pauses : []
        func spans(_ metric: ExportMetric) -> [Span] {
            subtractPauses(a.series[metric]?.intervals ?? [], pauses: pauses).filter {
                $0.value.isFinite && (metric == .heartRate ? (20...260).contains($0.value) : $0.value >= 0)
            }
        }
        let hr = spans(.heartRate), speed = spans(.speed)
        let supported = hr.reduce(0) { $0 + $1.seconds }
        let coverage = validTimer ? min(1, supported / workout.duration) : 0
        let maximum = calibration.validMaximum(at: now)
        let heartReference = calibration.reference(at: now)
        var load = AnalysisValue(unit: "AU", method: "edwards-trimp-v1", coverage: coverage)
        load.estimated = heartReference.estimated
        var zones = (0...5).map { AnalysisZone(index: $0, seconds: 0) }
        var parts: [AnalysisLoadPart] = []
        var notes: [String] = []
        if !validTimer { load.reason = "暂停事件与运动计时未对齐，无法确定有效运动区间" }
        else if maximum == nil { load.reason = "未获得成人年龄或手动最大心率，暂不能计算Edwards负荷" }
        else if hr.contains(where: { $0.seconds > 30 }) { load.reason = "心率采样区间过长，无法可靠还原分区时间" }
        else if hr.isEmpty { load.reason = "无有效心率采样" }
        else if hr.contains(where: { $0.value > maximum! }) {
            load.reason = heartReference.estimated ? "有效采样超过年龄估算最大心率；估计与记录不一致，本次Edwards负荷暂不计算，Apple区间仍可查看" : "采样超过已校准最大心率，请检查采样或校准值"
        }
        else if let maximum {
            var total = 0.0
            for span in hr {
                guard let zone = edwardsZone(span.value, maximum: maximum) else { continue }
                zones[zone].seconds += span.seconds
                let value = span.seconds / 60 * Double(zone)
                total += value
                var cursor = workout.start.addingTimeInterval(span.start)
                let end = workout.start.addingTimeInterval(span.end)
                while cursor < end {
                    let day = calendar.startOfDay(for: cursor)
                    let next = min(end, calendar.date(byAdding: .day, value: 1, to: day)!)
                    parts.append(AnalysisLoadPart(date: day, value: next.timeIntervalSince(cursor) / 60 * Double(zone)))
                    cursor = next
                }
            }
            load.value = total; load.complete = coverage >= AnalysisMethod.coverage
            if !load.complete { load.reason = "仅覆盖部分有效运动时间，数值为已观测负荷下限" }
            if heartReference.estimated {
                load.reason = [load.reason, "最大心率采用Tanaka年龄估计，负荷为估算参考，不代表实测极限。"].compactMap { $0 }.joined(separator: "；")
            }
        }
        let groupedParts = Dictionary(grouping: parts, by: \.date).map { AnalysisLoadPart(date: $0.key, value: $0.value.reduce(0) { $0 + $1.value }) }.sorted { $0.date < $1.date }
        if !load.complete { notes.append(load.reason ?? "心率负荷不完整") }
        let pairs = paired(speed, hr)
        // Analyze the longest uninterrupted run of well-covered 30-second bins, after fixed warm-up/cool-down exclusions.
        var chunks: [[Span]] = [], chunk: [Span] = []
        if a.elapsed >= 2100 && validTimer {
            let coarseHeart = hr.filter { $0.seconds > 30 }, coarseSpeed = speed.filter { $0.seconds > 30 }
            for bin in pairBins(pairs, start: 600, end: a.elapsed - 300) {
                if bin.seconds >= (bin.end - bin.start) * AnalysisMethod.coverage, let binSpeed = bin.speed, binSpeed >= 1,
                   !coarseHeart.contains(where: { $0.start < bin.end && $0.end > bin.start }),
                   !coarseSpeed.contains(where: { $0.start < bin.end && $0.end > bin.start }) {
                    chunk.append(Span(start: bin.start, end: bin.end, value: binSpeed))
                } else if !chunk.isEmpty { chunks.append(chunk); chunk = [] }
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        let stable = chunks.max { ($0.last!.end - $0.first!.start) < ($1.last!.end - $1.first!.start) } ?? []
        let cv = variation(stable)
        let start = stable.first?.start, end = stable.last?.end
        let stablePairs = start.flatMap { s in end.map { clip(pairs, start: s, end: $0) } } ?? []
        let stats = pairStatistics(stablePairs)
        let duration = (end ?? 0) - (start ?? 0)
        let stableCoverage = duration > 0 ? stats.seconds / duration : 0
        var efficiency = AnalysisValue(unit: "m/beat", method: "paired-speed-heart-v1", coverage: stableCoverage)
        var drift = AnalysisValue(unit: "%", method: "equal-time-half-efficiency-v1", coverage: stableCoverage)
        efficiency.estimated = heartReference.estimated; drift.estimated = heartReference.estimated
        var variationValue = AnalysisValue(value: cv, unit: "%", method: "30-second-speed-weighted-cv-v1", coverage: stableCoverage,
                                          reason: cv == nil ? "未获得稳定候选片段" : nil, complete: cv != nil)
        let flat = start.flatMap { s in end.flatMap { flatFraction(workout.points, start: workout.start.addingTimeInterval(s), end: workout.start.addingTimeInterval($0)) } }
        let reason: String?
        if !validTimer { reason = "暂停与运动计时未对齐" }
        else if duration < 1200 { reason = "剔除前10分钟与末5分钟后，连续可比较片段不足20分钟" }
        else if (cv ?? .infinity) > 5 { reason = "速度变化较大，不适用稳定有氧分析" }
        else if flat == nil { reason = "缺少足够的地形数据，无法确认平路条件" }
        else if flat! < 0.9 { reason = "明显坡段占比较高，不作平路有氧比较" }
        else { reason = nil }
        if reason == nil, let start, let end, let first = pairStatistics(clip(pairs, start: start, end: (start + end) / 2)).efficiency,
           let second = pairStatistics(clip(pairs, start: (start + end) / 2, end: end)).efficiency, first > 0 {
            efficiency.value = stats.efficiency
            drift.value = (first - second) / first * 100
            let intensityKnown = maximum.map { maximum in stablePairs.allSatisfy { $0.heart <= maximum * 0.8 } } ?? false
            efficiency.complete = intensityKnown; drift.complete = intensityKnown
            if !intensityKnown { efficiency.reason = "强度未校准或超出80%最大心率，仅展示片段比值"; drift.reason = efficiency.reason }
            else if heartReference.estimated { efficiency.reason = "低强度条件按年龄估算最大心率筛选，存在个体误差"; drift.reason = efficiency.reason }
        } else { efficiency.reason = reason; drift.reason = reason }
        if !validTimer { variationValue.complete = false }
        if let reason = efficiency.reason { notes.append(reason) }
        func formValues(start: Double, end: Double, expected: Double, method: String) -> [AnalysisFormValue] {
            [ExportMetric.steps, .stride, .contact, .oscillation, .power].compactMap { metric -> AnalysisFormValue? in
            let data = spans(metric).compactMap { span -> Span? in
                let a = max(start, span.start), b = min(end, span.end)
                return b > a ? Span(start: a, end: b, value: span.value) : nil
            }
            let seconds = data.reduce(0) { $0 + $1.seconds }
            guard seconds > 0 else { return nil }
            let fraction = validTimer && expected > 0 ? min(1, seconds / expected) : 0
            let average = data.reduce(0) { $0 + $1.value * $1.seconds } / seconds
            return AnalysisFormValue(metric: metric.rawValue,
                value: AnalysisValue(value: average, unit: metric.unit, method: method, coverage: fraction,
                    reason: fraction >= AnalysisMethod.coverage ? nil : "有效运动时间覆盖不足，均值仅代表已采样部分", complete: fraction >= AnalysisMethod.coverage),
                sourceGroup: sourceGroup(a.series[metric]))
        }
        }
        let form = formValues(start: 0, end: a.elapsed, expected: workout.duration, method: "active-time-weighted-mean-v1")
        let stableForm = start.flatMap { s in end.map { formValues(start: s, end: $0, expected: $0 - s, method: "stable-span-time-weighted-mean-v1") } } ?? []
        let splitResult = ExportSplits.calculate(workout.points, start: workout.start, end: workout.end)
        let splits = splitResult.rows.map { row in AnalysisSplit(index: row.index, kilometers: row.km, elapsedSeconds: row.duration,
            activeSeconds: a.activeSeconds(start: row.start, end: row.end), heartRate: a.series[.heartRate]?.statistic(start: row.start, end: row.end).average) }
        if splits.isEmpty { notes.append(splitResult.status) }
        let candidate = intervalCandidate(speed)
        let structure = workout.intervals.count > 1 ? (candidate ? "设备分段 · 间歇候选" : "设备分段") : (candidate ? "间歇候选" : ((cv ?? .infinity) <= 5 && duration >= 1200 ? "稳定片段" : "未确定"))
        if candidate { notes.append("间歇候选依据：至少3组30秒至10分钟快段与恢复段交替，速度差≥20%；不能证明训练目的") }
        var performance: AnalysisPerformance?
        let gpsKm = splitResult.rows.reduce(0) { $0 + $1.km }
        if let km = workout.distanceKm, (5...42.3).contains(km), workout.indoor == false,
           validTimer, a.elapsed <= 14400, abs(a.elapsed - workout.duration) <= max(2, a.elapsed * 0.005),
           km > 0, abs(gpsKm / km - 1) <= 0.03,
           let index = danielsIndex(distanceKm: km, seconds: a.elapsed) {
            let recent = workout.start >= calendar.date(byAdding: .day, value: -90, to: now)!
            performance = AnalysisPerformance(activityID: activity.id, date: workout.start, distanceKm: km,
                elapsedSeconds: a.elapsed, index: index,
                fullEffortConfirmed: recent && calibration.performanceActivityID == activity.id
                    && calibration.performanceConfirmedAt.map { $0 <= now } == true)
        }
        if !workout.readIssues.isEmpty { notes.append("部分指标读取失败：" + workout.readIssues.keys.sorted().joined(separator: "、")) }
        return RunTrainingAnalysis(id: activity.id, date: workout.start, end: workout.end,
            distanceKm: max(0, workout.distanceKm ?? activity.distanceKm), activeSeconds: workout.duration.isFinite ? max(0, workout.duration) : 0, elapsedSeconds: a.elapsed,
            calculatedAt: now, version: AnalysisMethod.version, calibrationKey: calibration.key, timeZone: calendar.timeZone.identifier,
            inputSignature: signature(activity), sources: Dictionary(uniqueKeysWithValues: a.series.map { ($0.key.rawValue, $0.value.source) }), sourceGroups: Dictionary(uniqueKeysWithValues: a.series.map { ($0.key.rawValue, sourceGroup($0.value)) }),
            load: load, loadParts: groupedParts, zones: zones, efficiency: efficiency, drift: drift, speedVariation: variationValue,
            stableStart: start, stableEnd: end, stableHeartRate: stats.heart, stableSpeed: stats.speed,
            recordedIntervals: workout.intervals, form: form, stableForm: stableForm, splits: splits, structure: structure, performance: performance, notes: notes,
            heartRateReference: heartReference,
            appleHeartRateZones: appleZones(recorded: workout.appleHeartRateZones, preferred: workout.preferredAppleHeartRateZones,
                heart: hr, elapsed: a.elapsed, active: workout.duration, validTimer: validTimer))
    }

    static func flatFraction(_ points: [RoutePointPayload], start: Date, end: Date) -> Double? {
        let p = points.filter { $0.timestamp >= start && $0.timestamp <= end }.sorted { $0.timestamp < $1.timestamp }
        guard p.count > 2 else { return nil }
        var distance = 0.0, flat = 0.0, assessed = 0.0, window = 0.0
        var altitudes: [Double] = [], firstAltitude: Double?
        for (a, b) in zip(p, p.dropFirst()) {
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            let meters = GeoPoint(latitude: a.latitude, longitude: a.longitude).meters(to: GeoPoint(latitude: b.latitude, longitude: b.longitude))
            guard GeoPoint(latitude: a.latitude, longitude: a.longitude).valid,
                  GeoPoint(latitude: b.latitude, longitude: b.longitude).valid,
                  seconds > 0, seconds <= 30, meters / seconds <= 12,
                  a.altitude.isFinite, b.altitude.isFinite,
                  let av = a.verticalAccuracy, let bv = b.verticalAccuracy, (0...10).contains(av), (0...10).contains(bv),
                  let ah = a.horizontalAccuracy, let bh = b.horizontalAccuracy, (0...30).contains(ah), (0...30).contains(bh) else { return nil }
            distance += meters; window += meters
            if firstAltitude == nil { firstAltitude = a.altitude }
            altitudes.append(b.altitude)
            if window >= 100 {
                // Median reduces isolated altitude spikes; this remains an eligibility heuristic, not grade adjustment.
                let altitude = median(Array(altitudes.suffix(5))) ?? b.altitude
                if abs(altitude - firstAltitude!) / window <= 0.02 { flat += window }
                assessed += window; window = 0; firstAltitude = altitude; altitudes = []
            }
        }
        guard distance >= 1000, assessed >= distance * 0.8 else { return nil }
        return flat / assessed
    }
    static func intervalCandidate(_ speed: [Span]) -> Bool {
        guard let first = speed.first, let last = speed.last, last.end - first.start >= 300 else { return false }
        let pairs = speed.map { Pair(start: $0.start, end: $0.end, speed: $0.value, heart: 1) }
        let bins = pairBins(pairs, start: first.start, end: last.end).compactMap { bin -> Span? in
            guard bin.seconds >= (bin.end - bin.start) * 0.9, let value = bin.speed else { return nil }
            return Span(start: bin.start, end: bin.end, value: value)
        }
        guard let center = median(bins.map(\.value)), center >= 1 else { return false }
        var runs: [(high: Bool, start: Double, end: Double, sum: Double, seconds: Double)] = []
        for bin in bins {
            let high = bin.value >= center
            if let previous = runs.last, previous.high == high && bin.start - previous.end <= 1 {
                runs[runs.count - 1].end = bin.end
                runs[runs.count - 1].sum += bin.value * bin.seconds
                runs[runs.count - 1].seconds += bin.seconds
            } else { runs.append((high, bin.start, bin.end, bin.value * bin.seconds, bin.seconds)) }
        }
        var cycles = 0
        for i in 0..<max(0, runs.count - 1) {
            let a = runs[i], b = runs[i + 1]
            if a.high && !b.high && (30...600).contains(a.seconds) && (30...600).contains(b.seconds)
                && b.start - a.end <= 1 && a.sum / a.seconds >= 1.2 * (b.sum / b.seconds) { cycles += 1 }
        }
        return cycles >= 3
    }

    static func weeks(_ summaries: [AnalysisRunSummary], analyses: [RunTrainingAnalysis], now: Date, calendar: Calendar) -> [AnalysisWeek] {
        let lookup = Dictionary(analyses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Dictionary(grouping: summaries.filter { $0.date <= now }) { calendar.dateInterval(of: .weekOfYear, for: $0.date)!.start }
            .map { start, runs in
                let km = runs.reduce(0) { $0 + $1.kilometers }, longest = runs.map(\.kilometers).max() ?? 0
                var zones = Array(repeating: 0.0, count: 6)
                for run in runs { if let a = lookup[run.id], a.load.complete { for z in a.zones { zones[z.index] += z.seconds } } }
                return AnalysisWeek(start: start, kilometers: km, seconds: runs.reduce(0) { $0 + $1.seconds }, count: runs.count,
                    longestKm: longest, longestShare: km > 0 ? longest / km : nil, zoneSeconds: zones,
                    classifiedSeconds: zones.reduce(0, +), expectedSeconds: runs.reduce(0) { $0 + $1.seconds }, activityIDs: runs.map(\.id).sorted())
            }.sorted { $0.start < $1.start }
    }
    static func loadDays(_ summaries: [AnalysisRunSummary], analyses: [RunTrainingAnalysis], now: Date, days: Int = 126, calendar: Calendar) -> [AnalysisLoadDay] {
        let end = calendar.startOfDay(for: now), start = calendar.date(byAdding: .day, value: -(days - 1), to: end)!
        let lookup = Dictionary(analyses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let relevant = summaries.filter { $0.date <= now && ($0.date >= start || (lookup[$0.id]?.end ?? $0.date.addingTimeInterval($0.seconds)) > start) }
        let firstDate = summaries.filter { $0.date <= now }.map(\.date).min().map { calendar.startOfDay(for: $0) }
        var unknown = Set<Date>()
        var daily: [Date: Double] = [:]
        for run in relevant {
            if let analysis = lookup[run.id] {
                for part in analysis.loadParts where part.date >= start && part.date <= end { daily[part.date, default: 0] += part.value }
                if !analysis.load.complete {
                    var day = calendar.startOfDay(for: analysis.date)
                    let last = calendar.startOfDay(for: max(analysis.date, analysis.end.addingTimeInterval(-0.001)))
                    while day <= last { unknown.insert(day); day = calendar.date(byAdding: .day, value: 1, to: day)! }
                }
            } else {
                // Even without raw data, a summary can straddle midnight. Mark every known
                // affected day instead of letting the second day appear fully observed.
                var day = calendar.startOfDay(for: run.date)
                let last = calendar.startOfDay(for: run.date.addingTimeInterval(max(0, run.seconds - 0.001)))
                while day <= last {
                    if day >= start && day <= end { unknown.insert(day) }
                    day = calendar.date(byAdding: .day, value: 1, to: day)!
                }
            }
        }
        var short = 0.0, long = 0.0, output: [AnalysisLoadDay] = []
        var lastUnknown: Date?
        for offset in 0..<days {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let load = daily[day] ?? 0
            short += (1 - exp(-1.0 / 7)) * (load - short)
            long += (1 - exp(-1.0 / 42)) * (load - long)
            if unknown.contains(day) { lastUnknown = day }
            let elapsed = firstDate.map { calendar.dateComponents([.day], from: $0, to: day).day ?? 0 } ?? 0
            let complete = lastUnknown.map { (calendar.dateComponents([.day], from: $0, to: day).day ?? 0) >= 126 } ?? true
            output.append(AnalysisLoadDay(date: day, observedLoad: load, shortLoad: short, longLoad: long,
                completeHistory: complete, warmedUp: offset >= 125 && elapsed >= 125))
        }
        return output
    }
    static func recovery(_ observations: [AnalysisObservation], now: Date, calendar: Calendar) -> [AnalysisTrend] {
        let end = calendar.startOfDay(for: now), recentStart = calendar.date(byAdding: .day, value: -7, to: end)!
        let baselineStart = calendar.date(byAdding: .day, value: -35, to: end)!
        return ["hrv_sdnn", "resting_heart_rate", "sleep_minutes"].map { metric in
            let candidates = observations.filter { $0.metric == metric && $0.complete && $0.date < end && $0.date >= baselineStart && $0.value.isFinite && $0.value > 0 && !$0.sourceGroup.isEmpty }
            let groups = Dictionary(grouping: candidates) { $0.sourceGroup + "|" + $0.context }
            // Choose the group with the newest observations, then broadest daily coverage. Never combine groups.
            let key = groups.keys.sorted().max { a, b in
                let x = groups[a]!, y = groups[b]!
                let xd = x.map(\.date).max()!, yd = y.map(\.date).max()!
                return xd == yd ? Set(x.map { calendar.startOfDay(for: $0.date) }).count < Set(y.map { calendar.startOfDay(for: $0.date) }).count : xd < yd
            }
            let selected = key.flatMap { groups[$0] } ?? []
            let daily = Dictionary(grouping: selected) { calendar.startOfDay(for: $0.date) }.compactMap { date, points in median(points.map(\.value)).map { (date, $0) } }
            let recent = daily.filter { $0.0 >= recentStart }, baseline = daily.filter { $0.0 < recentStart }
            let ready = recent.count >= 4 && baseline.count >= 14
            return AnalysisTrend(metric: metric, unit: metric == "hrv_sdnn" ? "ms" : (metric == "sleep_minutes" ? "min" : "bpm"),
                recent: ready ? median(recent.map(\.1)) : nil, baseline: ready ? median(baseline.map(\.1)) : nil,
                recentCount: recent.count, baselineCount: baseline.count, recentIDs: [], baselineIDs: [],
                reason: ready ? nil : "同来源同采样时段：近7日需≥4个有效日，此前28日需≥14个有效日；未结束睡眠窗口不参与比较")
        }
    }
    static func aerobicTrend(_ analyses: [RunTrainingAnalysis], now: Date, calendar: Calendar) -> AnalysisTrend {
        let end = calendar.startOfDay(for: now), recentStart = calendar.date(byAdding: .day, value: -28, to: end)!
        let baselineStart = calendar.date(byAdding: .day, value: -56, to: end)!
        let valid = analyses.filter { $0.efficiency.usable && $0.date >= baselineStart && $0.date < now && !($0.sourceGroups[ExportMetric.heartRate.rawValue] ?? "").isEmpty && !($0.sourceGroups[ExportMetric.speed.rawValue] ?? "").isEmpty }
        // Comparable heart-rate band, speed band and both sensor sources. No cross-device "improvement".
        let groups = Dictionary(grouping: valid) { run in
            "\(Int((run.stableHeartRate ?? 0) / 5))|\(Int((run.stableSpeed ?? 0) / 0.5))|\(run.sourceGroups[ExportMetric.heartRate.rawValue] ?? "")|\(run.sourceGroups[ExportMetric.speed.rawValue] ?? "")"
        }
        let chosen = groups.values.filter { g in g.filter { $0.date >= recentStart }.count >= 3 && g.filter { $0.date < recentStart }.count >= 3 }
            .sorted { a, b in a.count == b.count ? a.map(\.id).sorted().joined() < b.map(\.id).sorted().joined() : a.count > b.count }.first ?? []
        let recent = chosen.filter { $0.date >= recentStart }, baseline = chosen.filter { $0.date < recentStart }
        return AnalysisTrend(metric: "speed_heart_efficiency", unit: "m/beat", recent: median(recent.compactMap { $0.efficiency.value }), baseline: median(baseline.compactMap { $0.efficiency.value }),
            recentCount: recent.count, baselineCount: baseline.count, recentIDs: recent.map(\.id).sorted(), baselineIDs: baseline.map(\.id).sorted(),
            reason: chosen.isEmpty ? "需同来源、相近心率/速度及平路条件，前后28天各≥3条有效记录；天气未校正" : "相近心率/速度及同来源比较；天气未校正，不能单独归因为体能变化")
    }
    static func formTrends(_ analyses: [RunTrainingAnalysis], now: Date, calendar: Calendar) -> [AnalysisTrend] {
        let recentStart = calendar.date(byAdding: .day, value: -28, to: now)!, baselineStart = calendar.date(byAdding: .day, value: -56, to: now)!
        return [ExportMetric.steps, .stride, .contact, .oscillation, .power].map { metric in
            let items = analyses.filter { $0.date >= baselineStart && $0.date <= now && $0.efficiency.value != nil }.compactMap { run -> (RunTrainingAnalysis, AnalysisFormValue)? in
                guard let form = run.stableForm.first(where: { $0.metric == metric.rawValue && $0.value.usable && !$0.sourceGroup.isEmpty }) else { return nil }
                return (run, form)
            }
            let groups = Dictionary(grouping: items) { "\($0.1.sourceGroup)|\(Int(($0.0.stableSpeed ?? 0) / 0.25))" }
            let group = groups.values.filter { $0.filter { $0.0.date >= recentStart }.count >= 3 && $0.filter { $0.0.date < recentStart }.count >= 3 }
                .sorted { $0.map { $0.0.id }.sorted().joined() < $1.map { $0.0.id }.sorted().joined() }.max { $0.count < $1.count } ?? []
            let recent = group.filter { $0.0.date >= recentStart }, baseline = group.filter { $0.0.date < recentStart }
            return AnalysisTrend(metric: metric.rawValue, unit: metric.unit, recent: median(recent.compactMap { $0.1.value.value }), baseline: median(baseline.compactMap { $0.1.value.value }),
                recentCount: recent.count, baselineCount: baseline.count, recentIDs: recent.map { $0.0.id }.sorted(), baselineIDs: baseline.map { $0.0.id }.sorted(),
                reason: "只比较平路候选跑步、相近速度及同来源，前后28天各≥3次；数值高低不直接代表跑姿好坏")
        }
    }
}

/// Display-only explanations. These never change the measured values or infer fitness/readiness.
struct AnalysisMetricGuide {
    let meaning: String
    let caution: String
    let calculation: String
}
enum AnalysisReading {
    static func guide(_ metric: String) -> AnalysisMetricGuide {
        switch metric {
        case "edwards-trimp-v1":
            return .init(meaning: "把跑步时长和心率强度合起来，描述这次训练的刺激量。", caution: "只和自己在相同计算口径下比较；不是体能分数，也不能直接与其他App对照。", calculation: "有效分钟 × 心率分区权重，再相加。最大心率的50–60%、60–70%、70–80%、80–90%、90–100%分别取1–5；低于50%取0。单位AU。")
        case "paired-speed-heart-v1", "speed_heart_efficiency":
            return .init(meaning: "相似条件下，同样的心率能跑多快；数值更高表示速度与心率的比值更高。", caution: "天气、坡度和佩戴都会影响结果；一次变化不能证明体能进步或退步。", calculation: "稳定片段中，共同有效时间内的平均速度（米/分钟）÷平均心率（次/分钟）。比较近28天与此前28天，同来源、相近速度和心率，每段至少3次。")
        case "equal-time-half-efficiency-v1":
            return .init(meaning: "看稳定片段跑到后半段，维持速度是否更费劲。正值表示后半段效率下降，负值表示上升。", caution: "比较的是筛选片段的前后两半，不一定是整次跑步；温度、补水和疲劳都可能影响，数值不是越低越好。", calculation: "（前半效率−后半效率）÷前半效率×100%，按相等时长分半。效率为平均速度÷平均心率。")
        case "30-second-speed-weighted-cv-v1":
            return .init(meaning: "描述候选片段的速度起伏；数值越小，速度越均匀。", caution: "只用于说明片段是否稳定，不代表跑得更好；间歇训练本来就会有速度变化。", calculation: "30秒速度分箱，按有效时长加权计算标准差÷平均速度×100%。")
        case "hrv_sdnn":
            return .init(meaning: "HRV描述心跳间隔的变化程度，重点看它与自己平时相比怎样。", caution: "Apple记录的是SDNN；不能与其他算法的HRV直接比较，也不是越高越好。", calculation: "按来源和采样时段分组，先取每日中位数，再比较近7个完整日与此前28日的中位数；分别至少4和14个有效日。")
        case "resting_heart_rate":
            return .init(meaning: "静息心率是安静状态下的心率水平，观察最近是否偏离自己的常态。", caution: "睡眠、压力、身体状态等都会影响；升高不一定就是训练疲劳。", calculation: "同来源先取每日中位数，再比较近7个完整日与此前28日的中位数；分别至少4和14个有效日。")
        case "sleep_minutes":
            return .init(meaning: "记录实际入睡时长，观察最近是否比平时睡得更少或更多。", caution: "时长不等于睡眠质量，可能包含午睡；只统计健康中已有的记录。", calculation: "中午到次日中午为一个窗口，合并重叠入睡记录；未结束窗口不参加比较。近7个完整日与此前28日比较，至少4和14个有效日。")
        case "step_count", "步频":
            return .init(meaning: "每分钟的步数。相近配速下，观察自己的步频是否发生变化。", caution: "没有人人适用的180步目标；步频高低不能单独评价跑姿。", calculation: "单次取有效运动时间加权均值；趋势只比较同来源、相近速度的稳定片段，前后28天各至少3次。")
        case "stride_length", "步幅":
            return .init(meaning: "每一步前进的距离，通常会随速度改变。", caution: "步幅更长不一定更好；应在相近速度下比较，不必刻意跨大步。", calculation: "单次取有效运动时间加权均值；趋势只比较同来源、相近速度的稳定片段，前后28天各至少3次。")
        case "ground_contact_time", "触地时间":
            return .init(meaning: "每一步脚接触地面的时间，帮助观察动作随训练的变化。", caution: "受配速、坡度和测量设备影响；并不是越短越好。", calculation: "单次取有效运动时间加权均值；趋势只比较同来源、相近速度的稳定片段，前后28天各至少3次。")
        case "vertical_oscillation", "垂直振幅":
            return .init(meaning: "跑步时身体上下起伏的幅度。", caution: "受速度和个人动作影响；单凭振幅大小不能判断是否省力。", calculation: "单次取有效运动时间加权均值；趋势只比较同来源、相近速度的稳定片段，前后28天各至少3次。")
        case "running_power", "功率":
            return .init(meaning: "设备估算的跑步输出，帮助观察相近条件下的用力变化。", caution: "不同设备算法可能不同；功率更高不一定代表效率更高。", calculation: "单次取有效运动时间加权均值；趋势只比较同来源、相近速度的稳定片段，前后28天各至少3次。")
        default:
            return .init(meaning: "这是已记录数据的统计结果，需要结合记录范围和来源理解。", caution: "缺失不等于零；单个数值不能独立判断训练效果。", calculation: "详细计算方法和适用条件见本页的计算依据。")
        }
    }
    static func metric(_ value: AnalysisValue) -> String {
        guard let number = value.value, number.isFinite else { return "暂时没有可用结果。" }
        guard value.complete else { return "仅有部分数据或适用条件不足，暂不据此判断训练变化。" }
        switch value.method {
        case "edwards-trimp-v1":
            return value.estimated == true ? "本次负荷以年龄估算最大心率为依据，适合持续观察自己的变化。" : "本次训练刺激量已记录，可与自己其他完整记录比较。"
        case "paired-speed-heart-v1":
            return "本次稳定片段中，每次心跳对应约\(String(format: "%.3f", number))米的前进距离。"
        case "equal-time-half-efficiency-v1":
            let amount = abs(number)
            if amount < 0.05 { return "按当前显示精度，片段前后两半的效率变化为0.0%。" }
            return "稳定片段后半段的效率比前半段\(number > 0 ? "低" : "高")\(String(format: "%.1f", amount))%。"
        case "30-second-speed-weighted-cv-v1": return "该数值描述片段内的速度起伏，不是与上次跑步的变化。"
        default: return "本次数值为有效采样时间内的平均水平。"
        }
    }
    static func change(_ trend: AnalysisTrend) -> String {
        guard let recent = trend.recent, let baseline = trend.baseline,
              recent.isFinite, baseline.isFinite, baseline > 0 else {
            return "暂时无法比较：还没有足够的同条件数据。"
        }
        let percent = (recent / baseline - 1) * 100
        guard percent.isFinite else { return "暂时无法比较：参考值不适合计算变化。" }
        if abs(percent) < 0.05 { return "与此前相比，按当前显示精度变化为0.0%。" }
        let direction: String
        if trend.metric == "sleep_minutes" { direction = percent > 0 ? "多" : "少" }
        else { direction = percent > 0 ? "高" : "低" }
        return "与此前相比，近期\(direction)了\(String(format: "%.1f", abs(percent)))%。"
    }
    static func load(_ day: AnalysisLoadDay) -> String {
        guard day.completeHistory && day.warmedUp else {
            return "历史还不完整：曲线只表示已读取的跑步，暂不判断最近是否比平常练得更多。"
        }
        guard day.shortLoad.isFinite, day.longLoad.isFinite, day.longLoad > 0 else {
            return "还没有足够的长期负荷作参照。"
        }
        let difference = (day.shortLoad / day.longLoad - 1) * 100
        guard difference.isFinite else { return "暂时无法比较短期与长期负荷。" }
        if abs(difference) < 0.05 { return "按当前显示精度，最近7日的加权负荷与42日水平相同。" }
        return "最近7日的加权负荷比42日水平\(difference > 0 ? "高" : "低")\(String(format: "%.1f", abs(difference)))%。"
    }
    static func appleZones(_ zones: AnalysisAppleHeartRateZones) -> String {
        let timed = zones.zones.enumerated().compactMap { index, zone -> (Int, Double)? in
            guard let seconds = zone.seconds, seconds.isFinite, seconds >= 0 else { return nil }
            return (index + 1, seconds)
        }
        guard let most = timed.max(by: { $0.1 < $1.1 }) else {
            return "目前只能查看区间设置，尚无有效的区间时长分布。"
        }
        guard most.1 > 0 else { return "已记录的区间时长均为0，不能据此判断强度分布。" }
        return "已记录的区间时长中，区间\(most.0)最多，共\(String(format: "%.1f", most.1 / 60))分钟。"
    }
}

struct AnalysisReadAttempt: Codable {
    var date: Date
    var signature: String
    var calibrationKey: String
    var timeZone: String
}
/// Cache scheduling only; changing this policy never changes a calculated metric.
enum AnalysisRefreshPolicy {
    static func shouldRead(_ activity: ArchiveActivity, saved: RunTrainingAnalysis?, failed: AnalysisReadAttempt?,
                           calibrationKey: String, timeZone: String, now: Date, force: Bool = false) -> Bool {
        if force { return true }
        let signature = TrainingAnalysisMath.signature(activity)
        if let failed, failed.signature == signature, failed.calibrationKey == calibrationKey,
           failed.timeZone == timeZone, failed.date <= now, now.timeIntervalSince(failed.date) < 3600 { return false }
        guard let saved, saved.version == AnalysisMethod.version, saved.calibrationKey == calibrationKey,
              saved.timeZone == timeZone, saved.inputSignature == signature, saved.calculatedAt <= now else { return true }
        // Allow late HealthKit deliveries, without re-reading GPS and samples on every navigation.
        let recent = activity.date > now.addingTimeInterval(-7 * 86400)
        let lifetime: TimeInterval = recent ? 6 * 3600 : (saved.load.coverage < AnalysisMethod.coverage ? 86400 : 30 * 86400)
        return now.timeIntervalSince(saved.calculatedAt) >= lifetime
    }
}

struct AnalysisInsight {
    var headline: String
    var detail: String
    var note: String
}
/// Personal comparisons describe measured training, not a vendor fitness/readiness score.
enum AnalysisInsights {
    static func load(_ day: AnalysisLoadDay?, hasMeasurements: Bool) -> AnalysisInsight {
        guard hasMeasurements, let day else {
            return .init(headline: "先看最近的跑量与次数", detail: "心率负荷还没有形成可用结果。跑量和频次仍可直接查看。", note: "不会把缺失数据当成没有训练。")
        }
        guard day.completeHistory, day.warmedUp, day.shortLoad.isFinite, day.longLoad.isFinite, day.longLoad > 0 else {
            return .init(headline: "先建立你的日常训练参照", detail: "已有训练已记录，历史还不完整，暂时不能判断近期是否比平时练得更多。", note: "已有记录保留；不用为了得到分数额外加跑。")
        }
        let change = (day.shortLoad / day.longLoad - 1) * 100
        guard change.isFinite else { return .init(headline: "训练参照暂不可比较", detail: "现有记录不足以给出可靠的负荷变化。", note: "可先查看跑量与次数。") }
        let headline = abs(change) < 0.05 ? "近期负荷与长期水平相近" : (change > 0 ? "近期练得比平时更多" : "近期练得比平时更少")
        return .init(headline: headline, detail: abs(change) < 0.05 ? "训练时长与心率强度合起来看，短期和长期水平按当前显示精度相同。" : "结合跑步时长和心率强度，近期训练刺激比长期水平\(change > 0 ? "高" : "低")了\(String(format: "%.1f", abs(change)))%。",
                     note: "多或少本身不代表好坏，是否加量或减量还要结合目标与体感。")
    }
    static func session(_ run: RunTrainingAnalysis, history: [RunTrainingAnalysis]) -> AnalysisInsight {
        guard run.load.usable, let load = run.load.value else {
            return .init(headline: "这次先看距离、用时和心率", detail: "过程数据不足，暂时不能可靠评价这次训练刺激。", note: "不影响查看原始记录和分段。")
        }
        let cutoff = run.date.addingTimeInterval(-42 * 86400)
        let comparable = history.filter { $0.id != run.id && $0.date >= cutoff && $0.date < run.date &&
            $0.calibrationKey == run.calibrationKey && $0.version == run.version && $0.load.usable }
        guard comparable.count >= 6, let middle = TrainingAnalysisMath.median(comparable.compactMap { $0.load.value }), middle > 0 else {
            return .init(headline: "这次训练已记入你的负荷", detail: "近期完整记录还不够，先积累自己的参照，不给这次贴轻松或过量标签。", note: run.load.estimated == true ? "心率参考采用年龄估算，比较也带有估算性质。" : "持续与自己的记录比较即可。")
        }
        let change = (load / middle - 1) * 100
        return .init(headline: abs(change) < 0.05 ? "这次接近近期的单次训练水平" : (change > 0 ? "这次比近期通常的一次跑步更重" : "这次比近期通常的一次跑步更轻"),
                     detail: abs(change) < 0.05 ? "与此前42天\(comparable.count)次完整跑步的中间水平接近。" : "比此前42天\(comparable.count)次完整跑步的中间水平\(change > 0 ? "高" : "低")\(String(format: "%.1f", abs(change)))%；比较同时考虑时长与心率强度。",
                     note: "这是相对你自己的训练比较，不表示已经恢复或训练过量。" + (run.load.estimated == true ? "心率参考为年龄估算。" : ""))
    }
    static func aerobicExclusions(_ runs: [RunTrainingAnalysis]) -> [(reason: String, count: Int)] {
        let groups = Dictionary(grouping: runs.filter { !$0.efficiency.usable }) {
            $0.efficiency.reason ?? "尚未形成可比较的稳定片段"
        }
        return groups.map { (reason: $0.key, count: $0.value.count) }.sorted {
            $0.count == $1.count ? $0.reason < $1.reason : $0.count > $1.count
        }
    }
}

extension AnalysisInsights {
    static func recovery(_ trend: AnalysisTrend) -> AnalysisInsight? {
        guard let recent = trend.recent, let baseline = trend.baseline,
              recent.isFinite, baseline.isFinite, baseline > 0 else { return nil }
        let delta = recent - baseline
        switch trend.metric {
        case "sleep_minutes":
            let minutes = Int(abs(delta).rounded())
            return .init(headline: minutes == 0 ? "最近睡眠时长接近平时" : "最近每天记录的睡眠比平时\(delta > 0 ? "多" : "少")约\(minutes)分钟",
                         detail: "近期典型睡眠\(duration(recent))，此前\(duration(baseline))。", note: "包含已记录的午睡；时长不能单独反映睡眠质量。")
        case "resting_heart_rate":
            let amount = abs(delta)
            return .init(headline: amount < 0.05 ? "静息心率与平时接近" : "静息心率比平时\(delta > 0 ? "高" : "低")\(String(format: "%.1f", amount))次/分钟",
                         detail: "近期\(String(format: "%.1f", recent))次/分钟，此前\(String(format: "%.1f", baseline))次/分钟。", note: "结合睡眠、训练和身体感受理解，不能单独判定疲劳。")
        case "hrv_sdnn":
            let percent = (recent / baseline - 1) * 100
            return .init(headline: abs(percent) < 0.05 ? "心率波动与平时接近" : "心率波动比平时\(percent > 0 ? "高" : "低")了\(String(format: "%.1f", abs(percent)))%",
                         detail: "这是Apple记录的HRV变化，用于补充训练分析。", note: "高低都不单独等于恢复更好；与高驰HRV的计算口径不同。")
        default: return nil
        }
    }
    private static func duration(_ minutes: Double) -> String {
        let rounded = Int(max(0, min(minutes, 10080)).rounded())
        return "\(rounded / 60)小时\(rounded % 60)分钟"
    }
}

extension TrainingAnalysisMath {
    /// One history origin for dashboard, charts and AI; changing a chart range only crops this series.
    static func loadTimeline(_ summaries: [AnalysisRunSummary], analyses: [RunTrainingAnalysis], now: Date, calendar: Calendar) -> [AnalysisLoadDay] {
        let end = calendar.startOfDay(for: now)
        let first = summaries.filter { $0.date <= now }.map { calendar.startOfDay(for: $0.date) }.min() ?? end
        let count = max(126, (calendar.dateComponents([.day], from: first, to: end).day ?? 0) + 1)
        return loadDays(summaries.filter { $0.date <= now }, analyses: analyses.filter { $0.end <= now }, now: now, days: count, calendar: calendar)
    }
}
