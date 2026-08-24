import SwiftUI

@MainActor
final class HealthSyncViewModel: ObservableObject {
    @Published var previews: [WorkoutPreview] = []
    @Published var selectedIDs: Set<String> = []
    @Published var status = "先授权健康数据，再检查新增跑步。"
    @Published var isWorking = false
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ArchiveAPI.defaultBaseURL
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
        status = initialStatus
        do { try await operation() } catch { status = "失败：\(error.localizedDescription)" }
        isWorking = false
    }
}

struct ContentView: View {
    @StateObject private var archiveStore = ArchiveStore()

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("档案", systemImage: "map.fill") }
            NavigationStack { ActivityListView() }
                .tabItem { Label("记录", systemImage: "figure.run") }
            NavigationStack { ShareStudioView() }
                .tabItem { Label("分享", systemImage: "photo.on.rectangle.angled") }
            NavigationStack { HealthSyncView() }
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
        }
        .environmentObject(archiveStore)
        .tint(RunTheme.accent)
    }
}

struct HealthSyncView: View {
    @StateObject private var model = HealthSyncViewModel()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Apple Health 同步", systemImage: "heart.fill")
                        .font(.title3.bold()).foregroundStyle(RunTheme.accent)
                    Text("从这台 iPhone 读取 Apple Watch 跑步，并安全上传到你的个人档案。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
            Section("服务器") {
                TextField("https://你的域名", text: $model.serverURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("同步令牌", text: $model.token)
            }
            Section("待同步跑步（\(model.previews.count)）") {
                if model.previews.isEmpty {
                    Text("暂无记录").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("全选") { model.selectAll() }
                        Spacer()
                        Button("取消全选") { model.clearSelection() }
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(model.previews) { workout in
                    Button {
                        if model.selectedIDs.contains(workout.id) { model.selectedIDs.remove(workout.id) }
                        else { model.selectedIDs.insert(workout.id) }
                    } label: {
                        HStack {
                            Image(systemName: model.selectedIDs.contains(workout.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(workout.date.formatted(date: .abbreviated, time: .shortened))
                                Text(String(format: "%.2f km · %@", workout.distanceKm, duration(workout.duration)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            Section {
                Button("授权并检查新增跑步") { Task { await model.authorizeAndRefresh() } }
                Button("同步所选记录（\(model.selectedIDs.count)）") { Task { await model.syncSelected() } }
                    .disabled(model.selectedIDs.isEmpty)
            }
            Section("状态") { Text(model.status).foregroundStyle(.secondary) }
        }
        .navigationTitle("数据同步")
        .disabled(model.isWorking)
        .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
