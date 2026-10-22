import SwiftUI
import SwiftData

@MainActor
extension HealthSyncViewModel {
    convenience init(archive: ArchiveStore) {
        let api = SyncAPI()
        self.init(defaults: .standard, token: KeychainStore.read("syncToken"), dependencies: HealthSyncDependencies(
            authorize: { try await archive.requestSyncAuthorization() },
            previews: { try await archive.syncWorkoutPreviews() },
            payload: { try await archive.syncWorkoutPayload(id: $0) },
            upload: { try await api.upload([$0], baseURL: $1, token: $2) },
            saveToken: { try KeychainStore.writeChecked($0, account: "syncToken") }
        ))
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var archiveStore = RunningArchiveRuntime.shared.archive
    @StateObject private var appearance = AppearanceStore()
    @StateObject private var navigation = ArchiveNavigationStore()
    @StateObject private var journal = RunningArchiveRuntime.shared.journal
    @StateObject private var training = RunningArchiveRuntime.shared.training

    private var showsBottomBar: Bool { navigation.presentedDetailIDs.isEmpty && !navigation.isEditingShareTitle }

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab("档案", systemImage: "map", value: ArchiveTab.archive) { tabScreen(.archive) }
            Tab("汇总", systemImage: "chart.bar", value: ArchiveTab.summary) { tabScreen(.summary) }
            Tab("记录", systemImage: "figure.run", value: ArchiveTab.log) { tabScreen(.log) }
            Tab("分享", systemImage: "square.and.arrow.up", value: ArchiveTab.share) { tabScreen(.share) }
            Tab("同步", systemImage: "arrow.triangle.2.circlepath", value: ArchiveTab.sync) { tabScreen(.sync) }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .background(RunTheme.page)
        .environmentObject(archiveStore)
        .environmentObject(appearance)
        .environmentObject(navigation)
        .environmentObject(journal)
        .environmentObject(training)
        .environmentObject(RunningArchiveRuntime.shared.analytics)
        .environmentObject(RunningArchiveRuntime.shared.watch)
        .alert("跑步手记", isPresented: Binding(get: { journal.errorMessage != nil }, set: { if !$0 { journal.errorMessage = nil } })) {
            Button("好") { journal.errorMessage = nil }
        } message: { Text(journal.errorMessage ?? "") }
        .preferredColorScheme(appearance.preferredColorScheme)
        .tint(RunTheme.accent)
        .task {
            await archiveStore.configureCache(modelContext)
            RunningArchiveRuntime.shared.startObserving()
            await RunningArchiveRuntime.shared.refresh(authorize: true)
            RunningArchiveRuntime.shared.sync.setForeground(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await RunningArchiveRuntime.shared.refresh(authorize: false)
                    RunningArchiveRuntime.shared.sync.setForeground(scenePhase == .active)
                }
            } else {
                RunningArchiveRuntime.shared.sync.setForeground(false)
                if phase == .background { Task { await RunningArchiveRuntime.shared.analytics.waitForPersistence() } }
            }
        }
    }

    private func tabScreen(_ tab: ArchiveTab) -> some View {
        Group {
            switch tab {
            case .archive: DashboardView()
            case .summary: SummaryCollectionView()
            case .log: NavigationStack { ActivityListView() }
            case .share: NavigationStack { ShareHubView() }
            case .sync: NavigationStack { HealthSyncView() }
            }
        }
        .toolbarVisibility(showsBottomBar ? .automatic : .hidden, for: .tabBar)
    }

}

@MainActor
final class ArchiveNavigationStore: ObservableObject {
    @Published var selectedTab: ArchiveTab = .archive
    @Published var shareActivity: ArchiveActivity?
    @Published var shareScope: ArchiveShareScope = .run
    @Published var isEditingShareTitle = false
    @Published var presentedDetailIDs: Set<String> = []

    func openShare(for activity: ArchiveActivity) {
        shareActivity = activity
        shareScope = .run
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

    func toggle(using colorScheme: ColorScheme) {
        mode = colorScheme == .dark ? .light : .dark
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
    }
}

struct ThemeToggleButton: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { appearance.toggle(using: colorScheme) } label: {
            Image(systemName: colorScheme == .dark ? "sun.max.fill" : "moon.fill")
                .foregroundStyle(.primary)
        }
        .accessibilityLabel(colorScheme == .dark ? "切换到日间模式" : "切换到夜间模式")
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

struct HealthSyncView: View {
    @StateObject private var model = RunningArchiveRuntime.shared.sync
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("同步到网站")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(RunTheme.ink)
                    Text("打开 App 后自动上传新增跑步；更早的历史记录可在这里手动补传。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: model.errorDetails != nil ? "exclamationmark" : (model.hasCheckedHealth ? "checkmark" : "heart.text.square"))
                            .font(.headline.weight(.black))
                            .foregroundStyle(model.errorDetails == nil ? Color.green : RunTheme.accent)
                            .frame(width: 30, height: 30)
                            .background(
                                (model.errorDetails == nil ? Color.green : RunTheme.accent).opacity(0.20),
                                in: Circle()
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.errorDetails != nil ? "同步出现错误" : (model.isWorking ? "正在处理" : (model.hasCheckedHealth ? "HealthKit 已准备" : "等待检查健康数据")))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(RunTheme.ink)
                            Text(model.status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    if let progress = model.syncProgress {
                        ProgressView(value: progress)
                            .tint(RunTheme.accent)
                            .accessibilityLabel("上传进度")
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

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("自动上传新增跑步", isOn: Binding(get: { model.automaticEnabled }, set: { model.setAutomaticEnabled($0) }))
                    Text(model.configured ? "首次补传最近7天。之后离线积压的记录也会继续补传。" : "保存服务器地址和令牌后生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("打开 App、回到前台或收到健康数据变化时检查。刚结束的跑步会等待2分钟；退出 App 后不保证上传，失败会在前台自动重试。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = model.lastSuccess {
                        Text("最近成功：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }.nativeCard()
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
                                    Text(model.selectedIDs.contains(workout.id) ? "已选择" : "未选择")
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
                    .disabled(model.isWorking)
                    Button("保存设置") { model.saveSettings() }.disabled(model.isWorking)
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
                .disabled(model.selectedIDs.isEmpty || model.isWorking)
                .opacity(model.selectedIDs.isEmpty ? 0.45 : 1)

                Button("授权并检查新增跑步") { Task { await model.authorizeAndRefresh() } }
                    .disabled(model.isWorking)
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(RunTheme.route)
            }
            .padding(.horizontal, 17)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .background(RunTheme.page)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("同步")

    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
