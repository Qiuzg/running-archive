import Charts
import MapKit
import SwiftUI

enum RunTheme {
    static let accent = Color(red: 1.0, green: 0.34, blue: 0.22)
    static let route = Color(red: 0.18, green: 0.68, blue: 0.65)
}

struct DashboardView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    latestPanel
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
        ZStack(alignment: .bottom) {
            RouteMapView(routes: Array(store.routes.prefix(100)))
                .frame(height: 420)
            LinearGradient(
                colors: [.clear, Color(.systemBackground).opacity(0.12), Color(.systemBackground).opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 18) {
                HStack {
                    ZStack {
                        Circle().fill(.black.opacity(0.82))
                        Image(systemName: "figure.run")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RUN LOG").font(.caption2.bold()).tracking(2)
                        Text("我的跑步档案").font(.headline)
                    }
                    Spacer()
                    Image(systemName: "heart.fill")
                        .foregroundStyle(RunTheme.accent)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.28)))
                .padding(.horizontal, 14)
                .padding(.top, 56)
                Spacer()
                summaryStrip
                    .padding(.bottom, 26)
            }
        }
    }

    private var summaryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                SummaryMetric(label: "累计里程", value: store.summary.map { "\(Int($0.totalDistanceKm)) km" } ?? "--")
                SummaryMetric(label: "今年跑量", value: store.summary.map { "\(Int($0.yearlyDistanceKm)) km" } ?? "--")
                SummaryMetric(label: "全马 PB", value: store.summary?.marathonPb ?? "--")
                SummaryMetric(label: "半马 PB", value: store.summary?.halfMarathonPb ?? "--")
                SummaryMetric(label: "完赛场次", value: store.summary.map { "\($0.raceCount) 场" } ?? "--", divider: false)
            }
            .padding(.vertical, 13)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.06)))
            .padding(.horizontal, 14)
        }
    }

    private var latestPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ROUTE ATLAS").font(.caption2.bold()).tracking(2).foregroundStyle(RunTheme.accent)
                    Text("路线足迹").font(.title2.bold())
                }
                Spacer()
                NavigationLink {
                    ActivityListView()
                } label: {
                    Text("查看全部").font(.subheadline.weight(.semibold))
                }
            }
            ForEach(Array(store.activities.filter { $0.routeId != nil }.prefix(8))) { activity in
                NavigationLink(value: activity) {
                    RouteActivityRow(activity: activity, route: store.routeSummary(id: activity.routeId))
                }
                .buttonStyle(.plain)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let status = store.routeScanStatus {
                Label(status, systemImage: "waveform.path.ecg")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .offset(y: -20)
        .padding(.bottom, -20)
    }
}

private struct SummaryMetric: View {
    let label: String
    let value: String
    var divider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit()
        }
        .frame(minWidth: 86, alignment: .leading)
        .padding(.horizontal, 12)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayActivity.kind == .race ? "RACE RESULT" : "RUNNING ACTIVITY")
                            .font(.caption2.bold()).tracking(2).foregroundStyle(RunTheme.accent)
                        Text(displayActivity.name).font(.title.bold())
                        Text(displayActivity.date.formatted(date: .long, time: .omitted) + (displayActivity.city.isEmpty ? "" : " · \(displayActivity.city)"))
                            .foregroundStyle(.secondary)
                    }
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
        .navigationBarTitleDisplayMode(.inline)
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
        if let route, !route.mapCoordinates.isEmpty {
            RouteDetailMapView(coordinates: route.mapCoordinates)
                .frame(height: 330)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, Color(.systemGroupedBackground)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70).allowsHitTesting(false)
                }
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                ProgressView()
            }.frame(height: 240)
        }
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

struct ActivityCharts: View {
    let series: ArchiveTimeSeries

    var body: some View {
        VStack(spacing: 12) {
            if !series.pace.isEmpty {
                MetricLineChart(title: "配速趋势", unit: "分钟/公里", points: paired(series.pace), color: .blue)
            }
            if !series.elevation.isEmpty {
                MetricLineChart(title: "海拔变化", unit: "米", points: paired(series.elevation.map(Optional.some)), color: .orange)
            }
            if !series.heartRate.isEmpty {
                let elapsed = series.heartRateElapsed ?? interpolatedElapsed(count: series.heartRate.count)
                let values = series.heartRate.enumerated().compactMap { index, value in
                    index < elapsed.count ? ChartPoint(id: index, seconds: elapsed[index], value: value) : nil
                }
                MetricLineChart(title: "心率趋势", unit: "bpm", points: values, color: RunTheme.accent)
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
    let title: String
    let unit: String
    let points: [ChartPoint]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Chart(points) { point in
                AreaMark(x: .value("时间", point.seconds / 60), y: .value(unit, point.value))
                    .foregroundStyle(color.opacity(0.10))
                LineMark(x: .value("时间", point.seconds / 60), y: .value(unit, point.value))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxisLabel("分钟")
            .frame(height: 150)
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MiniRouteView: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        Canvas { context, size in
            guard coordinates.count > 1 else { return }
            let points = normalizedPoints(coordinates, size: size, inset: 2)
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
        map.isPitchEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let signature = routes.map(\.id).joined(separator: "|")
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        map.removeOverlays(map.overlays)
        let lines = routes.compactMap { route -> MKPolyline? in
            let coordinates = route.coordinates
            guard coordinates.count > 1 else { return nil }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }
        map.addOverlays(lines)
        if let rect = lines.map(\.boundingMapRect).reduce(nil, { current, rect in
            current.map { $0.union(rect) } ?? rect
        }) {
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 70, left: 32, bottom: 80, right: 32), animated: false)
        }
    }
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
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        guard context.coordinator.signature != "\(coordinates.count)" else { return }
        context.coordinator.signature = "\(coordinates.count)"
        map.removeOverlays(map.overlays)
        guard coordinates.count > 1 else { return }
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(line)
        map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 50, left: 36, bottom: 80, right: 36), animated: false)
    }
}

final class MapCoordinator: NSObject, MKMapViewDelegate {
    var signature = ""
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
