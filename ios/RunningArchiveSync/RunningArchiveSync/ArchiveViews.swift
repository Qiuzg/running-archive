import Charts
import ImageIO
import MapKit
import SwiftUI
import UIKit

enum RunTheme {
    static let accent = Color(red: 1.0, green: 0.34, blue: 0.22)
    static let route = Color(red: 0.18, green: 0.68, blue: 0.65)
    static let ink = Color(uiColor: .label)
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.90)
    static let page = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
    static let deepPage = Color(uiColor: .systemGroupedBackground)
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
                .ignoresSafeArea(edges: .bottom)
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
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到近期路线")
                }
                heroSummaryCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            if store.isLoading && store.activities.isEmpty {
                ProgressView("正在读取 Apple Health")
                    .padding(18)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
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
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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
        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
    @State private var atlasExportImage: UIImage?
    @State private var showingAtlasShare = false
    @State private var showingAtlasStyle = false
    @State private var isExportingAtlas = false
    @State private var showingYearShare = false

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
    private var report: YearlyReport { YearlyReport(year: selectedYear, activities: store.activities) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    annualOverview
                    TrainingAnalysisEntry()
                    routeCollection
                    if let status = store.routeScanStatus {
                        Label(status, systemImage: "map").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
            }
            .background(RunTheme.page).scrollIndicators(.hidden)
            .navigationTitle("汇总").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(years.isEmpty ? [selectedYear] : years, id: \.self) { year in
                            Button { selectedYear = year } label: {
                                if year == selectedYear { Label(String(year), systemImage: "checkmark") }
                                else { Text(String(year)) }
                            }
                        }
                    } label: { Text(String(selectedYear)).monospacedDigit() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink { YearlyReviewView(year: selectedYear) } label: { Label("年度详情", systemImage: "chart.bar") }
                        NavigationLink { ReferenceMetricTrendsView() } label: { Label("体能趋势", systemImage: "heart.text.clipboard") }
                        NavigationLink { PersonalRecordsView() } label: { Label("个人纪录", systemImage: "medal") }
                        NavigationLink { RouteLibraryView() } label: { Label("路线收藏", systemImage: "map") }
                        NavigationLink { RaceGoalsView() } label: { Label("目标赛事", systemImage: "flag.checkered") }
                        NavigationLink { AnalysisExportView() } label: { Label("导出分析数据", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多跑步功能")
                }
            }
            .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
            .navigationDestination(for: ArchiveMonthRoute.self) { MonthlyReviewView(month: $0.month) }
            .onAppear { selectAvailableYear() }
            .onChange(of: store.activities.count) { _, _ in selectAvailableYear() }
            .refreshable { await RunningArchiveRuntime.shared.refresh(authorize: true, force: true) }
            .confirmationDialog("长距离路线分享配色", isPresented: $showingAtlasStyle, titleVisibility: .visible) {
                Button("浅色路线图") { exportAtlas(dark: false) }
                Button("深色路线图") { exportAtlas(dark: true) }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showingAtlasShare) { if let atlasExportImage { ShareSheet(items: [atlasExportImage]) } }
            .sheet(isPresented: $showingYearShare) { YearlyShareView(report: report) }
        }
    }

    private func selectAvailableYear() {
        if !years.contains(selectedYear) { selectedYear = years.first ?? Calendar.current.component(.year, from: .now) }
    }

    private var annualOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("年度跑量").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { showingYearShare = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享年度数据").disabled(report.activities.isEmpty)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%.1f", report.distance)).font(.system(size: 38, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                Text("公里").font(.subheadline)
            }.foregroundStyle(RunTheme.route)
            Text("\(report.activities.count) 次跑步  ·  \(report.durationText)").font(.subheadline)
            HStack {
                Text("月跑量").font(.headline)
                Spacer()
                Menu {
                    ForEach(1...12, id: \.self) { month in
                        NavigationLink("\(month) 月 · \(formatKm(report.months[month - 1].distance)) km",
                            value: ArchiveMonthRoute(month: report.months[month - 1].start))
                    }
                } label: { Label("查看月报", systemImage: "calendar").font(.caption) }
            }.padding(.top, 8)
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(report.months, id: \.key) { month in
                    NavigationLink(value: ArchiveMonthRoute(month: month.start)) {
                        VStack(spacing: 8) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4).fill(RunTheme.route.opacity(month.distance > 0 ? 1 : 0.15))
                                .frame(height: max(4, 100 * month.distance / max(report.months.map(\.distance).max() ?? 1, 1)))
                            Text("\(month.monthNumber)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).frame(height: 125).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(month.monthNumber) 月，\(formatKm(month.distance)) 公里，查看月度统计与分享")
                }
            }
            HStack {
                Text(report.cutoffText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                NavigationLink("年度详情") { YearlyReviewView(year: selectedYear) }.font(.caption)
            }
        }.nativeCard()
    }

    private var routeCollection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("长距离路线").font(.headline)
                Spacer()
                Button { showingAtlasStyle = true } label: {
                    if isExportingAtlas { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.and.arrow.up") }
                }.disabled(routeEntries.isEmpty || isExportingAtlas).accessibilityLabel("分享长距离路线集")
            }
            Text("全部年份 · \(routeEntries.count) 条 10 km 以上路线").font(.caption).foregroundStyle(.secondary)
            if routeEntries.isEmpty {
                Text("路线会随 Apple Health 数据自动整理。").font(.subheadline).foregroundStyle(.secondary)
            } else {
                routeGrid(Array(routeEntries.prefix(4)))
                if routeEntries.count > 4 {
                    NavigationLink {
                        ScrollView { routeGrid(routeEntries).padding(16) }
                            .background(RunTheme.page).navigationTitle("长距离路线")
                            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                                Button { showingAtlasStyle = true } label: { Image(systemName: "square.and.arrow.up") }.disabled(isExportingAtlas)
                            } }
                    } label: { HStack { Text("查看全部 \(routeEntries.count) 条路线"); Spacer(); Image(systemName: "chevron.right") }.font(.subheadline) }
                }
            }
        }.nativeCard()
    }

    private func routeGrid(_ entries: [ArchiveActivity]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 18) {
            ForEach(entries) { activity in
                NavigationLink(value: activity) {
                    CollectionRouteCard(activity: activity, route: store.routeSummary(id: activity.routeId))
                }.buttonStyle(.plain)
            }
        }
    }

    private func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func exportAtlas(dark: Bool) {
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
            Text("\(formatKm(activity.distanceKm)) km · \(activity.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
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
    @EnvironmentObject private var store: ArchiveStore
    @State private var selectedYear: Int?
    @State private var initializedYear = false
    private var years: [Int] { Array(Set(store.activities.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >) }
    private var filtered: [ArchiveActivity] {
        store.activities.filter { selectedYear == nil || Calendar.current.component(.year, from: $0.date) == selectedYear }.sorted { $0.date > $1.date }
    }
    private var months: [Int] {
        Array(Set(filtered.map { Calendar.current.component(.year, from: $0.date) * 100 + Calendar.current.component(.month, from: $0.date) })).sorted(by: >)
    }
    private func records(_ month: Int) -> [ArchiveActivity] {
        filtered.filter { Calendar.current.component(.year, from: $0.date) * 100 + Calendar.current.component(.month, from: $0.date) == month }
    }
    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView("暂无跑步记录", systemImage: "figure.run", description: Text("授权健康数据后，在这里回顾每一次跑步。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(months, id: \.self) { month in
                let runs = records(month)
                Section {
                    ForEach(runs) { activity in
                        NavigationLink(value: activity) { ActivityLogCard(activity: activity, route: store.routeSummary(id: activity.routeId)) }
                    }
                } header: {
                    HStack {
                        Text(selectedYear == nil ? "\(month / 100) 年 \(month % 100) 月" : "\(month % 100) 月")
                        Spacer()
                        Text(String(format: "\(runs.count) 次 · %.1f km", runs.reduce(0) { $0 + $1.distanceKm })).font(.caption)
                    }.textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped).navigationTitle("记录").navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("所有年份") { selectedYear = nil; initializedYear = true }
                ForEach(years, id: \.self) { year in Button(String(year)) { selectedYear = year; initializedYear = true } }
            } label: { Text(selectedYear.map(String.init) ?? "所有年份") }
        } }
        .onChange(of: years, initial: true) { _, values in
            if !initializedYear, let year = values.first { selectedYear = year; initializedYear = true }
        }
        .refreshable { await RunningArchiveRuntime.shared.refresh(authorize: true, force: true) }
        .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
    }
}

