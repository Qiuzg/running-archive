import Charts
import Photos
import SwiftUI

enum ArchiveShareScope: String, CaseIterable {
    case run = "单次", month = "月度", year = "年度"
}

struct ShareHubView: View {
    @EnvironmentObject private var navigation: ArchiveNavigationStore
    @EnvironmentObject private var archive: ArchiveStore
    var body: some View {
        Group {
            switch navigation.shareScope {
            case .run: ShareStudioView(initialActivity: navigation.shareActivity)
            case .month:
                MonthlyReviewView(month: Calendar.current.dateInterval(of: .month, for: archive.activities.map(\.date).max() ?? .now)!.start)
            case .year: YearlyReviewView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("分享范围", selection: $navigation.shareScope) {
                ForEach(ArchiveShareScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 10)
                .background(RunTheme.page)
        }
    }
}

struct YearlyReviewView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State var year = Calendar.current.component(.year, from: .now)
    @State private var sharing = false
    @State private var openedMonth: Date?
    private var report: YearlyReport { YearlyReport(year: year, activities: store.activities) }
    private var years: [Int] { Array(Set(store.activities.map { Calendar.current.component(.year, from: $0.date) })).sorted(by: >) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("年度统计").font(.title.bold())
                    Spacer()
                    Menu {
                        ForEach(years.isEmpty ? [year] : years, id: \.self) { value in Button(String(value)) { year = value } }
                    } label: { Label(String(year), systemImage: "calendar") }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(format: "%.1f km", report.distance)).font(.system(size: 38, weight: .bold)).foregroundStyle(RunTheme.route)
                    LabeledContent("跑步次数", value: "\(report.activities.count) 次")
                    LabeledContent("累计用时", value: report.durationText)
                    LabeledContent("平均配速", value: report.paceText + " /km")
                    LabeledContent("跑步天数", value: "\(report.activeDays) 天")
                    if let longest = report.longest {
                        NavigationLink(value: longest) {
                            LabeledContent("最长一次", value: String(format: "%.2f km", longest.distanceKm))
                        }
                    }
                    Text(report.cutoffText).font(.caption).foregroundStyle(.secondary)
                }.nativeCard()
                VStack(alignment: .leading, spacing: 12) {
                    Text("月跑量").font(.headline)
                    ForEach(report.months, id: \.key) { month in
                        Button { openedMonth = month.start } label: {
                            HStack(spacing: 14) {
                                Text("\(month.monthNumber) 月").frame(width: 40, alignment: .leading).foregroundStyle(.primary)
                                GeometryReader { geometry in
                                    Capsule().fill(RunTheme.route.opacity(0.1))
                                    Capsule().fill(RunTheme.route).frame(width: geometry.size.width * month.distance / max(report.months.map(\.distance).max() ?? 1, 1))
                                }.frame(height: 8)
                                Text(String(format: "%.1f km", month.distance)).monospacedDigit()
                                    .frame(width: 85, alignment: .trailing).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.font(.subheadline).padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                }.nativeCard()
                Button { sharing = true } label: {
                    Label("分享 \(String(year)) 年跑步数据", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(report.activities.isEmpty)
            }.padding(16)
        }
        .background(RunTheme.page).navigationTitle("年度统计").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }.disabled(report.activities.isEmpty)
        } }
        .onAppear { if !years.contains(year) { year = years.first ?? year } }
        .navigationDestination(item: $openedMonth) { MonthlyReviewView(month: $0) }
        .sheet(isPresented: $sharing) { YearlyShareView(report: report) }
    }
}

