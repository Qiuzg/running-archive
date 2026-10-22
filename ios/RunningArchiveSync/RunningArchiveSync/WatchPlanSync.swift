import Foundation
import Combine
import CryptoKit

struct WatchScheduledEntry {
    var id: UUID
    var date: DateComponents
    var complete: Bool
    var data: Data
    var day: String? {
        guard let y = date.year, let m = date.month, let d = date.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

@MainActor
protocol WatchWorkoutTransport {
    var isSupported: Bool { get }
    var maximumCount: Int { get }
    func authorize(request: Bool) async -> Bool
    func entries() async -> [WatchScheduledEntry]
    func prepare(_ session: AITrainingSession, id: UUID) throws -> Data
    func equivalent(_ lhs: Data, _ rhs: Data) throws -> Bool
    func schedule(data: Data, date: DateComponents) async throws
    func remove(_ entry: WatchScheduledEntry) async throws
}

struct WatchSyncPreferences: Codable {
    var automaticUpdates = false
    var hasConfigured: Bool? = nil
}

/// Reconciles only this feature's deterministic IDs. No bulk deletion or random IDs on retries.
@MainActor
final class WatchPlanSyncStore: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var automaticUpdates = false
    @Published private(set) var hasConfigured = false
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    private let transport: any WatchWorkoutTransport
    private let fileURL: URL
    private var readable = true
    private var queued: Input?

    struct Input {
        var sessions: [AITrainingSession]
        var completed: Set<String>
        var requestAuthorization: Bool
        var now: Date
        var calendar: Calendar
    }

    var isSupported: Bool { transport.isSupported }

    init(transport: any WatchWorkoutTransport, fileURL: URL? = nil) {
        self.transport = transport
        self.fileURL = fileURL ?? URL.applicationSupportDirectory.appending(path: "RunningArchive/watch-sync-v1.json")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let saved = try JSONDecoder().decode(WatchSyncPreferences.self, from: Data(contentsOf: self.fileURL))
                automaticUpdates = saved.automaticUpdates
                hasConfigured = saved.hasConfigured ?? true
            }
        } catch {
            readable = false
            errorMessage = "手表同步设置无法读取，已保留原文件。"
        }
    }

    static func identifier(for day: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("running-archive.watch-plan.v1|" + day).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUID v8: application-defined SHA-256 identifier.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func setAutomaticUpdates(_ value: Bool) throws {
        guard readable else { throw AITrainingError.invalid("手表同步设置无法读取，请先备份检查。") }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(WatchSyncPreferences(automaticUpdates: value, hasConfigured: true))
            .write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        automaticUpdates = value
        hasConfigured = true
        if !value { queued = nil; status = "已关闭自动同步，手表已有安排保留" }
    }

    func sync(sessions: [AITrainingSession], completed: Set<String>, requestAuthorization: Bool = false,
              now: Date = .now, calendar: Calendar = AIDate.localCalendar) async {
        guard requestAuthorization || automaticUpdates || isWorking else { return }
        let input = Input(sessions: sessions, completed: completed, requestAuthorization: requestAuthorization, now: now, calendar: calendar)
        // Actor reentrancy: the newest plan must be reconciled after an in-flight older plan.
        if isWorking { queued = input; return }
        isWorking = true
        defer { isWorking = false }
        var next: Input? = input
        while let input = next {
            queued = nil
            do { try await reconcile(input) }
            catch { errorMessage = error.localizedDescription; status = "同步未完成，可重试" }
            next = queued
            if input.requestAuthorization { next?.requestAuthorization = true }
        }
    }

    private func reconcile(_ input: Input) async throws {
        guard readable else { throw AITrainingError.invalid("手表同步设置无法读取，请先备份检查。") }
        guard transport.isSupported else {
            throw AITrainingError.invalid("当前设备不支持训练同步，请在已配对 Apple Watch 的 iPhone 上操作。")
        }
        guard await transport.authorize(request: input.requestAuthorization) else {
            throw AITrainingError.invalid("尚未允许同步训练，请在 iPhone 的 Watch App → 体能训练中检查本 App 的权限。")
        }
        let today = input.calendar.startOfDay(for: input.now)
        let end = input.calendar.date(byAdding: .day, value: 7, to: today)!
        let existing = await transport.entries()
        guard Set(input.sessions.map(\.date)).count == input.sessions.count else {
            throw AITrainingError.invalid("计划中有重复日期，请调整后再同步；手表原安排已保留。")
        }
        let completedDays = input.completed.union(existing.filter { entry in
            guard entry.complete, let key = entry.day else { return false }
            return entry.id == Self.identifier(for: key)
        }.compactMap(\.day))
        var desired: [WatchScheduledEntry] = []
        // Prepare and validate EVERY workout before removing anything from the existing schedule.
        for session in input.sessions {
            guard let day = AIDate.parse(session.date, calendar: input.calendar) else {
                throw AITrainingError.invalid("计划日期无效，手表原安排已保留。")
            }
            guard day >= today, day <= end,
                  session.kind != .rest, !completedDays.contains(session.date) else { continue }
            guard !desired.contains(where: { $0.day == session.date }) else {
                throw AITrainingError.invalid("同一天有重复训练，请先调整计划。")
            }
            let id = Self.identifier(for: session.date)
            desired.append(WatchScheduledEntry(id: id,
                date: input.calendar.dateComponents([.calendar, .year, .month, .day], from: day), complete: false,
                data: try transport.prepare(session, id: id)))
        }
        func matches(_ a: WatchScheduledEntry, _ b: WatchScheduledEntry) throws -> Bool {
            guard a.id == b.id, a.day == b.day else { return false }
            return try transport.equivalent(a.data, b.data)
        }
        var removals: [WatchScheduledEntry] = []
        for entry in existing where !entry.complete {
            guard let key = entry.day, let day = AIDate.parse(key, calendar: input.calendar), day >= today,
                  entry.id == Self.identifier(for: key) else { continue }
            if existing.filter({ $0.id == entry.id && $0.day == key }).count == 1,
               let replacement = desired.first(where: { $0.id == entry.id }), try matches(entry, replacement) { continue }
            removals.append(entry)
        }
        let additions = try desired.filter { candidate in
            if removals.contains(where: { $0.id == candidate.id }) { return true }
            return try !existing.contains { try matches($0, candidate) }
        }
        guard existing.count - removals.count + additions.count <= transport.maximumCount else {
            throw AITrainingError.invalid("手表已安排的训练达到系统上限，请先清理不需要的安排再重试。")
        }
        if input.requestAuthorization, !hasConfigured { try setAutomaticUpdates(true) }
        errorMessage = nil
        status = "正在更新 Apple Watch 训练…"
        for old in removals { try Task.checkCancellation(); try await transport.remove(old) }
        if !removals.isEmpty {
            var remaining = await transport.entries()
            for _ in 0..<3 {
                if !remaining.contains(where: { entry in removals.contains { $0.id == entry.id && $0.date == entry.date } }) { break }
                try await Task.sleep(for: .milliseconds(250))
                remaining = await transport.entries()
            }
            guard !remaining.contains(where: { entry in removals.contains { $0.id == entry.id && $0.date == entry.date } }) else {
                throw AITrainingError.invalid("系统尚未确认旧安排已移除，请稍后重试；未重复添加课程。")
            }
        }
        for new in additions { try Task.checkCancellation(); try await transport.schedule(data: new.data, date: new.date) }
        var confirmed = await transport.entries()
        for _ in 0..<3 {
            if try desired.allSatisfy({ expected in try confirmed.contains { try matches($0, expected) } }) { break }
            try await Task.sleep(for: .milliseconds(250))
            confirmed = await transport.entries()
        }
        guard try desired.allSatisfy({ expected in try confirmed.contains { try matches($0, expected) } }) else {
            throw AITrainingError.invalid("训练已提交，系统尚未确认全部安排，请稍后重试。")
        }
        status = desired.isEmpty ? "本期暂无待发送训练" : "已更新 \(desired.count) 次训练，等待系统同步到手表"
    }
}
