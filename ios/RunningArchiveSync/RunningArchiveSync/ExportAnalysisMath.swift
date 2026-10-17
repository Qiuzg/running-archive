import Foundation

enum ExportMetric: String, Codable, CaseIterable {
    case heartRate = "heart_rate", speed = "running_speed", power = "running_power"
    case steps = "step_count", stride = "stride_length", contact = "ground_contact_time", oscillation = "vertical_oscillation"
    var name: String {
        switch self {
        case .heartRate: "心率"; case .speed: "速度"; case .power: "功率"; case .steps: "步频"
        case .stride: "步长"; case .contact: "触地时间"; case .oscillation: "垂直振幅"
        }
    }
    var unit: String {
        switch self {
        case .heartRate: "bpm"; case .speed: "m/s"; case .power: "W"; case .steps: "步/min"
        case .stride: "m"; case .contact: "ms"; case .oscillation: "cm"
        }
    }
    var allowsZero: Bool { self == .speed || self == .power || self == .steps }
}

struct ExportMetricInterval {
    let start: Double
    let end: Double
    let value: Double
}

struct ExportMetricStatistic {
    var average: Double?
    var maximum: Double?
    var supportedSeconds = 0.0
    var fraction: Double?
}

struct ExportMetricSeries {
    let metric: ExportMetric
    let intervals: [ExportMetricInterval]
    let source: String
    let sampleCount: Int
    let invalidCount: Int
    let pointEstimateCount: Int
    let status: String

    func statistic(start: Double, end: Double) -> ExportMetricStatistic {
        guard end > start else { return ExportMetricStatistic() }
        // Intervals are sorted and disjoint. Binary search prevents a full-series
        // scan for every 30-second bucket in a long run.
        var lo = 0, hi = intervals.count
        while lo < hi {
            let middle = (lo + hi) / 2
            if intervals[middle].end <= start { lo = middle + 1 } else { hi = middle }
        }
        var weighted = 0.0, seconds = 0.0, maximum: Double?
        for interval in intervals[lo...] {
            if interval.start >= end { break }
            let overlap = min(end, interval.end) - max(start, interval.start)
            guard overlap > 0 else { continue }
            weighted += interval.value * overlap; seconds += overlap
            maximum = max(maximum ?? interval.value, interval.value)
        }
        return ExportMetricStatistic(average: seconds > 0 ? weighted / seconds : nil,
            maximum: maximum, supportedSeconds: min(seconds, end - start), fraction: seconds > 0 ? min(1, seconds / (end - start)) : nil)
    }
}

struct ExportObjectiveAnalysis {
    let series: [ExportMetric: ExportMetricSeries]
    let elapsed: Double
    let pauses: [ExportMetricInterval]
    let pauseTimingKnown: Bool

