import SwiftUI

struct AITrainingView: View {
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var showingSettings = false

    @State private var raceToConfigure: RaceGoal?
    init(raceGoal: RaceGoal? = nil) {
        _raceToConfigure = State(initialValue: raceGoal)
        _showingSettings = State(initialValue: raceGoal != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TrainingPhaseGoalCard(profile: training.state.profile) { showingSettings = true }
                if training.isWorking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(training.status).font(.subheadline)
                        Spacer()
                        Button("停止") { RunningArchiveRuntime.shared.cancelAnalysis() }.font(.caption)
                    }.nativeCard()
                }
                if let error = training.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.subheadline)
                        Button("重试更新") { RunningArchiveRuntime.shared.scheduleAnalysis(force: true) }
                            .disabled(training.isWorking || !training.configured)
                    }.nativeCard()
                }
                if let revision = training.current {
                    if TrainingFeedback.stale(snapshot: revision.feedbackContext, activities: archive.activities, journal: journal.data, now: .now, calendar: AIDate.localCalendar) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("跑后反馈已变化", systemImage: "arrow.clockwise").font(.headline)
                            Text("当前仍是上一版安排。更新后查看新建议；手动修改的课程会继续保留。").font(.subheadline)
                            Button("用最新反馈更新") { RunningArchiveRuntime.shared.scheduleAnalysis(force: true) }
                                .disabled(training.isWorking || !training.configured)
                        }.nativeCard()
                    }
                    TrainingPhaseDashboard(revision: revision)
                    if !revision.plan.limitations.isEmpty {
                        DisclosureGroup("数据与分析说明") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(revision.plan.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.top, 10)
                        }.nativeCard()
                    }
                    Text("更新于 \(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(revision.model == AITrainingConfiguration.defaultModel ? "DeepSeek V4.1 Flash" : revision.model)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView {
                        Label("生成你的训练安排", systemImage: "figure.run")
                    } description: {
                        Text(training.configured ? "结合近期跑步、目标和可训练时间，生成下一周安排。" : "设置目标与 DeepSeek API Key，让计划随跑步记录更新。")
                    } actions: {
                        Button(training.configured ? "生成训练计划" : "设置 AI 训练") {
                            if training.configured { RunningArchiveRuntime.shared.scheduleAnalysis(force: true) }
                            else { showingSettings = true }
                        }.buttonStyle(.borderedProminent).disabled(training.isWorking)
                    }
                    if !training.status.isEmpty { Text(training.status).font(.caption).foregroundStyle(.secondary) }
                }
                if training.current != nil {
                    Button {
                        RunningArchiveRuntime.shared.scheduleAnalysis(force: true)
                    } label: { Label("分析跑步并生成新计划", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).disabled(training.isWorking || !training.configured)
                }
                Button("目标、可训练时间与模型设置") { showingSettings = true }.font(.subheadline)
            }.padding(16)
        }
        .background(RunTheme.page).navigationTitle("阶段训练").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
        } }
        .sheet(isPresented: $showingSettings, onDismiss: { raceToConfigure = nil }) { AITrainingSettingsView(initialRace: raceToConfigure) }
        .task { if !showingSettings { RunningArchiveRuntime.shared.scheduleAnalysis() }; await training.syncWatch() }
    }
}

