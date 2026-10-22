import CoreImage.CIFilterBuiltins
import MapKit
import Photos
import SwiftUI
import UIKit

enum ShareLayout: String, CaseIterable, Identifiable {
    case compact = "图文 3:4"
    case detailed = "竖屏 9:16"
    var id: Self { self }
    var size: CGSize { self == .compact ? CGSize(width: 1080, height: 1440) : CGSize(width: 1080, height: 1920) }
    var mapSize: CGSize { size }
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
    @EnvironmentObject private var navigation: ArchiveNavigationStore
    @Environment(\.colorScheme) private var colorScheme
    let initialActivity: ArchiveActivity?

    @FocusState private var titleIsFocused: Bool
    @State private var selectedID: String?
    @State private var shareTitle: String
    @State private var layout: ShareLayout = .compact
    @State private var mapProvider: ShareMapProvider = .leaflet
    @State private var darkCard = false
    @State private var includeQRCode = false
    @State private var renderedImage: UIImage?
    @State private var isRendering = false
    @State private var showingShareSheet = false
    @State private var showingActivityPicker = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var renderRequested = false
    @State private var renderToken = 0
    @State private var didInitializeAppearance = false

    init(initialActivity: ArchiveActivity? = nil) {
        self.initialActivity = initialActivity
        _selectedID = State(initialValue: initialActivity?.id)
        _shareTitle = State(initialValue: "")
    }

    private var selected: ArchiveActivity? {
        store.activities.first { $0.id == selectedID } ?? initialActivity ?? store.activities.first
    }

    private var selectedRoute: ArchiveRouteSummary? {
        store.routeSummary(id: selected?.routeId)
    }

    private var displayTitle: String {
        let custom = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? (selected?.name ?? "户外跑步") : custom
    }

