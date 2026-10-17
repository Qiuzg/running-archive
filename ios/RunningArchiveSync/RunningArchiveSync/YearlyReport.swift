import Foundation

/// The screen and exported poster share this calculation, including the cutoff date.
struct YearlyReport {
    let year: Int
    let cutoff: Date
    let activities: [ArchiveActivity]
    let months: [MonthlyReport]
    let calendar: Calendar

    init(year: Int, activities all: [ArchiveActivity], now: Date = .now, calendar: Calendar = .current) {
        self.year = year
        self.calendar = calendar
        cutoff = now
        activities = all.filter { calendar.component(.year, from: $0.date) == year && $0.date <= now }
        months = (1...12).compactMap { month in
            calendar.date(from: DateComponents(year: year, month: month, day: 1))
                .map { MonthlyReport(month: $0, activities: all, now: now, calendar: calendar) }
        }
    }

    var distance: Double { activities.reduce(0) { $0 + $1.distanceKm } }
    var seconds: Double { activities.compactMap { MonthlyReport.seconds($0.duration) }.reduce(0, +) }
    var durationText: String { "\(Int(seconds) / 3600)h \(Int(seconds) / 60 % 60)m" }
    var activeDays: Int { Set(activities.map { calendar.startOfDay(for: $0.date) }).count }
    var longest: ArchiveActivity? { activities.max { $0.distanceKm < $1.distanceKm } }
    var paceText: String {
        let timed = activities.filter { $0.distanceKm > 0 && MonthlyReport.seconds($0.duration) != nil }
        let distance = timed.reduce(0) { $0 + $1.distanceKm }
        guard distance > 0 else { return "—" }
        let pace = Int((timed.reduce(0) { $0 + (MonthlyReport.seconds($1.duration) ?? 0) } / distance).rounded())
        return String(format: "%d′%02d″", pace / 60, pace % 60)
    }
    var cutoffText: String {
        calendar.component(.year, from: cutoff) == year
            ? "截至 " + cutoff.formatted(.dateTime.month().day())
            : "\(year) 年全年"
    }
}
