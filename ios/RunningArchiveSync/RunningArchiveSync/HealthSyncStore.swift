import Combine
import Foundation

@MainActor
struct HealthSyncDependencies {
    var authorize: () async throws -> Void
    var previews: () async throws -> [WorkoutPreview]
    var payload: (String) async throws -> WorkoutPayload?
    var upload: (WorkoutPayload, String, String) async throws -> SyncResponse
    var saveToken: (String) throws -> Void
}

/// One owner for foreground checks, HealthKit notifications and manual backfills.
@MainActor
final class HealthSyncViewModel: ObservableObject {
    @Published var previews: [WorkoutPreview] = []
    @Published var selectedIDs: Set<String> = []
    @Published var status = "打开 App 后自动检查最近的跑步；请先保存服务器设置。"
    @Published var errorDetails: String?
    @Published private(set) var isWorking = false
    @Published private(set) var hasCheckedHealth = false
    @Published private(set) var syncProgress: Double?
    @Published var serverURL: String
    @Published var token: String
    @Published private(set) var automaticEnabled: Bool
    @Published private(set) var lastSuccess: Date?
    private let defaults: UserDefaults
    private let dependencies: HealthSyncDependencies
    private let now: () -> Date
    private var savedURL: String
    private var savedToken: String
    private var automaticTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var automaticQueued = false
    private var foreground = false
    private var nextCheck = Date.distantPast
    private var retryAfter = Date.distantPast
    private var failureCount = 0

    init(defaults: UserDefaults, token: String, dependencies: HealthSyncDependencies, now: @escaping () -> Date = { .now }) {
        self.defaults = defaults
        self.dependencies = dependencies
        self.now = now
        savedURL = defaults.string(forKey: "serverURL") ?? RunningArchiveConfiguration.defaultServerURL
        serverURL = savedURL
        savedToken = token
        self.token = token
        automaticEnabled = defaults.object(forKey: "automaticWorkoutSync") as? Bool ?? true
        lastSuccess = nil
        lastSuccess = defaults.object(forKey: "lastWorkoutSync." + scope) as? Date
        _ = syncedIDs()
    }

    var configured: Bool { !savedToken.isEmpty && (try? SyncAPI.endpoint(baseURL: savedURL)) != nil }

