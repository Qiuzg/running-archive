import Foundation
@main struct MonthlyReportTests {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 8) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
        func run(_ y: Int, _ m: Int, _ d: Int, _ km: Double, _ sec: Double) -> ArchiveActivity {
            ArchiveActivity(preview: WorkoutPreview(id: UUID().uuidString, date: date(y,m,d), distanceKm: km, duration: sec, avgHeartRate: nil, maxHeartRate: nil, avgPower: nil))
        }
        let records = [run(2024,2,1,10,3600), run(2024,2,1,5,1200), run(2024,2,29,21,6300), run(2024,3,1,8,2400)]
        let leap = MonthlyReport(month: date(2024,2,10), activities: records, now: date(2026,10,15), calendar: cal)
        assert(leap.days.count == 29 && leap.activeDays == 2 && leap.activities.count == 3)
        assert(leap.distance == 36 && leap.days[0].distance == 15 && leap.days[0].activities.count == 2)
        assert(leap.seconds == 11100 && leap.paceText == "5′08″")
        assert(leap.weeks.reduce(0) { $0 + $1.distance } == leap.distance)
        assert(leap.leadingDays == 3 && leap.longest?.distanceKm == 21)
        let current = MonthlyReport(month: date(2026,1,1), activities: [run(2025,12,10,20,6000),run(2025,12,25,100,30000),run(2026,1,5,10,3000),run(2026,1,20,40,12000)], now: date(2026,1,15,12), calendar: cal)
        assert(current.comparisonDistance == 20 && current.distance == 10 && current.changeText == "-50%")
        let six = MonthlyReport(month: date(2026,8,1), activities: [], now: date(2026,10,15), calendar: cal)
        assert(six.weeks.count == 6 && six.days.count == 31 && six.activeDays == 0 && six.paceText == "—")
        let shortMonth = MonthlyReport(month: date(2026,3,1), activities: [run(2026,2,28,10,3000),run(2026,3,28,20,6000),run(2026,3,31,5,1500)], now: date(2026,3,31,12), calendar: cal)
        assert(shortMonth.distance == 25 && shortMonth.comparedDistance == 20 && shortMonth.changeText == "+100%")
        assert(shortMonth.comparisonDistance == 10)
        assert(MonthlyReport.seconds("01:02:03") == 3723 && MonthlyReport.seconds("32:15") == 1935)
        assert(MonthlyReport.seconds("--") == nil && MonthlyReport.seconds("nan:00") == nil)
        print("PASS: leap month, multi-run day, month boundaries, weighted pace, weekly totals, prior-year comparison, future exclusion, six-row empty calendar, invalid duration")
    }
}
