import Charts
import MapKit
import SwiftUI
import UIKit

enum RunTheme {
    static let accent = Color(red: 1.0, green: 0.34, blue: 0.22)
    static let route = Color(red: 0.18, green: 0.68, blue: 0.65)
}

struct DashboardView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var isSummaryExpanded = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    ArchiveStatsPanel(activities: store.activities)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                }
            }
            .ignoresSafeArea(edges: .top)
            .background(Color(.systemGroupedBackground))
            .refreshable { await store.load(force: true) }
            .overlay {
                if store.isLoading && store.activities.isEmpty { ProgressView().controlSize(.large) }
            }
            .navigationDestination(for: ArchiveActivity.self) { activity in
                ActivityDetailView(activity: activity)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .top) {
            RouteMapView(routes: Array(store.routes.prefix(40)))
                .frame(height: 560)
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.12), Color(.systemBackground).opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            HStack(alignment: .center, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        isSummaryExpanded.toggle()
                    }
                } label: {
                    profileAvatar
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)

                SummaryMetric(
                    label: "累计里程",
                    value: store.summary.map { "\(Int($0.totalDistanceKm)) km" } ?? "--",
                    color: RunTheme.accent,
                    divider: false
                )

                if isSummaryExpanded {
                    SummaryMetric(
                        label: "全马 PB",
                        value: store.summary?.marathonPb ?? "--",
                        color: Color(red: 59 / 255, green: 139 / 255, blue: 1),
                        divider: false
                    )
                    SummaryMetric(
                        label: "半马 PB",
                        value: store.summary?.halfMarathonPb ?? "--",
                        color: Color(red: 45 / 255, green: 212 / 255, blue: 168 / 255),
                        divider: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 56)
        }
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

    private var entries: [ArchiveActivity] {
        store.activities.filter { $0.distanceKm > 10 && $0.routeId != nil }
    }

    private var totalDistance: Double { entries.reduce(0) { $0 + $1.distanceKm } }
    private var marathonCount: Int { entries.filter { $0.distanceKm >= 41 }.count }
    private var halfCount: Int { entries.filter { $0.distanceKm >= 20 && $0.distanceKm < 41 }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ROUTE COLLECTION · \(entries.count) RUNS · \(formatKm(totalDistance)) KM")
                            .font(.caption2.bold()).tracking(1.4).foregroundStyle(RunTheme.accent)
                        Text("Over 10km Runs")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                        Text("每一条超过 10 公里的路线，组成你的长距离轨迹收藏。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)

                    HStack(spacing: 10) {
                        CollectionLegend(label: "日常长跑", count: max(0, entries.count - marathonCount - halfCount), color: RunTheme.route)
                        CollectionLegend(label: "半马", count: halfCount, color: .blue)
                        CollectionLegend(label: "全马", count: marathonCount, color: RunTheme.accent)
                    }
                    .padding(.horizontal, 18)

                    if entries.isEmpty {
                        ContentUnavailableView("暂无长距离路线", systemImage: "figure.run", description: Text("同步或读取 Apple Health 后，这里会显示超过 10 km 的轨迹。"))
                            .padding(.top, 32)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(entries) { activity in
                                NavigationLink(value: activity) {
                                    CollectionRouteCard(activity: activity, route: store.routeSummary(id: activity.routeId))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("汇总")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
        }
    }

    private func formatKm(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
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

private struct CollectionRouteCard: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MiniRouteView(coordinates: route?.coordinates ?? [])
                .frame(maxWidth: .infinity).frame(height: 112)
                .padding(8)
                .background(RunTheme.route.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            Text(activity.name).font(.subheadline.bold()).lineLimit(1)
            Text("\(formatKm(activity.distanceKm)) km · \(activity.date.formatted(date: .numeric, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    @State private var search = ""
    @State private var filter: Filter = .all

    private var filtered: [ArchiveActivity] {
        store.activities.filter { item in
            let kindMatches = filter == .all || (filter == .run && item.kind == .run) || (filter == .race && item.kind == .race)
            let searchMatches = search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                || item.city.localizedCaseInsensitiveContains(search)
            return kindMatches && searchMatches
        }
    }

    var body: some View {
        List {
            Picker("类型", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            ForEach(filtered) { activity in
                NavigationLink(value: activity) {
                    RouteActivityRow(activity: activity, route: store.routeSummary(id: activity.routeId))
                        .padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("跑步记录")
        .searchable(text: $search, prompt: "搜索路线或城市")
        .refreshable { await store.load(force: true) }
        .navigationDestination(for: ArchiveActivity.self) { ActivityDetailView(activity: $0) }
    }
}

struct ActivityDetailView: View {
    @EnvironmentObject private var store: ArchiveStore
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
            .padding(.bottom, 30)
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ShareStudioView(initialActivity: displayActivity)
                } label: { Image(systemName: "square.and.arrow.up") }
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
                RouteDetailMapView(coordinates: route.mapCoordinates)
                    .frame(height: 420)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView()
                }
                .frame(height: 420)
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
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.title2.bold()).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
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
        let values = points.map(\.value).filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        if abs(maximum - minimum) < 0.001 {
            return (minimum - 1)...(maximum + 1)
        }
        let padding = max((maximum - minimum) * 0.08, kind == .pace ? 0.25 : 1)
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
                    yEnd: .value(unit, point.value)
                )
                    .foregroundStyle(color.opacity(0.10))
                LineMark(x: .value("时间", point.seconds / 60), y: .value(unit, point.value))
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
                            Text(kind == .pace ? paceAxisLabel(metric) : String(format: "%.0f", metric))
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
}

struct MiniRouteView: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        Canvas { context, size in
            guard coordinates.count > 1 else { return }
            let points = normalizedPoints(decimatedMapCoordinates(coordinates, limit: 80), size: size, inset: 2)
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(RunTheme.route), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
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

    func makeCoordinator() -> MapCoordinator { MapCoordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
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
        let signature = routes.map { "\($0.id):\($0.previewCoordinates.count)" }.joined(separator: "|")
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature

        let desiredIDs = Set(routes.map(\.id))
        let staleOverlays = map.overlays.filter { overlay in
            guard let line = overlay as? MKPolyline, let id = line.title else { return false }
            return !desiredIDs.contains(id)
        }
        if !staleOverlays.isEmpty { map.removeOverlays(staleOverlays) }

        let existingIDs = Set(map.overlays.compactMap { ($0 as? MKPolyline)?.title })
        let lines = routes.compactMap { route -> MKPolyline? in
            guard !existingIDs.contains(route.id) else { return nil }
            let coordinates = decimatedMapCoordinates(route.coordinates, limit: 60).map(mapDisplayCoordinate)
            guard coordinates.count > 1 else { return nil }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            line.title = route.id
            return line
        }

        if !lines.isEmpty { map.addOverlays(lines) }
        if !context.coordinator.hasSetInitialRegion,
           let rect = map.overlays.compactMap({ $0 as? MKPolyline }).map(\.boundingMapRect).reduce(nil, { current, rect in
            current.map { $0.union(rect) } ?? rect
        }) {
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 70, left: 32, bottom: 80, right: 32), animated: false)
            context.coordinator.hasSetInitialRegion = true
        }
    }
}

private func decimatedMapCoordinates(_ coordinates: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D] {
    guard coordinates.count > limit, limit > 1 else { return coordinates }
    let step = Double(coordinates.count - 1) / Double(limit - 1)
    return (0..<limit).map { coordinates[Int((Double($0) * step).rounded())] }
}

struct RouteDetailMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]

    func makeCoordinator() -> MapCoordinator { MapCoordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .mutedStandard
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
        let signature = "\(coordinates.count):\(coordinates.first?.latitude ?? 0):\(coordinates.first?.longitude ?? 0)"
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
    var signature = ""
    var hasSetInitialRegion = false
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = UIColor(red: 0.18, green: 0.68, blue: 0.65, alpha: 0.9)
        renderer.lineWidth = 3
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