struct AITrainingSessionView: View {
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var watch: WatchPlanSyncStore
    private let initialSession: AITrainingSession
    let editable: Bool
    @State private var selectedDate: String
    @State private var showingEditor = false
    init(session: AITrainingSession, editable: Bool = false) {
        initialSession = session
        self.editable = editable
        _selectedDate = State(initialValue: session.date)
    }
    private var session: AITrainingSession {
        editable ? (training.current?.plan.sessions.first { $0.date == selectedDate } ?? initialSession) : initialSession
    }
    private var canEdit: Bool {
        editable && session.date >= AIDate.key(.now, calendar: AIDate.localCalendar) && !training.state.completed.contains { $0.id == session.date }
    }
    var body: some View {
        List {
            Section {
                LabeledContent("日期", value: session.date)
                LabeledContent("训练", value: session.kind.title)
                if session.kind != .rest {
                    LabeledContent(session.workout?.allSteps.contains(where: { $0.goal == .distance }) == true ? "预计总时长" : "总时长",
                        value: String(format: "%g 分钟（含热身与放松）", session.duration_minutes))
                    if let km = session.distance_km { LabeledContent("参考距离", value: String(format: "%.1f km", km)) }
                    if let lower = session.pace_seconds_per_km_min, let upper = session.pace_seconds_per_km_max {
                        LabeledContent("参考配速", value: "\(TrainingFormat.pace(lower))–\(TrainingFormat.pace(upper)) /km")
                    }
                }
                Text(session.intensity)
            }
            if session.kind != .rest {
                TrainingExecutionSection(session: session)
            }
            Section("训练目的") { Text(session.purpose) }
            if let workout = session.workout {
                RunWorkoutSections(workout: workout)
            } else {
                ForEach(Array(session.steps.enumerated()), id: \.offset) { _, step in
                    Section("\(step.phase) · \(Int(step.minutes)) 分钟") { Text(step.instructions) }
                }
            }
            if canEdit {
                Section {
                    if training.state.manualOverrides?.contains(where: { $0.session.date == session.date }) == true {
                        Text("已手动修改，后续 AI 新计划保留该日安排。").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("同步本期安排到 Apple Watch", systemImage: "applewatch") {
                        Task { await training.syncWatch(requestAuthorization: true) }
                    }.disabled(watch.isWorking || training.isWorking)
                    if let error = watch.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                    else if !watch.status.isEmpty { Text(watch.status).font(.caption).foregroundStyle(.secondary) }
                } footer: { Text("更新本期待跑课程，包含这次训练；已完成记录保留，不会重复添加。") }
            }
            if let revision = training.state.revisions.reversed().first(where: { $0.plan.sessions.contains(session) }),
               let feedback = revision.feedbackContext,
               !Set(session.evidence_ids).isDisjoint(with: Set(feedback.map(\.id))) {
                Section("参考跑后自述") {
                    NavigationLink("这次训练引用了哪些反馈") {
                        FeedbackPlanEvidenceView(revision: revision, selectedIDs: Set(session.evidence_ids))
                    }
                }
            }
            if let context = training.state.revisions.reversed().first(where: { $0.plan.sessions.contains(session) })?.analysisContext,
               !Set(session.evidence_ids).intersection(context.evidenceIDs).isEmpty {
                Section("参考分析指标") {
                    NavigationLink("查看生成时的计算快照与依据") { AIAnalysisEvidenceView(context: context, selectedIDs: Set(session.evidence_ids)) }
                }
            }
            if !session.evidence_ids.isEmpty {
                Section("参考跑步") {
                    ForEach(archive.activities.filter { session.evidence_ids.contains($0.id) }) { item in
                        NavigationLink(value: item) {
                            Text(item.date.formatted(.dateTime.month().day()) + String(format: " · %.2f km", item.distanceKm))
                        }
                    }
                }
            }
        }.navigationTitle(session.kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { if canEdit { ToolbarItem(placement: .topBarTrailing) {
            Button("修改", systemImage: "pencil") { showingEditor = true }.accessibilityIdentifier("training.edit")
        } } }
        .sheet(isPresented: $showingEditor) {
            AITrainingSessionEditor(session: session) { selectedDate = $0 }
        }
    }
}

struct AITrainingHistoryView: View {
    @EnvironmentObject private var training: AITrainingStore
    var body: some View {
        List {
            ForEach(training.state.revisions.reversed()) { revision in
                Section(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                    Text(revision.plan.stage).font(.headline)
                    Text(revision.plan.summary).font(.subheadline)
                    ForEach(Array(revision.plan.adjustments.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(change.date + " · " + change.change).font(.subheadline.bold())
                            Text(change.reason).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink("当时的跑后反馈与计划响应") { FeedbackPlanEvidenceView(revision: revision) }
                    DisclosureGroup("查看这一版安排") {
                        ForEach(revision.plan.sessions) { session in
                            NavigationLink { AITrainingSessionView(session: session) } label: {
                                Text("\(session.date) · \(session.kind.title)")
                            }
                        }
                    }
                    Text("\(revision.model) · \(revision.promptVersion)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            let pending = (training.state.associations ?? []).filter {
                !$0.candidates.isEmpty || $0.activityID != nil
            }.filter { !training.state.isCompleted($0.session) }
            if !pending.isEmpty {
                Section("待核对的训练") {
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, entry in
                        NavigationLink { AITrainingSessionView(session: entry.session) } label: {
                            Label("\(entry.session.date) · \(entry.session.kind.title)", systemImage: "questionmark.circle")
                        }
                    }
                }
            }
            if !training.state.completed.isEmpty {
                Section("已确认完成的训练") {
                    ForEach(training.state.completed.sorted { $0.id > $1.id }) { completed in
                        NavigationLink { AITrainingSessionView(session: completed.session) } label: {
                            Label("\(completed.id) · \(completed.session.kind.title)", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
        }.navigationTitle("分析与历史计划")
    }
}

struct AITrainingSettingsView: View {
    var initialRace: RaceGoal? = nil
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var journal: TrainingJournal
    @Environment(\.dismiss) private var dismiss
    @State private var profile = AITrainingProfile()
    @State private var configuration = AITrainingConfiguration()
    @State private var apiKey = ""
    @State private var distance = ""
    @State private var targetTime = ""
    @State private var hasDeadline = false
    @State private var deadline = Date.now.addingTimeInterval(90 * 86400)
    @State private var testing = false
    @State private var models: [DeepSeekAvailableModel] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 AI 训练", isOn: $configuration.enabled)
                    Toggle("跑后自动生成新计划", isOn: $configuration.automatic).disabled(!configuration.enabled)
                } footer: {
                    Text("开启后，将目标、可训练时间、近六周训练摘要、最近三次分段统计、个人纪录、可用恢复背景及你单独授权的跑后反馈发送到所配置的模型服务。路线坐标留在本机。后台未完成的分析会在下次打开时补做。")
                }
                Section("目标") {
                    TextField("例如：12月半马提升成绩", text: $profile.goal, axis: .vertical).lineLimit(2...4)
                    if !journal.data.races.isEmpty {
                        Menu("使用已有赛事目标") {
                            ForEach(journal.data.races.filter { $0.date >= AIDate.localCalendar.startOfDay(for: .now) }) { race in
                                Button(race.name) {
                                    useRace(race)
                                }
                            }
                        }
                    }
                    TextField("目标距离 km（可选）", text: $distance).keyboardType(.decimalPad)
                    TextField("目标用时，如 01:45:00（可选）", text: $targetTime).keyboardType(.numbersAndPunctuation)
                    Toggle("设置目标日期", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("目标日期", selection: $deadline, in: AIDate.localCalendar.startOfDay(for: .now)..., displayedComponents: .date) }
                }
                Section("可训练时间") {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(dayName(day), isOn: Binding(
                            get: { profile.availableDays.contains(day) },
                            set: { on in
                                if on { profile.availableDays.append(day); profile.availableDays.sort() }
                                else { profile.availableDays.removeAll { $0 == day } }
                                if !profile.availableDays.contains(profile.longRunDay), let first = profile.availableDays.first {
                                    profile.longRunDay = first
                                }
                            }))
                    }
                    Stepper("普通训练最多 \(Int(profile.minutesPerDay)) 分钟", value: $profile.minutesPerDay, in: 10...300, step: 5)
                    Picker("长距离适合安排在", selection: $profile.longRunDay) {
                        ForEach(profile.availableDays, id: \.self) { Text(dayName($0)).tag($0) }
                    }
                    Stepper("该日最多 \(Int(profile.longRunMinutes)) 分钟", value: $profile.longRunMinutes, in: 10...480, step: 10)
                }
                Section {
                    SecureField("DeepSeek API Key", text: $apiKey).textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("模型", selection: $configuration.model) {
                        if !models.contains(where: { $0.id == configuration.model }) {
                            Text(configuration.model == AITrainingConfiguration.defaultModel ? "DeepSeek V4.1 Flash（当前预置）" : configuration.model + "（当前保存）")
                                .tag(configuration.model)
                        }
                        ForEach(models) { model in Text(model.displayName).tag(model.id) }
                    }
                    if loadingModels { ProgressView("正在读取可用模型…") }
                    if let modelError { Text(modelError).font(.caption).foregroundStyle(.secondary) }
                    Button("刷新可用模型") { Task { await loadModels() } }
                        .disabled(loadingModels || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(testing ? "正在测试…" : "测试连接") {
                        testing = true
                        Task {
                            defer { testing = false }
                            do {
                                try await training.test(configuration: configuration, key: apiKey)
                                message = "连接成功。测试未发送运动数据。"
                            } catch { message = "测试连接失败：\(error.localizedDescription)" }
                        }
                    }.disabled(testing || apiKey.isEmpty)
                } header: { Text("DeepSeek") } footer: { Text("密钥仅保存到这台设备的钥匙串。") }
                Section("高级设置") {
                    TextField("HTTPS 基础地址", text: $configuration.baseURL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("模型标识", value: configuration.model).font(.caption).textSelection(.enabled)
                    Button("恢复官方预置") {
                        configuration.baseURL = AITrainingConfiguration.defaultBaseURL
                        configuration.model = AITrainingConfiguration.defaultModel
                    }
                    NavigationLink("发送数据与完整提示词") { AITrainingDataGuide() }
                }
            }
            .disabled(training.isWorking)
            .navigationTitle("AI 训练设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(testing || training.isWorking) }
            }
            .onAppear {
                profile = training.state.profile
                configuration = training.state.configuration
                apiKey = training.key
                distance = profile.targetDistanceKm.map { String(format: "%g", $0) } ?? ""
                targetTime = profile.targetSeconds.map { TrainingFormat.duration($0) } ?? ""
                hasDeadline = profile.targetDate != nil
                deadline = profile.targetDate ?? .now.addingTimeInterval(90 * 86400)
                if let initialRace { useRace(initialRace) }
            }
            .task(id: configuration.baseURL + "|" + apiKey) {
                models = []
                modelError = nil
                guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                await loadModels()
            }
            .alert("AI 训练", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
    @MainActor private func loadModels() async {
        let requestedBase = configuration.baseURL
        let requestedKey = apiKey
        loadingModels = true
        modelError = nil
        defer { if requestedBase == configuration.baseURL && requestedKey == apiKey { loadingModels = false } }
        do {
            let available = try await training.availableModels(configuration: configuration, key: apiKey)
            try Task.checkCancellation()
            guard requestedBase == configuration.baseURL && requestedKey == apiKey else { return }
            models = available
        } catch is CancellationError {} catch {
            if !Task.isCancelled && requestedBase == configuration.baseURL && requestedKey == apiKey { modelError = "无法读取模型列表：" + error.localizedDescription }
        }
    }

    private func useRace(_ race: RaceGoal) {
        profile.useRaceGoal(race)
        distance = String(format: "%g", race.distanceKm)
        targetTime = race.targetSeconds.map(TrainingFormat.duration) ?? ""
        deadline = race.date
        hasDeadline = true
    }

    private func dayName(_ day: Int) -> String { ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1] }
    private func save() {
        do {
            let distanceText = distance.trimmingCharacters(in: .whitespacesAndNewlines)
            let timeText = targetTime.trimmingCharacters(in: .whitespacesAndNewlines)
            if !distanceText.isEmpty && Double(distanceText) == nil { throw AITrainingError.invalid("目标距离格式不正确。") }
            if !timeText.isEmpty && AITrainingProfile.targetTime(timeText) == nil { throw AITrainingError.invalid("目标用时请使用 时:分:秒，分钟和秒应小于 60。") }
            profile.targetDistanceKm = Double(distanceText)
            profile.targetSeconds = timeText.isEmpty ? nil : AITrainingProfile.targetTime(timeText)
            profile.targetDate = hasDeadline ? deadline : nil
            try training.save(profile: profile, configuration: configuration, key: apiKey)
            dismiss()
            Task { await RunningArchiveRuntime.shared.refresh(authorize: true) }
        } catch { message = error.localizedDescription }
    }
}

extension View {
    func nativeCard() -> some View {
        self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .containerShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct AITrainingDataGuide: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var requestJSON: String?
    @State private var preparing = false
    @State private var error: String?

    var body: some View {
        List {
            Section("主观反馈的使用范围") {
                Text("subjective_feedback 只包含近六周已授权的实际跑步反馈。每条可选择仅本机、评分、评分及该条备注；旧记录默认仅本机。用力程度、感受、跑后疲劳及填写/修改时间独立提供，不用于重算心率负荷、区间或能力指标。")
                Text("AI 需引用具体反馈，解释对七天计划的响应或未调整的原因。修改或撤回授权会使旧请求失效，历史计划保留当时的依据；私人备注与路线名称不会自动发送。")
            }
            Section("目标与时间") {
                Text("目标文字、目标距离（km）、目标用时（秒）、目标当地日期；每周可训练日（周一=1）、普通日时长上限、长距离日与该日时长上限。")
                Text("当地时区、今天、计划起止日期、42 天回看窗口；任务为分析实际跑步并生成新的七天计划。今天已跑步时，从明天开始安排七天。")
            }
            Section("最近 42 天 · 每次跑步摘要") {
                Text("记录 ID、开始时间、当地日期、距离 km、运动秒数、全程秒/km、平均/最高心率 bpm、平均功率 W、平均步频 步/分钟。缺失字段不补零。")
                Text("摘要由 App 直接读取 HealthKit 活动统计并计算距离 ÷ 用时关系，无需模型生成；平均配速为运动秒数 ÷ 距离。")
            }
            Section("按周统计 · 本机计算") {
                Text("按当地周一到周日分组：周开始、周结束（不包含该日）、是否不足一周、总公里数、次数、运动秒数之和、最长一次公里数。42 天窗口可能跨七个自然周，首尾会标注 partial_week。训练间隔可由逐次日期计算；不额外推测训练标签。")
            }
            Section("最近三次 · 分段与五分钟统计") {
                Text("室内标记、累计爬升 m、全程经过秒数、已知暂停秒数、全程采样均值与覆盖比例、HealthKit 已记录的分段/间歇事件。")
                Text("GPS 公里分段：序号、实际段长 km（末段可能不足 1 km）、经过秒数、已知的运动秒数、GPS 估算标记、该段指标均值与覆盖。")
                Text("每 300 秒一个窗口：起止经过秒数及各指标均值、覆盖比例。指标为心率 bpm、速度 m/s、功率 W、步频 步/分钟、步长 m、触地时间 ms、垂直振幅 cm；不把逐秒原始采样或经纬度发给模型。")
                Text("均值按有效采样覆盖的时间加权；步数区间先换算步频。coverage 为该段被有效数据覆盖的时长比例，不足覆盖不会被外推为全程测量。暂停口径未知时 active_seconds / pause_seconds 缺省。")
            }
            Section("可用体能参考") {
                Text("VO₂ max（ml/kg/min）与系统记录的一分钟心率恢复（bpm）；各带记录日期、数值、单位和是否标注为实验室测量的说明。只取最近 42 天，每种指标最多 30 条。静息心率、HRV 和睡眠归入下面的恢复背景。")
            }
            Section("恢复与其他运动 · 可用时") {
                Text("近 56 天静息心率 bpm、HRV SDNN ms，按单一来源与相同采样时段生成每日中位数和样本数；不混用 SDNN 与 RMSSD。")
                Text("近 56 天实际入睡时长：按当地中午切分、同来源合并重叠时段，不把卧床或清醒算作入睡，不把多个 App 的相同睡眠重复相加。最新窗口标注 partial_window，可能包含午睡，不等于完整监测。")
                Text("最近 180 天内最新体重 kg 及记录日期；近 42 天最多 100 条其他运动的日期、类型、运动秒数、可用活动能量 kcal。用于补充实际活动背景。")
                Text("缺失不代表零；模型只能结合个人趋势辅助判断，不推算疲劳分数或诊断疾病。首次使用会请求对应健康读取权限。")
            }
            Section("历史个人纪录 · 四种距离") {
                Text("5 km、10 km、半马、全马各自的历史最佳整次活动成绩，以及已在本机分析的 GPS 最快片段（最多 8 条），遵守个人纪录页面的排除设置。")
                Text("每条含距离类别、标准距离、记录 ID、日期、原活动距离、用时秒数、计算口径、官方成绩未验证标记。整次活动接受标准距离至 +3%，不按均速折算；GPS 片段采用包含停留的经过时间。未分析过的 GPS 片段不临时猜算。历史 PB 只作背景，不能直接视为当前能力。")
            }
            Section("缺失与读取说明") {
                Text("发送读取失败、缺失字段和采样限制的说明。每次依据实际跑步、PB、目标和可训练时间独立分析并生成新的七天计划。")
                Text("不提供姓名、经纬度、设备标识或伤病诊断；附带当前最大心率依据（年龄公式估算或手动覆盖）与可用的近期能力标定；出生日期不发送。API Key 只在请求鉴权头中使用。")
            }
            Section("本机训练分析") {
                Text("优先读取Apple运动保存的心率区间；历史缺失时按当前区间重新分类并注明来源。Apple区间与Edwards区间分别提供，不能混用权重。最大心率默认采用Tanaka成人年龄公式208−0.7×年龄，明确标为估算；可选手动覆盖。原始出生日期不保存、不发送。")
                Text("Edwards心率负荷、7/42日指数加权趋势、稳定片段的速度/心率效率与漂移、周结构、同来源跑姿比较、经典成绩指数及恢复基线变化。逐项附单位、方法版本、覆盖、不可用原因和依据记录；过程数据未整理完成时明确缺失。")
                Text("最大心率可按年龄公式估算，并明确标注估算依据；近期比赛/测试未经标定时，计划不返回精确训练配速。负荷仅含跑步，恢复不生成准备度分数。")
                NavigationLink("查看公式与筛选规则") { TrainingAnalysisMethodsView() }
            }
            Section("查看实际 JSON") {
                Text("按已保存设置在本机整理待发送数据，仅预览，不调用模型。包含你的运动数据。")
                Button(preparing ? "正在整理…" : "预览待发送数据") { Task { await prepare() } }.disabled(preparing)
                if let error { Text(error).foregroundStyle(.secondary) }
                if let requestJSON {
                    NavigationLink("打开完整数据 JSON") {
                        ScrollView { Text(requestJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                            .navigationTitle("待发送数据")
                    }
                }
            }
            Section("完整 System 提示词 · \(AITrainingPrompt.version)") {
                Text(AITrainingPrompt.system).font(.caption).textSelection(.enabled)
            }
            Section("请求与接收") {
                Text("System 消息为上述完整提示词；User 消息是结构化 JSON 数据。要求 json_object、非流式返回；默认模型 deepseek-flash，开启思考、high reasoning_effort，最多 16384 输出 token。模型列表由 GET /models 查询。")
                Text("返回 stage、summary、run_review、七条 sessions、limitations。App 校验日期、可训练日、时长、步骤合计、配速范围和依据 ID；通过后保存版本并展示为原生页面，失败则保留旧计划。")
            }
        }.navigationTitle("数据与完整提示词").navigationBarTitleDisplayMode(.inline)
    }

    @MainActor private func prepare() async {
        preparing = true
        error = nil
        defer { preparing = false }
        do {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            calendar.firstWeekday = 2
            let now = Date.now
            let cutoff = calendar.date(byAdding: .day, value: -42, to: calendar.startOfDay(for: now))!
            let runs = archive.activities.filter { $0.date >= cutoff && $0.date <= now }.sorted { $0.date < $1.date }
            try await archive.requestAIContextAccess()
            await RunningArchiveRuntime.shared.analytics.prepareHeartRateProfile(archive: archive, authorize: true)
            let input = try await training.makeInput(archive: archive, journal: journal.data, activities: runs, now: now, calendar: calendar)
            let object = try JSONSerialization.jsonObject(with: input.encoded())
            requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        } catch { self.error = error.localizedDescription }
    }
}