private struct ActivityLogCard: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteSummary?
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(String(Calendar.current.component(.day, from: activity.date))).font(.headline).monospacedDigit().lineLimit(1)
                Text(activity.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
            }.frame(width: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(String(format: "%.2f km", activity.distanceKm)).font(.headline).monospacedDigit()
                Text("\(activity.pace) /km · \(activity.duration)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 3)
            if let route {
                MiniRouteView(coordinates: route.coordinates, color: activity.distanceKm >= 41 ? RunTheme.accent : (activity.distanceKm >= 20 ? .blue : RunTheme.route))
                    .frame(width: 56, height: 42).accessibilityHidden(true)
            }
        }.padding(.vertical, 7)
    }
}

struct ActivityDetailView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var navigation: ArchiveNavigationStore
    @Environment(\.colorScheme) private var colorScheme
    let activity: ArchiveActivity
    @State private var route: ArchiveRouteDetail?
    @State private var errorMessage: String?
    @State private var extraMetrics: WorkoutMetricPresentation?
    @State private var extraError: String?
    @State private var detailsLoading = true
    @State private var presentationID = UUID().uuidString

    private var displayActivity: ArchiveActivity { store.activities.first { $0.id == activity.id } ?? activity }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(displayActivity.date.formatted(.dateTime.year().month().day().hour().minute())
                         + (displayActivity.city.isEmpty ? "" : " · \(displayActivity.city)"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    detailMap
                }
                overview
                RunFeedbackCard(activity: displayActivity)
                Divider()
                ActivityCharts(series: route?.timeSeries, auxiliary: extraMetrics, activity: displayActivity, isLoading: detailsLoading)
                if let extraMetrics { RunningFormMetricsView(metrics: extraMetrics) }
                NavigationLink { RunTrainingAnalysisView(activity: displayActivity) } label: {
                    detailAction("本次训练分析与公里分段", icon: "chart.xyaxis.line")
                }.buttonStyle(.plain)
                if let extraError { Text(extraError).font(.caption).foregroundStyle(.secondary) }
                Divider()
                VStack(spacing: 0) {
                    if store.routeSummary(id: displayActivity.routeId) != nil {
                        NavigationLink { RouteComparisonView(activity: displayActivity) } label: {
                            detailAction("同路线历史对比", icon: "chart.xyaxis.line")
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    NavigationLink { ReferenceMetricTrendsView() } label: {
                        detailAction("体能参考与长期趋势", icon: "heart.text.clipboard")
                    }.buttonStyle(.plain)
                    Divider()
                    DisclosureGroup("路线收藏、备注与导出") {
                        ActivityJournalSection(activity: displayActivity).padding(.top, 10)
                    }.font(.subheadline).tint(.primary).padding(.vertical, 16)
                }
                Button { navigation.openShare(for: displayActivity) } label: {
                    Label("分享这次跑步", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(RunTheme.accent).disabled(route == nil)
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(displayActivity.name).navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear { navigation.presentedDetailIDs.insert(presentationID) }
        .onDisappear { navigation.presentedDetailIDs.remove(presentationID) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { navigation.openShare(for: displayActivity) } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("分享这次跑步")
        } }
        .task(id: activity.id) {
            let cached = await store.cachedActivityPresentation(id: activity.id)
            route = cached.0
            extraMetrics = cached.1
            detailsLoading = cached.0 == nil || cached.1 == nil
            defer { detailsLoading = false }
            do {
                let presentation = try await store.activityPresentation(id: activity.id)
                route = presentation.0
                extraMetrics = presentation.1
            } catch is CancellationError {} catch {
                extraError = "部分过程数据暂时不可读取，下次打开会重试。"
                if route == nil {
                    route = try? await store.routeDetail(id: activity.id)
                    if route == nil { errorMessage = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder private var detailMap: some View {
        Group {
            if let route, !route.mapCoordinates.isEmpty {
                RouteDetailMapView(coordinates: route.mapCoordinates, colorScheme: colorScheme)
            } else if route == nil && errorMessage == nil && activity.routeId != nil {
                ZStack { Color(uiColor: .secondarySystemBackground); ProgressView() }
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Label("这次跑步没有可用轨迹", systemImage: "map").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var facts: [DetailFact] {
        var result: [DetailFact] = []
        if let value = displayActivity.avgHeartRate { result.append(DetailFact(label: "平均心率", value: "\(value)", unit: "bpm")) }
        if let value = displayActivity.maxHeartRate { result.append(DetailFact(label: "最高心率", value: "\(value)", unit: "bpm")) }
        if let value = displayActivity.avgCadence ?? extraMetrics?.averages[.steps], value > 0 {
            result.append(DetailFact(label: "平均步频", value: String(format: "%.0f", value), unit: "步/分"))
        }
        if let value = displayActivity.avgPower ?? extraMetrics?.averages[.power], value > 0 {
            result.append(DetailFact(label: "平均功率", value: String(format: "%.0f", value), unit: "W"))
        }
        if let value = extraMetrics?.elevationGain ?? route?.elevationGain, value > 0 {
            result.append(DetailFact(label: "累计爬升", value: String(format: "%.0f", value), unit: "m"))
        }
        if let value = extraMetrics?.energy, value > 0 {
            result.append(DetailFact(label: "活动能量", value: String(format: "%.0f", value), unit: "千卡"))
        }
        return result
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                primaryValue("距离 · km", String(format: "%.2f", displayActivity.distanceKm), size: 32)
                primaryValue("运动用时", compactDuration, size: 25)
                primaryValue("平均配速 · /km", compactPace, size: 25)
            }
            if !facts.isEmpty {
                Divider()
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ForEach(facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(fact.label).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(fact.value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            Text(fact.unit).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var compactDuration: String {
        let seconds = Int(TrainingFormat.seconds(displayActivity.duration))
        return seconds < 3600 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : displayActivity.duration
    }
    private var compactPace: String {
        guard displayActivity.distanceKm > 0, let seconds = MonthlyReport.seconds(displayActivity.duration) else { return displayActivity.pace }
        let pace = Int((seconds / displayActivity.distanceKm).rounded())
        return String(format: "%d:%02d", pace / 60, pace % 60)
    }
    private func primaryValue(_ title: String, _ value: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: size, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .frame(height: 38, alignment: .bottomLeading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func detailAction(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }.font(.subheadline).padding(.vertical, 16)
    }
}

private struct DetailFact: Identifiable {
    var label: String
    var value: String
    var unit: String
    var id: String { label }
}

private struct ChartPoint: Identifiable {
    var id: Int
    var seconds: Double
    var value: Double
    var segment = 0
}

private enum ActivityMetric: String, CaseIterable {
    case pace = "配速", heart = "心率", elevation = "海拔", power = "功率", cadence = "步频"
    var unit: String {
        switch self { case .pace: "/km"; case .heart: "bpm"; case .elevation: "m"; case .power: "W"; case .cadence: "步/分" }
    }
    var color: Color {
        switch self { case .pace: .blue; case .heart: .red; case .elevation: .brown; case .power: .orange; case .cadence: .purple }
    }
    func formatted(_ value: Double) -> String {
        if self == .pace {
            let seconds = max(0, Int((value * 60).rounded()))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return String(format: "%.0f", value)
    }
    func ordinate(_ value: Double) -> Double { self == .pace ? -value : value }
}

private struct ActivityTrendData {
    var points: [ChartPoint]
    var mean: Double
    var minimum: Double
    var maximum: Double
    var timeRange: ClosedRange<Double>
    var valueRange: ClosedRange<Double>

    init(_ raw: [ChartPoint], metric: ActivityMetric) {
        let ordered = raw.filter { $0.seconds.isFinite && $0.value.isFinite }.sorted { $0.seconds < $1.seconds }
        mean = ordered.reduce(0) { $0 + $1.value } / Double(max(ordered.count, 1))
        minimum = ordered.map(\.value).min() ?? 0
        maximum = ordered.map(\.value).max() ?? 1
        timeRange = 0...max(1, ordered.last?.seconds ?? 1)
        let span = max(maximum - minimum, max(abs(maximum), 1) * 0.04)
        let low = minimum - span * 0.12
        let high = maximum + span * 0.12
        valueRange = metric == .pace ? (-high)...(-low) : low...high
        let gaps = zip(ordered, ordered.dropFirst()).map { $1.seconds - $0.seconds }.filter { $0 > 0 }.sorted()
        let limit = max(30, (gaps.isEmpty ? 10 : gaps[gaps.count / 2]) * 4)
        var segment = 0
        var segmented: [ChartPoint] = []
        for (index, var point) in ordered.enumerated() {
            if index > 0 && point.seconds - ordered[index - 1].seconds > limit { segment += 1 }
            point.segment = segment
            segmented.append(point)
        }
        if segmented.count > 400 {
            points = ActivityChartSampling.indices(values: segmented.map(\.value), segments: segmented.map(\.segment))
                .map { segmented[$0] }
        } else { points = segmented }
    }
}

struct ActivityCharts: View {
    @State private var selectedMetric: ActivityMetric = .pace
    @State private var selectedSeconds: Double?
    private let dataSets: [ActivityMetric: ActivityTrendData]
    private let activity: ArchiveActivity?
    private let auxiliary: WorkoutMetricPresentation?
    private let isLoading: Bool

    init(series: ArchiveTimeSeries?, auxiliary: WorkoutMetricPresentation? = nil, activity: ArchiveActivity? = nil, isLoading: Bool = false) {
        self.isLoading = isLoading
        self.activity = activity
        self.auxiliary = auxiliary
        var result: [ActivityMetric: ActivityTrendData] = [:]
        for metric in ActivityMetric.allCases {
            let points: [ChartPoint]
            if metric == .power || metric == .cadence {
                points = (auxiliary?.series[metric == .power ? .power : .steps] ?? []).enumerated().map {
                    ChartPoint(id: $0.offset, seconds: $0.element.seconds, value: $0.element.value)
                }
            } else { points = series.map { Self.points(for: metric, series: $0) } ?? [] }
            if points.count > 1 { result[metric] = ActivityTrendData(points, metric: metric) }
        }
        dataSets = result
    }

    private var metric: ActivityMetric { selectedMetric }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("过程分析").font(.headline)
                Spacer()
                Text(selectedSeconds.map { elapsed($0, hours: (dataSets[metric]?.timeRange.upperBound ?? 0) >= 3600) } ?? "拖动查看数值")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if selectedSeconds != nil { Button("重置") { selectedSeconds = nil }.font(.caption) }
            }
            Picker("指标", selection: Binding(get: { metric }, set: { selectedMetric = $0; selectedSeconds = nil })) {
                ForEach(ActivityMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if let data = dataSets[metric] {
                metricHeader(data)
                plot(data)
                HStack {
                    Text(data.timeRange.upperBound >= 3600 ? "经过时间（时:分:秒）" : "经过时间（分:秒）")
                    Spacer()
                    Text("\(metric == .pace ? "最快" : "最低") \(metric.formatted(data.minimum))  ·  \(metric == .pace ? "最慢" : "最高") \(metric.formatted(data.maximum)) \(metric.unit)")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    if isLoading { ProgressView() }
                    Text(isLoading ? "正在读取\(metric.rawValue)数据…" : "这次跑步没有可用的\(metric.rawValue)采样")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 235)
            }
        }
    }

    private func metricHeader(_ data: ActivityTrendData) -> some View {
        let selected = selectedSeconds.flatMap { seconds in data.points.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } }
        let summary = summaryValue(metric)
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(metric.formatted(selected?.value ?? summary ?? data.mean)).font(.system(size: 25, weight: .semibold)).monospacedDigit()
            Text(metric.unit).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(selected == nil ? (summary == nil ? "采样均值" : "全程均值") : "所选时刻")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func plot(_ data: ActivityTrendData) -> some View {
        Chart {
            ForEach(data.points) { point in
                LineMark(x: .value("经过时间", point.seconds), y: .value(metric.rawValue, metric.ordinate(point.value)), series: .value("连续采样区间", point.segment))
                    .foregroundStyle(metric.color).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).interpolationMethod(.linear)
            }
            if let seconds = selectedSeconds,
               let point = data.points.min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) }) {
                RuleMark(x: .value("选中时间", point.seconds)).foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("经过时间", point.seconds), y: .value(metric.rawValue, metric.ordinate(point.value)))
                    .foregroundStyle(metric.color).symbolSize(32)
            }
        }
        .chartXScale(domain: data.timeRange).chartYScale(domain: data.valueRange)
        .chartXSelection(value: $selectedSeconds)
        .chartXAxis {
            AxisMarks(values: timeTicks(data.timeRange.upperBound)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(Color.gray.opacity(0.18))
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(elapsed(seconds, hours: data.timeRange.upperBound >= 3600)).font(.system(size: 10)).monospacedDigit() }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.gray.opacity(0.18))
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(metric.formatted(metric == .pace ? -number : number)).font(.system(size: 10)).monospacedDigit() }
                }
            }
        }
        .frame(height: 180)
        .accessibilityLabel("\(metric.rawValue)随经过时间变化，单位\(metric.unit)")
    }

    private func summaryValue(_ metric: ActivityMetric) -> Double? {
        switch metric {
        case .pace:
            guard let activity, activity.distanceKm > 0, let seconds = MonthlyReport.seconds(activity.duration) else { return nil }
            return seconds / activity.distanceKm / 60
        case .heart: return activity?.avgHeartRate.map(Double.init)
        case .power: return activity?.avgPower ?? auxiliary?.averages[.power]
        case .cadence: return activity?.avgCadence ?? auxiliary?.averages[.steps]
        case .elevation: return nil
        }
    }

    private static func points(for metric: ActivityMetric, series: ArchiveTimeSeries) -> [ChartPoint] {
        switch metric {
        case .pace: return paired(series.pace, elapsed: series.elapsed).filter { (2...30).contains($0.value) }
        case .elevation: return paired(series.elevation.map(Optional.some), elapsed: series.elapsed)
        case .heart:
            guard series.heartRateElapsed != nil || series.heartRate.count == series.elapsed.count else { return [] }
            let times = series.heartRateElapsed ?? series.elapsed
            return paired(series.heartRate.map(Optional.some), elapsed: times).filter { $0.value > 0 }
        case .power, .cadence: return []
        }
    }
    private static func paired(_ values: [Double?], elapsed: [Double]) -> [ChartPoint] {
        values.enumerated().compactMap { index, value in
            guard let value, index < elapsed.count, value.isFinite, elapsed[index].isFinite else { return nil }
            return ChartPoint(id: index, seconds: elapsed[index], value: value)
        }
    }
    private func elapsed(_ seconds: Double, hours: Bool) -> String {
        let value = max(0, Int(seconds.rounded()))
        return hours ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
    private func timeTicks(_ duration: Double) -> [Double] {
        let steps: [Double] = [30, 60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 14400]
        let interval = steps.first { $0 >= duration / 4 } ?? 14400
        return Array(stride(from: 0, through: duration, by: interval))
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
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 22, left: 26, bottom: 22, right: 26), animated: false)
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
            : UIColor(red: 0.04, green: 0.48, blue: 0.47, alpha: 1)
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
