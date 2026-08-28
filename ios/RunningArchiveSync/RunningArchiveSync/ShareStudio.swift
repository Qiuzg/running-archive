import CoreImage.CIFilterBuiltins
import MapKit
import Photos
import SwiftUI
import UIKit

enum ShareLayout: String, CaseIterable, Identifiable {
    case compact = "精简"
    case detailed = "详细"
    var id: Self { self }
    var size: CGSize { self == .compact ? CGSize(width: 1080, height: 1400) : CGSize(width: 1080, height: 2800) }
    // 1.5x keeps the exported PNG sharper than the web canvas while avoiding
    // the very large intermediate bitmaps that can lock up an iPhone.
    var renderScale: CGFloat { 1.5 }
}

enum ShareMapProvider: String, CaseIterable, Identifiable {
    case leaflet = "Leaflet"
    case amap = "高德"
    var id: Self { self }
}

struct ShareStudioView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.colorScheme) private var colorScheme
    let initialActivity: ArchiveActivity?

    @State private var selectedID: String?
    @State private var shareTitle: String
    @State private var layout: ShareLayout = .compact
    @State private var mapProvider: ShareMapProvider = .leaflet
    @State private var darkCard = false
    @State private var renderedImage: UIImage?
    @State private var isRendering = false
    @State private var showingShareSheet = false
    @State private var errorMessage: String?
    @State private var renderRequested = false
    @State private var renderToken = 0

    init(initialActivity: ArchiveActivity? = nil) {
        self.initialActivity = initialActivity
        _selectedID = State(initialValue: initialActivity?.id)
        _shareTitle = State(initialValue: "户外跑步")
    }

    private var selected: ArchiveActivity? {
        store.activities.first { $0.id == selectedID } ?? initialActivity ?? store.activities.first
    }

    private var selectedRoute: ArchiveRouteSummary? {
        store.routeSummary(id: selected?.routeId)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                controls
                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 140)
        }
        .background(RunTheme.page)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(RunTheme.page, for: .navigationBar)
        .task { await store.load(); selectDefault() }
        .task(id: renderToken) {
            guard renderRequested, selected != nil else { return }
            await render()
        }
        .onChange(of: store.activities.count) { _, _ in
            guard selectedID == nil else { return }
            selectDefault()
        }
        .onChange(of: selectedID) { _, _ in invalidateRenderedImage() }
        .onChange(of: shareTitle) { _, _ in invalidateRenderedImage() }
        .onChange(of: layout) { _, _ in invalidateRenderedImage() }
        .onChange(of: mapProvider) { _, _ in invalidateRenderedImage() }
        .onChange(of: darkCard) { _, _ in invalidateRenderedImage() }
        .sheet(isPresented: $showingShareSheet) {
            if let renderedImage { ShareSheet(items: [renderedImage]) }
        }
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分享预览")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(layout.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RunTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RunTheme.accent.opacity(0.1), in: Capsule())
            }
            ZStack {
                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(10)
                } else if isRendering {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成分享图片…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    conceptPreviewCard
                }
            }
            .frame(height: layout == .compact ? 330 : 440)
        }
        .padding(.top, 2)
    }

    private var conceptPreviewCard: some View {
        let surface = darkCard ? Color(red: 0.063, green: 0.137, blue: 0.153) : Color(red: 0.90, green: 0.94, blue: 0.92)
        let lowerSurface = darkCard ? surface : Color.white.opacity(0.94)
        let primaryText = darkCard ? Color.white : RunTheme.ink
        let secondaryText = darkCard ? Color.white.opacity(0.62) : RunTheme.ink.opacity(0.58)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                surface
                MiniRouteView(coordinates: selectedRoute?.coordinates ?? [], color: darkCard ? RunTheme.mint : RunTheme.route)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                    .scaleEffect(1.18)
                LinearGradient(
                    colors: darkCard ? [.clear, Color.black.opacity(0.44)] : [.clear, Color.white.opacity(0.25)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Text("路线示意 · 生成后使用真实地图")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(darkCard ? RunTheme.mint : RunTheme.route)
                    .padding(14)
            }
            .frame(height: 192)

            VStack(alignment: .leading, spacing: 5) {
                Text("TODAY RUN")
                    .font(.caption2.weight(.black))
                    .tracking(1.6)
                    .foregroundStyle(darkCard ? RunTheme.mint : RunTheme.route)
                Text(selected?.name ?? "户外跑步")
                    .font(.headline.weight(.black))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text(selected.map { "\(String(format: "%.1f", $0.distanceKm)) km · \($0.pace)/km · \($0.duration)" } ?? "选择一条有路线的记录")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(lowerSurface)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 9)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("生成设置")
                .font(.headline.weight(.bold))
                .padding(.horizontal, 4)
            settingGroup(title: "内容") {
                VStack(spacing: 0) {
                    settingRow(icon: "figure.run", title: "跑步记录") {
                        Menu {
                            ForEach(store.activities.filter { $0.routeId != nil }.prefix(300)) { activity in
                                Button {
                                    selectedID = activity.id
                                } label: {
                                    Text("\(activity.date.formatted(date: .numeric, time: .omitted)) · \(activity.name)")
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selected.map { $0.date.formatted(date: .numeric, time: .omitted) } ?? "选择记录")
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    Divider().padding(.leading, 52)
                    settingRow(icon: "textformat", title: "图片标题") {
                        TextField("户外跑步", text: $shareTitle)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .foregroundStyle(RunTheme.ink)
                    }
                }
            }
            settingGroup(title: "样式") {
                VStack(spacing: 0) {
                    settingPickerRow(title: "版式", options: ShareLayout.allCases, selection: $layout)
                    Divider().padding(.horizontal, 16)
                    settingPickerRow(title: "地图", options: ShareMapProvider.allCases, selection: $mapProvider)
                    Divider().padding(.horizontal, 16)
                    HStack {
                        Label("夜间配色", systemImage: darkCard ? "moon.fill" : "sun.max.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Toggle("", isOn: $darkCard)
                            .labelsHidden()
                            .tint(RunTheme.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private func settingGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content()
                .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.primary.opacity(0.06), lineWidth: 1))
        }
    }

    private func settingRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RunTheme.accent)
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 10)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func settingPickerRow<Option: RawRepresentable & CaseIterable & Identifiable>(title: String, options: Option.AllCases, selection: Binding<Option>) -> some View where Option.RawValue == String {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(Array(options)) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                selection.wrappedValue.id == option.id ? RunTheme.accent.opacity(0.14) : RunTheme.page,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .foregroundStyle(selection.wrappedValue.id == option.id ? RunTheme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                renderRequested = true
                renderToken &+= 1
            } label: {
                Label("生成分享图片", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(RunTheme.accent)
            .disabled(selected?.routeId == nil || isRendering)
            if isRendering {
                Button("取消生成", role: .cancel) {
                    invalidateRenderedImage()
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                Button { saveToPhotos() } label: {
                    Label("保存相册", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(renderedImage == nil || isRendering)
                Button { showingShareSheet = true } label: {
                    Label("分享图片", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(renderedImage == nil || isRendering)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func selectDefault() {
        if selectedID == nil { selectedID = store.activities.first(where: { $0.routeId != nil })?.id }
        darkCard = colorScheme == .dark
    }

    private func invalidateRenderedImage() {
        renderRequested = false
        renderToken &+= 1
        renderedImage = nil
        errorMessage = nil
    }

    private func saveToPhotos() {
        guard let renderedImage else { return }
        Task { @MainActor in
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                errorMessage = "没有相册写入权限，请在系统设置中允许访问照片"
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: renderedImage)
                }
                errorMessage = "图片已保存到系统相册"
            } catch {
                errorMessage = "保存到相册失败：\(error.localizedDescription)"
            }
        }
    }

    @MainActor private func render() async {
        guard renderRequested, let activity = selected, let routeID = activity.routeId else { return }
        let requestedActivityID = activity.id
        isRendering = true
        errorMessage = nil
        defer { isRendering = false }
        do {
            let detail = try await store.routeDetail(id: routeID)
            guard !Task.isCancelled, renderRequested, selectedID == requestedActivityID else { return }
            let mapImage = try await ShareImageGenerator.routeSnapshot(
                coordinates: detail.mapCoordinates,
                size: layout.size,
                dark: darkCard,
                provider: mapProvider,
                scale: layout.renderScale
            )
            guard !Task.isCancelled, renderRequested, selectedID == requestedActivityID else { return }
            let displayActivity = store.activities.first { $0.id == activity.id } ?? activity
            let card = ShareCardView(
                activity: displayActivity,
                route: detail,
                mapImage: mapImage,
                layout: layout,
                title: shareTitle,
                dark: darkCard
            )
            let renderer = ImageRenderer(content: card)
            renderer.proposedSize = ProposedViewSize(layout.size)
            renderer.scale = layout.renderScale
            guard let image = renderer.uiImage else { throw LocalArchiveError.imageRenderFailed }
            renderedImage = image
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            renderedImage = nil
        }
    }
}

private struct ShareCardView: View {
    let activity: ArchiveActivity
    let route: ArchiveRouteDetail
    let mapImage: UIImage?
    let layout: ShareLayout
    let title: String
    let dark: Bool

    private var background: Color { dark ? Color(red: 0.055, green: 0.07, blue: 0.10) : Color(red: 0.96, green: 0.97, blue: 0.985) }
    private var foreground: Color { dark ? .white : Color(red: 0.08, green: 0.09, blue: 0.12) }
    private var card: Color { dark ? Color.white.opacity(0.08) : .white }
    private var detailedPanel: Color { dark ? Color(red: 0.063, green: 0.09, blue: 0.13).opacity(0.94) : Color.white.opacity(0.94) }
    private var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "户外跑步" : value
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if layout == .compact {
                compactCard
            } else {
                detailedCard
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .background(background)
        .foregroundStyle(foreground)
    }

    private var compactCard: some View {
        ZStack(alignment: .topLeading) {
            background
                .frame(width: 1080, height: 600)
                .offset(y: 800)
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1080, height: 800, alignment: .top)
                    .clipped()
            } else {
                background
                    .frame(width: 1080, height: 800)
            }

            LinearGradient(
                colors: [
                    background.opacity(0.92),
                    background.opacity(0.12),
                    background.opacity(0.06),
                    background.opacity(0.42)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1080, height: 800)

            RadialGradient(
                colors: [Color.blue.opacity(dark ? 0.18 : 0.12), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 620
            )
            .frame(width: 1080, height: 650)

            Text("TODAY RUN")
                .font(.system(size: 28, weight: .bold))
                .tracking(2)
                .foregroundStyle(RunTheme.accent)
                .offset(x: 72, y: 62)
            Text(displayTitle)
                .font(.system(size: 66, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .offset(x: 72, y: 108)
            VStack(alignment: .trailing, spacing: 3) {
                Text(activity.date.formatted(.dateTime.year().month().day()))
                Text(activity.city.isEmpty ? "" : activity.city)
            }
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(.secondary)
            .offset(x: 690, y: 62)

            compactMetrics
            compactFooter
        }
    }

    private var compactFooter: some View {
        ZStack(alignment: .topLeading) {
            detailedPanel
                .frame(width: 1080, height: 320)
            if let qr = ShareImageGenerator.qrCode(from: RunningArchiveConfiguration.defaultServerURL) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .offset(x: 62, y: 54)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("扫码查看我的跑步档案")
                    .font(.system(size: 31, weight: .black))
                Text("\(String(format: "%.2f", activity.distanceKm)) km · \(activity.date.formatted(.dateTime.year().month().day()))")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .offset(x: 294, y: 115)
            Text("RUN LOG")
                .font(.system(size: 22, weight: .black))
                .tracking(2)
                .foregroundStyle(RunTheme.accent)
                .offset(x: 910, y: 250)
        }
        .frame(width: 1080, height: 320, alignment: .topLeading)
        .offset(x: 0, y: 1080)
    }

    private var compactMetrics: some View {
        HStack(spacing: 0) {
            ShareMetric(label: "距离", value: String(format: "%.2f", activity.distanceKm), unit: "km")
            ShareMetric(label: "平均配速", value: activity.pace, unit: "/km")
            ShareMetric(label: "用时", value: activity.duration, unit: "")
            ShareMetric(label: "平均心率", value: activity.avgHeartRate.map(String.init) ?? "--", unit: "bpm")
            ShareMetric(label: "累计爬升", value: "\(Int(route.elevationGain.rounded()))", unit: "m", divider: false)
        }
        .frame(width: 972, height: 166)
        .background(card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .offset(x: 54, y: 840)
    }

    private var compactTrend: some View {
        ZStack(alignment: .topLeading) {
            Text("运动趋势")
                .font(.system(size: 28, weight: .black))
                .offset(x: 28, y: 45)
            Text("配速 · 海拔 · 心率")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(x: 28, y: 78)
            if let series = route.timeSeries {
                ShareMiniSparkline(values: series.pace.compactMap { $0 }, color: .blue, dark: dark)
                    .frame(width: 640, height: 55)
                    .offset(x: 276, y: 40)
                ShareMiniSparkline(values: series.elevation, color: .orange, dark: dark)
                    .frame(width: 640, height: 55)
                    .offset(x: 276, y: 130)
                ShareMiniSparkline(values: series.heartRate, color: RunTheme.accent, dark: dark)
                    .frame(width: 640, height: 55)
                    .offset(x: 276, y: 220)
            }
        }
        .frame(width: 972, height: 300, alignment: .topLeading)
        .background(card, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .offset(x: 54, y: 1230)
    }

    private var detailedCard: some View {
        ZStack(alignment: .topLeading) {
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1080, height: 2800)
                    .clipped()
            } else {
                background
                    .frame(width: 1080, height: 2800)
            }

            profileBadge
                .offset(x: 54, y: 48)
            Text("TODAY RUN")
                .font(.system(size: 24, weight: .black))
                .tracking(1)
                .foregroundStyle(RunTheme.accent)
                .offset(x: 160, y: 54)
            Text(displayTitle)
                .font(.system(size: 58, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .offset(x: 160, y: 90)
            VStack(alignment: .trailing, spacing: 4) {
                Text(activity.date.formatted(.dateTime.year().month().day()))
                Text(activity.city.isEmpty ? (route.city.isEmpty ? "" : route.city) : activity.city)
            }
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)
            .offset(x: 690, y: 52)

            detailedMetrics
            detailedCharts
            detailedFooter
        }
    }

    private var profileBadge: some View {
        Group {
            if let image = UIImage(named: "profile") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 82, height: 82, alignment: .trailing)
                    .clipped()
            } else {
                Image(systemName: "figure.run")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(.black.opacity(0.8))
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 3))
    }

    private var detailedMetrics: some View {
        HStack(spacing: 0) {
            ShareMetric(label: "平均心率", value: activity.avgHeartRate.map(String.init) ?? "--", unit: "bpm")
            ShareMetric(label: "平均功率", value: activity.avgPower.map { "\(Int($0.rounded()))" } ?? "--", unit: "W")
            ShareMetric(label: "平均配速", value: activity.pace, unit: "/km")
            ShareMetric(label: "用时", value: activity.duration, unit: "hh:mm:ss")
            ShareMetric(label: "累计爬升", value: "\(Int(route.elevationGain.rounded()))", unit: "m", divider: false)
        }
        .frame(width: 972, height: 166)
        .background(detailedPanel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .offset(x: 54, y: 1570)
    }

    private var detailedCharts: some View {
        ZStack(alignment: .topLeading) {
            Text("详细折线图")
                .font(.system(size: 30, weight: .black))
                .offset(x: 28, y: 38)
            Text("配速 · 爬升 · 心率")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(x: 610, y: 40)
            if let series = route.timeSeries {
                ShareDetailedChart(values: series.pace.compactMap { $0 }, label: "配速", color: .blue, dark: dark, unit: "′", reverse: true)
                    .offset(x: 0, y: 77)
                ShareDetailedChart(values: series.elevation, label: "海拔", color: .orange, dark: dark, unit: "m", reverse: false)
                    .offset(x: 0, y: 248)
                ShareDetailedChart(values: series.heartRate, label: "心率", color: RunTheme.accent, dark: dark, unit: "", reverse: false)
                    .offset(x: 0, y: 419)
            }
        }
        .frame(width: 972, height: 574, alignment: .topLeading)
        .background(detailedPanel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .offset(x: 54, y: 1825)
    }

    private var detailedFooter: some View {
        ZStack(alignment: .topLeading) {
            detailedPanel
                .frame(width: 1080, height: 320)
            if let qr = ShareImageGenerator.qrCode(from: RunningArchiveConfiguration.defaultServerURL) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .offset(x: 62, y: 54)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("扫码查看我的跑步档案")
                    .font(.system(size: 31, weight: .black))
                Text("\(String(format: "%.2f", activity.distanceKm)) km · \(activity.date.formatted(.dateTime.year().month().day()))")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .offset(x: 294, y: 115)
            Text("RUN LOG")
                .font(.system(size: 22, weight: .black))
                .tracking(2)
                .foregroundStyle(RunTheme.accent)
                .offset(x: 910, y: 250)
        }
        .frame(width: 1080, height: 320, alignment: .topLeading)
        .offset(x: 0, y: 2480)
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

private struct ShareRoutePreview: View {
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            guard coordinates.count > 1 else { return }
            let points = normalizedPoints(coordinates, size: size, inset: 76)
            guard points.count > 1 else { return }

            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(dark ? Color.black.opacity(0.42) : Color.white.opacity(0.95)),
                style: StrokeStyle(lineWidth: 20, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
            )

            for (point, markerColor) in [(points[0], Color(red: 0.06, green: 0.72, blue: 0.55)), (points[points.count - 1], RunTheme.accent)] {
                var marker = Path()
                marker.addEllipse(in: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
                context.fill(marker, with: .color(markerColor))
                context.stroke(
                    marker,
                    with: .color(dark ? Color.black.opacity(0.7) : .white),
                    style: StrokeStyle(lineWidth: 5)
                )
            }
        }
    }
}

private struct ShareMiniSparkline: View {
    let values: [Double]
    let color: Color
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let clean = values.filter(\.isFinite)
            guard clean.count > 1, let minimum = clean.min(), let maximum = clean.max() else { return }
            let range = max(maximum - minimum, 1)
            var path = Path()
            for (index, value) in clean.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(clean.count - 1)
                let y = size.height - size.height * CGFloat((value - minimum) / range)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height))
            context.stroke(baseline, with: .color((dark ? Color.white : Color.black).opacity(0.08)), lineWidth: 1)
        }
    }
}

private struct ShareDetailedChart: View {
    let values: [Double]
    let label: String
    let color: Color
    let dark: Bool
    let unit: String
    let reverse: Bool

    private var cleanValues: [Double] { values.filter(\.isFinite) }

    var body: some View {
        HStack(spacing: 20) {
            Text(label)
                .font(.system(size: 25, weight: .black))
                .frame(width: 150, alignment: .leading)
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    let chartWidth = max(size.width - 56, 1)
                    let chartHeight = size.height
                    let gridColor = (dark ? Color.white : Color.black).opacity(0.12)
                    for ratio in [0.0, 0.5, 1.0] {
                        var grid = Path()
                        let y = chartHeight * ratio
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: chartWidth, y: y))
                        context.stroke(grid, with: .color(gridColor), lineWidth: 1.5)
                    }

                    guard cleanValues.count > 1, let minimum = cleanValues.min(), let maximum = cleanValues.max() else { return }
                    let range = max(maximum - minimum, 1)
                    var path = Path()
                    for (index, value) in cleanValues.enumerated() {
                        let x = chartWidth * CGFloat(index) / CGFloat(cleanValues.count - 1)
                        let ratio = (value - minimum) / range
                        let y = chartHeight * CGFloat(reverse ? ratio : 1 - ratio)
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                if let minimum = cleanValues.min(), let maximum = cleanValues.max() {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(axisLabel(maximum))
                        Spacer()
                        Text(axisLabel(minimum))
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 112, alignment: .topTrailing)
                }
            }
            .frame(width: 720, height: 112)
        }
        .padding(.horizontal, 30)
        .frame(width: 972, height: 174, alignment: .leading)
    }

    private func axisLabel(_ value: Double) -> String {
        if unit == "′" { return String(format: "%.1f%@", value, unit) }
        return "\(Int(value.rounded()))\(unit)"
    }
}

private struct ShareSparkline: View {
    let values: [Double]
    let color: Color
    let label: String
    let dark: Bool

    var body: some View {
        HStack(spacing: 25) {
            Text(label).font(.system(size: 26, weight: .bold)).frame(width: 70, alignment: .leading)
            Canvas { context, size in
                let gridColor = (dark ? Color.white : Color.black).opacity(0.18)
                let gridStyle = StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                for index in 0...4 {
                    let fraction = CGFloat(index) / 4
                    var vertical = Path()
                    vertical.move(to: CGPoint(x: size.width * fraction, y: 0))
                    vertical.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    context.stroke(vertical, with: .color(gridColor), style: gridStyle)

                    var horizontal = Path()
                    horizontal.move(to: CGPoint(x: 0, y: size.height * fraction))
                    horizontal.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    context.stroke(horizontal, with: .color(gridColor), style: gridStyle)
                }

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
            .clipped()
        }
    }
}

enum ShareImageGenerator {
    private struct TilePayload: Sendable {
        let key: String
        let x: Int
        let y: Int
        let data: Data
    }

    private struct Tile {
        let key: String
        let x: Int
        let y: Int
        let image: UIImage
    }

    private struct MapLayout {
        let coordinates: [CLLocationCoordinate2D]
        let zoom: Int
        let centerX: Double
        let centerY: Double
        let targetCenterY: Double
        let worldScale: Double
    }

    private static let tileCache = NSCache<NSString, UIImage>()

    static func routeSnapshot(
        coordinates: [CLLocationCoordinate2D],
        size: CGSize,
        dark: Bool,
        provider: ShareMapProvider,
        scale: CGFloat = 2
    ) async throws -> UIImage {
        let trimmedCoordinates = privacyTrimmed(coordinates, meters: 600)
        // Match the web map providers: CARTO Leaflet data stays WGS-84;
        // only AMap tiles need the GCJ-02 conversion in mainland China.
        let shareCoordinates = provider == .amap ? mapDisplayCoordinates(trimmedCoordinates) : trimmedCoordinates
        guard shareCoordinates.count > 1 else { return solidImage(size: size, dark: dark, scale: scale) }

        // Keep Leaflet exports aligned with the web Leaflet layer.
        let mapLayout = makeMapLayout(coordinates: shareCoordinates, size: size)
        let cartoKey = provider == .leaflet ? mobileCartoKey() : nil
        if provider == .leaflet && cartoKey == nil {
            throw LocalArchiveError.cartoConfigurationMissing
        }
        let tileJobs = tileJobs(for: mapLayout, size: size, dark: dark, provider: provider, cartoKey: cartoKey)
        guard !tileJobs.isEmpty else { throw LocalArchiveError.mapRenderFailed }
        var tiles = tileJobs.compactMap { job -> Tile? in
            guard let image = tileCache.object(forKey: job.key as NSString) else { return nil }
            return Tile(key: job.key, x: job.x, y: job.y, image: image)
        }
        let missingJobs = tileJobs.filter { tileCache.object(forKey: $0.key as NSString) == nil }
        let payloads = await loadTiles(missingJobs)
        guard payloads.count == missingJobs.count else { throw LocalArchiveError.mapRenderFailed }
        var decodedTileCount = 0
        for payload in payloads {
            guard let image = UIImage(data: payload.data) else { continue }
            tileCache.setObject(image, forKey: payload.key as NSString)
            tiles.append(Tile(key: payload.key, x: payload.x, y: payload.y, image: image))
            decodedTileCount += 1
        }
        guard decodedTileCount == missingJobs.count else { throw LocalArchiveError.mapRenderFailed }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            (dark ? UIColor(red: 0.055, green: 0.07, blue: 0.10, alpha: 1) : UIColor(red: 0.929, green: 0.945, blue: 0.957, alpha: 1)).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))

            let tileSize: CGFloat = 256
            let worldTop = mapLayout.centerY - mapLayout.targetCenterY / mapLayout.worldScale
            for tile in tiles {
                let x = CGFloat((Double(tile.x * 256) - mapLayout.centerX) * mapLayout.worldScale + Double(size.width) / 2)
                let y = CGFloat((Double(tile.y * 256) - mapLayout.centerY) * mapLayout.worldScale + mapLayout.targetCenterY)
                tile.image.draw(in: CGRect(x: x, y: y, width: tileSize * mapLayout.worldScale, height: tileSize * mapLayout.worldScale))
            }
            // Web detailed sharing fades the map before drawing the route.
            // This keeps the background quiet without washing out the line.
            if size.height > size.width * 1.5 {
                let base = dark
                    ? UIColor(red: 0.031, green: 0.047, blue: 0.071, alpha: 1)
                    : UIColor(red: 0.953, green: 0.965, blue: 0.976, alpha: 1)
                let alphaStops: [CGFloat] = [0.92, 0.14, 0.04, 0.18, 0.30, 0.42]
                let locations: [CGFloat] = [0, 0.14, 0.50, 0.64, 0.82, 1]
                let colors = alphaStops.map { base.withAlphaComponent($0).cgColor } as [Any]
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors as CFArray,
                    locations: locations
                ) {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: 0),
                        end: CGPoint(x: 0, y: size.height),
                        options: []
                    )
                }
            }

            let projected = mapLayout.coordinates.map {
                projectedPoint($0, zoom: mapLayout.zoom, centerX: mapLayout.centerX, centerY: mapLayout.centerY, targetCenterY: mapLayout.targetCenterY, worldScale: mapLayout.worldScale, size: size)
            }
            guard projected.count > 1 else { return }
            var path = CGMutablePath()
            path.move(to: projected[0])
            for point in projected.dropFirst() { path.addLine(to: point) }

            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.setStrokeColor((dark ? UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 0.86) : UIColor.white.withAlphaComponent(0.94)).cgColor)
            context.setLineWidth(18)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor((dark ? UIColor(red: 1, green: 0.42, blue: 0.28, alpha: 1) : UIColor(red: 0.88, green: 0.29, blue: 0.16, alpha: 1)).cgColor)
            context.setLineWidth(9)
            context.strokePath()

            let markers: [(CGPoint, UIColor)] = [
                (projected[0], UIColor(red: 0.06, green: 0.72, blue: 0.55, alpha: 1)),
                (projected[projected.count - 1], UIColor(red: 0.88, green: 0.29, blue: 0.16, alpha: 1))
            ]
            for (point, color) in markers {
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
                context.setStrokeColor((dark ? UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 0.9) : UIColor.white).cgColor)
                context.setLineWidth(6)
                context.strokeEllipse(in: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
            }
        }
    }

    private static func solidImage(size: CGSize, dark: Bool, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            (dark ? UIColor(red: 0.055, green: 0.07, blue: 0.10, alpha: 1) : UIColor(red: 0.93, green: 0.95, blue: 0.96, alpha: 1)).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func makeMapLayout(coordinates: [CLLocationCoordinate2D], size: CGSize) -> MapLayout {
        let detailed = size.height > size.width * 1.5
        let fitWidth = Double(size.width) * (detailed ? 0.759 : 0.78)
        let fitHeight = Double(size.height) * (detailed ? 0.375 : 0.39)
        let targetCenterY = Double(size.height) * (detailed ? (830.0 / 2800.0) : 0.36)
        var zoom = 3
        var worldPoints: [(x: Double, y: Double)] = []

        for candidate in stride(from: 17, through: 3, by: -1) {
            let projected = coordinates.map { mercatorPoint($0, zoom: candidate) }
            let xs = projected.map { $0.x }
            let ys = projected.map { $0.y }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            if maxX - minX <= fitWidth && maxY - minY <= fitHeight {
                zoom = candidate
                worldPoints = projected
                break
            }
        }

        if worldPoints.isEmpty { worldPoints = coordinates.map { mercatorPoint($0, zoom: zoom) } }
        let xs = worldPoints.map { $0.x }
        let ys = worldPoints.map { $0.y }
        let spanX = max(xs.max()! - xs.min()!, 1)
        let spanY = max(ys.max()! - ys.min()!, 1)
        let worldScale = min(1.6, min(fitWidth / spanX, fitHeight / spanY))
        return MapLayout(
            coordinates: coordinates,
            zoom: zoom,
            centerX: (xs.min()! + xs.max()!) / 2,
            centerY: (ys.min()! + ys.max()!) / 2,
            targetCenterY: targetCenterY,
            worldScale: max(worldScale, 0.5)
        )
    }

    private static func mercatorPoint(_ coordinate: CLLocationCoordinate2D, zoom: Int) -> (x: Double, y: Double) {
        let worldSize = 256 * pow(2.0, Double(zoom))
        let safeLatitude = max(-85.0511, min(85.0511, coordinate.latitude))
        let sine = sin(safeLatitude * .pi / 180)
        return (
            x: (coordinate.longitude + 180) / 360 * worldSize,
            y: (0.5 - log((1 + sine) / (1 - sine)) / (4 * .pi)) * worldSize
        )
    }

    private static func projectedPoint(
        _ coordinate: CLLocationCoordinate2D,
        zoom: Int,
        centerX: Double,
        centerY: Double,
        targetCenterY: Double,
        worldScale: Double,
        size: CGSize
    ) -> CGPoint {
        let world = mercatorPoint(coordinate, zoom: zoom)
        return CGPoint(
            x: CGFloat((world.x - centerX) * worldScale + Double(size.width) / 2),
            y: CGFloat((world.y - centerY) * worldScale + targetCenterY)
        )
    }

    private static func tileJobs(for layout: MapLayout, size: CGSize, dark: Bool, provider: ShareMapProvider, cartoKey: String?) -> [(key: String, x: Int, y: Int, url: URL)] {
        let tileSize: Double = 256
        let worldLeft = layout.centerX - Double(size.width) / (2 * layout.worldScale)
        let worldRight = layout.centerX + Double(size.width) / (2 * layout.worldScale)
        let worldTop = layout.centerY - layout.targetCenterY / layout.worldScale
        let worldBottom = worldTop + Double(size.height) / layout.worldScale
        let maxTile = 1 << layout.zoom
        let style = dark ? "dark_all" : "light_all"
        let amapStyle = dark ? 8 : 7
        var jobs: [(key: String, x: Int, y: Int, url: URL)] = []

        for tileX in Int(floor(worldLeft / tileSize))...Int(floor(worldRight / tileSize)) {
            for tileY in Int(floor(worldTop / tileSize))...Int(floor(worldBottom / tileSize)) {
                guard tileY >= 0, tileY < maxTile else { continue }
                let wrappedX = ((tileX % maxTile) + maxTile) % maxTile
                let key: String
                let urlString: String
                switch provider {
                case .leaflet:
                    let subdomain = ["a", "b", "c", "d"][(wrappedX + tileY) % 4]
                    guard let cartoKey,
                          let encodedKey = cartoKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { continue }
                    key = "leaflet-carto-\(style)-\(layout.zoom)-\(wrappedX)-\(tileY)"
                    urlString = "https://\(subdomain).basemaps.cartocdn.com/\(style)/\(layout.zoom)/\(wrappedX)/\(tileY)@2x.png?key=\(encodedKey)"
                case .amap:
                    let subdomain = ["1", "2", "3", "4"][(wrappedX + tileY) % 4]
                    key = "amap-\(amapStyle)-\(layout.zoom)-\(wrappedX)-\(tileY)"
                    urlString = "https://webrd0\(subdomain).is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=\(amapStyle)&x=\(wrappedX)&y=\(tileY)&z=\(layout.zoom)"
                }
                guard let url = URL(string: urlString) else { continue }
                jobs.append((key: key, x: tileX, y: tileY, url: url))
            }
        }
        return jobs
    }

    private static func mobileCartoKey() -> String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "CARTOAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static func loadTiles(_ jobs: [(key: String, x: Int, y: Int, url: URL)]) async -> [TilePayload] {
        await withTaskGroup(of: TilePayload?.self) { group in
            for job in jobs {
                group.addTask {
                    var request = URLRequest(url: job.url)
                    request.timeoutInterval = 4
                    request.setValue("RunningArchiveSync/1.0 (personal running archive)", forHTTPHeaderField: "User-Agent")
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return TilePayload(key: job.key, x: job.x, y: job.y, data: data)
                }
            }
            var payloads: [TilePayload] = []
            for await payload in group {
                if let payload { payloads.append(payload) }
            }
            return payloads
        }
    }

    private static func privacyTrimmed(
        _ coordinates: [CLLocationCoordinate2D],
        meters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2, meters > 0 else { return coordinates }
        var cumulative = [CLLocationDistance](repeating: 0, count: coordinates.count)
        for index in 1..<coordinates.count {
            let previous = CLLocation(latitude: coordinates[index - 1].latitude, longitude: coordinates[index - 1].longitude)
            let current = CLLocation(latitude: coordinates[index].latitude, longitude: coordinates[index].longitude)
            cumulative[index] = cumulative[index - 1] + current.distance(from: previous)
        }
        guard let total = cumulative.last, total > meters * 2 else { return [] }
        guard let start = cumulative.firstIndex(where: { $0 >= meters }),
              let end = cumulative.firstIndex(where: { total - $0 <= meters }),
              start < end else { return [] }
        return Array(coordinates[start..<end])
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
