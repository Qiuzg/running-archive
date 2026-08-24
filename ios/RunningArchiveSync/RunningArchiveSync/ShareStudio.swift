import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI
import UIKit

enum ShareLayout: String, CaseIterable, Identifiable {
    case compact = "精简"
    case detailed = "详细"
    var id: Self { self }
    var size: CGSize { self == .compact ? CGSize(width: 1080, height: 1680) : CGSize(width: 1080, height: 2800) }
}

struct ShareStudioView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.colorScheme) private var colorScheme
    let initialActivity: ArchiveActivity?

    @State private var selectedID: String?
    @State private var layout: ShareLayout = .compact
    @State private var darkCard = false
    @State private var renderedImage: UIImage?
    @State private var isRendering = false
    @State private var showingShareSheet = false
    @State private var errorMessage: String?

    init(initialActivity: ArchiveActivity? = nil) {
        self.initialActivity = initialActivity
        _selectedID = State(initialValue: initialActivity?.id)
    }

    private var selected: ArchiveActivity? {
        store.activities.first { $0.id == selectedID } ?? initialActivity ?? store.activities.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                controls
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("分享图片")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load(); selectDefault(); await render() }
        .onChange(of: selectedID) { _, _ in Task { await render() } }
        .onChange(of: layout) { _, _ in Task { await render() } }
        .onChange(of: darkCard) { _, _ in Task { await render() } }
        .sheet(isPresented: $showingShareSheet) {
            if let renderedImage { ShareSheet(items: [renderedImage]) }
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground))
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(12)
            } else if isRendering {
                ProgressView("正在生成分享图片…")
            } else {
                ContentUnavailableView("选择一条跑步", systemImage: "photo")
            }
        }
        .frame(minHeight: layout == .compact ? 500 : 620)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Menu {
                ForEach(store.activities.filter { $0.routeId != nil }.prefix(300)) { activity in
                    Button {
                        selectedID = activity.id
                    } label: {
                        Text("\(activity.date.formatted(date: .numeric, time: .omitted)) · \(activity.name)")
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "figure.run")
                    Text(selected.map { "\($0.date.formatted(date: .numeric, time: .omitted)) · \($0.name)" } ?? "选择跑步")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
            Picker("版式", selection: $layout) {
                ForEach(ShareLayout.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("夜间分享图", isOn: $darkCard)
                .padding(.horizontal, 4)
            Button {
                showingShareSheet = true
            } label: {
                Label("分享或保存图片", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(RunTheme.accent)
            .disabled(renderedImage == nil || isRendering)
        }
    }

    private func selectDefault() {
        if selectedID == nil { selectedID = store.activities.first(where: { $0.routeId != nil })?.id }
        if initialActivity == nil { darkCard = colorScheme == .dark }
    }

    @MainActor private func render() async {
        guard let activity = selected, let routeID = activity.routeId else { return }
        isRendering = true
        errorMessage = nil
        do {
            let detail = try await store.routeDetail(id: routeID)
            let mapImage = try await ShareImageGenerator.routeSnapshot(
                coordinates: detail.mapCoordinates,
                size: CGSize(width: 1000, height: layout == .compact ? 660 : 920),
                dark: darkCard
            )
            let card = ShareCardView(
                activity: activity,
                route: detail,
                mapImage: mapImage,
                layout: layout,
                dark: darkCard
            )
            let renderer = ImageRenderer(content: card)
            renderer.proposedSize = ProposedViewSize(layout.size)
            renderer.scale = 1
            guard let image = renderer.uiImage else { throw ArchiveAPIError.server(0) }
            renderedImage = image
        } catch {
            errorMessage = error.localizedDescription
            renderedImage = nil
        }
        isRendering = false
    }
}

private struct ShareCardView: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteDetail
    let mapImage: UIImage
    let layout: ShareLayout
    let dark: Bool

    private var background: Color { dark ? Color(red: 0.055, green: 0.07, blue: 0.10) : Color(red: 0.96, green: 0.97, blue: 0.985) }
    private var foreground: Color { dark ? .white : Color(red: 0.08, green: 0.09, blue: 0.12) }
    private var card: Color { dark ? Color.white.opacity(0.08) : .white }

    var body: some View {
        VStack(spacing: 0) {
            header
            Image(uiImage: mapImage).resizable().scaledToFill()
                .frame(width: 1000, height: layout == .compact ? 660 : 920)
                .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text(activity.city.isEmpty ? "RUNNING ROUTE" : activity.city.uppercased())
                        .font(.system(size: 28, weight: .bold)).tracking(4)
                        .foregroundStyle(.white).padding(34)
                }
            metrics
            if layout == .detailed { charts }
            footer
        }
        .padding(.horizontal, 40)
        .frame(width: layout.size.width, height: layout.size.height)
        .background(background)
        .foregroundStyle(foreground)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 14) {
                Text(activity.date.formatted(.dateTime.year().month().day()))
                    .font(.system(size: 30, weight: .bold)).tracking(4).foregroundStyle(RunTheme.accent)
                Text(activity.name).font(.system(size: 58, weight: .black)).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.2f", activity.distanceKm))
                    .font(.system(size: 86, weight: .black)).monospacedDigit()
                Text("KILOMETERS").font(.system(size: 22, weight: .bold)).tracking(4).foregroundStyle(.secondary)
            }
        }
        .frame(height: layout == .compact ? 260 : 300)
        .padding(.horizontal, 18)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            ShareMetric(label: "平均心率", value: activity.avgHeartRate.map(String.init) ?? "--", unit: "bpm")
            ShareMetric(label: "平均功率", value: activity.avgPower.map { "\(Int($0.rounded()))" } ?? "--", unit: "W")
            ShareMetric(label: "平均配速", value: activity.pace, unit: "/km")
            ShareMetric(label: "用时", value: activity.duration, unit: "hh:mm:ss")
            ShareMetric(label: "累计爬升", value: "\(Int(route.elevationGain.rounded()))", unit: "m", divider: false)
        }
        .padding(.vertical, 30)
        .background(card, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
        .padding(.top, 28)
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Text("详细折线图").font(.system(size: 38, weight: .black))
                Spacer()
                Text("配速 · 海拔 · 心率").font(.system(size: 23, weight: .semibold)).foregroundStyle(.secondary)
            }
            if let series = route.timeSeries {
                ShareSparkline(values: series.pace.compactMap { $0 }, color: .blue, label: "配速")
                ShareSparkline(values: series.elevation, color: .orange, label: "海拔")
                ShareSparkline(values: series.heartRate, color: RunTheme.accent, label: "心率")
            }
        }
        .padding(38)
        .frame(height: 940)
        .background(card, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
        .padding(.top, 28)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("RUNNING ARCHIVE").font(.system(size: 28, weight: .black)).tracking(4)
                Text("每一步，都值得被记录").font(.system(size: 25, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            if let qr = ShareImageGenerator.qrCode(from: ArchiveAPI.defaultBaseURL) {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: 142, height: 142)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}

private struct ShareMetric: View {
    let label: String
    let value: String
    let unit: String
    var divider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 23, weight: .bold)).foregroundStyle(RunTheme.accent)
            Text(value).font(.system(size: 34, weight: .black)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(unit).font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .overlay(alignment: .trailing) {
            if divider { Rectangle().fill(.primary.opacity(0.10)).frame(width: 2, height: 100) }
        }
    }
}

