import Combine
import Foundation
import UIKit

private struct TrainingAnalysisDisk: Codable {
    var version = 1
    var calibration = AnalysisCalibration()
    var records: [String: RunTrainingAnalysis] = [:]
    var heartRateProfile: AnalysisHeartRateProfile? = nil
    var failedReads: [String: AnalysisReadAttempt]? = nil
    var paused: Bool? = nil
}

@MainActor
final class TrainingAnalysisStore: ObservableObject {
    @Published private(set) var calibration = AnalysisCalibration() { didSet { if oldValue.key != calibration.key { invalidatePresentation() } } }
    @Published private(set) var records: [String: RunTrainingAnalysis] = [:] { didSet { invalidatePresentation() } }
    @Published private(set) var summaries: [AnalysisRunSummary] = [] { didSet { invalidatePresentation() } }
    @Published private(set) var recovery = AIRecoveryContext()
    @Published private(set) var references = ExportReferenceData()
    @Published private(set) var heartRateProfile: AnalysisHeartRateProfile?
    @Published private(set) var isWorking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isRefreshingRecovery = false
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var jobs: [String: Task<RunTrainingAnalysis, Error>] = [:]
    private var jobIDs: [String: UUID] = [:]
    private var desiredDays = 126
    private var generation = UUID()
    private var lastRecovery: Date?
    private var recoveryRequestID: UUID?
    private var readable = true
    private var mutations = 0
    private var summarySignatures: [String: String] = [:]
    private var profileTask: Task<AnalysisHeartRateProfile, Never>?
    private var profileTaskID: UUID?
    private var needsRefreshPass = false
    private var forceQueued = false
    private var recoveryAccessQueued = false
    private var activeRecoveryAccess = false
    private var failedReads: [String: AnalysisReadAttempt] = [:]
    private let file: URL
    private let io = ArchiveFileIO()
    private var restoreTask: Task<TrainingAnalysisDisk?, Error>?
    private var restored = false
    private var saveTask: Task<Void, Never>?
    private var saveRevision = 0
    private var revision = 0
    private var presentation: (revision: Int, day: Date, zone: String, asOf: Date, nextBoundary: Date?, values: [RunTrainingAnalysis], timeline: [AnalysisLoadDay]?)?
    private(set) var timelineBuildCount = 0

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4
        return c
    }
    init(fileURL: URL? = nil) {
        file = fileURL ?? URL.applicationSupportDirectory.appending(path: "RunningArchive", directoryHint: .isDirectory).appending(path: "training-analysis-v1.json")
    }
    func restore() async {
        guard !restored else { return }
        if restoreTask == nil {
            let io = io, file = file
            restoreTask = Task { try await io.read(TrainingAnalysisDisk.self, from: file) }
        }
        do {
            let disk = try await restoreTask!.value
            guard !restored else { return }
            if let disk {
                guard disk.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                calibration = disk.calibration; records = disk.records; heartRateProfile = disk.heartRateProfile
                failedReads = disk.failedReads ?? [:]; isPaused = isPaused || (disk.paused ?? false)
                if isPaused { progress = "已暂停，可继续整理" }
            }
        } catch {
            readable = false
            errorMessage = "分析缓存暂时无法读取，原文件已保留。可在分析设置中重建；原始跑步不受影响。"
        }
        restored = true; restoreTask = nil
        if mutations > 0 { flush() }
    }
    private func invalidatePresentation() { revision &+= 1; presentation = nil }
    private func presentationValues(now: Date) -> [RunTrainingAnalysis] {
        let c = calendar, day = calendar.startOfDay(for: now)
        if let saved = presentation, saved.revision == revision, saved.day == day, saved.zone == c.timeZone.identifier,
           now >= saved.asOf, saved.nextBoundary.map({ now < $0 }) ?? true { return saved.values }
        let ids = Set(summaries.map(\.id)), key = calibration.key
        let values = records.values.filter { $0.version == AnalysisMethod.version && $0.calibrationKey == key && $0.timeZone == c.timeZone.identifier && ids.contains($0.id) && summarySignatures[$0.id] == $0.inputSignature && $0.date <= now }
            .sorted { $0.date < $1.date }
        let boundary = (summaries.map(\.date) + records.values.map(\.date) + records.values.map(\.end)).filter { $0 > now }.min()
        presentation = (revision, day, c.timeZone.identifier, now, boundary, values, nil)
        return values
    }
    var validRecords: [RunTrainingAnalysis] { presentationValues(now: .now) }
    func record(id: String) -> RunTrainingAnalysis? {
        guard let a = records[id], a.calibrationKey == calibration.key, a.version == AnalysisMethod.version,
              a.timeZone == calendar.timeZone.identifier, summarySignatures[id] == a.inputSignature else { return nil }
        return a
    }
    func updateSummaries(_ activities: [ArchiveActivity]) {
        let signatures = Dictionary(activities.map { ($0.id, TrainingAnalysisMath.signature($0)) }, uniquingKeysWith: { a, _ in a })
        let eligible = activities.filter { $0.date <= .now }
        guard signatures != summarySignatures || Set(eligible.map(\.id)) != Set(summaries.map(\.id)) else { return }
        summarySignatures = signatures
        summaries = eligible.map(AnalysisRunSummary.init).sorted { $0.date < $1.date }
    }
    func prepareHeartRateProfile(archive: ArchiveStore, authorize: Bool = false, force: Bool = false) async {
        await restore()
        var newlyAuthorized = false
        if authorize {
            do { newlyAuthorized = try await archive.requestHeartRateProfileAccess() }
            catch { errorMessage = "健康年龄暂不可读取，Apple区间和其他分析仍可使用。" }
            // A pre-authorization read may already be in flight. Re-read after it finishes,
            // otherwise its earlier denied DOB result could hide newly granted access for 15 min.
            if newlyAuthorized, let pending = profileTask {
                let pendingID = profileTaskID
                _ = await pending.value
                if pendingID == profileTaskID { profileTask = nil; profileTaskID = nil }
            }
        }
        let now = Date.now
        if !force, !newlyAuthorized, let profile = heartRateProfile,
           now.timeIntervalSince(profile.fetchedAt) < 900, calendar.isDate(profile.fetchedAt, inSameDayAs: now) { return }
        let value: AnalysisHeartRateProfile
        if let profileTask { value = await profileTask.value }
        else {
            let task = Task { await archive.heartRateProfile() }
            let taskID = UUID()
            profileTask = task; profileTaskID = taskID
            value = await task.value
            if taskID == profileTaskID { profileTask = nil; profileTaskID = nil }
        }
        guard !Task.isCancelled else { return }
        if let newer = heartRateProfile, newer.fetchedAt > value.fetchedAt { return }
        let oldKey = calibration.key
        heartRateProfile = value
        calibration.automaticAge = value.age
        calibration.automaticAgeDate = value.fetchedAt
        calibration.appleZoneConfigurationKey = value.preferredZones?.configurationKey
        if oldKey != calibration.key && isWorking { needsRefreshPass = true }
        if readable { mutations += 1; flush() }
    }
    func saveCalibration(maximum: Double?, source: String, performanceID: String?) async throws {
        await restore()
        if let maximum, !maximum.isFinite || !(80...240).contains(maximum) { throw AITrainingError.invalid("最大心率须为80–240 bpm；不确定时请留空。") }
        if maximum != nil && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AITrainingError.invalid("请填写最大心率来源，例如设备设置或已有测试。") }
        var next = calibration
        if maximum != calibration.maximumHeartRate || source != calibration.source {
            next.maximumHeartRate = maximum; next.source = maximum == nil ? "" : source
            next.confirmedAt = maximum == nil ? nil : .now
        }
        if performanceID != calibration.performanceActivityID {
            next.performanceActivityID = performanceID; next.performanceConfirmedAt = performanceID == nil ? nil : .now
        }
        guard next != calibration else { return }
        guard readable else { throw AITrainingError.invalid("请先重建无法读取的分析缓存。") }
        let previous = calibration
        calibration = next
        do { try await persist() } catch { calibration = previous; throw error }
        stop(userInitiated: false)
    }
    func rebuild() async throws {
        await restore()
        stop(userInitiated: false)
        await waitForPersistence()
        if !readable { try await io.backup(file) }
        readable = true; records = [:]; failedReads = [:]; errorMessage = nil; isPaused = false
        try await persist()
    }
    func stop(userInitiated: Bool = true) {
        if userInitiated { isPaused = true; mutations += 1 }
        generation = UUID(); needsRefreshPass = false; forceQueued = false; recoveryAccessQueued = false
        task?.cancel(); task = nil
        for job in jobs.values { job.cancel() }
        jobs.removeAll(); jobIDs.removeAll(); flush(); isWorking = false; isPreparing = false; progress = isPaused ? "已暂停，可继续整理" : "等待更新"
    }
    func start(archive: ArchiveStore, force: Bool = false, recoveryAccess: Bool = false, days: Int = 126) {
        updateSummaries(archive.activities)
        desiredDays = max(desiredDays, days)
        if force { isPaused = false }
        if task != nil {
            forceQueued = forceQueued || force
            recoveryAccessQueued = recoveryAccessQueued || (recoveryAccess && !activeRecoveryAccess)
            return
        }
        guard readable, !isPaused, UIApplication.shared.applicationState == .active else { return }
        generation = UUID()
        activeRecoveryAccess = recoveryAccess
        let token = generation, rangeDays = desiredDays
        task = Task { [weak self, weak archive] in
            guard let self, let archive else { return }
            await self.restore()
            defer {
                if self.generation == token {
                    self.isWorking = false; self.isPreparing = false; self.task = nil; self.flush()
                    if self.desiredDays > rangeDays || self.needsRefreshPass || self.forceQueued || self.recoveryAccessQueued {
                        let queuedForce = self.forceQueued, queuedAccess = self.recoveryAccessQueued
                        self.needsRefreshPass = false; self.forceQueued = false; self.recoveryAccessQueued = false
                        self.start(archive: archive, force: queuedForce, recoveryAccess: queuedAccess, days: self.desiredDays)
                    }
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            if force { self.isPaused = false; self.mutations += 1 }
            guard !self.isPaused, self.readable else { return }
            self.isPreparing = force || self.heartRateProfile == nil
            if recoveryAccess {
                do { if try await archive.requestAIContextAccess() { self.lastRecovery = nil } }
                catch { self.errorMessage = "恢复背景暂时未获得读取权限；跑步分析仍可使用。" }
            }
            await self.prepareHeartRateProfile(archive: archive, authorize: recoveryAccess, force: force)
            guard !Task.isCancelled, self.generation == token, !self.isPaused else { return }
            self.isPreparing = false
            self.needsRefreshPass = false
            let cutoff = self.calendar.date(byAdding: .day, value: -rangeDays, to: self.calendar.startOfDay(for: .now))!
            let candidates = archive.activities.filter { $0.date >= cutoff && $0.date <= .now }.sorted { $0.date > $1.date }
            let now = Date.now
            let pending = candidates.filter { self.needsRead($0, now: now, force: force) }
            var failures = 0
            self.isWorking = !pending.isEmpty
            for (i, activity) in pending.enumerated() {
                if Task.isCancelled || self.generation != token { return }
                if UIApplication.shared.applicationState != .active { self.progress = "历史分析将在前台继续"; return }
                self.progress = "更新训练数据 \(i + 1)/\(pending.count)"
                guard let current = archive.activities.first(where: { $0.id == activity.id }) else { continue }
                do { _ = try await self.analyze(activity: current, archive: archive, force: force) }
                catch is CancellationError {
                    if Task.isCancelled || self.generation != token { return }
                    // An edited workout invalidates this result, not the remaining history.
                    failures += 1
                }
                catch { failures += 1 }
                await Task.yield()
            }
            guard !Task.isCancelled, self.generation == token else { return }
            self.updateSummaries(archive.activities)
            let coverage = TrainingAnalysisMath.loadCoverage(self.summaries.filter { $0.date >= cutoff }, analyses: self.validRecords)
            if self.calibration.validMaximum(at: .now) == nil {
                self.progress = "已整理 \(coverage.processed)/\(coverage.expected) 次 · Edwards负荷缺少适用年龄；可先看Apple区间"
            } else {
                self.progress = "已整理 \(coverage.processed)/\(coverage.expected) 次 · \(coverage.calculated) 次可计算负荷"
            }
            if failures > 0 { self.progress += " · \(failures) 次读取未完成，可重试" }
            let deferred = candidates.filter { self.record(id: $0.id) == nil && !self.needsRead($0, now: .now, force: false) }.count
            if failures == 0 && deferred > 0 { self.progress += " · \(deferred) 次读取暂缓，可手动重试" }
            // Recovery queries have their own status; cached run charts stay immediately usable.
            self.isWorking = false
            if !Task.isCancelled, self.generation == token, UIApplication.shared.applicationState == .active {
                await self.refreshBackground(archive: archive, force: force)
            }
        }
    }
    func resume(archive: ArchiveStore) {
        isPaused = false; mutations += 1; flush()
        start(archive: archive, recoveryAccess: true)
    }
    func refresh(archive: ArchiveStore) async {
        await restore()
        isPaused = false; mutations += 1
        start(archive: archive, force: true, recoveryAccess: true)
        while let pending = task { await pending.value }
        await waitForPersistence()
    }

    func refreshBackground(archive: ArchiveStore, force: Bool = false) async {
        guard force || lastRecovery == nil || Date.now.timeIntervalSince(lastRecovery!) > 900 else { return }
        let requestID = UUID()
        recoveryRequestID = requestID
        isRefreshingRecovery = true
        defer { if recoveryRequestID == requestID { isRefreshingRecovery = false; recoveryRequestID = nil } }
        let now = Date.now, token = generation
        let context = await archive.trainingContext(now: now, calendar: calendar, days: 56)
        guard !Task.isCancelled, token == generation else { return }
        recovery = context
        let start = calendar.date(byAdding: .day, value: -126, to: now)!
        do {
            let loaded = try await archive.exportReferences(start: start, end: now)
            guard !Task.isCancelled, token == generation else { return }
            references = loaded
        } catch is CancellationError { return }
        catch { references.issues["体能参考"] = "暂时无法读取" }
        lastRecovery = now
    }
    func analyze(activity: ArchiveActivity, archive: ArchiveStore, force: Bool = false, provided: ExportWorkout? = nil) async throws -> RunTrainingAnalysis {
        await prepareHeartRateProfile(archive: archive)
        let now = Date.now, c = calendar, settings = calibration
        if provided == nil, !needsRead(activity, now: now, force: force) {
            if let saved = record(id: activity.id) { return saved }
            throw AITrainingError.invalid("这条记录刚才读取未完成，稍后会自动重试；也可手动刷新立即重试。")
        }
        let key = activity.id + "|" + settings.key + "|" + TrainingAnalysisMath.signature(activity)
        if let job = jobs[key] { return try await job.value }
        let job = Task { @MainActor in
            var workout: ExportWorkout
            if let provided { workout = provided } else { workout = try await archive.exportWorkout(id: activity.id) }
            workout.preferredAppleHeartRateZones = self.heartRateProfile?.preferredZones ?? workout.preferredAppleHeartRateZones
            try Task.checkCancellation()
            let snapshot = workout
            let computed = await Task.detached(priority: .utility) {
                TrainingAnalysisMath.calculate(snapshot, activity: activity, calibration: settings, now: now, calendar: c)
            }.value
            try Task.checkCancellation()
            return computed
        }
        let jobID = UUID()
        jobs[key] = job; jobIDs[key] = jobID
        defer { if jobIDs[key] == jobID { jobs[key] = nil; jobIDs[key] = nil } }
        let result: RunTrainingAnalysis
        do { result = try await job.value }
        catch {
            if !(error is CancellationError), !Task.isCancelled, settings.key == calibration.key {
                failedReads[activity.id] = AnalysisReadAttempt(date: .now, signature: TrainingAnalysisMath.signature(activity), calibrationKey: settings.key, timeZone: c.timeZone.identifier)
                mutations += 1
                // Persist backoff as well, so relaunching does not retry an unreadable history immediately.
                flush()
            }
            throw error
        }
        try Task.checkCancellation()
        updateSummaries(archive.activities)
        guard settings.key == calibration.key, summarySignatures[activity.id] == result.inputSignature else { throw CancellationError() }
        records[activity.id] = result
        failedReads[activity.id] = nil
        mutations += 1
        if mutations >= 8 { flush() }
        return result
    }
    private func needsRead(_ activity: ArchiveActivity, now: Date, force: Bool) -> Bool {
        AnalysisRefreshPolicy.shouldRead(activity, saved: records[activity.id], failed: failedReads[activity.id],
            calibrationKey: calibration.key, timeZone: calendar.timeZone.identifier, now: now, force: force)
    }
    func flush() {
        guard mutations > 0, readable, restored else { return }
        mutations = 0
        let snapshot = diskSnapshot(), previous = saveTask, io = io, file = file
        saveRevision += 1
        let token = saveRevision
        saveTask = Task { [weak self] in
            await previous?.value
            do { try await io.write(snapshot, to: file) }
            catch {
                self?.mutations += 1
                self?.errorMessage = "分析结果暂未写入缓存，下次打开可能需要重新整理。"
            }
            if self?.saveRevision == token { self?.saveTask = nil }
        }
    }
    func waitForPersistence() async {
        flush()
        while let pending = saveTask { await pending.value }
    }
    private func diskSnapshot() -> TrainingAnalysisDisk {
        TrainingAnalysisDisk(calibration: calibration, records: records, heartRateProfile: heartRateProfile, failedReads: failedReads, paused: isPaused)
    }
    private func persist() async throws {
        guard readable else { throw AITrainingError.unreadable }
        await waitForPersistence()
        try await io.write(diskSnapshot(), to: file)
    }
    var recoveryObservations: [AnalysisObservation] {
        let c = calendar
        var result = recovery.daily_metrics.compactMap { p -> AnalysisObservation? in
            guard let date = AIDate.parse(p.date, calendar: c) else { return nil }
            return AnalysisObservation(metric: p.metric, date: date, value: p.median,
                sourceGroup: p.source_group ?? "", context: p.sample_context ?? "unknown")
        }
        result += recovery.sleep_windows.map { p in
            AnalysisObservation(metric: "sleep_minutes", date: c.startOfDay(for: p.end.addingTimeInterval(-1)), value: p.asleep_minutes,
                sourceGroup: p.source_group ?? "", context: "noon_to_noon", complete: !p.partial_window)
        }
        return result
    }
    func ingestRecovery(_ context: AIRecoveryContext) { recovery = context; lastRecovery = .now }

    func loadTimeline(now: Date) -> [AnalysisLoadDay] {
        let values = presentationValues(now: now)
        if let timeline = presentation?.timeline { return timeline }
        let timeline = TrainingAnalysisMath.loadTimeline(summaries, analyses: values, now: now, calendar: calendar)
        timelineBuildCount += 1
        presentation?.timeline = timeline
        return timeline
    }

    func context(activities: [ArchiveActivity], now: Date, recovery background: AIRecoveryContext? = nil) -> TrainingAnalysisContext {
        let c = calendar
        let reference = calibration.reference(at: now)
        let cutoff = c.date(byAdding: .day, value: -126, to: c.startOfDay(for: now))!
        let runs = activities.filter { $0.date >= cutoff && $0.date <= now }.map(AnalysisRunSummary.init)
        let ids = Set(runs.map(\.id))
        let values = validRecords.filter { ids.contains($0.id) && $0.end <= now }
        var evidence: [AnalysisEvidence] = []
        for run in values.sorted(by: { $0.date > $1.date }).prefix(3) {
            let metrics = [("edwards_load", run.load), ("efficiency", run.efficiency), ("drift", run.drift), ("speed_cv", run.speedVariation)]
            for (name, value) in metrics {
                evidence.append(AnalysisEvidence(id: "analysis:\(run.id):\(name)", metric: name, value: value, activity_ids: [run.id], start: run.date, end: run.end))
            }
            if let zones = run.appleHeartRateZones, zones.zones.contains(where: { $0.seconds != nil }) {
                evidence.append(AnalysisEvidence(id: "analysis:\(run.id):apple-zones", metric: "apple_heart_rate_zone_seconds",
                    value: AnalysisValue(value: zones.zones.reduce(0) { $0 + ($1.seconds ?? 0) }, unit: "s", method: zones.scope,
                        coverage: zones.coverage ?? 0, reason: zones.reason, complete: (zones.coverage ?? 0) >= AnalysisMethod.coverage),
                    activity_ids: [run.id], start: run.date, end: run.end))
            }
        }
        let aerobic = TrainingAnalysisMath.aerobicTrend(values, now: now, calendar: c)
        evidence.append(AnalysisEvidence(id: "analysis:aerobic-trend", metric: aerobic.metric,
            value: AnalysisValue(value: aerobic.percent, unit: "%", method: "matched-cohort-28-vs-28-v1", coverage: aerobic.recent == nil ? 0 : 1,
                reason: aerobic.reason, complete: aerobic.recent != nil, estimated: reference.estimated), activity_ids: (aerobic.recentIDs + aerobic.baselineIDs).sorted(),
            start: c.date(byAdding: .day, value: -56, to: now)!, end: now))
        let timelineSummaries = activities.filter { $0.date <= now }.map(AnalysisRunSummary.init)
        let days: [AnalysisLoadDay]
        if Dictionary(activities.map { ($0.id, TrainingAnalysisMath.signature($0)) }, uniquingKeysWith: { a, _ in a }) == summarySignatures {
            days = loadTimeline(now: now)
        } else {
            days = TrainingAnalysisMath.loadTimeline(timelineSummaries, analyses: validRecords, now: now, calendar: c)
        }
        if let last = days.last {
            evidence.append(AnalysisEvidence(id: "analysis:load-trend", metric: "short_long_load_balance",
                value: AnalysisValue(value: calibration.validMaximum(at: now) == nil ? nil : last.balance, unit: "AU/day", method: "ewma-7-42-alpha-exponential-v1",
                    coverage: runs.isEmpty ? 0 : Double(values.filter { $0.load.complete }.count) / Double(runs.count),
                    reason: "仅跑步心率负荷；缺失时为已观测下限，起点从0预热126日；不是身体恢复评分",
                    complete: last.warmedUp && last.completeHistory && calibration.validMaximum(at: now) != nil, estimated: reference.estimated),
                activity_ids: timelineSummaries.map(\.id).sorted(), start: days.first?.date ?? cutoff, end: now))
        }
        let background = background ?? recovery
        var observations = background.daily_metrics.compactMap { point -> AnalysisObservation? in
            guard let date = AIDate.parse(point.date, calendar: c) else { return nil }
            return AnalysisObservation(metric: point.metric, date: date, value: point.median, sourceGroup: point.source_group ?? "", context: point.sample_context ?? "unknown")
        }
        observations += background.sleep_windows.map { point in AnalysisObservation(metric: "sleep_minutes", date: c.startOfDay(for: point.end.addingTimeInterval(-1)), value: point.asleep_minutes,
            sourceGroup: point.source_group ?? "", context: "noon_to_noon", complete: !point.partial_window) }
        let recovered = TrainingAnalysisMath.recovery(observations, now: now, calendar: c)
        for trend in recovered {
            evidence.append(AnalysisEvidence(id: "analysis:recovery:\(trend.metric)", metric: trend.metric,
                value: AnalysisValue(value: trend.percent, unit: "%", method: "same-source-context-7-vs-prior-28-median-v1", coverage: min(1, Double(trend.recentCount) / 7), reason: trend.reason, complete: trend.recent != nil),
                activity_ids: [], start: c.date(byAdding: .day, value: -35, to: now)!, end: now))
        }
        let performances = values.compactMap(\.performance).filter { $0.date >= c.date(byAdding: .day, value: -90, to: now)! }.sorted { $0.date < $1.date }
        var limits = ["分析采用公开模型及应用筛选规则，不等于佳明/高驰专有算法。", "负荷仅统计已读取的跑步，非跑步运动仍作为独立背景；未知数据不等于零。", "成绩指数仅表示已完成表现；只有 fullEffortConfirmed=true 且近期有效的成绩才可用于精确配速参考。", "恢复数据只表示相对个人基线的变化，不是0–100准备度或恢复倒计时。", "天气未校正，单一趋势不能证明训练适量或体能进步。"]
        if values.count < runs.count { limits.append("历史过程数据尚不完整：\(values.count)/\(runs.count) 条已整理，不能据此认为未整理日期没有负荷。") }
        if reference.bpm == nil { limits.append("没有适用的年龄或手动最大心率，Edwards负荷不可用；Apple区间可独立查看，不能反推最大心率。") }
        if reference.estimated { limits.append("最大心率来自Tanaka成人年龄回归估计，存在个体误差；依赖它的负荷和有氧强度均为估算，不得据此生成精确心率目标。有效采样超过估计值的活动未计算Edwards负荷。") }
        limits.append("Apple区间与Edwards最大心率百分比区间独立；recorded_workout保留系统原始时长，current_preference_reclassified按当前区间重新分类，均不能混作Edwards负荷权重。")
        if performances.isEmpty { limits.append("暂无满足完整记录条件的近期成绩换算。") }
        return TrainingAnalysisContext(version: AnalysisMethod.version, as_of: now,
            maximum_heart_rate_bpm: reference.bpm, heart_rate_calibration_date: reference.date,
            calibration_method: reference.method,
            evidence: evidence, weeks: Array(TrainingAnalysisMath.weeks(runs, analyses: values, now: now, calendar: c).suffix(7)),
            load_days: calibration.validMaximum(at: now) == nil ? [] : Array(days.suffix(42)), recovery: recovered, aerobic: [aerobic],
            form: TrainingAnalysisMath.formTrends(values, now: now, calendar: c), performances: performances, limitations: limits,
            heart_rate_reference: reference,
            apple_heart_rate_zones: values.sorted { $0.date > $1.date }.prefix(3).compactMap { run in run.appleHeartRateZones.map { AnalysisAppleZoneEvidence(activity_id: run.id, zones: $0) } },
            preferred_apple_heart_rate_zones: heartRateProfile?.preferredZones)
    }
}
