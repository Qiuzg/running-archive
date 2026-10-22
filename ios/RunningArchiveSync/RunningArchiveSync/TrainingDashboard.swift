import Foundation

/// Presentation only: keeps the versioned analysis formulas and their eligibility gates unchanged.
struct TrainingDashboard {
    struct Week: Identifiable {
        var start: Date
        var kilometers: Double
        var count: Int
        var knownLoad: Double
        var measured: Int
        var id: Date { start }
        var complete: Bool { measured == count }
    }
    var weeks: [Week]
    var current: Week { weeks.last! }
    var previous: Week { weeks[weeks.count - 2] }
    var loadDay: AnalysisLoadDay?
    var loadRatio: Double? {
        guard let day = loadDay, day.completeHistory, day.warmedUp,
              day.longLoad > 0, day.longLoad.isFinite, day.shortLoad.isFinite else { return nil }
        let ratio = day.shortLoad / day.longLoad
        return ratio.isFinite ? ratio : nil
    }
    var latest: AnalysisRunSummary?
    var latestAnalysis: RunTrainingAnalysis?
    var aerobic: AnalysisTrend
    var measuredCount: Int
    var recentCount: Int

    init(summaries: [AnalysisRunSummary], records: [RunTrainingAnalysis], timeline: [AnalysisLoadDay], now: Date, calendar: Calendar) {
        var c = calendar
        c.firstWeekday = 2 // Explicit Monday–Sunday, independent of the device's locale.
        let week = c.dateInterval(of: .weekOfYear, for: now)!.start
        let past = summaries.filter { $0.date <= now }
        let values = records.filter { $0.date <= now }
        let byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.calculatedAt > b.calculatedAt ? a : b })
        weeks = (-7...0).map { offset in
            let start = c.date(byAdding: .day, value: offset * 7, to: week)!
            let end = c.date(byAdding: .day, value: 7, to: start)!
            let runs = past.filter { $0.date >= start && $0.date < end }
            let loads = runs.compactMap { byID[$0.id]?.load }.filter { $0.usable }
            return Week(start: start, kilometers: runs.reduce(0) { $0 + $1.kilometers }, count: runs.count,
                        knownLoad: loads.reduce(0) { $0 + ($1.value ?? 0) }, measured: loads.count)
        }
        loadDay = timeline.last { $0.date <= now }
        latest = past.max { $0.date < $1.date }
        latestAnalysis = latest.flatMap { byID[$0.id] }
        aerobic = TrainingAnalysisMath.aerobicTrend(values, now: now, calendar: c)
        let start = c.date(byAdding: .day, value: -27, to: c.startOfDay(for: now))!
        let recent = past.filter { $0.date >= start }
        recentCount = recent.count
        measuredCount = recent.filter { byID[$0.id]?.load.usable == true }.count
    }
}
