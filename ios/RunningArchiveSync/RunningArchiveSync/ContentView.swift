import SwiftUI

@MainActor
final class HealthSyncViewModel: ObservableObject {
    @Published var previews: [WorkoutPreview] = []
    @Published var selectedIDs: Set<String> = []
    @Published var status = "先授权健康数据，再检查新增跑步。"
    @Published var isWorking = false
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published var token = KeychainStore.read("syncToken")

    private let health = HealthKitService()
    private let api = SyncAPI()

    func authorizeAndRefresh() async {
        await work("正在请求健康数据权限…") {
            try await health.requestAuthorization()
            let all = try await health.runningWorkoutPreviews()
            let synced = Set(UserDefaults.standard.stringArray(forKey: "syncedWorkoutIDs") ?? [])
            previews = all.filter { !synced.contains($0.id) }
            selectedIDs = Set(previews.map(\.id))
            status = previews.isEmpty ? "没有发现未同步的跑步。" : "发现 \(previews.count) 条未同步跑步。"
        }
    }

    func syncSelected() async {
        guard !serverURL.isEmpty, !token.isEmpty else { status = "请先填写服务器地址和同步令牌。"; return }
        let ids = selectedIDs
        guard !ids.isEmpty else { status = "请至少选择一条跑步。"; return }
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        KeychainStore.write(token, account: "syncToken")
        await work("正在读取路线和心率…") {
            var payloads: [WorkoutPayload] = []
            for (index, id) in ids.enumerated() {
                status = "正在准备第 \(index + 1)/\(ids.count) 条跑步…"
                if let payload = try await health.payload(forWorkoutID: id) { payloads.append(payload) }
            }
            status = "正在上传 \(payloads.count) 条跑步…"
            let response = try await api.upload(payloads, baseURL: serverURL, token: token)
            var synced = Set(UserDefaults.standard.stringArray(forKey: "syncedWorkoutIDs") ?? [])
            response.synced.forEach { synced.insert($0.id) }
            UserDefaults.standard.set(Array(synced), forKey: "syncedWorkoutIDs")
            previews.removeAll { synced.contains($0.id) }
            selectedIDs.removeAll()
            status = "同步完成：\(response.synced.count) 条。"
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
    @StateObject private var model = HealthSyncViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("https://你的域名", text: $model.serverURL)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("同步令牌", text: $model.token)
                }
                Section("待同步跑步") {
                    if model.previews.isEmpty {
                        Text("暂无记录").foregroundStyle(.secondary)
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
            .navigationTitle("Running Archive")
            .disabled(model.isWorking)
            .overlay { if model.isWorking { ProgressView().controlSize(.large) } }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
