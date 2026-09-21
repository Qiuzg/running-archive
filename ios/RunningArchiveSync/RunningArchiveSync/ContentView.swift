import SwiftUI
import SwiftData

@MainActor
final class HealthSyncViewModel: ObservableObject {
    @Published var previews: [WorkoutPreview] = []
    @Published var selectedIDs: Set<String> = []
    @Published var status = "先授权健康数据，再检查新增跑步。"
    @Published var errorDetails: String?
    @Published var isWorking = false
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? RunningArchiveConfiguration.defaultServerURL
    @Published var token = KeychainStore.read("syncToken")

    private let health = HealthKitService()
    private let api = SyncAPI()
    private let heartRateResyncMigrationKey = "heartRateCondensedSeriesResyncV2"

    func authorizeAndRefresh() async {
        await work("正在请求健康数据权限…") {
            try await health.requestAuthorization()
            let all = try await health.runningWorkoutPreviews()
            var synced = Set(UserDefaults.standard.stringArray(forKey: "syncedWorkoutIDs") ?? [])
            var retryCount = 0
            if !UserDefaults.standard.bool(forKey: heartRateResyncMigrationKey) {
                let cutoff = Calendar.current.date(
                    from: DateComponents(year: 2026, month: 4, day: 26)
                ) ?? .distantPast
                let retryIDs = Set(all.filter { $0.date < cutoff }.map(\.id))
                retryCount = synced.intersection(retryIDs).count
                synced.subtract(retryIDs)
                UserDefaults.standard.set(Array(synced), forKey: "syncedWorkoutIDs")
                UserDefaults.standard.set(true, forKey: heartRateResyncMigrationKey)
            }
            previews = all.filter { !synced.contains($0.id) }
            selectedIDs = Set(previews.prefix(30).map(\.id))
            if previews.isEmpty {
                status = "没有发现未同步的跑步。"
            } else if retryCount > 0 {
                status = "已将 \(retryCount) 条 2026-04-25 及以前的记录列为待重传，已预选最近 \(selectedIDs.count) 条。"
            } else {
                status = "发现 \(previews.count) 条未同步跑步，已预选最近 \(selectedIDs.count) 条。"
            }
        }
    }