    init(workout: ExportWorkout) {
        let elapsed = max(0, workout.end.timeIntervalSince(workout.start))
        self.elapsed = elapsed
        pauses = Self.mergePauses(workout.pauses, start: workout.start, duration: elapsed)
        let pausedSeconds = pauses.reduce(0) { $0 + $1.end - $1.start }
        // Accept event timings only when they reconcile with HealthKit's workout timer.
        pauseTimingKnown = abs(elapsed - pausedSeconds - workout.duration) <= max(2, elapsed * 0.005)
        var result: [ExportMetric: ExportMetricSeries] = [:]
        for metric in ExportMetric.allCases {
            let candidates = workout.samples.filter { $0.metric == metric.rawValue }
            let groups = Dictionary(grouping: candidates, by: \.sourceKey)
            let eligible = groups.filter { _, samples in samples.contains {
                $0.value.isFinite && (metric.allowsZero ? $0.value >= 0 : $0.value > 0)
                    && (metric == .steps ? $0.end > $0.start : $0.end >= $0.start)
                    && $0.end >= workout.start && $0.start < workout.end
            } }
            // Never sum two devices or average their overlapping measurements together.
            let selected = eligible.keys.sorted().max { a, b in
                let aa = eligible[a]!, bb = eligible[b]!
                let ap = aa.map(\.sourcePriority).max() ?? 0, bp = bb.map(\.sourcePriority).max() ?? 0
                if ap != bp { return ap < bp }
                let ac = Self.sourceSupport(aa, metric: metric, start: workout.start, duration: elapsed)
                let bc = Self.sourceSupport(bb, metric: metric, start: workout.start, duration: elapsed)
                return ac == bc ? a < b : ac < bc
            }.flatMap { eligible[$0] } ?? []
            let ordered = selected.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.value < $1.value
            }
            var valid: [ExportRawSample] = [], invalid = 0
            for sample in ordered {
                let duration = sample.end.timeIntervalSince(sample.start)
                if !sample.value.isFinite || sample.value < 0 || (!metric.allowsZero && sample.value == 0)
                    || duration < 0 || (metric == .steps && duration <= 0)
                    || sample.end < workout.start || sample.start >= workout.end {
                    invalid += 1; continue
                }
                // Same-timestamp entries from one source are represented once.
                if valid.last?.start == sample.start { valid.removeLast() }
                valid.append(sample)
            }
            var intervals: [ExportMetricInterval] = [], estimated = 0
            for (index, sample) in valid.enumerated() {
                let rawStart = sample.start.timeIntervalSince(workout.start)
                let rawEnd = sample.end.timeIntervalSince(workout.start)
                let next = index + 1 < valid.count ? valid[index + 1].start.timeIntervalSince(workout.start) : elapsed
                let end: Double
                if rawEnd > rawStart { end = min(rawEnd, next, elapsed) }
                else { end = min(rawStart + 10, next, elapsed); estimated += 1 }
                let start = max(0, rawStart)
                guard end > start else { continue }
                // Cumulative step samples are converted to an interval-average cadence.
                let value = metric == .steps ? sample.value / (rawEnd - rawStart) * 60 : sample.value
                intervals.append(ExportMetricInterval(start: start, end: end, value: value))
            }
            let issue = workout.readIssues[metric.rawValue]
            let sources = Set(selected.map(\.sourceLabel)).sorted().joined(separator: "；")
            let status: String
            if let issue { status = "读取失败：\(issue)" }
            else if intervals.isEmpty { status = "未获得可用数据（未记录或未授权）" }
            else { status = "已读取" + (groups.count > 1 ? "；存在多来源，仅采用一个来源" : "") }
            result[metric] = ExportMetricSeries(metric: metric, intervals: intervals, source: sources,
                sampleCount: selected.count, invalidCount: invalid, pointEstimateCount: estimated, status: status)
        }
        series = result
    }

    func statistics(start: Double, end: Double) -> [ExportMetric: ExportMetricStatistic] {
        Dictionary(uniqueKeysWithValues: ExportMetric.allCases.map { ($0, series[$0]!.statistic(start: start, end: end)) })
    }
    func activeSeconds(start: Double, end: Double) -> Double? {
        guard pauseTimingKnown else { return nil }
        return max(0, end - start - pauses.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) })
    }
    func heartRateDistribution() -> [Double] {
        let ranges: [Double] = [100,120,140,160,180]
        var values = Array(repeating: 0.0, count: 6)
        for interval in series[.heartRate]?.intervals ?? [] {
            let index = ranges.firstIndex { interval.value < $0 } ?? 5
            values[index] += interval.end - interval.start
        }
        return values
    }
    private static func sourceSupport(_ samples: [ExportRawSample], metric: ExportMetric, start: Date, duration: Double) -> Double {
        let spans = samples.filter { $0.value.isFinite && (metric.allowsZero ? $0.value >= 0 : $0.value > 0) && (metric == .steps ? $0.end > $0.start : $0.end >= $0.start) }
            .map { DateInterval(start: $0.start, end: max($0.end, $0.start.addingTimeInterval(1))) }
        return mergePauses(spans, start: start, duration: duration).reduce(0) { $0 + $1.end - $1.start }
    }
    private static func mergePauses(_ intervals: [DateInterval], start: Date, duration: Double) -> [ExportMetricInterval] {
        var merged: [ExportMetricInterval] = []
        for span in intervals.sorted(by: { $0.start < $1.start }) {
            let a = max(0, span.start.timeIntervalSince(start)), b = min(duration, span.end.timeIntervalSince(start))
            guard b > a else { continue }
            if let last = merged.last, a <= last.end {
                merged[merged.count - 1] = ExportMetricInterval(start: last.start, end: max(last.end, b), value: 0)
            } else { merged.append(ExportMetricInterval(start: a, end: b, value: 0)) }
        }
        return merged
    }
}