struct YearlyPoster: View {
    let report: YearlyReport
    let dark: Bool
    private var ink: Color { dark ? Color(red: 0.94, green: 0.96, blue: 0.94) : Color(red: 0.08, green: 0.15, blue: 0.17) }
    private var paper: Color { dark ? Color(red: 0.045, green: 0.09, blue: 0.105) : Color(red: 0.975, green: 0.967, blue: 0.945) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle().fill(RunTheme.accent).frame(width: 10, height: 10)
                Text("RUNNING ARCHIVE").font(.system(size: 22, weight: .semibold)).tracking(3)
                Spacer()
                Text("年度跑步").font(.system(size: 24))
            }.foregroundStyle(ink.opacity(0.75))
            Text(String(report.year)).font(.system(size: 76, weight: .bold)).padding(.top, 50)
            Text(report.cutoffText).font(.system(size: 24)).foregroundStyle(ink.opacity(0.58)).padding(.top, 12)
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(String(format: "%.1f", report.distance)).font(.system(size: 138, weight: .bold, design: .rounded)).tracking(-5)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("km").font(.system(size: 38, weight: .medium)).foregroundStyle(RunTheme.accent)
            }.padding(.top, 35)
            HStack {
                posterMetric("跑步次数", "\(report.activities.count) 次")
                posterMetric("累计用时", report.durationText)
                posterMetric("平均配速", report.paceText + " /km")
            }.padding(.top, 30)
            Rectangle().fill(ink.opacity(0.15)).frame(height: 1).padding(.top, 35)
            Text("每月跑量 · km").font(.system(size: 24, weight: .medium)).foregroundStyle(ink.opacity(0.6)).padding(.top, 35)
            HStack(alignment: .bottom, spacing: 15) {
                ForEach(report.months, id: \.key) { month in
                    VStack(spacing: 14) {
                        Text(month.distance > 0 ? String(format: "%.0f", month.distance) : "").font(.system(size: 18, weight: .medium))
                            .foregroundStyle(ink.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.65)
                        RoundedRectangle(cornerRadius: 9).fill(RunTheme.route.opacity(month.distance > 0 ? 1 : 0.15))
                            .frame(height: max(4, 380 * month.distance / max(report.months.map(\.distance).max() ?? 1, 1)))
                        Text("\(month.monthNumber)").font(.system(size: 22, weight: .medium)).foregroundStyle(ink.opacity(0.55))
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 460, alignment: .bottom)
            Spacer(minLength: 30)
            HStack {
                Text("\(report.activeDays) 个跑步日").font(.system(size: 27, weight: .medium))
                Spacer()
                if let longest = report.longest {
                    Text(String(format: "最长单次 %.2f km", longest.distanceKm)).font(.system(size: 27, weight: .medium))
                }
            }.foregroundStyle(ink.opacity(0.7))
        }.padding(64).frame(width: 1080, height: 1440).foregroundStyle(ink).background(paper)
    }
    private func posterMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 23)).foregroundStyle(ink.opacity(0.6))
            Text(value).font(.system(size: 30, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct YearlyShareView: View {
    @Environment(\.dismiss) private var dismiss
    let report: YearlyReport
    @State private var dark = false
    @State private var image: UIImage?
    @State private var showingShare = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("配色", selection: $dark) { Text("暖白").tag(false); Text("深色").tag(true) }.pickerStyle(.segmented)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    } else { ProgressView().frame(height: 300) }
                    Text("3:4 年度海报 · \(report.cutoffText)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            guard let image else { return }
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await saveReportImage(image); message = "年度海报已保存到相册。" }
                                catch { message = error.localizedDescription }
                            }
                        } label: { Label("保存相册", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(image == nil || saving)
                        Button { showingShare = true } label: { Label("分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).disabled(image == nil)
                    }
                }.padding(20)
            }.background(RunTheme.page).navigationTitle("分享年度数据").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: dark) {
                    image = nil
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    let renderer = ImageRenderer(content: YearlyPoster(report: report, dark: dark))
                    renderer.scale = 1.5
                    image = renderer.uiImage
                    if image == nil { message = "图片生成失败，请重试。" }
                }
                .sheet(isPresented: $showingShare) { if let image { ShareSheet(items: [image]) } }
                .alert("年度分享", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("好") { message = nil }
                } message: { Text(message ?? "") }
        }
    }
}

@MainActor
private func saveReportImage(_ image: UIImage) async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
        throw AITrainingError.invalid("请在系统设置中允许添加照片，然后重试。")
    }
    try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
}