    func selectAll() {
        selectedIDs = Set(previews.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func syncSelected() async {
        errorDetails = nil
        guard !serverURL.isEmpty, !token.isEmpty else { status = "请先填写服务器地址和同步令牌。"; return }
        let selected = previews.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { status = "请至少选择一条跑步。"; return }
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        KeychainStore.write(token, account: "syncToken")
        await work("正在读取路线和心率…") {
            var synced = Set(UserDefaults.standard.stringArray(forKey: "syncedWorkoutIDs") ?? [])
            var completed = 0
            var created = 0
            var updated = 0
            var skipped = 0
            var heartRatePoints = 0
            var failures: [String] = []

            for (index, workout) in selected.enumerated() {
                do {
                    status = "正在准备第 \(index + 1)/\(selected.count) 条跑步…"
                    guard let payload = try await health.payload(forWorkoutID: workout.id) else {
                        skipped += 1
                        continue
                    }
                    heartRatePoints += payload.heartRateSamples.count
                    status = "正在上传第 \(index + 1)/\(selected.count) 条跑步（心率 \(payload.heartRateSamples.count) 点）…"
                    let response = try await api.upload([payload], baseURL: serverURL, token: token)
                    let uploadedIDs = Set(response.synced.map(\.id))
                    uploadedIDs.forEach { synced.insert($0) }
                    UserDefaults.standard.set(Array(synced), forKey: "syncedWorkoutIDs")
                    previews.removeAll { uploadedIDs.contains($0.id) }
                    selectedIDs.subtract(uploadedIDs)
                    completed += response.synced.count
                    created += response.synced.filter { $0.status == "created" }.count
                    updated += response.synced.filter { $0.status == "updated" }.count
                } catch {
                    let date = workout.date.formatted(date: .numeric, time: .omitted)
                    failures.append("\(date)：\(error.localizedDescription)")
                }
            }
            let result = "同步完成：\(completed) 条（覆盖 \(updated)，新增 \(created)），读取心率 \(heartRatePoints) 点"
            if let firstFailure = failures.first {
                status = "\(result)，失败 \(failures.count) 条；首个错误：\(firstFailure)"
                errorDetails = failures.joined(separator: "\n\n")
            } else if skipped > 0 {
                status = "\(result)，跳过 \(skipped) 条无法读取的记录。"
            } else {
                status = result
            }
        }
    }

    private func work(_ initialStatus: String, operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorDetails = nil
        status = initialStatus
        do {
            try await operation()
        } catch {
            let message = error.localizedDescription
            status = "失败：\(message)"
            errorDetails = message
        }
        isWorking = false
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var archiveStore = ArchiveStore()
    @StateObject private var appearance = AppearanceStore()
    @StateObject private var navigation = ArchiveNavigationStore()

    var body: some View {
        currentScreen
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ArchiveTabBar(selection: $navigation.selectedTab)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
        .environmentObject(archiveStore)
        .environmentObject(appearance)
        .environmentObject(navigation)
        .preferredColorScheme(appearance.preferredColorScheme)
        .tint(RunTheme.accent)
        .task {
            archiveStore.configureCache(modelContext)
            await archiveStore.load()
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch navigation.selectedTab {
        case .archive:
            DashboardView()
        case .summary:
            SummaryCollectionView()
        case .log:
            NavigationStack { ActivityListView() }
        case .share:
            NavigationStack { ShareStudioView(initialActivity: navigation.shareActivity) }
        case .sync:
            NavigationStack { HealthSyncView() }
        }
    }
}

@MainActor
final class ArchiveNavigationStore: ObservableObject {
    @Published var selectedTab: ArchiveTab = .archive
    @Published var shareActivity: ArchiveActivity?

    func openShare(for activity: ArchiveActivity) {
        shareActivity = activity
        selectedTab = .share
    }
}

enum AppearanceMode: String {
    case system, light, dark
}

@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var mode: AppearanceMode

    init() {
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "system") ?? .system
    }

    var preferredColorScheme: ColorScheme? {
        switch mode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func toggle() {
        mode = mode == .dark ? .light : .dark
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
    }
}

struct ThemeToggleButton: View {
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        Button { appearance.toggle() } label: {
            Image(systemName: appearance.mode == .dark ? "sun.max.fill" : "moon.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RunTheme.accent)
                .frame(width: 32, height: 32)
                .background(RunTheme.accent.opacity(0.11), in: Circle())
        }
        .accessibilityLabel(appearance.mode == .dark ? "切换到日间模式" : "切换到夜间模式")
    }
}

enum ArchiveTab: Int, CaseIterable, Identifiable {
    case archive, summary, log, share, sync

    var id: Self { self }
    var title: String {
        switch self {
        case .archive: "档案"
        case .summary: "汇总"
        case .log: "记录"
        case .share: "分享"
        case .sync: "同步"
        }
    }
    var icon: String {
        switch self {
        case .archive: "map"
        case .summary: "chart.bar"
        case .log: "figure.run"
        case .share: "square.and.arrow.up"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

private struct ArchiveTabBar: View {
    @Binding var selection: ArchiveTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ArchiveTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: selection == tab ? .bold : .medium))
                        Text(tab.title)
                            .font(.caption2.weight(selection == tab ? .bold : .medium))
                    }
                    .foregroundStyle(selection == tab ? RunTheme.accent : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selection == tab ? RunTheme.accent.opacity(0.11) : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

struct HealthSyncView: View {
    @StateObject private var model = HealthSyncViewModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: model.errorDetails == nil ? "checkmark" : "exclamationmark")
                            .font(.headline.weight(.black))
                            .foregroundStyle(model.errorDetails == nil ? Color.green : RunTheme.accent)
                            .frame(width: 30, height: 30)
                            .background(
                                (model.errorDetails == nil ? Color.green : RunTheme.accent).opacity(0.20),
                                in: Circle()
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.errorDetails == nil ? "HealthKit 已准备" : "同步出现错误")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(RunTheme.ink)
                            Text(model.status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    if let errorDetails = model.errorDetails {
                        Divider()
                        DisclosureGroup {
                            Text(errorDetails)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                        } label: {
                            Label("查看完整错误详情", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(RunTheme.accent)
                        }
                    }
                }
                .padding(13)
                .background(
                    (model.errorDetails == nil ? Color.green : RunTheme.accent)
                        .opacity(colorScheme == .dark ? 0.12 : 0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )

                HStack {
                    Text("待同步记录")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(RunTheme.ink)
                    Spacer()
                    Text("已选 \(model.selectedIDs.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(RunTheme.route)
                }

                if model.previews.isEmpty {
                    Text("暂无记录，点击下方按钮检查 Apple Health。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(17)
                        .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.previews) { workout in
                            Button {
                                if model.selectedIDs.contains(workout.id) { model.selectedIDs.remove(workout.id) }
                                else { model.selectedIDs.insert(workout.id) }
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: model.selectedIDs.contains(workout.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(model.selectedIDs.contains(workout.id) ? RunTheme.route : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(workout.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(RunTheme.ink)
                                        Text(String(format: "%.2f km · %@", workout.distanceKm, duration(workout.duration)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(model.selectedIDs.contains(workout.id) ? "路线已读" : "待同步")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(RunTheme.route)
                                }
                                .padding(12)
                                .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("全选") { model.selectAll() }
                        Spacer()
                        Button("取消全选") { model.clearSelection() }
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(RunTheme.route)
                }

                DisclosureGroup {
                    VStack(spacing: 10) {
                        TextField("https://你的域名", text: $model.serverURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .padding(11)
                            .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        SecureField("同步令牌", text: $model.token)
                            .padding(11)
                            .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(.top, 10)
                } label: {
                    Label("服务器设置", systemImage: "server.rack")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(RunTheme.ink)
                }

                Button { Task { await model.syncSelected() } } label: {
                    Text("同步选中的 \(model.selectedIDs.count) 条记录")
                        .font(.subheadline.weight(.black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(RunTheme.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .disabled(model.selectedIDs.isEmpty)
                .opacity(model.selectedIDs.isEmpty ? 0.45 : 1)

                Button("授权并检查新增跑步") { Task { await model.authorizeAndRefresh() } }
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(RunTheme.route)
            }
            .padding(.horizontal, 17)
            .padding(.top, 24)
            .padding(.bottom, 140)
        }
        .background(RunTheme.page)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(RunTheme.page, for: .navigationBar)
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
