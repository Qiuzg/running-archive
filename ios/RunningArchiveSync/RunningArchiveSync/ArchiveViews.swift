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

    var body: some View {
        NavigationStack {
            hero
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
            .background(RunTheme.page)
            .overlay {
                if store.isLoading && store.activities.isEmpty { ProgressView().controlSize(.large) }
            }
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
            RouteMapView(routes: Array(store.routes.prefix(40)), colorScheme: colorScheme)
                .frame(height: max(UIScreen.main.bounds.height, 640))
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
            .frame(height: 150)
            .allowsHitTesting(false)
            HStack(spacing: 12) {
                profileAvatar
                AtlasHeroMetric(
                    label: "年度跑量",
                    value: store.summary.map { "\(Int($0.yearlyDistanceKm)) km" } ?? "--",
                    accent: Color(red: 0.16, green: 0.43, blue: 0.94)
                )
                AtlasHeroMetric(label: "全马 PB", value: store.summary?.marathonPb ?? "--", accent: RunTheme.mint)
                AtlasHeroMetric(label: "半马 PB", value: store.summary?.halfMarathonPb ?? "--", accent: RunTheme.accent)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 174)
        }
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
        }
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
    @State private var selectedMonth: Int?
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
    private var activeMonths: Int { monthlyTotals.filter { $0 > 0 }.count }
    private var longestDistance: Double { yearActivities.map(\.distanceKm).max() ?? 0 }
    private var selectedMonthActivities: [ArchiveActivity] {
        guard let selectedMonth else { return [] }
        return yearActivities
            .filter { Calendar.current.component(.month, from: $0.date) == selectedMonth + 1 }
            .sorted { $0.date < $1.date }
    }
    private var routeEntries: [ArchiveActivity] {
        store.activities.filter { $0.routeId != nil && $0.distanceKm >= 10 }.sorted { $0.date > $1.date }
    }
    private var routeTotalDistance: Double { routeEntries.reduce(0) { $0 + $1.distanceKm } }
    private var routeMarathonCount: Int { routeEntries.filter { $0.kind == .race && (41.0...44.0).contains($0.distanceKm) }.count }
    private var routeHalfCount: Int { routeEntries.filter { $0.kind == .race && (20.0...23.0).contains($0.distanceKm) }.count }
    private var routeRunCount: Int { routeEntries.count - routeMarathonCount - routeHalfCount }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    totalDistanceCard
                    yearSwitcher
                    monthlySummaryCard
                    if selectedMonth != nil {
                        dailyDetail
                    } else {
                        Text("点击柱状图中的月份，查看每天的跑步数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
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
            .toolbarBackground(RunTheme.deepPage, for: .navigationBar)
            .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
            .onChange(of: store.activities.count) { _, _ in
                if !years.contains(selectedYear) { selectedYear = years.first ?? Calendar.current.component(.year, from: .now) }
                selectedMonth = nil
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
                        Text("\(year)")
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

    private var monthlySummaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("月度跑量").font(.subheadline.weight(.bold)).foregroundStyle(RunTheme.paper)
                Spacer()
                Text("\(formatKm(yearDistance)) km")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(RunTheme.mint)
            }

            Chart(Array(monthlyTotals.enumerated()), id: \.offset) { item in
                BarMark(x: .value("月份", item.offset + 1), y: .value("公里", item.element))
                    .foregroundStyle(item.element == (monthlyTotals.max() ?? 0) && item.element > 0 ? RunTheme.accent : RunTheme.route.opacity(0.62))
                    .cornerRadius(7)
            }
            .chartXScale(domain: 0.5...12.5)
            .chartYScale(domain: 0...max(monthlyTotals.max() ?? 0, 10))
            .chartXAxis {
                AxisMarks(values: [1, 3, 5, 7, 9, 11]) { value in
                    AxisValueLabel { if let month = value.as(Int.self) { Text("\(month)月") } }
                }
            }
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plotFrameAnchor = proxy.plotFrame else { return }
                            let plotFrame = geometry[plotFrameAnchor]
                            let x = location.x - plotFrame.origin.x
                            guard let month = proxy.value(atX: x, as: Int.self), (1...12).contains(month) else { return }
                            selectedMonth = month - 1
                        }
                }
            }
            .frame(height: 154)

            HStack(spacing: 8) {
                SummaryMiniMetric(label: "月均跑量", value: formatKm(activeMonths > 0 ? yearDistance / Double(activeMonths) : 0))
                SummaryMiniMetric(label: "训练月份", value: "\(activeMonths) 个月")
                SummaryMiniMetric(label: "最长距离", value: "\(formatKm(longestDistance)) km")
            }
        }
        .padding(15)
        .background(RunTheme.deepPanel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var dailyDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedYear) 年 \((selectedMonth ?? 0) + 1) 月")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(RunTheme.ink)
                    Text("\(selectedMonthActivities.count) 次训练 · \(formatKm(selectedMonthActivities.reduce(0) { $0 + $1.distanceKm })) km")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedMonth = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if selectedMonthActivities.isEmpty {
                Text("这个月没有跑步记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    MonthlyDetailMetric(label: "训练次数", value: "\(selectedMonthActivities.count)")
                    MonthlyDetailMetric(label: "月度跑量", value: "\(formatKm(selectedMonthActivities.reduce(0) { $0 + $1.distanceKm })) km")
                    MonthlyDetailMetric(label: "最长单次", value: "\(formatKm(selectedMonthActivities.map(\.distanceKm).max() ?? 0)) km")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                    ForEach(selectedMonthActivities) { activity in
                        NavigationLink(value: activity) {
                            MonthlyRunTile(activity: activity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
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
                    Text("Over 10km Runs")
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

private struct SummaryMiniMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(RunTheme.paper.opacity(0.58))
            Text(value).font(.subheadline.weight(.black).monospacedDigit()).foregroundStyle(RunTheme.paper)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct MonthlyDetailMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.black).monospacedDigit())
                .foregroundStyle(RunTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RunTheme.deepPage.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct MonthlyRunTile: View {
    let activity: ArchiveActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(activity.date.formatted(.dateTime.month().day()))
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(RunTheme.accent)
                Spacer(minLength: 4)
                Text("\(formatKm(activity.distanceKm)) km")
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(RunTheme.ink)
            }
            Text(activity.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RunTheme.ink)
                .lineLimit(1)
            Text("\(activity.pace)/km · \(activity.duration)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 1))
    }

    private func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
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
                .padding(8)
            Text(activity.name).font(.subheadline.bold()).lineLimit(1)
            Text("\(formatKm(activity.distanceKm)) km · \(activity.date.formatted(date: .numeric, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 4)
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
    @State private var filter: Filter = .all

    private var filtered: [ArchiveActivity] {
        store.activities.filter { item in
            filter == .all || (filter == .run && item.kind == .run) || (filter == .race && item.kind == .race)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
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

                if filtered.isEmpty {
                    ContentUnavailableView("没有匹配记录", systemImage: "figure.run", description: Text("试试其他类型。"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { activity in
                            NavigationLink(value: activity) {
                                ActivityLogCard(activity: activity, route: store.routeSummary(id: activity.routeId))
                            }
                            .buttonStyle(.plain)
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
                    metrics
                    if let series = route?.timeSeries {
                        ActivityCharts(series: series)
                    }
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
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
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
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            DetailMetric(label: "距离", value: String(format: "%.2f", displayActivity.distanceKm), unit: "km", color: RunTheme.route)
            DetailMetric(label: "用时", value: displayActivity.duration, unit: "hh:mm:ss", color: RunTheme.accent)
            DetailMetric(label: "平均配速", value: displayActivity.pace, unit: "/km", color: .blue)
            DetailMetric(label: "累计爬升", value: String(format: "%.0f", route?.elevationGain ?? 0), unit: "m", color: .orange)
            if let heart = displayActivity.avgHeartRate {
                DetailMetric(label: "平均心率", value: "\(heart)", unit: "bpm", color: .red)
            }
            if let power = displayActivity.avgPower {
                DetailMetric(label: "平均功率", value: "\(Int(power.rounded()))", unit: "W", color: .purple)
            }
        }
    }
}

private struct DetailMetric: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
                Spacer(minLength: 0)
                Text(unit).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.bold()).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ChartPoint: Identifiable {
    let id: Int
    let seconds: Double
    let value: Double
}

private func sampledChartPoints(_ points: [ChartPoint], limit: Int = 360) -> [ChartPoint] {
    guard points.count > limit, limit > 1 else { return points }
    let step = Double(points.count - 1) / Double(limit - 1)
    return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
}

struct ActivityCharts: View {
    let series: ArchiveTimeSeries

    var body: some View {
        VStack(spacing: 12) {
            if !series.pace.isEmpty {
                MetricLineChart(title: "配速趋势", unit: "分/公里", kind: .pace, points: sampledChartPoints(paired(series.pace)), color: .blue)
            }
            if !series.elevation.isEmpty {
                MetricLineChart(title: "海拔变化", unit: "米", kind: .number, points: sampledChartPoints(paired(series.elevation.map(Optional.some))), color: .orange)
            }
            if !series.heartRate.isEmpty {
                let elapsed = series.heartRateElapsed ?? interpolatedElapsed(count: series.heartRate.count)
                let values = series.heartRate.enumerated().compactMap { index, value in
                    index < elapsed.count ? ChartPoint(id: index, seconds: elapsed[index], value: value) : nil
                }
                MetricLineChart(title: "心率趋势", unit: "bpm", kind: .number, points: sampledChartPoints(values), color: RunTheme.accent)
            }
        }
    }

    private func paired(_ values: [Double?]) -> [ChartPoint] {
        values.enumerated().compactMap { index, value in
            guard let value, index < series.elapsed.count, value.isFinite else { return nil }
            return ChartPoint(id: index, seconds: series.elapsed[index], value: value)
        }
    }

    private func interpolatedElapsed(count: Int) -> [Double] {
        guard count > 1, let first = series.elapsed.first, let last = series.elapsed.last else {
            return Array(0..<count).map(Double.init)
        }
        return (0..<count).map { first + (last - first) * Double($0) / Double(count - 1) }
    }
}

private struct MetricLineChart: View {
    enum ValueKind { case pace, number }

    let title: String
    let unit: String
    let kind: ValueKind
    let points: [ChartPoint]
    let color: Color

    private var xDomain: ClosedRange<Double> {
        let maximum = points.map { max(0, $0.seconds / 60) }.max() ?? 1
        return 0...max(1, maximum)
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map { plottedValue($0.value) }.filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        if abs(maximum - minimum) < 0.001 {
            let padding = kind == .pace ? max(minimum * 0.05, 0.005) : 1
            return max(0, minimum - padding)...(maximum + padding)
        }
        let padding = max((maximum - minimum) * 0.08, kind == .pace ? 0.005 : 1)
        return max(0, minimum - padding)...(maximum + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Chart(points) { point in
                AreaMark(
                    x: .value("时间", point.seconds / 60),
                    yStart: .value("基线", yDomain.lowerBound),
                    yEnd: .value(unit, plottedValue(point.value))
                )
                    .foregroundStyle(color.opacity(0.10))
                LineMark(x: .value("时间", point.seconds / 60), y: .value(unit, plottedValue(point.value)))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(position: .bottom, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                        .foregroundStyle(.secondary.opacity(0.28))
                    AxisTick()
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(String(format: "%.0f", minutes))
                        }
                    }
                }
            }
            .chartXAxisLabel("分钟")
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                        .foregroundStyle(.secondary.opacity(0.28))
                    AxisValueLabel {
                        if let metric = value.as(Double.self) {
                            if kind == .pace, metric > 0 { Text(paceAxisLabel(1 / metric)) }
                            else { Text(String(format: "%.0f", metric)) }
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.clipped()
            }
            .frame(height: 150)
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func paceAxisLabel(_ minutes: Double) -> String {
        let totalSeconds = max(0, Int((minutes * 60).rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func plottedValue(_ value: Double) -> Double {
        kind == .pace && value > 0 ? 1 / value : value
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
        context.coordinator.update(routes: routes, appearance: appearance, on: map)
    }
}

final class OverviewMapCoordinator: NSObject, MKMapViewDelegate {
    private var signature = ""
    private var appearanceSignature = ""
    private var hasSetInitialRegion = false
    private var isChangingRegion = false
    private var pendingRoutes: [ArchiveRouteSummary]?
    private var pendingAppearance: String?

    func update(routes: [ArchiveRouteSummary], appearance: String, on map: MKMapView) {
        guard !isChangingRegion else {
            pendingRoutes = routes
            pendingAppearance = appearance
            return
        }

        if appearanceSignature != appearance {
            appearanceSignature = appearance
            signature = ""
            hasSetInitialRegion = false
        }

        let nextSignature = "\(appearance)|" + routes.map {
            "\($0.id):\($0.previewCoordinates.count)"
        }.joined(separator: "|")
        guard signature != nextSignature else { return }
        signature = nextSignature

        let visibleRoutes = distinctRoutes(from: routes)
        let lines = visibleRoutes.compactMap { route -> MKPolyline? in
            let coordinates = decimatedMapCoordinates(route.coordinates, limit: 90).map(mapDisplayCoordinate)
            guard coordinates.count > 1 else { return nil }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        map.removeOverlays(map.overlays)
        guard !lines.isEmpty else { return }

        let routesOverlay = MKMultiPolyline(lines)
        map.addOverlay(routesOverlay)
        if !hasSetInitialRegion {
            map.setVisibleMapRect(
                routesOverlay.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 70, left: 32, bottom: 80, right: 32),
                animated: false
            )
            hasSetInitialRegion = true
        }
    }

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        isChangingRegion = true
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        isChangingRegion = false
        guard let pendingRoutes else { return }
        let appearance = pendingAppearance ?? appearanceSignature
        self.pendingRoutes = nil
        pendingAppearance = nil
        update(routes: pendingRoutes, appearance: appearance, on: mapView)
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
