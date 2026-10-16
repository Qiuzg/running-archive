import Foundation

/// All month views and exports use the same summary; routes and detailed samples are not required.
struct MonthlyReport {
    struct Day: Identifiable {
        let number: Int
        let date: Date
        let activities: [ArchiveActivity]
        var id: Int { number }
        var distance: Double { activities.reduce(0) { $0 + $1.distanceKm } }
    }
    struct Week: Identifiable {
        let id: Int
        let label: String
        let distance: Double
    }
    let start: Date
    let activities: [ArchiveActivity]
    let days: [Day]
    let leadingDays: Int
    let weeks: [Week]
    let comparedDistance: Double
    let comparisonDistance: Double
    let comparisonLabel: String
    let isCurrent: Bool
    let calendar: Calendar

    init(month: Date, activities all: [ArchiveActivity], now: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        let interval = calendar.dateInterval(of: .month, for: month)!
        start = interval.start
        isCurrent = calendar.isDate(month, equalTo: now, toGranularity: .month)
        activities = all.filter { $0.date >= interval.start && $0.date < interval.end && $0.date <= now }
            .sorted { $0.date > $1.date }
        let grouped = Dictionary(grouping: activities) { calendar.component(.day, from: $0.date) }
        days = calendar.range(of: .day, in: .month, for: month)!.map { day in
            Day(number: day, date: calendar.date(byAdding: .day, value: day - 1, to: interval.start)!, activities: grouped[day] ?? [])
        }
        leadingDays = (calendar.component(.weekday, from: interval.start) + 5) % 7 // Monday first
        var weekly: [Week] = []
        for row in 0..<((leadingDays + days.count + 6) / 7) {
            let first = max(1, row * 7 - leadingDays + 1)
            let last = min(days.count, (row + 1) * 7 - leadingDays)
            weekly.append(Week(id: row, label: "\(first)–\(last) 日", distance: days[(first - 1)..<last].reduce(0) { $0 + $1.distance }))
        }
        weeks = weekly
        let previous = calendar.date(byAdding: .month, value: -1, to: interval.start)!
        // Current month compares completed calendar dates, including today's partial data.
        let previousDayCount = calendar.range(of: .day, in: .month, for: previous)!.count
        let comparisonDays = min(calendar.component(.day, from: now), previousDayCount)
        let previousEnd = isCurrent
            ? calendar.date(byAdding: .day, value: comparisonDays, to: previous)!
            : interval.start
        comparisonDistance = all.filter { $0.date >= previous && $0.date < previousEnd }.reduce(0) { $0 + $1.distanceKm }
        let currentComparisonEnd = calendar.date(byAdding: .day, value: comparisonDays, to: interval.start)!
        comparedDistance = isCurrent
            ? activities.filter { $0.date < currentComparisonEnd }.reduce(0) { $0 + $1.distanceKm }
            : activities.reduce(0) { $0 + $1.distanceKm }
        comparisonLabel = isCurrent ? "两月 1–\(comparisonDays) 日对比 · 今日未结束" : "较上月整月"
    }

    var key: String { String(format: "%04d-%02d", calendar.component(.year, from: start), calendar.component(.month, from: start)) }
    var title: String { "\(calendar.component(.year, from: start)) 年 \(calendar.component(.month, from: start)) 月" }
    var monthNumber: Int { calendar.component(.month, from: start) }
    var distance: Double { activities.reduce(0) { $0 + $1.distanceKm } }
    var activeDays: Int { days.filter { !$0.activities.isEmpty }.count }
    var longest: ArchiveActivity? { activities.max { $0.distanceKm < $1.distanceKm } }
    var seconds: Double { activities.compactMap { Self.seconds($0.duration) }.reduce(0, +) }
    var durationText: String { "\(Int(seconds) / 3600)h \(Int(seconds) / 60 % 60)m" }
    var paceText: String {
        let timed = activities.filter { Self.seconds($0.duration) != nil && $0.distanceKm > 0 }
        let timedDistance = timed.reduce(0) { $0 + $1.distanceKm }
        guard timedDistance > 0 else { return "—" }
        let pace = Int((timed.reduce(0) { $0 + (Self.seconds($1.duration) ?? 0) } / timedDistance).rounded())
        return String(format: "%d′%02d″", pace / 60, pace % 60)
    }
    var changeText: String {
        guard comparisonDistance > 0 else { return "上月无跑量" }
        return String(format: "%+.0f%%", (comparedDistance / comparisonDistance - 1) * 100)
    }
    var distanceText: String { String(format: "%.1f", distance) }

    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Double($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let result = parts.reduce(0.0) { $0 * 60 + $1! }
        return result > 0 ? result : nil
    }
}
