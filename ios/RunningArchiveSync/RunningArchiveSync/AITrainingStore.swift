import Combine
import CryptoKit
import HealthKit
import Network
import UIKit

@MainActor
final class AITrainingStore: ObservableObject {
    @Published private(set) var state = AITrainingDiskState()
    @Published private(set) var isWorking = false
    @Published private(set) var status = ""
    @Published var errorMessage: String?
    private var readable = true
    private var restored = false
    private var restoreTask: Task<AITrainingDiskState?, Error>?
    private let io = ArchiveFileIO()
    private let fileURL: URL
    private var retryTask: Task<Void, Never>?
    private let service: DeepSeekTrainingService

    var current: AIPlanRevision? { state.effectiveRevision }
    var key: String { KeychainStore.read("deepseekAPIKey") }
    var configured: Bool { state.configuration.enabled && !key.isEmpty }

    init(fileURL: URL? = nil, deferLoading: Bool = false, service: DeepSeekTrainingService = DeepSeekTrainingService()) {
        self.service = service
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "RunningArchive", directoryHint: .isDirectory).appending(path: "ai-training-v1.json")
        guard !deferLoading else { readable = false; return }
        restored = true
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                state = try JSONDecoder().decode(AITrainingDiskState.self, from: Data(contentsOf: self.fileURL))
                guard state.version == 1 else { throw AITrainingError.unreadable }
                errorMessage = state.lastError
                if state.migrateCompletionEvidence() { try persist(state) }
            }
        } catch {
            readable = false
            errorMessage = AITrainingError.unreadable.localizedDescription
        }
    }

    func restore() async {
        guard !restored else { return }
        if restoreTask == nil {
            let io = io, file = fileURL
            restoreTask = Task { try await io.read(AITrainingDiskState.self, from: file) }
        }
        do {
            let saved = try await restoreTask!.value
            guard !restored else { return }
            if let saved {
                guard saved.version == 1 else { throw AITrainingError.unreadable }
                state = saved; errorMessage = saved.lastError
            }
            readable = true
            if state.migrateCompletionEvidence() { try persist(state) }
        } catch { readable = false; errorMessage = AITrainingError.unreadable.localizedDescription }
        restored = true; restoreTask = nil
    }

    func save(profile: AITrainingProfile, configuration: AITrainingConfiguration, key: String) throws {
        guard !isWorking else { throw AITrainingError.invalid("请等待当前分析完成后再修改设置。") }
        if configuration.enabled { try profile.validate() }
        guard configuration.endpoint != nil, !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AITrainingError.invalid("基础地址必须为 HTTPS，模型名称不能为空。")
        }
        if configuration.enabled && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AITrainingError.invalid("请填写 DeepSeek API Key。")
        }
        let previousKey = self.key
        try KeychainStore.writeChecked(key.trimmingCharacters(in: .whitespacesAndNewlines),
            account: "deepseekAPIKey", backgroundAccessible: true)
        var next = state
        if next.profile != profile || next.configuration != configuration || previousKey != key {
            next.lastFingerprint = ""
            next.nextRetry = nil
        }
        next.profile = profile
        next.configuration = configuration
        next.lastError = nil
        try persist(next)
        errorMessage = nil
    }

    func test(configuration: AITrainingConfiguration, key: String) async throws {
        try await service.test(configuration: configuration, key: key)
    }

    func availableModels(configuration: AITrainingConfiguration, key: String) async throws -> [DeepSeekAvailableModel] {
        try await service.availableModels(configuration: configuration, key: key)
    }

    func editSession(originalDate: String, session: AITrainingSession) throws {
        var next = state
        try next.editSession(originalDate: originalDate, session: session)
        try persist(next)
        Task { await syncWatch() }
    }

    func restoreAISession(on day: String) throws {
        guard let date = AIDate.parse(day, calendar: AIDate.localCalendar), date >= AIDate.localCalendar.startOfDay(for: .now),
              !state.completed.contains(where: { $0.id == day }) else {
            throw AITrainingError.invalid("已完成或过去的训练不能替换。")
        }
        var next = state
        next.manualOverrides?.removeAll { $0.session.date == day }
        try persist(next)
        Task { await syncWatch() }
    }

    func syncWatch(requestAuthorization: Bool = false) async {
        guard let current else { return }
        await RunningArchiveRuntime.shared.watch.sync(sessions: current.plan.sessions,
            completed: state.completedCurrentDates, requestAuthorization: requestAuthorization)
    }

    func reconcileSessions(activities: [ArchiveActivity], calendar: Calendar = AIDate.localCalendar) throws {
        var next = state
        if next.reconcileTraining(activities: activities, calendar: calendar) { try persist(next) }
    }

    func associate(_ session: AITrainingSession, activity: ArchiveActivity?) throws {
        var next = state
        try next.associate(session, activity: activity)
        try persist(next)
        Task { await syncWatch() }
    }

    func confirmCompletion(_ session: AITrainingSession, activity: ArchiveActivity) throws {
        var next = state
        try next.confirmCompletion(session, activity: activity)
        try persist(next)
        Task { await syncWatch() }
    }

    func undoCompletion(_ session: AITrainingSession) throws {
        var next = state
        next.undoCompletion(session)
        try persist(next)
        Task { await syncWatch() }
    }

    func generate(archive: ArchiveStore, journal: TrainingJournal, force: Bool = false) async {
        guard !isWorking, readable, configured, force || state.configuration.automatic else { return }
        if !force, let retry = state.nextRetry, retry > .now { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let now = Date.now
        let cutoff = calendar.date(byAdding: .day, value: -42, to: calendar.startOfDay(for: now))!
        let activities = archive.activities.filter { $0.date >= cutoff && $0.date <= now }.sorted { $0.date < $1.date }
        guard !activities.isEmpty else {
            status = "请先读取近期跑步记录，再生成训练计划。"
            return
        }
        // Workout summaries may arrive before routes and samples. Merge deliveries before generating.
        if !force, let last = activities.last, let seconds = MonthlyReport.seconds(last.duration) {
            let availableAfter = last.date.addingTimeInterval(seconds + 90)
            if availableAfter > now {
                status = "正在等待本次跑步数据同步完成…"
                retryTask?.cancel()
                retryTask = Task { [weak self, weak archive] in
                    try? await Task.sleep(for: .seconds(min(availableAfter.timeIntervalSinceNow, 300)))
                    guard !Task.isCancelled, let self, let archive else { return }
                    await archive.load(force: true, authorize: false)
                    await self.generate(archive: archive, journal: journal)
                }
                return
            }
        }
        do {
            try state.profile.validate(now: now)
            if UIApplication.shared.applicationState == .active { try await archive.requestAIContextAccess() }
            await RunningArchiveRuntime.shared.analytics.prepareHeartRateProfile(archive: archive, authorize: UIApplication.shared.applicationState == .active)
            try reconcileSessions(activities: archive.activities, calendar: calendar)
            let journalSnapshot = journal.data
            let feedback = TrainingFeedback.shared(activities: activities, journal: journalSnapshot, now: now, calendar: calendar)
            let signature = try triggerFingerprint(activities: activities, records: AIPersonalRecord.collect(activities: archive.activities, journal: journalSnapshot, calendar: calendar), feedback: feedback)
            let expired = (current?.plan.sessions.map(\.date).max() ?? "") < AIDate.key(now, calendar: calendar)
            guard force || expired || signature != state.lastFingerprint else { return }
            isWorking = true
            errorMessage = nil
            status = "正在整理近六周训练与最近三次跑步…"
            defer { isWorking = false }
            let input = try await makeInput(archive: archive, journal: journalSnapshot, activities: activities, now: now, calendar: calendar)
            try Task.checkCancellation()
            guard (input.subjective_feedback ?? []) == TrainingFeedback.shared(activities: activities, journal: journal.data, now: .now, calendar: calendar) else {
                status = "跑后反馈已更新，正在改用最新反馈。"
                RunningArchiveRuntime.shared.scheduleAnalysis()
                return
            }
            status = "DeepSeek 正在分析跑步并生成新计划…"
            var plan = try await service.generate(input: input, configuration: state.configuration, key: key)
            try Task.checkCancellation()
            guard plan.schema_version == 2 else {
                throw AITrainingError.invalid("模型没有返回新版可执行分段，原计划已保留，请重试。")
            }
            let start = AIDate.parse(input.plan_start, calendar: calendar)!
            try plan.validate(profile: state.profile, start: start, evidenceIDs: input.evidenceIDs, calendar: calendar)
            try plan.validateAnalysis(input.training_analysis)
            try plan.validateFeedback(input.subjective_feedback ?? [])
            let currentActivities = archive.activities.filter { $0.date >= cutoff && $0.date <= .now }.sorted { $0.date < $1.date }
            let currentSignature = try triggerFingerprint(activities: currentActivities, records: AIPersonalRecord.collect(activities: archive.activities, journal: journal.data, calendar: calendar),
                feedback: TrainingFeedback.shared(activities: currentActivities, journal: journal.data, now: .now, calendar: calendar))
            guard signature == currentSignature else {
                status = "跑步、反馈或分析校准已更新，本次旧快照未覆盖计划。"
                RunningArchiveRuntime.shared.scheduleAnalysis()
                return
            }
            plan.sessions.sort { $0.date < $1.date }
            var next = state
            next.revisions.append(AIPlanRevision(createdAt: now, model: state.configuration.model,
                promptVersion: AITrainingPrompt.version, inputFingerprint: try input.fingerprint(), plan: plan, analysisContext: input.training_analysis, feedbackContext: input.subjective_feedback, profileContext: input.profile))
            // Completed sessions have their own durable history and are never discarded with revisions.
            if next.revisions.count > 30 { next.revisions.removeFirst(next.revisions.count - 30) }
            next.lastFingerprint = signature
            next.lastSuccess = .now
            next.nextRetry = nil
            next.lastError = nil
            next.manualOverrides = next.manualOverrides?.filter { $0.session.date >= AIDate.key(now, calendar: calendar) }
            try persist(next)
            status = "计划已更新"
            await syncWatch()
        } catch is CancellationError {
            status = "分析已暂停，稍后会自动补分析。"
        } catch {
            errorMessage = error.localizedDescription
            status = "更新未完成，已保留原计划。"
            var next = state
            next.lastError = error.localizedDescription
            next.nextRetry = .now.addingTimeInterval(300)
            try? persist(next)
        }
    }

    private func triggerFingerprint(activities: [ArchiveActivity], records: [AIPersonalRecord], feedback: [RunSubjectiveFeedback]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let settings = try encoder.encode(state.profile) + encoder.encode(state.configuration) + encoder.encode(records) + encoder.encode(feedback) + Data((AITrainingPrompt.version + ":analysis=" + RunningArchiveRuntime.shared.analytics.calibration.key + ":context=" + String(UserDefaults.standard.bool(forKey: "healthAIContextAuthorization-v1"))).utf8)
        let runs = activities.map { TrainingAnalysisMath.signature($0) }.joined(separator: "|")
        return SHA256.hash(data: settings + Data(runs.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func makeInput(archive: ArchiveStore, journal: JournalData, activities: [ArchiveActivity], now: Date, calendar: Calendar) async throws -> AITrainingInput {
        let today = calendar.startOfDay(for: now)
        // A finished workout today is context, never an instruction to repeat today's session.
        let ranToday = activities.contains { calendar.isDate($0.date, inSameDayAs: today) }
        let start = calendar.date(byAdding: .day, value: ranToday ? 1 : 0, to: today)!
        let lookback = calendar.date(byAdding: .day, value: -42, to: today)!
        let summaries = activities.map { item -> AIWorkoutSummary in
            let seconds = MonthlyReport.seconds(item.duration)
            return AIWorkoutSummary(id: item.id, start: item.date, date: AIDate.key(item.date, calendar: calendar),
                distance_km: item.distanceKm, active_seconds: seconds,
                pace_seconds_per_km: seconds.flatMap { item.distanceKm > 0 ? $0 / item.distanceKm : nil },
                average_heart_rate_bpm: item.avgHeartRate, max_heart_rate_bpm: item.maxHeartRate,
                average_power_watts: item.avgPower, average_cadence_spm: item.avgCadence)
        }
        var weeks: [AIWeeklySummary] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: lookback)!.start
        while cursor <= today {
            let end = calendar.date(byAdding: .day, value: 7, to: cursor)!
            let runs = summaries.filter { $0.start >= cursor && $0.start < end }
            weeks.append(AIWeeklySummary(start: AIDate.key(cursor, calendar: calendar), end: AIDate.key(end, calendar: calendar),
                partial_week: cursor < lookback || end > now, distance_km: runs.reduce(0) { $0 + $1.distance_km },
                runs: runs.count, active_seconds: runs.compactMap(\.active_seconds).reduce(0, +),
                longest_km: runs.map(\.distance_km).max() ?? 0))
            cursor = end
        }
        let analytics = RunningArchiveRuntime.shared.analytics
        await analytics.prepareHeartRateProfile(archive: archive)
        analytics.updateSummaries(archive.activities)
        var details: [AIWorkoutDetail] = [], notes: [String] = ["伤病与个人阈值未提供；心率是否已校准见 training_analysis，恢复背景使用系统记录，主观疲劳仅来自明确授权的 subjective_feedback，二者不得混算。", "缺失字段表示未记录或不可读取，不代表零。"]
        for activity in activities.suffix(3) {
            try Task.checkCancellation()
            do {
                let workout = try await archive.exportWorkout(id: activity.id)
                let detail = await Task.detached(priority: .utility) { Self.detail(workout, id: activity.id) }.value
                details.append(detail)
                _ = try await analytics.analyze(activity: activity, archive: archive, provided: workout)
            } catch is CancellationError { throw CancellationError() }
            catch { notes.append("\(activity.id)：详细采样暂时不可用，仅使用运动摘要。") }
        }
        let referenceData = try await archive.exportReferences(start: lookback, end: now)
        notes += referenceData.issues.keys.sorted().map { "\($0)：暂时不可读取。" }
        let selectedReferences = Dictionary(grouping: referenceData.samples, by: \.metric).values.flatMap {
            $0.sorted { $0.date < $1.date }.suffix(30)
        }.sorted { $0.date < $1.date }
        let recovery = await archive.trainingContext(now: now, calendar: calendar, days: 56)
        analytics.ingestRecovery(recovery)
        analytics.flush()
        let analysisContext = analytics.context(activities: archive.activities, now: now, recovery: recovery)
        return AITrainingInput(task: "analyze_runs_and_generate_plan",
            time_zone: calendar.timeZone.identifier, today: AIDate.key(today, calendar: calendar),
            plan_start: AIDate.key(start, calendar: calendar),
            plan_end: AIDate.key(calendar.date(byAdding: .day, value: 6, to: start)!, calendar: calendar),
            profile: state.profile, target_date_local: state.profile.targetDate.map { AIDate.key($0, calendar: calendar) },
            lookback_start: AIDate.key(lookback, calendar: calendar),
            workouts: summaries, weeks: weeks, latest_details: details,
            references: selectedReferences.map {
                AIReferenceMetric(metric: $0.metric, date: $0.date, value: $0.value, unit: $0.unit, method: $0.method)
            },
            personal_records: AIPersonalRecord.collect(activities: archive.activities, journal: journal, calendar: calendar),
            recovery_context: recovery, data_notes: notes, training_analysis: analysisContext,
            subjective_feedback: TrainingFeedback.shared(activities: activities, journal: journal, now: now, calendar: calendar))
    }

    nonisolated static func detail(_ workout: ExportWorkout, id: String) -> AIWorkoutDetail {
        let analysis = ExportObjectiveAnalysis(workout: workout)
        func values(_ start: Double, _ end: Double) -> [AIMetricValue] {
            ExportMetric.allCases.compactMap { metric in
                guard let statistic = analysis.series[metric]?.statistic(start: start, end: end),
                      statistic.average != nil else { return nil }
                return AIMetricValue(metric: metric.rawValue, unit: metric.unit,
                    average: statistic.average, coverage: statistic.fraction)
            }
        }
        var windows: [AIDetailWindow] = []
        // Fixed five-minute objective windows keep payloads small without mixing pauses into active time.
        for start in stride(from: 0.0, to: analysis.elapsed, by: 300) {
            let end = min(start + 300, analysis.elapsed)
            windows.append(AIDetailWindow(start_elapsed_seconds: start, end_elapsed_seconds: end, values: values(start, end)))
        }
        let splits = ExportSplits.calculate(workout.points, start: workout.start, end: workout.end).rows.map {
            AISplit(index: $0.index, distance_km: $0.km, elapsed_seconds: $0.duration,
                active_seconds: analysis.activeSeconds(start: $0.start, end: $0.end),
                estimated_from_gps: true, values: values($0.start, $0.end))
        }
        return AIWorkoutDetail(id: id, indoor: workout.indoor, elevation_gain_m: workout.elevationGain,
            elapsed_seconds: analysis.elapsed, pause_seconds: analysis.pauseTimingKnown
                ? analysis.pauses.reduce(0) { $0 + $1.end - $1.start } : nil,
            metrics: values(0, analysis.elapsed), recorded_intervals: Array(workout.intervals.prefix(200)),
            kilometer_splits: splits, windows: windows,
            issues: workout.readIssues.keys.sorted().map { "\($0)：缺失或读取失败。" })
    }

    private func persist(_ next: AITrainingDiskState) throws {
        guard readable else { throw AITrainingError.unreadable }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = next
    }
}

/// One runtime is shared by the foreground UI and HealthKit cold/background launches.
@MainActor
final class RunningArchiveRuntime {
    static let shared = RunningArchiveRuntime()
    let archive = ArchiveStore()
    lazy var sync = HealthSyncViewModel(archive: archive)
    let journal = TrainingJournal(deferLoading: true)
    let training = AITrainingStore(deferLoading: true)
    let analytics = TrainingAnalysisStore()
    let watch = WatchPlanSyncStore(transport: AppleWatchWorkoutTransport())
    private let health = HKHealthStore()
    private var observer: HKObserverQuery?
    private var analysisTask: Task<Void, Never>?
    private var analysisQueued = false
    private var forceQueued = false
    private let network = NWPathMonitor()
    private var wasOffline = false
    private let refreshGate = ArchiveRefreshGate()
    private var preparation: Task<Void, Never>?

    private init() {
        journal.onFeedbackChange = { [weak self] old, new in
            guard let self else { return }
            let now = Date.now, calendar = AIDate.localCalendar
            let before = TrainingFeedback.shared(activities: self.archive.activities, journal: old, now: now, calendar: calendar)
            let after = TrainingFeedback.shared(activities: self.archive.activities, journal: new, now: now, calendar: calendar)
            guard before != after else { return }
            // Revoke/replace in-flight input immediately; private-only edits do not trigger cloud work.
            self.analysisTask?.cancel()
            self.training.clearRetryDelay()
            self.scheduleAnalysis()
        }
    }

    func prepare() async {
        if let preparation { await preparation.value; return }
        let work = Task { @MainActor in
            async let journalReady: Void = journal.restore()
            async let trainingReady: Void = training.restore()
            async let analyticsReady: Void = analytics.restore()
            _ = await (journalReady, trainingReady, analyticsReady)
        }
        preparation = work
        await work.value
    }

    func startObserving() {
        guard observer == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let query = HKObserverQuery(sampleType: .workoutType(), predicate: HKQuery.predicateForWorkouts(with: .running)) { _, completion, _ in
            Task { @MainActor in
                await RunningArchiveRuntime.shared.refresh(authorize: false, scanRoutes: false, changed: true)
                completion() // Acknowledge HealthKit promptly; model requests use their own background task.
            }
        }
        observer = query
        health.execute(query)
        network.pathUpdateHandler = { path in
            Task { @MainActor in
                let runtime = RunningArchiveRuntime.shared
                let recovered = runtime.wasOffline && path.status == .satisfied
                runtime.wasOffline = path.status != .satisfied
                if recovered {
                    await runtime.prepare()
                    runtime.training.clearRetryDelay()
                    await runtime.refresh(authorize: false)
                    runtime.sync.networkRecovered()
                    runtime.scheduleAnalysis()
                }
            }
        }
        network.start(queue: DispatchQueue(label: "running-archive.network"))
    }

    func refresh(authorize: Bool, scanRoutes: Bool = true, force: Bool = false, changed: Bool = false) async {
        await prepare()
        await refreshGate.refresh(ArchiveRefreshRequest(authorize: authorize, scanRoutes: scanRoutes, force: force, changed: changed)) { [self] request in
            await archive.load(force: true, authorize: request.authorize, scanRoutes: request.scanRoutes)
            if request.authorize, training.configured {
                try? await health.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
            }
            guard archive.errorMessage == nil, !archive.isLoading else { return false }
            analytics.updateSummaries(archive.activities)
            // Let the freshly restored/updated archive render before starting history work.
            await Task.yield()
            try? training.reconcileSessions(activities: archive.activities)
            Task { await self.training.syncWatch() }
            return true
        }
        guard archive.errorMessage == nil, !archive.isLoading else { return }
        sync.requestAutomaticCheck(changed: changed)
        analytics.start(archive: archive)
        scheduleAnalysis()
    }

    func scheduleAnalysis(force: Bool = false) {
        guard analysisTask == nil else {
            analysisQueued = true
            forceQueued = forceQueued || force
            return
        }
        analysisTask = Task { @MainActor [self] in
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "跑后训练分析") { [weak self] in
                Task { @MainActor in self?.analysisTask?.cancel() }
            }
            defer {
                if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
                analysisTask = nil
                if analysisQueued {
                    let forceNext = forceQueued
                    analysisQueued = false
                    forceQueued = false
                    scheduleAnalysis(force: forceNext)
                }
            }
            await training.generate(archive: archive, journal: journal, force: force)
        }
    }

    func cancelAnalysis() {
        analysisQueued = false
        forceQueued = false
        analysisTask?.cancel()
    }
}

extension AITrainingStore {
    func clearRetryDelay() {
        var next = state
        next.nextRetry = nil
        try? persist(next)
    }
}

final class RunningArchiveAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in RunningArchiveRuntime.shared.startObserving() }
        return true
    }
}