private struct ShareSparkline: View {
    let values: [Double]
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 25) {
            Text(label).font(.system(size: 26, weight: .bold)).frame(width: 70, alignment: .leading)
            Canvas { context, size in
                guard values.count > 1, let minValue = values.min(), let maxValue = values.max() else { return }
                let range = max(maxValue - minValue, 1)
                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = size.height - size.height * CGFloat((value - minValue) / range)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 190)
        }
    }
}

enum ShareImageGenerator {
    static func routeSnapshot(coordinates: [CLLocationCoordinate2D], size: CGSize, dark: Bool) async throws -> UIImage {
        guard coordinates.count > 1 else { return UIImage() }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = 1
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let rect = polyline.boundingMapRect
        let paddingX = rect.size.width * 0.16
        let paddingY = rect.size.height * 0.16
        options.mapRect = rect.insetBy(dx: -paddingX, dy: -paddingY)
        let snapshot = try await MKMapSnapshotter(options: options).start()
        return UIGraphicsImageRenderer(size: size).image { renderer in
            snapshot.image.draw(at: .zero)
            let context = renderer.cgContext
            context.setStrokeColor(UIColor(red: 1, green: 0.34, blue: 0.22, alpha: 1).cgColor)
            context.setLineWidth(8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
        }
    }

    static func qrCode(from value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let context = CIContext()
        guard let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
