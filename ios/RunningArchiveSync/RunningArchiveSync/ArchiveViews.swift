import Charts
import ImageIO
import MapKit
import SwiftUI
import UIKit

enum RunTheme {
    static let accent = Color(red: 1.0, green: 0.34, blue: 0.22)
    static let route = Color(red: 0.18, green: 0.68, blue: 0.65)
    static let ink = adaptive(light: UIColor(red: 0.055, green: 0.11, blue: 0.13, alpha: 1), dark: UIColor(red: 0.965, green: 0.945, blue: 0.90, alpha: 1))
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.90)
    static let page = adaptive(light: UIColor(red: 0.968, green: 0.949, blue: 0.914, alpha: 1), dark: UIColor(red: 0.055, green: 0.11, blue: 0.13, alpha: 1))
    static let panel = adaptive(light: UIColor(red: 1.0, green: 0.984, blue: 0.945, alpha: 1), dark: UIColor(red: 0.10, green: 0.20, blue: 0.22, alpha: 1))
    static let deepPage = adaptive(light: UIColor(red: 0.968, green: 0.949, blue: 0.914, alpha: 1), dark: UIColor(red: 0.059, green: 0.118, blue: 0.133, alpha: 1))
    static let deepPanel = adaptive(light: UIColor(red: 0.055, green: 0.11, blue: 0.13, alpha: 1), dark: UIColor(red: 0.078, green: 0.165, blue: 0.18, alpha: 1))
    static let mint = Color(red: 0.46, green: 0.84, blue: 0.75)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var mapFocusRequest = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                hero
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(RunTheme.page)
            }
            .ignoresSafeArea(edges: .top)
            .navigationDestination(for: ArchiveActivity.self) { activity in
                ActivityDetailView(activity: activity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ThemeToggleButton() }
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottom) {
            RouteMapView(routes: Array(store.routes.prefix(40)), colorScheme: colorScheme, focusRequest: mapFocusRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            routeAtlasLabel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 76)
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [.clear, Color.black.opacity(0.48)]
                    : [.clear, Color.white.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 250)
            .allowsHitTesting(false)
            VStack(alignment: .trailing, spacing: 12) {
                if !store.routes.isEmpty {
                    Button { mapFocusRequest += 1 } label: {
                        Label("回到路线", systemImage: "scope")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(RunTheme.ink)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到近期路线")
                }
                heroSummaryCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 85)

            if store.isLoading && store.activities.isEmpty {
                ProgressView("正在读取 Apple Health")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage, store.activities.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart.text.square")
                        .font(.system(size: 34))
                        .foregroundStyle(RunTheme.accent)
                    Text("无法读取跑步档案")
                        .font(.headline.weight(.bold))
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button("重试") { Task { await store.load(force: true) } }
                }
                .padding(22)
                .frame(width: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var heroSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                profileAvatar
                VStack(alignment: .leading, spacing: 3) {
                    Text("我的跑步档案")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(store.summary.map { "\(Int($0.totalDistanceKm)) km" } ?? "-- km")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(RunTheme.ink)
                }
                Spacer()
                Text("累计跑量")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                AtlasHeroMetric(label: "今年", value: store.summary.map { "\(Int($0.yearlyDistanceKm)) km" } ?? "--", accent: RunTheme.route)
                AtlasHeroMetric(label: "全马 PB", value: store.summary?.marathonPb ?? "--", accent: RunTheme.mint)
                AtlasHeroMetric(label: "半马 PB", value: store.summary?.halfMarathonPb ?? "--", accent: RunTheme.accent)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    private var routeAtlasLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ROUTE ATLAS")
                .font(.caption2.weight(.black))
                .tracking(2.2)
                .foregroundStyle(.white.opacity(0.78))
            Text("\(store.routes.count) 条轨迹 · \(formatNumber(store.routes.reduce(0) { $0 + $1.distanceKm })) km")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
            if let status = store.routeScanStatus {
                Label(status, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.top, 5)
            }
        }
        .padding(12)
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatNumber(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private var profileAvatar: some View {
        Group {
            if let image = UIImage(named: "profile") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54, alignment: .trailing)
                    .clipped()
            } else {
                Image(systemName: "figure.run")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(.black.opacity(0.82))
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
        .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
    }

}

private struct AtlasHeroMetric: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule()
                .fill(accent)
                .frame(width: 22, height: 3)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle((colorScheme == .dark ? Color.white : RunTheme.ink).opacity(0.72))
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.black).monospacedDigit())
                .foregroundStyle(colorScheme == .dark ? .white : RunTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ArchiveStatsPanel: View {
    let activities: [ArchiveActivity]
    @State private var selectedYear: Int
    @State private var selectedMonth: Int?

    init(activities: [ArchiveActivity]) {
        self.activities = activities
        let currentYear = Calendar.current.component(.year, from: .now)
        let latestYear = activities.map { Calendar.current.component(.year, from: $0.date) }.max() ?? currentYear
        _selectedYear = State(initialValue: activities.contains { Calendar.current.component(.year, from: $0.date) == currentYear } ? currentYear : latestYear)
        _selectedMonth = State(initialValue: nil)
    }

    private var years: [Int] {
        Array(Set(activities.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >)
    }

    private var yearActivities: [ArchiveActivity] {
        activities.filter { Calendar.current.component(.year, from: $0.date) == selectedYear }
    }

    private var monthlyTotals: [Double] {
        yearActivities.reduce(into: Array(repeating: 0.0, count: 12)) { totals, activity in
            let month = Calendar.current.component(.month, from: activity.date)
            totals[month - 1] += activity.distanceKm
        }
    }

    private var yearDistance: Double { monthlyTotals.reduce(0, +) }
    private var activeMonths: Int { monthlyTotals.filter { $0 > 0 }.count }
    private var monthlyAverage: Double { activeMonths > 0 ? yearDistance / Double(activeMonths) : 0 }
    private var longest: ArchiveActivity? { yearActivities.max { $0.distanceKm < $1.distanceKm } }
    private var races: [ArchiveActivity] { yearActivities.filter { $0.kind == .race } }
    private var maxMonth: Double { max(monthlyTotals.max() ?? 0, 10) }
    private var selectedMonthActivities: [ArchiveActivity] {
        guard let selectedMonth else { return [] }
        return yearActivities
            .filter { Calendar.current.component(.month, from: $0.date) == selectedMonth + 1 }
            .sorted { $0.date < $1.date }
    }
    private var selectedMonthTotal: Double {
        selectedMonthActivities.reduce(0) { $0 + $1.distanceKm }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YEAR IN MOTION").font(.caption2.bold()).tracking(2).foregroundStyle(RunTheme.accent)
                    Text("年度统计").font(.title2.bold())
                }
                Spacer()
                yearPicker
            }

            HStack(spacing: 10) {
                ArchiveStatValue(label: "年度总跑量", value: formatKm(yearDistance), unit: "km", color: RunTheme.route)
                ArchiveStatValue(label: "月均跑量", value: formatKm(monthlyAverage), unit: "km", color: .blue)
                ArchiveStatValue(label: "训练月份", value: "\(activeMonths)", unit: "个月", color: .orange)
            }

            Chart(Array(monthlyTotals.enumerated()), id: \.offset) { item in
                BarMark(
                    x: .value("月份", item.offset + 1),
                    y: .value("公里", item.element)
                )
                .foregroundStyle(item.element > 0 ? RunTheme.route : Color.secondary.opacity(0.12))
                .cornerRadius(5)
                .annotation(position: .top, alignment: .center) {
                    if selectedMonth == item.offset {
                        Text("\(formatKm(item.element)) km")
                            .font(.caption2.bold()).foregroundStyle(RunTheme.route)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(.background.opacity(0.92), in: Capsule())
                    }
                }
            }
            .chartXScale(domain: 0.5...12.5)
            .chartYScale(domain: 0...maxMonth)
            .chartXAxis {
                AxisMarks(values: [1, 3, 5, 7, 9, 11]) { value in
                    AxisValueLabel { if let month = value.as(Int.self) { Text("\(month)月") } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                        .foregroundStyle(.secondary.opacity(0.24))
                    AxisValueLabel { if let km = value.as(Double.self) { Text(formatKm(km)) } }
                }
            }
            .frame(height: 190)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plotFrameAnchor = proxy.plotFrame else { return }
                            let plotFrame = geometry[plotFrameAnchor]
                            let x = location.x - plotFrame.origin.x
                            guard let month = proxy.value(atX: x, as: Int.self), (1...12).contains(month) else { return }
                            selectedMonth = month - 1
                        }
                }
            }

            if let selectedMonth {
                monthlyDetail(month: selectedMonth)
            } else {
                Text("点击月份柱状图查看当月跑量和每次训练的具体数值")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack(spacing: 10) {
                ArchiveStatValue(label: "比赛", value: "\(races.count)", unit: "场", color: RunTheme.accent)
                ArchiveStatValue(label: "全马 / 半马", value: "\(races.filter { $0.distanceKm >= 41 }.count) / \(races.filter { $0.distanceKm >= 20 && $0.distanceKm < 41 }.count)", unit: "场", color: .purple)
                ArchiveStatValue(label: "最长距离", value: longest.map { formatKm($0.distanceKm) } ?? "--", unit: "km", color: .orange)
            }

            if let longest {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill").foregroundStyle(.orange)
                    Text("最长：\(longest.name) · \(formatKm(longest.distanceKm)) km")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onChange(of: activities.count) { _, _ in
            if !years.contains(selectedYear) { selectedYear = years.first ?? Calendar.current.component(.year, from: .now) }
            selectedMonth = nil
        }
    }

    private var yearPicker: some View {
        HStack(spacing: 4) {
            Button { moveYear(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(years.firstIndex(of: selectedYear).map { $0 >= years.count - 1 } ?? true)
            Text("\(selectedYear)").font(.subheadline.bold()).monospacedDigit().frame(minWidth: 48)
            Button { moveYear(1) } label: { Image(systemName: "chevron.right") }
                .disabled(years.firstIndex(of: selectedYear).map { $0 <= 0 } ?? true)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func moveYear(_ direction: Int) {
        guard let index = years.firstIndex(of: selectedYear) else { return }
        let next = index - direction
        guard years.indices.contains(next) else { return }
        selectedYear = years[next]
        selectedMonth = nil
    }

    @ViewBuilder
    private func monthlyDetail(month: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedYear) 年 \(month + 1) 月")
                        .font(.headline.bold())
                    Text("\(selectedMonthActivities.count) 次训练 · \(formatKm(selectedMonthTotal)) km")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedMonth = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if selectedMonthActivities.isEmpty {
                Text("这个月没有跑步记录")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 86)
            } else {
                Chart(Array(selectedMonthActivities.enumerated()), id: \.offset) { item in
                    BarMark(
                        x: .value("训练", item.offset + 1),
                        y: .value("公里", item.element.distanceKm)
                    )
                    .foregroundStyle(RunTheme.route.gradient)
                    .cornerRadius(5)
                }
                .chartXScale(domain: 0.5...(Double(selectedMonthActivities.count) + 0.5))
                .chartYScale(domain: 0...max(selectedMonthActivities.map(\.distanceKm).max() ?? 0, 10))
                .chartXAxis {
                    AxisMarks(values: detailAxisValues) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self), selectedMonthActivities.indices.contains(index - 1) {
                                Text("\(Calendar.current.component(.day, from: selectedMonthActivities[index - 1].date))日")
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                            .foregroundStyle(.secondary.opacity(0.24))
                        AxisValueLabel { if let km = value.as(Double.self) { Text(formatKm(km)) } }
                    }
                }
                .frame(height: 170)

                VStack(spacing: 0) {
                    ForEach(Array(selectedMonthActivities.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.date.formatted(.dateTime.month().day()))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(item.element.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(formatKm(item.element.distanceKm)) km")
                                .font(.subheadline.bold()).monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        if item.offset < selectedMonthActivities.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detailAxisValues: [Int] {
        let count = selectedMonthActivities.count
        let step = max(1, Int(ceil(Double(count) / 5.0)))
        return Array(stride(from: 1, through: count, by: step))
    }

    private func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

private struct ArchiveStatValue: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.title3.bold()).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SummaryCollectionView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedYear = Calendar.current.component(.year, from: .now)
    @State private var openedMonth: Date?
    @State private var atlasExportImage: UIImage?
    @State private var showingAtlasShare = false
    @State private var isExportingAtlas = false

    private var years: [Int] {
        Array(Set(store.activities.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >)
    }

    private var yearActivities: [ArchiveActivity] {
        store.activities.filter { Calendar.current.component(.year, from: $0.date) == selectedYear }
    }

    private var monthlyTotals: [Double] {
        yearActivities.reduce(into: Array(repeating: 0.0, count: 12)) { totals, activity in
            let month = Calendar.current.component(.month, from: activity.date)
            totals[month - 1] += activity.distanceKm
        }
    }

    private var yearDistance: Double { monthlyTotals.reduce(0, +) }
    private var totalDistance: Double { store.summary?.totalDistanceKm ?? store.activities.reduce(0) { $0 + $1.distanceKm } }
    private var routeEntries: [ArchiveActivity] {
        store.activities.filter { store.routeSummary(id: $0.routeId) != nil && $0.distanceKm >= 10 }
            .sorted { $0.date > $1.date }
    }
    private var routeTotalDistance: Double { routeEntries.reduce(0) { $0 + $1.distanceKm } }
    private var routeMarathonCount: Int { routeEntries.filter { $0.kind == .race && (41.0...44.0).contains($0.distanceKm) }.count }
    private var routeHalfCount: Int { routeEntries.filter { $0.kind == .race && (20.0...23.0).contains($0.distanceKm) }.count }
    private var routeRunCount: Int { routeEntries.count - routeMarathonCount - routeHalfCount }
    private var recentActivities: [ArchiveActivity] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
        return store.activities.filter { $0.date >= start }
    }
    private var previousWeekDistance: Double {
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: -13, to: today) ?? .distantPast
        let end = Calendar.current.date(byAdding: .day, value: -6, to: today) ?? .distantFuture
        return store.activities.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.distanceKm }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("跑步汇总")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(RunTheme.ink)
                        Text("\(String(selectedYear)) 年 · \(yearActivities.count) 次跑步")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    totalDistanceCard
                    yearSwitcher
                    monthlySummaryCard
                    recentTrainingCard
                    TrainingHubLinks()
                    if let status = store.routeScanStatus {
                        Label(status, systemImage: "map")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    routeCollection
                }
                .padding(.horizontal, 17)
                .padding(.top, 24)
                .padding(.bottom, 140)
            }
            .background(RunTheme.deepPage)
            .scrollIndicators(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("汇总")
            .toolbarBackground(RunTheme.deepPage, for: .navigationBar)
            .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
            .navigationDestination(item: $openedMonth) { month in
                MonthlyReviewView(month: month)
            }
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
            .onAppear {
                if !years.contains(selectedYear) { selectedYear = years.first ?? Calendar.current.component(.year, from: .now) }
            }
            .onChange(of: store.activities.count) { _, _ in
                if !years.contains(selectedYear) { selectedYear = years.first ?? Calendar.current.component(.year, from: .now) }

            }
            .sheet(isPresented: $showingAtlasShare) {
                if let atlasExportImage { ShareSheet(items: [atlasExportImage]) }
            }
        }
    }

    private var yearSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(years.isEmpty ? [selectedYear] : years, id: \.self) { year in
                    Button { selectedYear = year } label: {
                        Text(String(year))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(selectedYear == year ? RunTheme.ink : .secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(selectedYear == year ? RunTheme.mint : RunTheme.panel, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var totalDistanceCard: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("累计总跑量")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(formatKm(totalDistance)) km")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(RunTheme.accent)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Spacer()
            Text("全部历史记录")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var recentTrainingCard: some View {
        let distance = recentActivities.reduce(0) { $0 + $1.distanceKm }
        let longest = recentActivities.map(\.distanceKm).max() ?? 0
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("近 7 天", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(RunTheme.ink)
                Spacer()
                Text("持续积累")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RunTheme.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(formatKm(distance))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(RunTheme.ink)
                Text("km")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(recentActivities.count) 次训练")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RunTheme.route)
            }
            Rectangle().fill(RunTheme.route.opacity(0.16)).frame(height: 1)
            HStack {
                Text("最长单次  \(formatKm(longest)) km")
                Spacer()
                Text(previousWeekDistance > 0
                     ? String(format: "较前 7 天 %+.0f%%", (distance / previousWeekDistance - 1) * 100)
                     : "前 7 天无记录")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(17)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var monthlySummaryCard: some View {
        let month = selectedYear == Calendar.current.component(.year, from: .now)
            ? Calendar.current.component(.month, from: .now)
            : (yearActivities.map { Calendar.current.component(.month, from: $0.date) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每一步，都算数").font(.title3.bold())
                    Text("年度跑量 · \(formatKm(yearDistance)) km")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(1...12, id: \.self) { value in
                        Button("\(value) 月 · \(formatKm(monthlyTotals[value - 1])) km") { openMonth(value) }
                    }
                } label: {
                    Image(systemName: "calendar").font(.title3).padding(10)
                }
                .accessibilityLabel("选择月份查看月报")
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<12, id: \.self) { index in
                    Button { openMonth(index + 1) } label: {
                        VStack(spacing: 9) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(index + 1 == month ? RunTheme.accent : RunTheme.route.opacity(0.5))
                                .frame(height: max(4, 100 * monthlyTotals[index] / max(monthlyTotals.max() ?? 0, 1)))
                            Text("\(index + 1)").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).frame(height: 124)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(index + 1) 月，\(formatKm(monthlyTotals[index])) 公里，查看月报")
                }
            }
            Button { openMonth(month) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(month) 月跑步手记").font(.headline)
                        Text("\(formatKm(monthlyTotals[month - 1])) km · 日历、明细与分享")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.title3.weight(.semibold))
                }
                .padding(16)
                .background(RunTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(RunTheme.ink)
        .padding(18)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 24))
    }

    private func openMonth(_ month: Int) {
        openedMonth = Calendar.current.date(from: DateComponents(year: selectedYear, month: month, day: 1))
    }

    private var routeCollection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ROUTE COLLECTION · \(routeEntries.count) RUNS · \(formatKm(routeTotalDistance).uppercased()) KM")
                        .font(.caption2.weight(.black))
                        .tracking(1.35)
                        .foregroundStyle(RunTheme.accent)
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                    Text("长距离路线")
                        .font(.system(size: 27, weight: .black, design: .rounded))
                        .foregroundStyle(RunTheme.ink)
                }
                Spacer(minLength: 4)
                Button(action: exportAtlas) {
                    Group {
                        if isExportingAtlas {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(routeEntries.isEmpty ? .secondary : RunTheme.accent)
                        .padding(10)
                        .background(RunTheme.panel, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(routeEntries.isEmpty || isExportingAtlas)
            }
            Text("所有 10 km 以上轨迹 · 会随 Apple Health 新记录自动更新")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                CollectionLegend(label: "日常跑", count: routeRunCount, color: RunTheme.route)
                CollectionLegend(label: "半马", count: routeHalfCount, color: Color.blue)
                CollectionLegend(label: "全马", count: routeMarathonCount, color: RunTheme.accent)
            }
            if routeEntries.isEmpty {
                Text("暂无 10 km 以上路线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                    ForEach(routeEntries) { activity in
                        NavigationLink(value: activity) {
                            CollectionRouteCard(activity: activity, route: store.routeSummary(id: activity.routeId))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func exportAtlas() {
        guard !routeEntries.isEmpty, !isExportingAtlas else { return }
        let payload = AtlasExportPayload(
            activities: routeEntries.map { activity in
                AtlasExportActivity(
                    id: activity.id,
                    distanceKm: activity.distanceKm,
                    dateText: activity.date.formatted(date: .numeric, time: .omitted),
                    kind: activity.kind == .race ? (activity.distanceKm >= 41 ? .marathon : .half) : .run,
                    coordinates: store.routeSummary(id: activity.routeId)?.previewCoordinates ?? []
                )
            },
            totalDistance: routeTotalDistance,
            runCount: routeRunCount,
            halfCount: routeHalfCount,
            marathonCount: routeMarathonCount
        )
        let dark = colorScheme == .dark
        isExportingAtlas = true
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) {
                AtlasExportImageGenerator.makePNG(payload: payload, dark: dark)
            }.value
            isExportingAtlas = false
            guard let data, let image = UIImage(data: data) else { return }
            atlasExportImage = image
            showingAtlasShare = true
        }
    }
}

private struct CollectionLegend: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum AtlasExportRouteKind: Sendable {
    case run, half, marathon
}

private struct AtlasExportActivity: Sendable {
    let id: String
    let distanceKm: Double
    let dateText: String
    let kind: AtlasExportRouteKind
    let coordinates: [[Double]]
}

private struct AtlasExportPayload: Sendable {
    let activities: [AtlasExportActivity]
    let totalDistance: Double
    let runCount: Int
    let halfCount: Int
    let marathonCount: Int
}

private enum AtlasExportImageGenerator {
    static func makePNG(payload: AtlasExportPayload, dark: Bool) -> Data? {
        let canvasWidth: CGFloat = 1080
        let horizontalPadding: CGFloat = 58
        let columnGap: CGFloat = 28
        let columns = 3
        let cellWidth = (canvasWidth - horizontalPadding * 2 - columnGap * 2) / CGFloat(columns)
        let cellHeight: CGFloat = 190
        let headerHeight: CGFloat = 230
        let rowCount = max(1, Int(ceil(Double(payload.activities.count) / Double(columns))))
        let canvasHeight = horizontalPadding * 2 + headerHeight + CGFloat(rowCount) * cellHeight + CGFloat(max(0, rowCount - 1)) * 26
        let size = CGSize(width: canvasWidth, height: canvasHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.25
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let pageColor = dark
                ? UIColor(red: 0.055, green: 0.118, blue: 0.133, alpha: 1)
                : UIColor(red: 0.968, green: 0.949, blue: 0.914, alpha: 1)
            let inkColor = dark
                ? UIColor(red: 0.965, green: 0.945, blue: 0.90, alpha: 1)
                : UIColor(red: 0.055, green: 0.11, blue: 0.13, alpha: 1)
            let mutedColor = dark
                ? UIColor.white.withAlphaComponent(0.58)
                : UIColor(red: 0.055, green: 0.11, blue: 0.13, alpha: 0.52)
            pageColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            drawText(
                "ROUTE COLLECTION · \(payload.activities.count) RUNS · \(formatKm(payload.totalDistance).uppercased()) KM",
                at: CGPoint(x: horizontalPadding, y: horizontalPadding),
                font: .systemFont(ofSize: 22, weight: .black),
                color: UIColor(red: 1.0, green: 0.34, blue: 0.22, alpha: 1)
            )
            drawText(
                "Over 10km Runs",
                at: CGPoint(x: horizontalPadding, y: horizontalPadding + 42),
                font: .systemFont(ofSize: 66, weight: .black),
                color: inkColor
            )
            drawLegend("日常跑 \(payload.runCount)", color: routeColor(.run, dark: dark), at: CGPoint(x: canvasWidth - 250, y: horizontalPadding + 16), context: context, mutedColor: mutedColor)
            drawLegend("半马 \(payload.halfCount)", color: routeColor(.half, dark: dark), at: CGPoint(x: canvasWidth - 250, y: horizontalPadding + 52), context: context, mutedColor: mutedColor)
            drawLegend("全马 \(payload.marathonCount)", color: routeColor(.marathon, dark: dark), at: CGPoint(x: canvasWidth - 250, y: horizontalPadding + 88), context: context, mutedColor: mutedColor)

            for (index, activity) in payload.activities.enumerated() {
                let column = index % columns
                let row = index / columns
                let origin = CGPoint(
                    x: horizontalPadding + CGFloat(column) * (cellWidth + columnGap),
                    y: horizontalPadding + headerHeight + CGFloat(row) * (cellHeight + 26)
                )
                let routeRect = CGRect(x: origin.x, y: origin.y, width: cellWidth, height: 142)
                let coordinates = activity.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
                let points = normalizedPoints(mapDisplayCoordinates(coordinates), size: routeRect.size, inset: 9)
                if points.count > 1 {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: routeRect.minX + points[0].x, y: routeRect.minY + points[0].y))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: routeRect.minX + point.x, y: routeRect.minY + point.y))
                    }
                    let color = routeColor(activity.kind, dark: dark)
                    color.withAlphaComponent(0.12).setStroke()
                    path.lineWidth = 8
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    path.stroke()
                    color.setStroke()
                    path.lineWidth = 2.5
                    path.stroke()
                }
                drawText(
                    "\(formatKm(activity.distanceKm)) km · \(activity.dateText)",
                    at: CGPoint(x: origin.x, y: origin.y + 150),
                    font: .systemFont(ofSize: 18, weight: .semibold),
                    color: mutedColor
                )
            }
        }
        return opaquePNGData(from: image)
    }

    /// Encode the export as an RGB PNG instead of carrying an unnecessary
    /// premultiplied-alpha channel for an already opaque image.
    private static func opaquePNGData(from image: UIImage) -> Data? {
        guard let source = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let width = source.width
        let height = source.height
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgbImage = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, rgbImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func drawLegend(_ text: String, color: UIColor, at point: CGPoint, context: CGContext, mutedColor: UIColor) {
        color.setFill()
        context.fillEllipse(in: CGRect(x: point.x, y: point.y + 5, width: 12, height: 12))
        drawText(text, at: CGPoint(x: point.x + 22, y: point.y), font: .systemFont(ofSize: 18, weight: .medium), color: mutedColor)
    }

    private static func routeColor(_ kind: AtlasExportRouteKind, dark: Bool) -> UIColor {
        switch kind {
        case .run:
            return UIColor(red: 0.18, green: 0.68, blue: 0.65, alpha: 1)
        case .half:
            return dark ? UIColor(red: 0.35, green: 0.58, blue: 1, alpha: 1) : UIColor(red: 0.08, green: 0.42, blue: 0.86, alpha: 1)
        case .marathon:
            return UIColor(red: 1.0, green: 0.34, blue: 0.22, alpha: 1)
        }
    }

    private static func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor) {
        NSString(string: text).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

private struct CollectionRouteCard: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteSummary?

    private var routeColor: Color {
        if activity.kind == .race && (41.0...44.0).contains(activity.distanceKm) { return RunTheme.accent }
        if activity.kind == .race && (20.0...23.0).contains(activity.distanceKm) { return .blue }
        return RunTheme.route
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MiniRouteView(coordinates: route?.coordinates ?? [], color: routeColor)
                .frame(maxWidth: .infinity).frame(height: 112)
                .background(RunTheme.route.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(activity.name).font(.subheadline.bold()).lineLimit(1)
            Text("\(formatKm(activity.distanceKm)) km · \(activity.date.formatted(date: .numeric, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 1))
    }

    private func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

private struct SummaryMetric: View {
    let label: String
    let value: String
    let color: Color
    var divider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(color).frame(width: 24, height: 3)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value).font(.subheadline.bold()).monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .trailing) {
            if divider { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1, height: 34) }
        }
    }
}

struct RouteActivityRow: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteSummary?

    var body: some View {
        HStack(spacing: 14) {
            MiniRouteView(coordinates: route?.coordinates ?? [])
                .frame(width: 74, height: 58)
                .padding(7)
                .background(RunTheme.route.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(activity.name).font(.headline).lineLimit(1)
                    if activity.isPb {
                        Text("PB").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RunTheme.accent, in: Capsule())
                    }
                }
                Text("\(activity.date.formatted(date: .numeric, time: .omitted)) · \(activity.distanceKm, specifier: "%.1f") km · \(activity.pace)/km")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct ActivityListView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", run = "训练", race = "比赛"
        var id: Self { self }
    }

    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var trainingKind: TrainingKind = .unspecified
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var selectedYear: Int?
    @State private var routeOnly = false
    @State private var longDistanceOnly = false

    private var years: [Int] {
        Array(Set(store.activities.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >)
    }

    private var filtered: [ArchiveActivity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.activities.filter { item in
            let matchesType = filter == .all || (filter == .run && item.kind == .run) || (filter == .race && item.kind == .race)
            let matchesYear = selectedYear == nil || Calendar.current.component(.year, from: item.date) == selectedYear
            let matchesRoute = !routeOnly || store.routeSummary(id: item.routeId) != nil
            let matchesDistance = !longDistanceOnly || item.distanceKm >= 10
            let matchesSearch = query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
                || item.city.localizedCaseInsensitiveContains(query)
                || item.date.formatted(date: .numeric, time: .omitted).contains(query)
                || journal.annotation(item.id).note.localizedCaseInsensitiveContains(query)
                || journal.annotation(item.id).routeName.localizedCaseInsensitiveContains(query)
            let matchesTraining = trainingKind == .unspecified || journal.annotation(item.id).kind == trainingKind
            return matchesType && matchesYear && matchesRoute && matchesDistance && matchesSearch && matchesTraining
        }
    }

    private var monthKeys: [Int] {
        Array(Set(filtered.map {
            let parts = Calendar.current.dateComponents([.year, .month], from: $0.date)
            return (parts.year ?? 0) * 100 + (parts.month ?? 0)
        })).sorted(by: >)
    }

    private func activities(in monthKey: Int) -> [ArchiveActivity] {
        filtered.filter {
            let parts = Calendar.current.dateComponents([.year, .month], from: $0.date)
            return (parts.year ?? 0) * 100 + (parts.month ?? 0) == monthKey
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("跑步记录")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(RunTheme.ink)
                    Text("\(filtered.count) 条记录 · 从一次跑步开始回顾")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索名称、城市或日期", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(13)
                .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { item in
                            Button { filter = item } label: {
                                Text(item.rawValue)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(filter == item ? .white : RunTheme.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(filter == item ? RunTheme.accent : RunTheme.panel, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Menu {
                        Button("所有年份") { selectedYear = nil }
                        ForEach(years, id: \.self) { year in
                            Button("\(year) 年") { selectedYear = year }
                        }
                    } label: {
                        Label(selectedYear.map { "\($0) 年" } ?? "所有年份", systemImage: "calendar")
                    }
                    Spacer()
                    Button { longDistanceOnly.toggle() } label: {
                        Text("10 km+")
                            .foregroundStyle(longDistanceOnly ? .white : RunTheme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(longDistanceOnly ? RunTheme.route : RunTheme.panel, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { routeOnly.toggle() } label: {
                        Label("有路线", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .foregroundStyle(routeOnly ? .white : RunTheme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(routeOnly ? RunTheme.route : RunTheme.panel, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(RunTheme.ink)

                Picker("训练标签", selection: $trainingKind) {
                    Text("全部训练标签").tag(TrainingKind.unspecified)
                    ForEach(TrainingKind.allCases.filter { $0 != .unspecified }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)

                if filtered.isEmpty {
                    ContentUnavailableView("没有匹配记录", systemImage: "figure.run", description: Text("试试更换年份或清除筛选。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(monthKeys, id: \.self) { monthKey in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(monthKey / 100) 年 \(monthKey % 100) 月")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.secondary)
                                ForEach(activities(in: monthKey)) { activity in
                                    NavigationLink(value: activity) {
                                        ActivityLogCard(activity: activity, route: store.routeSummary(id: activity.routeId))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.top, 24)
            .padding(.bottom, 140)
        }
        .background(RunTheme.page)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(RunTheme.page, for: .navigationBar)
        .navigationTitle("记录")
        .refreshable { await store.load(force: true) }
        .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
    }
}

private struct ActivityLogCard: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteSummary?

    var body: some View {
        HStack(spacing: 13) {
            MiniRouteView(coordinates: route?.coordinates ?? [])
                .frame(width: 76, height: 58)
                .padding(8)
                .background(RunTheme.route.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(activity.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(RunTheme.ink)
                        .lineLimit(1)
                    if activity.isPb {
                        Text("PB")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RunTheme.accent, in: Capsule())
                    }
                }
                Text("\(String(format: "%.1f", activity.distanceKm)) km · \(activity.pace)/km · \(activity.duration)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(activity.date.formatted(.dateTime.year().month().day()) + (activity.city.isEmpty ? "" : " · \(activity.city)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(RunTheme.mint)
        }
        .padding(14)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 5)
    }
}

struct ActivityDetailView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var navigation: ArchiveNavigationStore
    @Environment(\.colorScheme) private var colorScheme
    let activity: ArchiveActivity
    @State private var route: ArchiveRouteDetail?
    @State private var errorMessage: String?

    private var displayActivity: ArchiveActivity {
        store.activities.first { $0.id == activity.id } ?? activity
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                detailMap
                VStack(alignment: .leading, spacing: 18) {
                    Text("训练数据")
                        .font(.title3.weight(.black))
                        .foregroundStyle(RunTheme.ink)
                    metrics
                    if let series = route?.timeSeries {
                        ActivityCharts(series: series)
                    }
                    ActivityJournalSection(activity: displayActivity)
                    Button { navigation.openShare(for: displayActivity) } label: {
                        Label("制作这次跑步的分享图", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RunTheme.accent)
                    .disabled(route == nil)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 140)
        }
        .background(RunTheme.page)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { navigation.openShare(for: displayActivity) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task(id: activity.routeId) {
            guard let id = activity.routeId else { return }
            do { route = try await store.routeDetail(id: id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder private var detailMap: some View {
        ZStack(alignment: .bottomLeading) {
            if let route, !route.mapCoordinates.isEmpty {
                RouteDetailMapView(coordinates: route.mapCoordinates, colorScheme: colorScheme)
                    .frame(height: 360)
            } else if route == nil && errorMessage == nil && activity.routeId != nil {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
                }
                .frame(height: 360)
            } else {
                ZStack {
                    Rectangle().fill(RunTheme.deepPanel)
                    VStack(spacing: 9) {
                        Image(systemName: "map")
                            .font(.system(size: 34, weight: .light))
                        Text("这次跑步没有可用轨迹")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(RunTheme.paper.opacity(0.74))
                }
                .frame(height: 360)
            }
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 190)
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 6) {
                Text(displayActivity.kind == .race ? "RACE RESULT" : "RUNNING ACTIVITY")
                    .font(.caption2.bold()).tracking(2).foregroundStyle(RunTheme.accent)
                Text(displayActivity.name).font(.title.bold())
                Text(displayActivity.date.formatted(date: .long, time: .omitted) + (displayActivity.city.isEmpty ? "" : " · \(displayActivity.city)"))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
    }

    private var metrics: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DetailMetric(label: "距离", value: String(format: "%.2f", displayActivity.distanceKm), unit: "km", color: RunTheme.route, prominent: true)
                DetailMetric(label: "用时", value: displayActivity.duration, unit: "", color: RunTheme.accent, prominent: true)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                DetailMetric(label: "平均配速", value: displayActivity.pace, unit: "/km", color: .blue)
                if let route, !route.mapCoordinates.isEmpty {
                    DetailMetric(label: "累计爬升", value: String(format: "%.0f", route.elevationGain), unit: "m", color: .orange)
                }
                if let heart = displayActivity.avgHeartRate {
                    DetailMetric(label: "平均心率", value: "\(heart)", unit: "bpm", color: .red)
                }
                if let maxHeart = displayActivity.maxHeartRate {
                    DetailMetric(label: "最高心率", value: "\(maxHeart)", unit: "bpm", color: RunTheme.accent)
                }
                if let cadence = displayActivity.avgCadence, cadence > 0 {
                    DetailMetric(label: "平均步频", value: "\(Int(cadence.rounded()))", unit: "步/分", color: RunTheme.route)
                }
                if let power = displayActivity.avgPower {
                    DetailMetric(label: "平均功率", value: "\(Int(power.rounded()))", unit: "W", color: .purple)
                }
            }
        }
    }
}

private struct DetailMetric: View {
    let label: String
    let value: String
    let unit: String
    let color: Color
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
                Spacer(minLength: 0)
                Text(unit).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(prominent ? .system(size: 32, weight: .black, design: .rounded) : .title2.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(prominent ? 18 : 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ChartPoint: Identifiable {
    let id: Int
    let seconds: Double
    let value: Double
}

private func sampledChartPoints(_ points: [ChartPoint], limit: Int = 280) -> [ChartPoint] {
    guard points.count > limit, limit > 1 else { return points }
    let step = Double(points.count - 1) / Double(limit - 1)
    return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
}

private enum ActivityMetric: String, CaseIterable {
    case pace = "配速"
    case heart = "心率"
    case elevation = "海拔"

    var unit: String {
        switch self {
        case .pace: return "/km"
        case .heart: return "bpm"
        case .elevation: return "m"
        }
    }

    var color: Color {
        switch self {
        case .pace: return RunTheme.mint
        case .heart: return Color(red: 1, green: 0.49, blue: 0.36)
        case .elevation: return Color(red: 1, green: 0.73, blue: 0.40)
        }
    }

    var lowLabel: String { self == .pace ? "最快" : "最低" }
    var highLabel: String { self == .pace ? "最慢" : "最高" }
}

private final class ActivityTrendData {
    let points: [ChartPoint]
    let smoothed: [ChartPoint]
    let mean: Double
    let minimum: Double
    let maximum: Double
    let timeRange: ClosedRange<Double>
    let valueRange: ClosedRange<Double>

    init(_ rawPoints: [ChartPoint]) {
        let ordered = sampledChartPoints(rawPoints).sorted { $0.seconds < $1.seconds }
        points = ordered
        mean = ordered.reduce(0) { $0 + $1.value } / Double(max(1, ordered.count))
        let sortedValues = ordered.map(\.value).sorted()
        minimum = sortedValues.first ?? 0
        maximum = sortedValues.last ?? 0
        let low = sortedValues[Int(Double(max(0, sortedValues.count - 1)) * 0.05)]
        let high = sortedValues[Int(Double(max(0, sortedValues.count - 1)) * 0.95)]
        let spread = max(high - low, max(abs(maximum), 1) * 0.04)
        valueRange = (low - spread * 0.16)...(high + spread * 0.16)
        let firstTime = ordered.first?.seconds ?? 0
        timeRange = firstTime...max(firstTime + 1, ordered.last?.seconds ?? 1)
        smoothed = ordered.indices.map { index in
            let neighbors = ordered[max(0, index - 2)...min(ordered.count - 1, index + 2)]
            let average = neighbors.reduce(0) { $0 + $1.value } / Double(neighbors.count)
            return ChartPoint(id: ordered[index].id, seconds: ordered[index].seconds, value: average)
        }
    }

    func nearestIndex(fraction: CGFloat) -> Int {
        let target = timeRange.lowerBound + (timeRange.upperBound - timeRange.lowerBound) * Double(min(1, max(0, fraction)))
        var lower = 0
        var upper = points.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].seconds < target { lower = middle + 1 }
            else { upper = middle }
        }
        if lower > 0 && abs(points[lower - 1].seconds - target) < abs(points[lower].seconds - target) {
            return lower - 1
        }
        return lower
    }

    func position(for point: ChartPoint, in size: CGSize, pace: Bool) -> CGPoint {
        let timeSpan = max(1, timeRange.upperBound - timeRange.lowerBound)
        let valueSpan = max(0.001, valueRange.upperBound - valueRange.lowerBound)
        let normalized = (min(valueRange.upperBound, max(valueRange.lowerBound, point.value)) - valueRange.lowerBound) / valueSpan
        let vertical = pace ? normalized : 1 - normalized
        return CGPoint(
            x: size.width * CGFloat((point.seconds - timeRange.lowerBound) / timeSpan),
            y: 8 + max(1, size.height - 16) * CGFloat(vertical)
        )
    }
}

private struct ActivityTrendPlot: View, Equatable {
    let data: ActivityTrendData
    let metric: ActivityMetric

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data === rhs.data && lhs.metric == rhs.metric
    }

    var body: some View {
        Canvas { context, size in
            guard data.smoothed.count > 1 else { return }
            for fraction in [0.18, 0.5, 0.82] {
                let y = 8 + max(1, size.height - 16) * fraction
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: y))
                guide.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(guide, with: .color(.white.opacity(0.10)), lineWidth: 1)
            }
            let positions = data.smoothed.map { data.position(for: $0, in: size, pace: metric == .pace) }
            var line = Path()
            for (index, point) in positions.enumerated() {
                if index == 0 { line.move(to: point) }
                else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: positions.last?.x ?? size.width, y: size.height))
            area.addLine(to: CGPoint(x: positions.first?.x ?? 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [metric.color.opacity(0.36), metric.color.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: 8),
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(metric.color.opacity(0.20)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            context.stroke(line, with: .color(metric.color), style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
        }
    }
}

struct ActivityCharts: View {
    @State private var selectedMetric: ActivityMetric = .pace
    @State private var selectedIndex: Int?
    private let dataSets: [ActivityMetric: ActivityTrendData]
    private let ink = Color(red: 0.055, green: 0.12, blue: 0.14)

    init(series: ArchiveTimeSeries) {
        var result: [ActivityMetric: ActivityTrendData] = [:]
        for metric in ActivityMetric.allCases {
            let points = Self.points(for: metric, series: series)
            if points.count > 1 { result[metric] = ActivityTrendData(points) }
        }
        dataSets = result
    }

    private var availableMetrics: [ActivityMetric] {
        ActivityMetric.allCases.filter { dataSets[$0] != nil }
    }

    private var metric: ActivityMetric {
        availableMetrics.contains(selectedMetric) ? selectedMetric : (availableMetrics.first ?? .pace)
    }

    var body: some View {
        if let data = dataSets[metric] {
            let selectedPoint = selectedIndex.flatMap { data.points.indices.contains($0) ? data.points[$0] : nil }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("过程表现")
                            .font(.title3.weight(.black))
                        Text("在曲线上左右拖动查看")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if selectedIndex != nil {
                        Button("返回均值") { selectedIndex = nil }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(metric.color)
                            .padding(.top, 4)
                    } else {
                        Image(systemName: "waveform.path")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(metric.color)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    }
                }
                HStack(spacing: 8) {
                    ForEach(availableMetrics, id: \.self) { option in
                        Button {
                            selectedMetric = option
                            selectedIndex = nil
                        } label: {
                            Text(option.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(metric == option ? ink : .white.opacity(0.68))
                                .padding(.horizontal, 15)
                                .padding(.vertical, 9)
                                .background(metric == option ? option.color : .white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 22)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(valueText(selectedPoint?.value ?? data.mean, metric: metric))
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(metric.unit)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(metric.color)
                    Spacer()
                    Text(selectedPoint.map { timeText($0.seconds) } ?? "采样均值")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.57))
                }
                .padding(.top, 24)

                GeometryReader { geometry in
                    ZStack {
                        ActivityTrendPlot(data: data, metric: metric)
                            .equatable()
                        if let selectedPoint {
                            Canvas { context, size in
                                let selected = data.position(for: selectedPoint, in: size, pace: metric == .pace)
                                var rule = Path()
                                rule.move(to: CGPoint(x: selected.x, y: 8))
                                rule.addLine(to: CGPoint(x: selected.x, y: size.height - 8))
                                context.stroke(rule, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                                let halo = Path(ellipseIn: CGRect(x: selected.x - 8, y: selected.y - 8, width: 16, height: 16))
                                context.fill(halo, with: .color(ink))
                                context.stroke(halo, with: .color(metric.color), lineWidth: 3)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let fraction = gesture.location.x / max(1, geometry.size.width)
                                let next = data.nearestIndex(fraction: fraction)
                                if selectedIndex != next { selectedIndex = next }
                            }
                    )
                }
                .frame(height: 174)
                .padding(.top, 16)

                HStack {
                    Text(timeText(data.timeRange.lowerBound))
                    Spacer()
                    Text(timeText((data.timeRange.lowerBound + data.timeRange.upperBound) / 2))
                    Spacer()
                    Text(timeText(data.timeRange.upperBound))
                }
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.48))
                .padding(.top, 8)

                Rectangle()
                    .fill(.white.opacity(0.11))
                    .frame(height: 1)
                    .padding(.top, 21)
                HStack(spacing: 8) {
                    Text("\(metric.lowLabel) \(valueText(data.minimum, metric: metric)) \(metric.unit)")
                    Spacer()
                    Text("\(metric.highLabel) \(valueText(data.maximum, metric: metric)) \(metric.unit)")
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.62))
                .padding(.top, 14)
            }
            .padding(20)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.20, blue: 0.22), ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 25, style: .continuous)
            )
        }
    }

    private static func points(for metric: ActivityMetric, series: ArchiveTimeSeries) -> [ChartPoint] {
        switch metric {
        case .pace:
            return paired(series.pace, elapsed: series.elapsed).filter { (2...30).contains($0.value) }
        case .elevation:
            return paired(series.elevation.map(Optional.some), elapsed: series.elapsed)
        case .heart:
            let elapsed = series.heartRateElapsed ?? interpolatedElapsed(series.heartRate.count, series.elapsed)
            return series.heartRate.enumerated().compactMap { index, value in
                guard index < elapsed.count, value.isFinite, value > 0, elapsed[index].isFinite else { return nil }
                return ChartPoint(id: index, seconds: elapsed[index], value: value)
            }
        }
    }

    private static func paired(_ values: [Double?], elapsed: [Double]) -> [ChartPoint] {
        values.enumerated().compactMap { index, value in
            guard let value, index < elapsed.count, value.isFinite, elapsed[index].isFinite else { return nil }
            return ChartPoint(id: index, seconds: elapsed[index], value: value)
        }
    }

    private static func interpolatedElapsed(_ count: Int, _ elapsed: [Double]) -> [Double] {
        guard count > 1, let first = elapsed.first, let last = elapsed.last else {
            return Array(0..<count).map(Double.init)
        }
        return (0..<count).map { first + (last - first) * Double($0) / Double(count - 1) }
    }

    private func valueText(_ value: Double, metric: ActivityMetric) -> String {
        if metric == .pace {
            let seconds = max(0, Int((value * 60).rounded()))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return String(format: "%.0f", value)
    }

    private func timeText(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

struct MiniRouteView: View {
    let coordinates: [CLLocationCoordinate2D]
    var color: Color = RunTheme.route

    var body: some View {
        Canvas { context, size in
            guard coordinates.count > 1 else { return }
            let points = normalizedPoints(decimatedMapCoordinates(mapDisplayCoordinates(coordinates), limit: 240), size: size, inset: 2)
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
    }
}

func normalizedPoints(_ coordinates: [CLLocationCoordinate2D], size: CGSize, inset: CGFloat) -> [CGPoint] {
    guard !coordinates.isEmpty else { return [] }
    let minLon = coordinates.map(\.longitude).min() ?? 0
    let maxLon = coordinates.map(\.longitude).max() ?? 1
    let minLat = coordinates.map(\.latitude).min() ?? 0
    let maxLat = coordinates.map(\.latitude).max() ?? 1
    let lonRange = max(maxLon - minLon, 0.000001)
    let latRange = max(maxLat - minLat, 0.000001)
    let width = max(size.width - inset * 2, 1)
    let height = max(size.height - inset * 2, 1)
    let scale = min(width / lonRange, height / latRange)
    let drawnWidth = lonRange * scale
    let drawnHeight = latRange * scale
    let xOffset = inset + (width - drawnWidth) / 2
    let yOffset = inset + (height - drawnHeight) / 2
    return coordinates.map {
        CGPoint(x: xOffset + ($0.longitude - minLon) * scale,
                y: yOffset + (maxLat - $0.latitude) * scale)
    }
}

struct RouteMapView: UIViewRepresentable {
    let routes: [ArchiveRouteSummary]
    let colorScheme: ColorScheme
    let focusRequest: Int

    func makeCoordinator() -> OverviewMapCoordinator { OverviewMapCoordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.isUserInteractionEnabled = true
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let appearance = colorScheme == .dark ? "dark" : "light"
        context.coordinator.update(routes: routes, appearance: appearance, focusRequest: focusRequest, on: map)
    }
}

final class OverviewMapCoordinator: NSObject, MKMapViewDelegate {
    private var signature = ""
    private var appearanceSignature = ""
    private var hasSetInitialRegion = false
    private var lastFocusRequest = 0
    private var isChangingRegion = false
    private var pendingRoutes: [ArchiveRouteSummary]?
    private var pendingAppearance: String?
    private var pendingFocusRequest: Int?

    func update(routes: [ArchiveRouteSummary], appearance: String, focusRequest: Int, on map: MKMapView) {
        guard !isChangingRegion else {
            pendingRoutes = routes
            pendingAppearance = appearance
            pendingFocusRequest = focusRequest
            return
        }

        if appearanceSignature != appearance {
            appearanceSignature = appearance
            signature = ""
        }

        let shouldFocus = lastFocusRequest != focusRequest
        lastFocusRequest = focusRequest
        let nextSignature = "\(appearance)|" + routes.map {
            "\($0.id):\($0.previewCoordinates.count)"
        }.joined(separator: "|")
        guard signature != nextSignature || shouldFocus else { return }
        signature = nextSignature

        let visibleRoutes = distinctRoutes(from: routes)
        let lines = visibleRoutes.compactMap { route -> MKPolyline? in
            let coordinates = decimatedMapCoordinates(route.coordinates, limit: 90).map(mapDisplayCoordinate)
            guard coordinates.count > 1 else { return nil }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        map.removeOverlays(map.overlays)
        guard !lines.isEmpty else {
            if !hasSetInitialRegion { setFallbackRegion(on: map) }
            return
        }

        let routesOverlay = MKMultiPolyline(lines)
        map.addOverlay(routesOverlay)
        if !hasSetInitialRegion || shouldFocus {
            focusOnRecentRoute(routes.first, on: map)
            hasSetInitialRegion = true
        }
    }

    private func setFallbackRegion(on map: MKMapView) {
        let defaults = UserDefaults.standard
        let latitude = defaults.object(forKey: "archiveMapLatitude") as? Double ?? 32.05
        let longitude = defaults.object(forKey: "archiveMapLongitude") as? Double ?? 118.78
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
            ),
            animated: false
        )
    }

    private func focusOnRecentRoute(_ route: ArchiveRouteSummary?, on map: MKMapView) {
        guard let coordinates = route?.coordinates.map(mapDisplayCoordinate), !coordinates.isEmpty else { return }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let center = coordinates[coordinates.count / 2]
        let minimumSide = MKMapPointsPerMeterAtLatitude(center.latitude) * 14_000
        let width = max(maxX - minX, minimumSide)
        let height = max(maxY - minY, minimumSide)
        let rect = MKMapRect(
            x: (minX + maxX - width) / 2,
            y: (minY + maxY - height) / 2,
            width: width,
            height: height
        )
        map.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 110, left: 28, bottom: 215, right: 28),
            animated: hasSetInitialRegion
        )
        UserDefaults.standard.set(center.latitude, forKey: "archiveMapLatitude")
        UserDefaults.standard.set(center.longitude, forKey: "archiveMapLongitude")
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        isChangingRegion = true
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        isChangingRegion = false
        guard let pendingRoutes else { return }
        let appearance = pendingAppearance ?? appearanceSignature
        let focusRequest = pendingFocusRequest ?? lastFocusRequest
        self.pendingRoutes = nil
        pendingAppearance = nil
        pendingFocusRequest = nil
        update(routes: pendingRoutes, appearance: appearance, focusRequest: focusRequest, on: mapView)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let routesOverlay = overlay as? MKMultiPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKMultiPolylineRenderer(multiPolyline: routesOverlay)
        renderer.strokeColor = mapView.overrideUserInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.82, blue: 0.73, alpha: 0.96)
            : UIColor(red: 0.18, green: 0.68, blue: 0.65, alpha: 0.9)
        renderer.lineWidth = 1.6
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    private struct RouteCell: Hashable {
        let x: Int
        let y: Int
    }

    private func distinctRoutes(from routes: [ArchiveRouteSummary]) -> [ArchiveRouteSummary] {
        var selected: [(route: ArchiveRouteSummary, cells: Set<RouteCell>)] = []
        for route in routes {
            let cells = occupiedCells(for: route.coordinates)
            guard cells.count > 1 else { continue }
            if let index = selected.firstIndex(where: { routesAreSimilar(cells, $0.cells) }) {
                if cells.count > selected[index].cells.count { selected[index] = (route, cells) }
            } else {
                selected.append((route, cells))
            }
        }
        return selected.map(\.route)
    }

    private func occupiedCells(for coordinates: [CLLocationCoordinate2D]) -> Set<RouteCell> {
        guard coordinates.count > 1 else { return [] }
        // Around Nanjing this is roughly a 25-metre cell. Neighbour matching below
        // absorbs normal GPS drift without merging routes that only share one road.
        let cellSize = 192.0
        let points = coordinates.map(MKMapPoint.init)
        var cells = Set<RouteCell>()
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let maximumDelta = max(abs(end.x - start.x), abs(end.y - start.y))
            let steps = min(max(Int(ceil(maximumDelta / cellSize)), 1), 24)
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                let x = start.x + (end.x - start.x) * fraction
                let y = start.y + (end.y - start.y) * fraction
                cells.insert(RouteCell(x: Int(floor(x / cellSize)), y: Int(floor(y / cellSize))))
            }
        }
        return cells
    }

    private func routesAreSimilar(_ first: Set<RouteCell>, _ second: Set<RouteCell>) -> Bool {
        let smaller = first.count <= second.count ? first : second
        let larger = first.count <= second.count ? second : first
        guard Double(smaller.count) / Double(larger.count) >= 0.68 else { return false }

        var matched = 0
        for cell in smaller {
            var found = false
            for xOffset in -1...1 where !found {
                for yOffset in -1...1 {
                    if larger.contains(RouteCell(x: cell.x + xOffset, y: cell.y + yOffset)) {
                        found = true
                        break
                    }
                }
            }
            if found { matched += 1 }
        }
        return Double(matched) / Double(smaller.count) >= 0.80
    }
}

private func decimatedMapCoordinates(_ coordinates: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D] {
    guard coordinates.count > limit, limit > 1 else { return coordinates }
    let step = Double(coordinates.count - 1) / Double(limit - 1)
    return (0..<limit).map { coordinates[Int((Double($0) * step).rounded())] }
}

struct RouteDetailMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let colorScheme: ColorScheme

    func makeCoordinator() -> MapCoordinator { MapCoordinator(lineWidth: 3) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
        map.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = false
        map.isUserInteractionEnabled = true
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.gestureRecognizers?.forEach { $0.cancelsTouchesInView = false }
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let appearance = colorScheme == .dark ? "dark" : "light"
        if context.coordinator.appearanceSignature != appearance {
            map.removeOverlays(map.overlays)
            context.coordinator.appearanceSignature = appearance
            context.coordinator.signature = ""
        }
        let signature = "\(appearance)|\(coordinates.count):\(coordinates.first?.latitude ?? 0):\(coordinates.first?.longitude ?? 0)"
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        map.removeOverlays(map.overlays)
        guard coordinates.count > 1 else { return }
        let displayCoordinates = decimatedMapCoordinates(coordinates, limit: 900).map(mapDisplayCoordinate)
        let line = MKPolyline(coordinates: displayCoordinates, count: displayCoordinates.count)
        map.addOverlay(line)
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 50, left: 36, bottom: 80, right: 36), animated: false)
    }
}

final class MapCoordinator: NSObject, MKMapViewDelegate {
    let lineWidth: CGFloat
    var signature = ""
    var appearanceSignature = ""
    var hasSetInitialRegion = false

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init()
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = mapView.overrideUserInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.82, blue: 0.73, alpha: 0.96)
            : UIColor(red: 0.18, green: 0.68, blue: 0.65, alpha: 0.9)
        renderer.lineWidth = lineWidth
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}

// HealthKit locations are WGS-84. Mainland Chinese map tiles use GCJ-02, so
// convert only the coordinates passed to MapKit and keep all stored data raw.
private func mapDisplayCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
    guard !isOutsideChina(coordinate) else { return coordinate }
    let (latitude, longitude) = wgs84ToGCJ02(latitude: coordinate.latitude, longitude: coordinate.longitude)
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
}

func mapDisplayCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
    coordinates.map(mapDisplayCoordinate)
}

private func isOutsideChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
    coordinate.longitude < 72.004 || coordinate.longitude > 137.8347
        || coordinate.latitude < 0.8293 || coordinate.latitude > 55.8271
}

private func wgs84ToGCJ02(latitude: Double, longitude: Double) -> (Double, Double) {
    let earthRadius = 6378245.0
    let eccentricity = 0.00669342162296594323
    let deltaLatitude = transformLatitude(longitude - 105.0, latitude - 35.0)
    let deltaLongitude = transformLongitude(longitude - 105.0, latitude - 35.0)
    let radLatitude = latitude / 180.0 * Double.pi
    let magic = max(1 - eccentricity * sin(radLatitude) * sin(radLatitude), 0.000001)
    let sqrtMagic = sqrt(magic)
    let adjustedLatitude = latitude + (deltaLatitude * 180.0) / ((earthRadius * (1 - eccentricity)) / (magic * sqrtMagic) * Double.pi)
    let adjustedLongitude = longitude + (deltaLongitude * 180.0) / (earthRadius / sqrtMagic * cos(radLatitude) * Double.pi)
    return (adjustedLatitude, adjustedLongitude)
}

private func transformLatitude(_ x: Double, _ y: Double) -> Double {
    var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
    result += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
    result += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
    result += (160.0 * sin(y / 12.0 * Double.pi) + 320.0 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
    return result
}
private func transformLongitude(_ x: Double, _ y: Double) -> Double {
    var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
    result += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
    result += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
    result += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
    return result
}