    @discardableResult func saveSettings(schedule: Bool = true) -> Bool {
        guard !isWorking else { return false }
        do {
            let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try SyncAPI.endpoint(baseURL: url)
            let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw SyncAPIError.server(0, "请填写同步令牌") }
            try dependencies.saveToken(secret)
            let endpointChanged = (try SyncAPI.endpoint(baseURL: url)) != (try? SyncAPI.endpoint(baseURL: savedURL))
            savedURL = url
            if endpointChanged { lastSuccess = defaults.object(forKey: "lastWorkoutSync." + scope) as? Date }
            savedToken = secret
            defaults.set(url, forKey: "serverURL")
            serverURL = url
            token = secret
            errorDetails = nil
            status = "设置已保存。自动同步首次补传最近7天，更早记录可手动选择。"
            retryAfter = .distantPast
            nextCheck = .distantPast
            if schedule { requestAutomaticCheck(changed: true) }
            return true
        } catch { report(error); return false }
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        automaticEnabled = enabled
        defaults.set(enabled, forKey: "automaticWorkoutSync")
        if enabled { requestAutomaticCheck(changed: true) }
        else { automaticQueued = false; wakeTask?.cancel(); wakeTask = nil }
        // An in-flight server acknowledgement is still committed. Stop before the next record.
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active { requestAutomaticCheck(changed: true) }
        else { wakeTask?.cancel(); wakeTask = nil }
    }

    func networkRecovered() {
        wakeTask?.cancel(); wakeTask = nil
        retryAfter = .distantPast
        requestAutomaticCheck(changed: true)
    }

    func requestAutomaticCheck(changed: Bool = false) {
        guard foreground, automaticEnabled, configured else { return }
        if changed { nextCheck = .distantPast }
        guard now() >= retryAfter else { scheduleWake(at: retryAfter); return }
        guard now() >= nextCheck else { return }
        if isWorking || automaticTask != nil { automaticQueued = true; return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            await self.checkAutomatically()
            self.automaticTask = nil
            if self.automaticQueued {
                self.automaticQueued = false
                self.requestAutomaticCheck(changed: true)
            }
        }
    }

    private func scheduleWake(at date: Date) {
        guard foreground, automaticEnabled else { return }
        wakeTask?.cancel()
        let delay = max(1, date.timeIntervalSince(now()))
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.requestAutomaticCheck(changed: true)
        }
    }

    private var scope: String { (try? SyncAPI.endpoint(baseURL: savedURL).absoluteString) ?? savedURL }
    private var ledgerKey: String { "syncedWorkoutIDs.v3." + scope }
    private var verificationKey: String { "workoutSyncVerification." + scope }
    private var verifications: [String: Date] { defaults.dictionary(forKey: verificationKey) as? [String: Date] ?? [:] }
    private var cutoffKey: String { "automaticWorkoutSyncStart." + scope }
    private func syncedIDs() -> Set<String> {
        if defaults.object(forKey: ledgerKey) == nil {
            // Bind the old global ledger once, to the server it was actually used with.
            if defaults.string(forKey: "legacySyncLedgerOwner") == nil {
                defaults.set(scope, forKey: "legacySyncLedgerOwner")
                defaults.set(defaults.stringArray(forKey: "syncedWorkoutIDs") ?? [], forKey: ledgerKey)
            }
        }
        return Set(defaults.stringArray(forKey: ledgerKey) ?? [])
    }
    private func pending() async throws -> [WorkoutPreview] {
        let all = try await dependencies.previews()
        var synced = syncedIDs()
        if !defaults.bool(forKey: "heartRateCondensedSeriesResyncV2") {
            let cutoff = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 26)) ?? .distantPast
            synced.subtract(all.filter { $0.date < cutoff }.map(\.id))
            defaults.set(Array(synced), forKey: ledgerKey)
            defaults.set(true, forKey: "heartRateCondensedSeriesResyncV2")
        }
        hasCheckedHealth = true
        let due = verifications
        let time = now()
        let result = all.filter { !synced.contains($0.id) || (due[$0.id].map { $0 <= time } ?? false) }.sorted { $0.date > $1.date }
        previews = result
        selectedIDs.formIntersection(Set(result.map(\.id)))
        return result
    }

    private func checkAutomatically() async {
        await work("正在检查新增跑步…") {
            let time = now()
            // Persist a fixed lower bound so an offline workout never ages out of a sliding 7-day window.
            let start = defaults.object(forKey: cutoffKey) as? Date ?? Calendar.current.date(byAdding: .day, value: -7, to: time)!
            defaults.set(start, forKey: cutoffKey)
            let all = try await pending().filter { $0.date >= start && $0.date <= time }
            let ready = all.filter { ($0.endDate ?? $0.date.addingTimeInterval($0.duration)).addingTimeInterval(120) <= time }
            if ready.isEmpty { status = all.isEmpty ? "没有新增跑步需要上传。更早记录可手动补传。" : "跑步刚结束，等待健康数据写入后自动上传…" }
            else { try await upload(ready, automatic: true) }
            nextCheck = time.addingTimeInterval(60)
            if ready.count < all.count { scheduleWake(at: time.addingTimeInterval(120)) }
            else if let due = verifications.values.filter({ $0 > time }).min() { scheduleWake(at: due) }
        }
    }

    func authorizeAndRefresh() async {
        await work("正在请求健康数据权限…") {
            try await dependencies.authorize()
            let all = try await pending()
            selectedIDs = Set(all.prefix(30).map(\.id))
            status = all.isEmpty ? "没有发现未同步的跑步。" : "发现 \(all.count) 条未同步跑步，已预选最近 \(selectedIDs.count) 条。"
        }
    }
    func selectAll() { selectedIDs = Set(previews.map(\.id)) }
    func clearSelection() { selectedIDs.removeAll() }
    func syncSelected() async {
        guard !isWorking else { return }
        guard saveSettings(schedule: false) else { return }
        let selected = previews.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { status = "请至少选择一条跑步。"; return }
        await work("正在读取路线和心率…") { try await upload(selected, automatic: false) }
    }

    private func upload(_ workouts: [WorkoutPreview], automatic: Bool) async throws {
        let url = savedURL, secret = savedToken, key = ledgerKey
        let verificationStorage = verificationKey
        var verification = verifications
        var synced = syncedIDs(), completed = 0, created = 0, updated = 0, heartRatePoints = 0
        var failures: [String] = []
        for (index, workout) in workouts.enumerated() {
            if automatic && (!automaticEnabled || !foreground) { break }
            try Task.checkCancellation()
            syncProgress = Double(index) / Double(workouts.count)
            status = "\(automatic ? "自动上传" : "上传")第 \(index + 1)/\(workouts.count) 条跑步…"
            var attemptedUpload = false
            do {
                guard let payload = try await dependencies.payload(workout.id) else { throw SyncAPIError.server(0, "暂时无法读取运动，稍后重试") }
                if automatic && (!automaticEnabled || !foreground) { break }
                attemptedUpload = true
                let response = try await dependencies.upload(payload, url, secret)
                guard let acknowledgement = response.synced.first(where: { $0.id == workout.id && ["created", "updated"].contains($0.status) }) else {
                    throw SyncAPIError.server(0, "服务器未确认该跑步已保存")
                }
                // HealthKit route/sample delivery can lag the workout. Re-read recent uploads once after 15 minutes.
                // Persist the due date so terminating the app cannot lose this finalization pass.
                if verification[workout.id] != nil { verification.removeValue(forKey: workout.id) }
                else if !synced.contains(workout.id), now().timeIntervalSince(workout.endDate ?? workout.date.addingTimeInterval(workout.duration)) < 86400 {
                    verification[workout.id] = now().addingTimeInterval(900)
                }
                defaults.set(verification, forKey: verificationStorage)
                synced.insert(workout.id)
                defaults.set(Array(synced), forKey: key)
                previews.removeAll { $0.id == workout.id }
                selectedIDs.remove(workout.id)
                completed += 1
                if acknowledgement.status == "created" { created += 1 } else { updated += 1 }
                heartRatePoints += payload.heartRateSamples.count
                lastSuccess = now()
                defaults.set(lastSuccess, forKey: "lastWorkoutSync." + scope)
            } catch {
                failures.append(workout.date.formatted(date: .numeric, time: .omitted) + "：" + error.localizedDescription)
                if automatic && attemptedUpload { break } // Do not flood an unavailable or unauthorized server.
            }
        }
        status = "\(automatic ? "自动同步" : "同步")完成 \(completed) 条（新增 \(created)，覆盖 \(updated)），心率 \(heartRatePoints) 点。"
        if !failures.isEmpty { throw SyncAPIError.server(0, failures.joined(separator: "\n")) }
        failureCount = 0
        retryAfter = .distantPast
        if automatic && !automaticEnabled { status += "自动同步已关闭。" }
        if let due = verification.values.filter({ $0 > now() }).min() { scheduleWake(at: due) }
    }
    private func report(_ error: Error) {
        errorDetails = error.localizedDescription
        status = "同步未完成，已成功的记录已保留；可手动重试。"
    }
    private func work(_ message: String, operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true; errorDetails = nil; status = message
        defer {
            syncProgress = nil; isWorking = false
            if automaticTask == nil, automaticQueued {
                automaticQueued = false
                requestAutomaticCheck(changed: true)
            }
        }
        do { try await operation() }
        catch {
            report(error)
            failureCount += 1
            retryAfter = now().addingTimeInterval(min(3600, 60 * pow(2, Double(min(failureCount - 1, 6)))))
            scheduleWake(at: retryAfter)
        }
    }
}