    private var previewRoute: ArchiveRouteDetail? {
        guard let route = selectedRoute else { return nil }
        return ArchiveRouteDetail(
            id: route.id,
            name: route.name,
            city: route.city,
            distanceKm: route.distanceKm,
            elevationGain: route.elevationGain,
            previewCoordinates: route.previewCoordinates,
            coordinates: route.previewCoordinates,
            elevations: [],
            timeSeries: nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                activitySelector
                controls
                actions
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RunTheme.page)
        .navigationTitle("分享")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { titleIsFocused = false }
                    .accessibilityIdentifier("share.title.done")
            }
        }
        .onChange(of: titleIsFocused) { _, focused in navigation.isEditingShareTitle = focused }
        .onDisappear {
            titleIsFocused = false
            navigation.isEditingShareTitle = false
        }
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
        .onChange(of: includeQRCode) { _, _ in invalidateRenderedImage() }
        .sheet(isPresented: $showingShareSheet) {
            if let renderedImage { ShareSheet(items: [renderedImage]) }
        }
        .sheet(isPresented: $showingActivityPicker) {
            ShareActivityPicker(
                activities: store.activities.filter { store.routeSummary(id: $0.routeId) != nil },
                selectedID: $selectedID
            )
        }
    }

    private var activitySelector: some View {
        Button {
            titleIsFocused = false
            showingActivityPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.run").font(.title3).foregroundStyle(RunTheme.accent)
                    .frame(width: 38, height: 38).background(RunTheme.accent.opacity(0.09), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("跑步记录").font(.caption).foregroundStyle(.secondary)
                    Text(selected.map { $0.date.formatted(.dateTime.year().month().day()) + String(format: " · %.2f km", $0.distanceKm) } ?? "选择想分享的一次跑步")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(14).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let scale = geometry.size.width / layout.size.width
                ZStack(alignment: .topLeading) {
                    if let renderedImage {
                        Image(uiImage: renderedImage).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                    } else if let selected, let previewRoute {
                        ShareCardView(activity: selected, route: previewRoute, mapImage: nil, layout: layout,
                            title: displayTitle, dark: darkCard, includeQRCode: includeQRCode)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    } else {
                        ContentUnavailableView("路线准备中", systemImage: "map")
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    if isRendering {
                        ProgressView("正在生成地图…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.09), radius: 14, y: 5)
            }
            .aspectRatio(layout.size, contentMode: .fit)
            .frame(maxWidth: layout == .compact ? 286 : 238)
            Text(renderedImage == nil ? "预览为轨迹示意 · 生成后显示真实地图" : "图片已生成，可保存或分享")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { titleIsFocused = false }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("图片设置").font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 16) {
                Text("图片版式").font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    layoutOption(.compact, title: "图文", ratio: "3:4")
                    layoutOption(.detailed, title: "竖屏", ratio: "9:16")
                }
                Divider()
                HStack {
                    Label("配色", systemImage: "circle.lefthalf.filled")
                    Spacer(minLength: 24)
                    Picker("配色", selection: $darkCard) {
                        Text("浅色").tag(false)
                        Text("深色").tag(true)
                    }.pickerStyle(.segmented).frame(width: 160)
                }
                Divider()
                HStack {
                    Label("地图", systemImage: "map")
                    Spacer()
                    Picker("地图", selection: $mapProvider) {
                        ForEach(ShareMapProvider.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().tint(RunTheme.route)
                }
            }
            .font(.subheadline).padding(16)
            .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 14) {
                Text("分享标题").font(.subheadline.weight(.medium))
                TextField(selected?.name ?? "户外跑步", text: $shareTitle)
                    .font(.body).padding(12)
                    .background(RunTheme.page, in: RoundedRectangle(cornerRadius: 10))
                    .focused($titleIsFocused).submitLabel(.done)
                    .onSubmit { titleIsFocused = false }
                    .accessibilityIdentifier("share.title")
                Divider()
                Toggle(isOn: $includeQRCode) {
                    Label("档案二维码", systemImage: "qrcode")
                        .font(.subheadline)
                }.tint(RunTheme.accent)
            }
            .padding(16)
            .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        }
        .onChange(of: layout) { _, _ in titleIsFocused = false }
        .onChange(of: darkCard) { _, _ in titleIsFocused = false }
        .onChange(of: mapProvider) { _, _ in titleIsFocused = false }
        .onChange(of: includeQRCode) { _, _ in titleIsFocused = false }
    }

    private func layoutOption(_ option: ShareLayout, title: String, ratio: String) -> some View {
        let selected = layout == option
        return Button {
            titleIsFocused = false
            layout = option
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(selected ? RunTheme.route : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .frame(width: option == .compact ? 20 : 15, height: 26)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(ratio).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? RunTheme.route : Color.secondary.opacity(0.3))
            }
            .foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity)
            .background(selected ? RunTheme.route.opacity(0.07) : RunTheme.page, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? RunTheme.route.opacity(0.55) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                titleIsFocused = false
                renderRequested = true
                renderToken &+= 1
            } label: {
                Label(renderedImage == nil ? "生成分享图片" : "重新生成图片", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(RunTheme.accent)
            .disabled(selectedRoute == nil || isRendering)
            if isRendering {
                Button("取消生成", role: .cancel) {
                    invalidateRenderedImage()
                }
                .buttonStyle(.bordered)
            }
            if renderedImage != nil {
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
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if let noticeMessage {
                Label(noticeMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func selectDefault() {
        if selectedID == nil { selectedID = store.activities.first(where: { $0.routeId != nil })?.id }
        if !didInitializeAppearance {
            darkCard = colorScheme == .dark
            didInitializeAppearance = true
        }
    }

    private func invalidateRenderedImage() {
        renderRequested = false
        renderToken &+= 1
        renderedImage = nil
        errorMessage = nil
        noticeMessage = nil
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
                noticeMessage = "图片已保存到系统相册"
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
        noticeMessage = nil
        defer { isRendering = false }
        do {
            let detail = try await store.routeDetail(id: routeID)
            guard !Task.isCancelled, renderRequested, selectedID == requestedActivityID else { return }
            let mapImage = try await ShareImageGenerator.routeSnapshot(
                coordinates: detail.mapCoordinates,
                size: layout.mapSize,
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
                title: displayTitle,
                dark: darkCard,
                includeQRCode: includeQRCode
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

private struct ShareActivityPicker: View {
    @Environment(\.dismiss) private var dismiss
    let activities: [ArchiveActivity]
    @Binding var selectedID: String?
    @State private var searchText = ""

    private var matches: [ArchiveActivity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return activities }
        return activities.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.city.localizedCaseInsensitiveContains(query)
                || $0.date.formatted(date: .numeric, time: .omitted).contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(matches) { activity in
                Button {
                    selectedID = activity.id
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedID == activity.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedID == activity.id ? RunTheme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.name)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(RunTheme.ink)
                            Text("\(activity.date.formatted(date: .numeric, time: .omitted)) · \(String(format: "%.2f", activity.distanceKm)) km")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "搜索跑步记录")
            .navigationTitle("选择跑步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
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
    let includeQRCode: Bool

    private var background: Color { dark ? Color(red: 0.045, green: 0.09, blue: 0.105) : Color(red: 0.975, green: 0.967, blue: 0.945) }
    private var foreground: Color { dark ? Color(red: 0.94, green: 0.96, blue: 0.94) : Color(red: 0.08, green: 0.15, blue: 0.17) }
    private var accent: Color { Color(red: 0.94, green: 0.34, blue: 0.22) }
    private var tall: Bool { layout == .detailed }
    private var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "户外跑步" : value
    }
    private var thirdMetric: (label: String, value: String, unit: String)? {
        if let heart = activity.avgHeartRate { return ("平均心率", "\(heart)", "bpm") }
        if let cadence = activity.avgCadence, cadence > 0 { return ("平均步频", "\(Int(cadence.rounded()))", "步/分") }
        if let power = activity.avgPower, power > 0 { return ("平均功率", "\(Int(power.rounded()))", "W") }
        if route.elevationGain > 0 { return ("累计爬升", "\(Int(route.elevationGain.rounded()))", "m") }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            mapLayer
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: tall ? 0.10 : 0.13),
                        .init(color: .black, location: tall ? 0.17 : 0.20),
                        .init(color: .black, location: tall ? 0.59 : 0.60),
                        .init(color: .clear, location: tall ? 0.69 : 0.68),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 14) {
                        Circle().fill(accent).frame(width: 10, height: 10)
                        Text("RUNNING ARCHIVE").font(.system(size: 22, weight: .semibold)).tracking(3)
                    }
                    Spacer()
                    Text(activity.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 23, weight: .medium).monospacedDigit())
                        .foregroundStyle(foreground.opacity(0.6))
                }
                .padding(.bottom, tall ? 42 : 33)
                Text(displayTitle)
                    .font(.system(size: tall ? 64 : 57, weight: .semibold))
                    .lineLimit(2).minimumScaleFactor(0.8)
                HStack(spacing: 12) {
                    Text(activity.kind == .race ? "比赛记录" : "户外跑步")
                    if !activity.city.isEmpty { Text("/  \(activity.city)") }
                }
                .font(.system(size: 25)).foregroundStyle(foreground.opacity(0.58))
                .padding(.top, 14)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(String(format: "%.2f", activity.distanceKm))
                        .font(.system(size: tall ? 174 : 154, weight: .medium, design: .rounded))
                        .tracking(-6).lineLimit(1).minimumScaleFactor(0.55)
                    Text("km").font(.system(size: 37, weight: .medium)).foregroundStyle(accent)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, tall ? 36 : 26)
                HStack(alignment: .top, spacing: 24) {
                    metric("平均配速", activity.pace, "/km")
                    metric("运动用时", activity.duration, "")
                    if let thirdMetric { metric(thirdMetric.label, thirdMetric.value, thirdMetric.unit) }
                }
                .padding(.top, 27)
                .overlay(alignment: .top) { Rectangle().fill(foreground.opacity(0.18)).frame(height: 1) }
                HStack(alignment: .bottom) {
                    Text("\(activity.date.formatted(.dateTime.hour().minute()))  /  \(activity.kind == .race ? "RACE" : "RUN")")
                        .font(.system(size: 21, weight: .medium)).tracking(2)
                        .foregroundStyle(foreground.opacity(0.48))
                    Spacer()
                    if includeQRCode, let qr = ShareImageGenerator.qrCode(from: RunningArchiveConfiguration.defaultServerURL) {
                        HStack(spacing: 15) {
                            Text("我的跑步档案").font(.system(size: 19)).foregroundStyle(foreground.opacity(0.6))
                            Image(uiImage: qr).interpolation(.none).resizable().frame(width: 66, height: 66)
                                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
                        }
                    } else {
                        Text("\(activity.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))")
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(foreground.opacity(0.48))
                    }
                }
                .padding(.top, tall ? 48 : 36)
            }
            .padding(.horizontal, 66).padding(.top, 60).padding(.bottom, tall ? 66 : 48)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .clipped().foregroundStyle(foreground)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var mapLayer: some View {
        Group {
            if let mapImage {
                Image(uiImage: mapImage).resizable().frame(width: layout.size.width, height: layout.size.height)
            } else {
                ZStack {
                    background
                    ShareRoutePreview(coordinates: route.mapCoordinates, color: accent, dark: dark)
                        .padding(.horizontal, 50)
                        .frame(height: tall ? 950 : 670)
                        .position(x: layout.size.width / 2, y: tall ? 720 : 570)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func metric(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.system(size: 23)).foregroundStyle(foreground.opacity(0.62))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: tall ? 45 : 41, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 19)).foregroundStyle(foreground.opacity(0.58))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round)
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
    private static let nightTileCache = NSCache<NSString, UIImage>()
    private static let imageContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])

    private static func nightTile(_ image: UIImage, key: String) throws -> UIImage {
        if let cached = nightTileCache.object(forKey: key as NSString) { return cached }
        guard let source = CIImage(image: image) else { throw LocalArchiveError.mapRenderFailed }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = source
        // Invert luminance into a restrained blue-green palette. AMap's numbered
        // tile styles are not a reliable dark basemap; use one source geometry.
        matrix.rVector = CIVector(x: -0.2126 * 0.20, y: -0.7152 * 0.20, z: -0.0722 * 0.20, w: 0)
        matrix.gVector = CIVector(x: -0.2126 * 0.20, y: -0.7152 * 0.20, z: -0.0722 * 0.20, w: 0)
        matrix.bVector = CIVector(x: -0.2126 * 0.20, y: -0.7152 * 0.20, z: -0.0722 * 0.20, w: 0)
        matrix.biasVector = CIVector(x: 0.24, y: 0.29, z: 0.30, w: 0)
        guard let output = matrix.outputImage,
              let cg = imageContext.createCGImage(output, from: source.extent) else { throw LocalArchiveError.mapRenderFailed }
        let result = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
        nightTileCache.setObject(result, forKey: key as NSString)
        return result
    }

    static func routeSnapshot(
        coordinates: [CLLocationCoordinate2D],
        size: CGSize,
        dark: Bool,
        provider: ShareMapProvider,
        scale: CGFloat = 2
    ) async throws -> UIImage {
        // Match the web map providers: CARTO Leaflet data stays WGS-84;
        // only AMap tiles need the GCJ-02 conversion in mainland China.
        let shareCoordinates = provider == .amap ? mapDisplayCoordinates(coordinates) : coordinates
        guard shareCoordinates.count > 1 else { throw LocalArchiveError.routeUnavailable }

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

        if provider == .amap && dark {
            tiles = try tiles.map { tile in
                Tile(key: tile.key, x: tile.x, y: tile.y, image: try nightTile(tile.image, key: tile.key))
            }
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            (dark ? UIColor(red: 0.055, green: 0.07, blue: 0.10, alpha: 1) : UIColor(red: 0.929, green: 0.945, blue: 0.957, alpha: 1)).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))

            let tileSize: CGFloat = 256
            for tile in tiles {
                let x = CGFloat((Double(tile.x * 256) - mapLayout.centerX) * mapLayout.worldScale + Double(size.width) / 2)
                let y = CGFloat((Double(tile.y * 256) - mapLayout.centerY) * mapLayout.worldScale + mapLayout.targetCenterY)
                tile.image.draw(in: CGRect(x: x, y: y, width: tileSize * mapLayout.worldScale, height: tileSize * mapLayout.worldScale))
            }
            // Quiet the basemap only; draw the full-colour route and markers afterwards.
            if !dark {
                context.setFillColor(UIColor(red: 0.975, green: 0.967, blue: 0.945, alpha: 0.22).cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            let projected = mapLayout.coordinates.map {
                projectedPoint($0, zoom: mapLayout.zoom, centerX: mapLayout.centerX, centerY: mapLayout.centerY, targetCenterY: mapLayout.targetCenterY, worldScale: mapLayout.worldScale, size: size)
            }
            guard projected.count > 1 else { return }
            let path = CGMutablePath()
            path.move(to: projected[0])
            for point in projected.dropFirst() { path.addLine(to: point) }

            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            context.setStrokeColor((dark ? UIColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 0.86) : UIColor.white.withAlphaComponent(0.94)).cgColor)
            context.setLineWidth(dark ? 14 : 15)
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

    private static func makeMapLayout(coordinates: [CLLocationCoordinate2D], size: CGSize) -> MapLayout {
        let detailed = size.height > size.width * 1.5
        let fitWidth = Double(size.width) * 0.76
        let fitHeight = detailed ? 780.0 : 520.0
        let targetCenterY = detailed ? 720.0 : 570.0
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
            worldScale: worldScale
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
        let amapStyle = 7
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
