import Charts
import SwiftUI

enum TrainingAnalysisSection: String, CaseIterable, Identifiable {
    case load = "训练负荷", aerobic = "相似跑步对比", structure = "跑量与频率"
    case performance = "跑步表现", recovery = "睡眠与心率", form = "跑姿与功率"
    var id: Self { self }
    var icon: String {
        switch self {
        case .load: "waveform.path.ecg"; case .aerobic: "heart"; case .structure: "chart.bar"
        case .performance: "chart.line.uptrend.xyaxis"; case .recovery: "moon.zzz"; case .form: "figure.run"
        }
    }
    var detail: String {
        switch self {
        case .load: "最近是否比平常练得更多"
        case .aerobic: "同样的心率，能否跑得更快"
        case .structure: "跑了多少，训练如何分布"
        case .performance: "完成过什么成绩，如何理解换算"
        case .recovery: "最近睡眠和心率是否偏离平时"
        case .form: "相近配速下，动作有什么变化"
        }
    }
}

struct TrainingAnalysisEntry: View {
    var body: some View {
        NavigationLink { TrainingAnalysisHome() } label: {
            HStack(spacing: 14) {
                Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(RunTheme.route)
                VStack(alignment: .leading, spacing: 4) {
                    Text("训练分析").font(.headline).foregroundStyle(.primary)
                    Text("近期状态、跑步表现与下次训练").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.nativeCard()
        }.buttonStyle(.plain)
    }
}

struct TrainingAnalysisHome: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var analytics: TrainingAnalysisStore
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var weekMetric = "跑量"
    @State private var selectedWeek: Date?
    private var dashboard: TrainingDashboard {
        TrainingDashboard(summaries: analytics.summaries, records: values, timeline: analytics.loadTimeline(now: .now), now: .now, calendar: analytics.calendar)
    }
    private var values: [RunTrainingAnalysis] { analytics.validRecords }
    private var loadInsight: AnalysisInsight {
        let days = analytics.loadTimeline(now: .now)
        return AnalysisInsights.load(days.last, hasMeasurements: values.contains { $0.load.usable })
    }
    private var best: AnalysisPerformance? {
        values.compactMap(\.performance).filter { $0.date >= Date.now.addingTimeInterval(-90 * 86400) }.max { $0.index < $1.index }
    }
    var body: some View {
        let data = dashboard
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                weeklyCard(data)
                if analytics.isWorking || analytics.isPreparing || analytics.isPaused {
                    HStack {
                        if !analytics.isPaused { ProgressView().controlSize(.small) }
                        Text(analytics.isPaused ? "已暂停历史整理，已有分析仍可查看" : (analytics.isPreparing ? "正在检查需要更新的数据…" : analytics.progress)).font(.caption)
                        Spacer()
                        if analytics.isPaused {
                            Button("继续") { analytics.resume(archive: archive) }.font(.caption)
                        } else {
                            Button("暂停") { analytics.stop() }.font(.caption)
                        }
                    }.nativeCard()
                }
                loadCard(data)
                latestRunCard(data)
                TrainingFeedbackHistoryCard()
                adviceCard
                aerobicCard(data)
                VStack(alignment: .leading, spacing: 12) {
                    Label("跑步表现", systemImage: "figure.run").font(.subheadline).foregroundStyle(.secondary)
                    if let best {
                        Text(String(format: "%.2f公里 · ", best.distanceKm) + analysisTime(best.elapsedSeconds)).font(.title3.bold())
                        Text(best.date.formatted(.dateTime.month().day()) + "完成的近期较好表现。轻松跑成绩较慢，不会据此判定能力下降。")
                            .font(.subheadline)
                    } else {
                        Text("先看你真正完成过的成绩").font(.title3.bold())
                        Text("5公里、10公里、半马和全马纪录，比一个没有个人参照的分数更直观。")
                            .font(.subheadline)
                    }
                    NavigationLink("查看个人纪录与表现") { TrainingAnalysisModule(section: .performance) }.font(.subheadline)
                }.nativeCard()
                DisclosureGroup("辅助数据") {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink("睡眠与心率记录") { TrainingAnalysisModule(section: .recovery) }
                        Text("作为训练建议的背景；跑姿和功率可在单次记录中展开查看。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = analytics.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                    }.font(.subheadline).padding(.top, 12)
                }.nativeCard()
            }.padding(16)
        }
        .background(RunTheme.page).navigationTitle("训练分析").navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { TrainingAnalysisSettingsView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("分析设置")
        } }
        .task { await analytics.prepareHeartRateProfile(archive: archive, authorize: true); analytics.start(archive: archive, recoveryAccess: true) }
        .refreshable { await analytics.refresh(archive: archive) }
    }
    private func weeklyCard(_ data: TrainingDashboard) -> some View {
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本周训练", systemImage: "calendar").font(.headline)
                Spacer()
                Text("周一至今").font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { weekNumbers(data) }
                VStack(alignment: .leading, spacing: 12) { weekNumbers(data) }
            }
            Picker("周趋势指标", selection: $weekMetric) { Text("跑量").tag("跑量"); Text("心率负荷").tag("负荷") }.pickerStyle(.segmented)
            Chart(data.weeks) { week in
                BarMark(x: .value("周", week.start, unit: .weekOfYear), y: .value(weekMetric == "跑量" ? "公里" : "已知负荷", weekMetric == "跑量" ? week.kilometers : week.knownLoad))
                    .foregroundStyle(week.start == data.current.start ? RunTheme.accent : RunTheme.route)
                    .opacity(weekMetric == "负荷" && !week.complete ? 0.4 : 1)
            }.frame(height: 110).chartYAxisLabel(weekMetric == "跑量" ? "km" : "AU")
                .chartXSelection(value: $selectedWeek)
                .accessibilityLabel("近8周" + (weekMetric == "跑量" ? "跑量" : "已知心率负荷") + "趋势")
            if let selectedWeek, let week = data.weeks.first(where: { selectedWeek >= $0.start && selectedWeek < analytics.calendar.date(byAdding: .day, value: 7, to: $0.start)! }) {
                Text(week.start.formatted(.dateTime.month().day()) + String(format: " 起 · %.1f km · %d次 · %.0f AU", week.kilometers, week.count, week.knownLoad) + (week.complete ? "" : "（仅已知负荷）"))
                    .font(.caption).monospacedDigit()
            }
            Text(weekMetric == "跑量" ? String(format: "上周完整周 %.1f km · %d 次；本周尚未结束。", data.previous.kilometers, data.previous.count) : "按跑步开始日归周。浅色柱表示有缺失，仅展示已知负荷；空柱不一定代表休息。")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink("查看训练分布与历史") { TrainingAnalysisModule(section: .structure) }.font(.subheadline)
        }.nativeCard()
    }
    @ViewBuilder private func weekNumbers(_ data: TrainingDashboard) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.1f", data.current.kilometers) + " km").font(.title.bold()).monospacedDigit()
            Text("已完成 \(data.current.count) 次跑步").font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 3) {
            Text(data.current.measured == 0 && data.current.count > 0 ? "—" : String(format: "%.0f AU", data.current.knownLoad)).font(.title2.bold()).monospacedDigit()
            Text(data.current.complete ? "本周心率负荷" : "已知负荷 · \(data.current.measured)/\(data.current.count) 次完整").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func loadCard(_ data: TrainingDashboard) -> some View {
        let insight = loadInsight
        return VStack(alignment: .leading, spacing: 12) {
            Label("近期训练状态", systemImage: "waveform.path.ecg").font(.headline)
            Text(insight.headline).font(.title3.bold())
            if let ratio = data.loadRatio {
                Text(String(format: "%.2f ×", ratio)).font(.system(.largeTitle, design: .rounded).bold()).monospacedDigit()
                Text("短期负荷 / 长期负荷 · 1.00 表示两者相等").font(.caption).foregroundStyle(.secondary)
            }
            if let day = data.loadDay, data.measuredCount > 0 {
                HStack(spacing: 24) {
                    analysisNumber("短期 · 7日", day.shortLoad, unit: "AU/日")
                    analysisNumber("长期 · 42日", day.longLoad, unit: "AU/日")
                }
                Text("指数加权日均" + (data.loadRatio == nil ? " · 仅已知数据，参照尚未完整" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("近28天心率负荷覆盖 \(data.measuredCount)/\(data.recentCount) 次跑步").font(.caption).foregroundStyle(.secondary)
            if data.loadRatio == nil { Text(insight.detail).font(.subheadline) }
            NavigationLink("查看曲线与每次训练负荷") { TrainingAnalysisModule(section: .load) }.font(.subheadline)
            DisclosureGroup("怎样理解这些数值") {
                Text(insight.note + " 本 App 使用 Edwards 心率负荷，只统计跑步，AU是相对单位。短长期比值不能单独代表恢复程度或受伤风险，也不能与高驰分数直接比较。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }.nativeCard()
    }
    @ViewBuilder private func latestRunCard(_ data: TrainingDashboard) -> some View {
        if let latest = data.latest {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("最近一次跑步", systemImage: "figure.run").font(.headline)
                    Spacer()
                    Text(latest.date.formatted(.dateTime.month().day())).font(.caption).foregroundStyle(.secondary)
                }
                Text(String(format: "%.2f km · ", latest.kilometers) + analysisTime(latest.seconds)).font(.title3.bold())
                if let run = data.latestAnalysis {
                    let insight = AnalysisInsights.session(run, history: values)
                    if run.load.usable, let load = run.load.value { Text(String(format: "心率负荷 %.0f AU", load)).font(.subheadline.bold()) }
                    Text(insight.headline).font(.subheadline)
                    Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                } else { Text("过程数据待整理；完成后显示这次跑步对训练负荷的影响。").font(.caption).foregroundStyle(.secondary) }
                if let activity = archive.activities.first(where: { $0.id == latest.id }) {
                    NavigationLink("查看这次跑步与分段") { ActivityDetailView(activity: activity) }.font(.subheadline)
                }
            }.nativeCard()
        }
    }
    private func aerobicCard(_ data: TrainingDashboard) -> some View {
        let trend = data.aerobic
        return VStack(alignment: .leading, spacing: 12) {
            Label("有没有进步", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
            if let change = trend.percent {
                Text(String(format: "%+.1f%%", change)).font(.title.bold()).monospacedDigit()
                Text("稳定跑速度/心率比 · 最近28天对比此前28天").font(.subheadline)
                Text("近期 \(trend.recentCount) 次 / 此前 \(trend.baselineCount) 次符合条件的跑步；正值表示单位心率对应的速度更高，仍会受天气等条件影响。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("等待更多条件相近的跑步").font(.title3.bold())
                Text(trend.reason ?? "需要两组各至少3次符合条件的稳定跑，避免把轻松跑或间歇跑的差异当成能力变化。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink("查看入选记录与比较条件") { TrainingAnalysisModule(section: .aerobic) }.font(.subheadline)
        }.nativeCard()
    }
    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("接下来怎么练", systemImage: "sparkles").font(.subheadline).foregroundStyle(.secondary)
            if let revision = training.current {
                let newerRun = archive.activities.contains { $0.date > revision.createdAt }
                let feedbackChanged = TrainingFeedback.stale(snapshot: revision.feedbackContext, activities: archive.activities, journal: journal.data, now: .now, calendar: AIDate.localCalendar)
                let ended = (revision.plan.sessions.map(\.date).max() ?? "") < AIDate.key(.now, calendar: .current)
                let profileChanged = revision.profileContext.map { $0 != training.state.profile } ?? false
                if profileChanged { Label("训练目标或时间已变化，阶段待更新", systemImage: "arrow.clockwise").font(.subheadline) }
                if feedbackChanged { Label("跑后反馈已变化，建议待更新", systemImage: "arrow.clockwise").font(.subheadline) }
                Text(newerRun ? "有新跑步，建议待更新" : (ended ? "上次计划已结束" : revision.plan.stage)).font(.title3.bold())
                Text(newerRun ? "上次分析之后新增了跑步记录，查看并更新建议后再安排下一次训练。" : (ended ? "结合最近记录更新后续安排，旧计划仍保留在历史中。" : revision.plan.summary))
                    .font(.subheadline).lineLimit(4)
                if !newerRun && !ended && !feedbackChanged && !profileChanged, let next = revision.plan.sessions.sorted(by: { $0.date < $1.date }).first(where: { session in
                    session.date >= AIDate.key(.now, calendar: .current) && !training.state.isCompleted(session)
                }) {
                    Divider()
                    Text(next.date + " · " + next.kind.title).font(.headline)
                    if next.kind != .rest { Text(String(format: "%.0f 分钟 · ", next.duration_minutes) + next.intensity).font(.subheadline) }
                    Text(next.purpose).font(.caption).foregroundStyle(.secondary)
                }
                Text("AI建议 · " + revision.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("让近期训练直接变成下一步安排").font(.title3.bold())
                Text("结合最近几次跑步、个人纪录、睡眠和你的目标，解释训练重点并安排下一次训练。")
                    .font(.subheadline)
            }
            NavigationLink("查看阶段训练与七天执行") { AITrainingView() }.font(.subheadline)
        }.nativeCard()
    }
}

struct TrainingAnalysisModule: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var analytics: TrainingAnalysisStore
    let section: TrainingAnalysisSection
    var month: Date? = nil
    @State private var days = 84
    @State private var selectedDate: Date?
    @State private var selectedFormMetric: ExportMetric = .steps
    private var start: Date { month ?? (days == 366 ? analytics.calendar.dateInterval(of: .year, for: .now)!.start : analytics.calendar.date(byAdding: .day, value: -days, to: .now)!) }
    private var end: Date { month.flatMap { analytics.calendar.date(byAdding: .month, value: 1, to: $0) } ?? .now }
    private var records: [RunTrainingAnalysis] { analytics.validRecords.filter { $0.date >= start && $0.date < end } }
    private var runs: [AnalysisRunSummary] { analytics.summaries.filter { $0.date >= start && $0.date < end } }
    private var context: TrainingAnalysisContext { analytics.context(activities: archive.activities, now: .now) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if month == nil && section != .recovery {
                    Picker("观察范围", selection: $days) {
                        Text("四周").tag(28); Text("十二周").tag(84); Text("本年").tag(366)
                    }.pickerStyle(.segmented)
                }
                Group {
                    switch section {
                    case .load: loadBody
                    case .aerobic: aerobicBody
                    case .structure: structureBody
                    case .performance: performanceBody
                    case .recovery: recoveryBody
                    case .form: formBody
                    }
                }
                DisclosureGroup("数据状态") { coverageCard.padding(.top, 8) }.font(.caption)
            }.padding(16)
        }
        .background(RunTheme.page).navigationTitle(section.rawValue).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { TrainingAnalysisSettingsView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("分析设置")
        } }
        .task {
            await analytics.prepareHeartRateProfile(archive: archive, authorize: true)
            analytics.start(archive: archive, recoveryAccess: section == .recovery)
            if let month {
                // Older monthly summaries stay immediate; only that month's raw records are requested here.
                for activity in archive.activities.filter({ $0.date >= month && $0.date < end }) {
                    if Task.isCancelled { break }
                    _ = try? await analytics.analyze(activity: activity, archive: archive)
                }
                analytics.flush()
            }
        }
        .onChange(of: days) { _, value in analytics.start(archive: archive, days: value == 366 ? (analytics.calendar.ordinality(of: .day, in: .year, for: .now) ?? 126) + 126 : 126) }
    }
    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据覆盖").font(.subheadline.weight(.semibold))
            Text("当前范围 \(runs.count) 次跑步，\(records.count) 次已整理过程数据。缺失不计为零，图表保留不可比较条件。")
            if analytics.isWorking || analytics.isPreparing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(analytics.isPreparing ? "正在检查更新…" : analytics.progress)
                    Button("暂停") { analytics.stop() }
                }
            } else if analytics.isPaused {
                Text("已暂停历史整理")
                Button("继续整理") { analytics.resume(archive: archive) }
            } else {
                Text(analytics.progress)
                Button("重新读取与计算") { Task { await analytics.refresh(archive: archive) } }
            }
            if let error = analytics.errorMessage { Text(error) }
        }.font(.caption).foregroundStyle(.secondary).nativeCard()
    }
    @ViewBuilder private var loadBody: some View {
        if analytics.calibration.validMaximum(at: .now) == nil {
            VStack(alignment: .leading, spacing: 14) {
                Text("暂时缺少心率负荷参考").font(.headline)
                Text(analytics.heartRateProfile?.ageStatus ?? "正在读取健康年龄。未获得适用年龄时，Apple区间仍可独立展示。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("重新读取健康资料") { Task { await analytics.prepareHeartRateProfile(archive: archive, authorize: true, force: true); analytics.start(archive: archive) } }.buttonStyle(.bordered)
                Text("请在Apple健康中填写出生日期并允许读取。手动最大心率是可选覆盖，不要求额外测试。")
                    .font(.caption).foregroundStyle(.secondary)
            }.nativeCard()
            appleZoneOverview
        } else {
            let coverage = TrainingAnalysisMath.loadCoverage(runs, analyses: records)
            if coverage.calculated == 0 || coverage.pending > 0 || !coverage.reasons.isEmpty || coverage.complete < coverage.expected { loadCoverageCard(coverage) }
            let hasLoad = records.contains { $0.load.value != nil }
            let allDays = analytics.loadTimeline(now: .now)
            let shown = allDays.filter { $0.date >= start && $0.date < end }
            if hasLoad, let last = shown.last {
                VStack(alignment: .leading, spacing: 14) {
                    let insight = AnalysisInsights.load(last, hasMeasurements: true)
                    Text(insight.headline).font(.title3.bold())
                    Text(insight.detail).font(.subheadline)
                    Text(insight.note).font(.caption).foregroundStyle(.secondary)
                    Chart(shown) { day in
                        LineMark(x: .value("日期", day.date), y: .value("负荷", day.shortLoad), series: .value("类型", "短期"))
                            .foregroundStyle(by: .value("类型", "短期"))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: day.completeHistory ? [] : [4, 3]))
                        LineMark(x: .value("日期", day.date), y: .value("负荷", day.longLoad), series: .value("类型", "长期"))
                            .foregroundStyle(by: .value("类型", "长期"))
                    }.frame(height: 200).chartForegroundStyleScale(["短期": RunTheme.accent, "长期": RunTheme.route])
                        .chartYAxisLabel("AU/日").chartXSelection(value: $selectedDate)
                    if let selectedDate, let picked = shown.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                        Text(picked.date.formatted(.dateTime.month().day()) + String(format: " · 短期 %.1f / 长期 %.1f AU/日", picked.shortLoad, picked.longLoad)).font(.caption).monospacedDigit()
                    }
                    DisclosureGroup("查看负荷数值") {
                        HStack(spacing: 24) {
                            analysisNumber("短期", last.shortLoad, unit: "AU/日")
                            analysisNumber("长期", last.longLoad, unit: "AU/日")
                        }.padding(.top, 8)
                    }.font(.caption)
                    DisclosureGroup("曲线说明") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("7日更敏感，42日提供较长时间的训练背景。短期高于长期，表示最近的加权训练刺激更高；不等于疲劳或受伤风险。")
                            Text("只包含跑步。缺失数据不补零；历史需126日预热，未完整时不能判断是否已恢复。")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.caption)
                }.nativeCard()
            }
            appleZoneOverview
            DisclosureGroup("心率参考与估算依据") { maximumReferenceCard.padding(.top, 8) }.font(.caption)
            runRows(records.sorted { $0.date > $1.date }) { run in
                VStack(alignment: .leading, spacing: 12) {
                    let insight = AnalysisInsights.session(run, history: analytics.validRecords)
                    Text(insight.headline).font(.subheadline.weight(.medium))
                    Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                    if let zones = run.appleHeartRateZones {
                        DisclosureGroup("Apple心率区间") { AppleHeartRateZonesContent(zones: zones).padding(.top, 10) }.font(.subheadline)
                    }
                }
            }
        }
    }
    @ViewBuilder private var appleZoneOverview: some View {
        if let latest = records.sorted(by: { $0.date > $1.date }).first(where: { $0.appleHeartRateZones != nil }), let zones = latest.appleHeartRateZones {
            VStack(alignment: .leading, spacing: 12) {
                Text("Apple心率区间").font(.headline)
                Text("最近一次 · " + latest.date.formatted(.dateTime.month().day())).font(.caption).foregroundStyle(.secondary)
                AppleHeartRateZonesContent(zones: zones, compact: true)
            }.nativeCard()
        } else if let zones = analytics.heartRateProfile?.preferredZones {
            VStack(alignment: .leading, spacing: 12) {
                Text("Apple当前心率区间").font(.headline)
                AppleHeartRateZonesContent(zones: zones, compact: true)
            }.nativeCard()
        } else {
            analysisMessage("Apple心率区间", analytics.heartRateProfile?.zoneStatus ?? "正在读取Apple心率区间；历史记录可能没有保存区间信息。")
        }
    }
    private var maximumReferenceCard: some View {
        let reference = analytics.calibration.reference(at: .now)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(reference.estimated ? "最大心率 · 自动估算" : "最大心率参考").font(.subheadline.weight(.semibold))
                Spacer()
                Text(reference.bpm.map { String(format: "%.1f bpm", $0) } ?? "—").font(.subheadline).monospacedDigit()
            }
            Text(reference.estimated ? "根据健康中的年龄估算，可能与实际最大心率有差异。" : "采用你设置的最大心率参考。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("估算依据与用途") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reference.explanation)
                    Text("只用于Edwards参考负荷；Apple心率区间单独读取，不由此公式生成。可在右上角设置中手动覆盖。")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }.nativeCard()
    }
    private func loadCoverageCard(_ coverage: AnalysisLoadCoverage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(coverage.calculated > 0 ? "当前范围 · \(coverage.calculated) 次有负荷结果" : (analytics.isWorking ? "正在计算心率负荷" : "当前范围暂无可计算负荷"))
                .font(.headline)
            Text("已整理 \(coverage.processed)/\(coverage.expected) 次 · \(coverage.complete) 次满足计算条件")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(coverage.reasons, id: \.reason) { item in
                Text("\(item.count) 次：\(item.reason)").font(.caption).foregroundStyle(.secondary)
            }
            if coverage.pending > 0 {
                Text("\(coverage.pending) 次尚未得到过程结果，不会作为零负荷。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if coverage.expected == 0 {
                Text("当前日期范围没有跑步记录，可切换十二周或本年查看。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !analytics.isWorking && coverage.calculated < coverage.expected {
                Button("重新读取心率数据") { analytics.start(archive: archive, force: true) }.font(.subheadline)
            }
        }.nativeCard()
    }
    @ViewBuilder private var aerobicBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相似跑步中的效率变化").font(.headline)
            if let trend = context.aerobic.first {
                AnalysisTrendRow(title: "速度 / 心率效率", trend: trend, showGuide: false)
            }
            Text("比较窗口：近28天与此前28天；上方范围仅控制下面的记录图表。")
                .font(.caption).foregroundStyle(.secondary)
            if analytics.calibration.reference(at: .now).bpm == nil {
                Text("尚未获得适用年龄或手动最大心率，无法确认低强度条件。可在右上角检查健康资料授权与参考设置。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if analytics.calibration.reference(at: .now).estimated {
                Text("低强度筛选依赖年龄估算最大心率，存在个体误差；不代表实测强度分区。").font(.caption).foregroundStyle(.secondary)
            }
        }.nativeCard()
        let points = records.filter { $0.efficiency.usable }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("每次跑步的效率").font(.headline)
                Chart(points) { run in
                    PointMark(x: .value("日期", run.date), y: .value("米/心跳", run.efficiency.value!))
                        .foregroundStyle(run.efficiency.complete ? RunTheme.route : .gray)
                }.frame(height: 180).chartYScale(domain: analysisChartDomain(points.compactMap { $0.efficiency.value }, minimumSpan: 0.1))
                    .chartYAxisLabel("m/beat").chartXSelection(value: $selectedDate)
                if let selectedDate, let picked = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                    Text(picked.date.formatted(.dateTime.month().day()) + String(format: " · %.3f m/beat", picked.efficiency.value!)).font(.caption).monospacedDigit()
                }
                Text("只显示条件足够的记录；天气等因素仍可能影响比较。").font(.caption2).foregroundStyle(.secondary)
            }.nativeCard()
        }
        runRows(points.sorted { $0.date > $1.date }) { run in
            VStack(alignment: .leading, spacing: 8) {
                Text(AnalysisReading.metric(run.efficiency)).font(.subheadline)
                if run.drift.usable { Text(AnalysisReading.metric(run.drift)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        let exclusions = AnalysisInsights.aerobicExclusions(records)
        if !exclusions.isEmpty {
            DisclosureGroup("未纳入的\(records.count - points.count)次跑步") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这些跑步保留在记录中；不适合本次对比，不代表训练没有效果。")
                    ForEach(exclusions, id: \.reason) { item in Text("\(item.count)次：\(item.reason)") }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.nativeCard()
        }
    }
    private var structureBody: some View {
        let weeks = TrainingAnalysisMath.weeks(runs, analyses: records, now: .now, calendar: analytics.calendar)
        return VStack(alignment: .leading, spacing: 18) {
            if let week = weeks.max(by: { $0.start < $1.start }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近一周实际跑量").font(.headline)
                    Text(String(format: "这一周已跑%d次，共%.1f公里；最长一次%.1f公里。", week.count, week.kilometers, week.longestKm)).font(.subheadline)
                    Text("周一开始统计；未结束的一周为累计值，不直接与完整周比较。最长一次的占比用于观察跑量是否集中，不是达标分数。")
                        .font(.caption).foregroundStyle(.secondary)
                }.nativeCard()
            }
            appleZoneOverview
            VStack(alignment: .leading, spacing: 14) {
                Text("周跑量").font(.headline)
                if weeks.isEmpty { Text("当前范围没有记录").font(.subheadline).foregroundStyle(.secondary) }
                else {
                    Chart(weeks) { week in
                        BarMark(x: .value("周", week.start), y: .value("公里", week.kilometers)).foregroundStyle(RunTheme.route)
                    }.frame(height: 180).chartYAxisLabel("km").chartXSelection(value: $selectedDate)
                    if let selectedDate, let picked = weeks.min(by: { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) }) {
                        Text(picked.start.formatted(.dateTime.month().day()) + String(format: " 起 · %.1f km", picked.kilometers)).font(.caption).monospacedDigit()
                    }
                }
                Text("按周一开始分组 · km").font(.caption).foregroundStyle(.secondary)
            }.nativeCard()
            ForEach(weeks.reversed()) { week in
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(week.start.formatted(.dateTime.month().day())) 起的一周").font(.headline)
                    LabeledContent("跑量 / 次数", value: String(format: "%.1f km · %d 次", week.kilometers, week.count))
                    LabeledContent("累计运动时间", value: "\(Int(week.seconds / 60)) 分钟")
                    LabeledContent("最长一次", value: String(format: "%.1f km · 占周跑量 %.0f%%", week.longestKm, (week.longestShare ?? 0) * 100))
                    let coverage = week.expectedSeconds > 0 ? week.classifiedSeconds / week.expectedSeconds : 0
                    Text("已分类心率覆盖 \(Int(min(1, coverage) * 100))% 的运动时间；未覆盖部分不推算强度，边界周可能不完整。").font(.caption).foregroundStyle(.secondary)
                    if week.classifiedSeconds > 0 {
                        DisclosureGroup("查看强度分布") {
                            Text(analytics.calibration.reference(at: .now).estimated ? "Edwards参考分区 · 年龄估算" : "Edwards参考分区 · 手动最大心率").font(.caption.weight(.semibold))
                            if week.zoneSeconds[0] > 0 { LabeledContent("低于50%最大心率", value: String(format: "%.1f 分钟", week.zoneSeconds[0] / 60)).font(.caption) }
                            ForEach(1...5, id: \.self) { index in
                                HStack {
                                    Text("\(50 + (index - 1) * 10)–\(50 + index * 10)% 最大心率").font(.caption)
                                    Spacer()
                                    Text(String(format: "%.1f 分钟", week.zoneSeconds[index] / 60)).font(.caption).monospacedDigit()
                                }
                            }
                        }.font(.caption)
                    }
                }.font(.subheadline).nativeCard()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("训练间隔").font(.headline)
                let ordered = runs.sorted { $0.date < $1.date }
                if ordered.count < 2 { Text("至少需要两次跑步").font(.caption).foregroundStyle(.secondary) }
                else {
                    ForEach(Array(ordered.suffix(8).enumerated()), id: \.element.id) { _, run in
                        if let previous = ordered.last(where: { $0.date < run.date }) {
                            LabeledContent(run.date.formatted(.dateTime.month().day()), value: String(format: "距上次 %.1f 小时", run.date.timeIntervalSince(previous.date) / 3600)).font(.subheadline)
                        }
                    }
                }
            }.nativeCard()
        }
    }
    private var performanceBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink { PersonalRecordsView() } label: { Label("我的个人纪录", systemImage: "medal") }.nativeCard()
            let performances = records.compactMap(\.performance)
            if let best = performances.max(by: { $0.index < $1.index }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("这段时间完成过的较好表现").font(.subheadline).foregroundStyle(.secondary)
                    Text(String(format: "%.2f公里 · ", best.distanceKm) + analysisTime(best.elapsedSeconds)).font(.title2.bold())
                    Text(best.date.formatted(.dateTime.year().month().day())).font(.caption).foregroundStyle(.secondary)
                    Text(best.fullEffortConfirmed ? "你已确认这次充分发挥，可作为训练安排的参考。" : "先看这次实际完成的成绩；尚未确认是否充分发挥，不把它当成当前能力上限。")
                        .font(.subheadline)
                    Text("轻松跑慢一些不会被判定为能力下降。").font(.caption).foregroundStyle(.secondary)
                    if let activity = archive.activities.first(where: { $0.id == best.activityID }) {
                        NavigationLink("查看这次跑步") { ActivityDetailView(activity: activity) }.font(.subheadline)
                    }
                    DisclosureGroup("参考数值与其他距离换算") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("经典成绩指数", value: String(format: "%.1f", best.index))
                            ForEach([5.0, 10.0, 21.0975, 42.195], id: \.self) { distance in
                                if let seconds = TrainingAnalysisMath.equivalentSeconds(index: best.index, distanceKm: distance) {
                                    LabeledContent(distance == 21.0975 ? "半马" : (distance == 42.195 ? "全马" : "\(Int(distance)) km"), value: analysisTime(seconds))
                                }
                            }
                            Text("换算不保证能在实战完成；也不是高驰跑步能力分数。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }.font(.caption)
                }.nativeCard()
            }
            if let trend = context.aerobic.first, trend.recent != nil, trend.baseline != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("相似跑步中的变化").font(.headline)
                    Text(AnalysisReading.change(trend)).font(.subheadline)
                    Text("比较相近心率和速度的稳定片段，说明同样心率下跑得怎样；天气等条件仍会影响结果。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("查看可比较的跑步") { TrainingAnalysisModule(section: .aerobic) }.font(.subheadline)
                }.nativeCard()
            }
            DisclosureGroup("Apple记录的体能数据") {
                NavigationLink("VO₂ max与心率恢复") { ReferenceMetricTrendsView() }.padding(.top, 10)
            }.font(.subheadline).nativeCard()
        }
    }
    private var recoveryBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这些变化会作为AI训练建议的背景，不单独计算恢复分数。")
                .font(.subheadline).foregroundStyle(.secondary)
            if analytics.isRefreshingRecovery {
                HStack { ProgressView().controlSize(.small); Text("正在更新睡眠与心率") }.font(.caption)
            }
            let available = context.recovery.filter { AnalysisInsights.recovery($0) != nil }
            if available.isEmpty {
                analysisMessage("还不能和自己的平时水平比较", "睡眠或心率记录还不足。已有跑步分析和AI训练不受影响，这里不反复列出空数值。")
            }
            ForEach(available) { trend in
                if let insight = AnalysisInsights.recovery(trend) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(insight.headline).font(.headline)
                        Text(insight.detail).font(.subheadline)
                        Text(insight.note).font(.caption).foregroundStyle(.secondary)
                    }.nativeCard()
                }
            }
            DisclosureGroup("记录范围与可用数据") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("近期为7个完整日，此前为28日；只比较相同来源和采样时段。")
                    ForEach(context.recovery) { trend in
                        Text(analysisMetricName(trend.metric) + "：近期\(trend.recentCount)个有效日，此前\(trend.baselineCount)个。")
                        if trend.recent == nil, let reason = trend.reason { Text(reason) }
                    }
                    ForEach(analytics.recovery.notes, id: \.self) { Text($0) }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.caption).nativeCard()
        }
    }
    private var formBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("比较近28天与此前28天；图表显示当前所选范围。只在相近速度、相同来源下比较，数值高低不等于跑姿好坏。").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("稳定片段的测量变化").font(.headline)
                Picker("跑姿指标", selection: $selectedFormMetric) {
                    Text("步频").tag(ExportMetric.steps); Text("步幅").tag(ExportMetric.stride)
                    Text("触地").tag(ExportMetric.contact); Text("振幅").tag(ExportMetric.oscillation); Text("功率").tag(ExportMetric.power)
                }.pickerStyle(.segmented)
                Text(AnalysisReading.guide(selectedFormMetric.rawValue).meaning).font(.caption).foregroundStyle(.secondary)
                let points = records.compactMap { run -> (RunTrainingAnalysis, AnalysisFormValue)? in
                    guard run.efficiency.value != nil,
                          let form = run.stableForm.first(where: { $0.metric == selectedFormMetric.rawValue && $0.value.usable && !$0.sourceGroup.isEmpty }) else { return nil }
                    return (run, form)
                }
                let keys = Array(Set(points.map { $0.1.sourceGroup })).sorted()
                if points.isEmpty { Text("尚无符合稳定片段与覆盖条件的记录").font(.caption).foregroundStyle(.secondary) }
                else {
                    Chart(Array(points.enumerated()), id: \.offset) { _, pair in
                        PointMark(x: .value("日期", pair.0.date), y: .value(selectedFormMetric.unit, pair.1.value.value!))
                            .foregroundStyle(by: .value("来源", "来源组\((keys.firstIndex(of: pair.1.sourceGroup) ?? 0) + 1)"))
                    }.frame(height: 180).chartYScale(domain: analysisChartDomain(points.compactMap { $0.1.value.value }, minimumSpan: selectedFormMetric == .stride ? 0.1 : (selectedFormMetric == .oscillation ? 1 : 10)))
                        .chartYAxisLabel(selectedFormMetric.unit).chartXSelection(value: $selectedDate)
                    if let selectedDate, let p = points.min(by: { abs($0.0.date.timeIntervalSince(selectedDate)) < abs($1.0.date.timeIntervalSince(selectedDate)) }) {
                        Text(p.0.date.formatted(.dateTime.month().day()) + String(format: " · %.2f %@", p.1.value.value!, selectedFormMetric.unit)).font(.caption).monospacedDigit()
                    }
                }
                Text("图中不同来源分组着色；相近配速的严格比较见下方。").font(.caption2).foregroundStyle(.secondary)
            }.nativeCard()
            ForEach(context.form) { trend in
                VStack(alignment: .leading, spacing: 12) {
                    Text(analysisMetricName(trend.metric)).font(.headline)
                    AnalysisTrendRow(title: "近期水平", trend: trend)
                }.nativeCard()
            }
            runRows(records.sorted { $0.date > $1.date }) { run in
                VStack(spacing: 10) {
                    ForEach(run.form) { value in AnalysisMetricRow(title: analysisMetricName(value.metric), value: value.value, metric: value.metric) }
                }
            }
        }
    }
    private func runRows<Content: View>(_ runs: [RunTrainingAnalysis], @ViewBuilder content: @escaping (RunTrainingAnalysis) -> Content) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(runs) { run in
                if let activity = archive.activities.first(where: { $0.id == run.id }) {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink { RunTrainingAnalysisView(activity: activity) } label: {
                            HStack {
                                Text(run.date.formatted(.dateTime.month().day()))
                                Text(String(format: "%.2f km", run.distanceKm)).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.font(.subheadline.weight(.semibold))
                        }
                        content(run)
                    }.nativeCard()
                }
            }
        }
    }
}

struct RunTrainingAnalysisView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var analytics: TrainingAnalysisStore
    let activity: ArchiveActivity
    @State private var loading = false
    @State private var error: String?
    private var record: RunTrainingAnalysis? { analytics.record(id: activity.id) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(activity.date.formatted(.dateTime.year().month().day()) + String(format: " · %.2f km", activity.distanceKm)).font(.subheadline).foregroundStyle(.secondary)
                RunFeedbackCard(activity: activity)
                if loading { HStack { ProgressView(); Text("整理原始过程数据…") }.font(.subheadline).nativeCard() }
                if let record {
                    VStack(alignment: .leading, spacing: 12) {
                        let insight = AnalysisInsights.session(record, history: analytics.validRecords)
                        Text(insight.headline).font(.title3.bold())
                        Text(insight.detail).font(.subheadline)
                        Text(insight.note).font(.caption).foregroundStyle(.secondary)
                        if record.efficiency.usable {
                            Divider()
                            Text(AnalysisReading.metric(record.efficiency)).font(.subheadline)
                            if record.drift.usable { Text(AnalysisReading.metric(record.drift)).font(.caption).foregroundStyle(.secondary) }
                        }
                        DisclosureGroup("查看本次测量值") {
                            VStack(spacing: 12) {
                                AnalysisMetricRow(title: "训练负荷", value: record.load)
                                if record.efficiency.usable { AnalysisMetricRow(title: "效率", value: record.efficiency) }
                                if record.drift.usable { AnalysisMetricRow(title: "片段前后变化", value: record.drift) }
                            }.padding(.top, 12)
                        }.font(.subheadline)
                    }.nativeCard()
                    if let zones = record.appleHeartRateZones {
                        DisclosureGroup("心率分布") {
                            AppleHeartRateZonesContent(zones: zones).padding(.top, 12)
                        }.font(.subheadline).nativeCard()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("过程与分段").font(.headline)
                        if !record.recordedIntervals.isEmpty {
                            DisclosureGroup("设备记录的阶段与事件") {
                                ForEach(Array(record.recordedIntervals.enumerated()), id: \.offset) { _, interval in
                                    Text("\(interval.label ?? interval.eventType ?? interval.kind) · \(analysisTime(interval.startElapsedSeconds))–\(analysisTime(interval.endElapsedSeconds))").font(.caption).foregroundStyle(.secondary)
                                }
                            }.font(.subheadline)
                        }
                        if !record.splits.isEmpty {
                            ForEach(record.splits) { split in
                                HStack {
                                    Text(split.kilometers >= 0.999 ? "第\(split.index)公里" : String(format: "末段 %.2f km", split.kilometers)).frame(width: 90, alignment: .leading)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(analysisPace((split.activeSeconds ?? split.elapsedSeconds) / split.kilometers))
                                        Text(split.activeSeconds == nil ? "经过配速 · 可能含暂停" : "运动配速").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(split.heartRate.map { String(format: "%.0f bpm", $0) } ?? "—").frame(width: 72, alignment: .trailing)
                                }.font(.subheadline).padding(.vertical, 4)
                            }
                        } else { Text("无可用GPS分段；不影响其他已测指标。").font(.caption).foregroundStyle(.secondary) }
                    }.nativeCard()
                    if !record.form.isEmpty {
                        DisclosureGroup("跑姿与功率明细") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(record.form) { form in AnalysisMetricRow(title: analysisMetricName(form.metric), value: form.value, metric: form.metric) }
                            }.padding(.top, 12)
                        }.nativeCard()
                    }
                    DisclosureGroup("覆盖、来源与计算依据") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("过程识别：" + record.structure)
                            if let start = record.stableStart, let end = record.stableEnd {
                                Text("候选片段 \(analysisTime(start))–\(analysisTime(end))")
                            }
                            ForEach(record.notes, id: \.self) { Text($0) }
                            ForEach(record.sources.keys.sorted(), id: \.self) { key in
                                if !(record.sources[key] ?? "").isEmpty { Text("\(analysisMetricName(key))：\(record.sources[key]!)") }
                            }
                            Text("计算于 \(record.calculatedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.version)")
                            NavigationLink("查看公式与来源") { TrainingAnalysisMethodsView() }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }.nativeCard()
                }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { Task { await load(force: true) } } }
            }.padding(16)
        }
        .background(RunTheme.page).navigationTitle("本次训练分析").navigationBarTitleDisplayMode(.inline)
        .task(id: analytics.calibration.key) { await load() }
        .refreshable { await load(force: true) }
    }
    private func load(force: Bool = false) async {
        // Existing results stay visible during a quiet freshness check.
        loading = force || record == nil; error = nil
        defer { loading = false; analytics.flush() }
        analytics.updateSummaries(archive.activities)
        await analytics.prepareHeartRateProfile(archive: archive, authorize: true)
        do { _ = try await analytics.analyze(activity: activity, archive: archive, force: force) }
        catch is CancellationError {} catch { self.error = "部分原始采样暂时无法读取，请重试。" }
    }
}

struct TrainingAnalysisSettingsView: View {
    @EnvironmentObject private var analytics: TrainingAnalysisStore
    @EnvironmentObject private var archive: ArchiveStore
    @State private var maximum = ""
    @State private var source = ""
    @State private var selectedPerformance = ""
    @State private var useManualMaximum = false
    @State private var error: String?
    @State private var saved = false
    @State private var isSaving = false
    @FocusState private var editing: Bool
    var body: some View {
        Form {
            Section { NavigationLink("计算依据与数据规则") { TrainingAnalysisMethodsView() } }
            Section("自动读取与估算") {
                let reference = analytics.calibration.reference(at: .now)
                LabeledContent(reference.estimated ? "自动估算最大心率" : "当前最大心率参考", value: reference.bpm.map { String(format: "%.1f bpm", $0) } ?? "暂不可用")
                Text(reference.estimated ? "根据健康中的年龄估算，可能与个人实际值有差异。" : "优先采用有效的手动参考；未设置时自动按年龄估算。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("最大心率计算依据") { Text(reference.explanation).font(.caption).foregroundStyle(.secondary) }
                Text(analytics.heartRateProfile?.zoneStatus ?? "正在读取Apple心率区间…").font(.caption).foregroundStyle(.secondary)
                Button("重新读取健康资料") { Task { await analytics.prepareHeartRateProfile(archive: archive, authorize: true, force: true); analytics.start(archive: archive) } }
                Text("年龄来自健康出生日期；只保存计算所需年龄，原始出生日期不保存、不发送给AI。").font(.caption).foregroundStyle(.secondary)
            }
            Section("可选 · 手动覆盖") {
                Toggle("使用手动最大心率", isOn: $useManualMaximum)
                if useManualMaximum {
                    HStack { TextField("已知可靠参考", text: $maximum).keyboardType(.decimalPad).focused($editing); Text("bpm").foregroundStyle(.secondary) }
                    TextField("来源，例如已有测试或设备设置", text: $source).focused($editing)
                }
                Text("默认自动估算，关闭手动覆盖并保存即可恢复自动。手动设置不改变Apple区间，也不要求额外进行极限测试。").font(.caption).foregroundStyle(.secondary)
            }
            Section("可选 · 近期比赛或充分发挥的测试") {
                Picker("成绩依据", selection: $selectedPerformance) {
                    Text("尚未确认").tag("")
                    ForEach(analytics.validRecords.compactMap(\.performance).filter { $0.date >= Date.now.addingTimeInterval(-90 * 86400) }) { p in
                        Text(p.date.formatted(.dateTime.month().day()) + String(format: " · %.2f km", p.distanceKm)).tag(p.activityID)
                    }
                }
                Text("选择即确认这次记录可作为近期能力标定。未选择时，成绩指数只表示已完成表现，AI不输出未经标定的精确训练配速。无需逐条分类或打标签。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("保存分析设置") { Task { await save() } }.disabled(isSaving)
                if saved { Label("已保存，过程数据将按同一口径重新计算", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("分析缓存") {
                Text("仅缓存可重算的派生指标；更改校准会使旧计算失效。原始运动与AI历史计划保留。").font(.caption)
                Button("重建分析缓存") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do { try await analytics.rebuild(); analytics.start(archive: archive, recoveryAccess: true) }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(isSaving)
            }
            Section { NavigationLink("计算方法与来源") { TrainingAnalysisMethodsView() } }
        }
        .navigationTitle("分析设置").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { editing = false } } }
        .onAppear {
            useManualMaximum = analytics.calibration.maximumHeartRate != nil
            maximum = analytics.calibration.maximumHeartRate.map { String(format: "%g", $0) } ?? ""
            source = analytics.calibration.source; selectedPerformance = analytics.calibration.performanceActivityID ?? ""
        }
        .task { await analytics.prepareHeartRateProfile(archive: archive, authorize: true) }
    }
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        editing = false; saved = false; error = nil
        let text = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = useManualMaximum ? Double(text.replacingOccurrences(of: ",", with: ".")) : nil
        guard !useManualMaximum || value != nil else { error = "请输入有效的手动最大心率，或关闭手动覆盖。"; return }
        do {
            try await analytics.saveCalibration(maximum: value, source: useManualMaximum ? source : "", performanceID: selectedPerformance.isEmpty ? nil : selectedPerformance)
            saved = true; analytics.start(archive: archive)
        } catch { self.error = error.localizedDescription }
    }
}

struct TrainingAnalysisMethodsView: View {
    @EnvironmentObject private var analytics: TrainingAnalysisStore
    var body: some View {
        List {
            Section("当前数据覆盖") {
                LabeledContent("跑步摘要", value: "\(analytics.summaries.count) 次")
                LabeledContent("已整理过程数据", value: "\(analytics.validRecords.count) 次")
                LabeledContent("最大心率依据", value: analytics.calibration.reference(at: .now).estimated ? "年龄公式估算" : (analytics.calibration.validMaximum(at: .now) == nil ? "暂无适用年龄" : "手动参考"))
            }
            ForEach(Array(AnalysisMethod.sources.enumerated()), id: \.offset) { _, method in
                Section {
                    DisclosureGroup(method.0) {
                        Text(method.1).font(.subheadline)
                        Link("公开依据", destination: URL(string: method.2)!)
                    }
                }
            }
            Section {
                DisclosureGroup("公式与版本") {
                    Text("Edwards负荷 = Σ(有效分钟 × 最大心率百分比分区权重)。低于50%最大心率权重0；高于参考最大心率时本次不计算，保留矛盾提示，不把缺失填0。最大心率默认按Tanaka成人年龄回归208−0.7×年龄估算；可选手动覆盖。18–100岁为本App的应用范围，不代表公式对每个人准确。")
                    Text("Apple区间优先使用运动保存的区间与系统时长。缺失时，按当前Apple区间对有效运动心率重新分类，明确标注不代表历史设置；不同配置不混合。区间边界不用于反推最大心率，区间序号不用于Edwards权重。")
                    Text("短期/长期：yₜ = yₜ₋₁ + (1−exp(−1/N)) × (Lₜ−yₜ₋₁)，N为7/42。起点0预热126日；缺失时仅为已观测下限。负荷差为当日长期减短期。")
                    Text("效率 = 共同有效区间的平均速度(m/min) / 平均心率(bpm)。漂移 = (前半效率−后半效率) / 前半效率 × 100%，按等时分半。")
                    Text("成绩指数：v=d/t，C=−4.6+0.182253v+0.000104v²；F=0.8+0.1894393e^(−0.012778t)+0.2989558e^(−0.1932605t)；指数=C/F。d单位米，t单位分钟。")
                    Text(AnalysisMethod.version).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("数据筛选与比较条件") {
                    Text(AnalysisMethod.eligibility)
                    Text("GPS地形筛选还要求有效精度元数据：垂直误差0–10米、水平误差0–30米；缺失或无效时不确认平路。心率或速度采样区间超过30秒时，不视为足够的过程分辨率。")
                    Text("有氧强度筛选为稳定片段内心率均不高于当前参考最大心率80%；年龄估计时同时标注估算，不能当成实测强度分区。成绩候选为5–42.3 km、≤4小时的完整户外记录，GPS与记录距离误差≤3%，暂停差≤0.5%或2秒。它不能自动证明全力程度。")
                    Text("效率趋势按5 bpm心率带、0.5 m/s速度带及同来源分组；跑姿按0.25 m/s速度带及来源分组。每组前后28天各至少3次，每次跑步等权取中位数。边界附近可能被分到相邻组，不作跨组推断。")
                }
            }
            Section("解释边界") {
                Text("不生成未经验证的恢复百分比、伤病风险或跑姿评分。训练结构是实际过程的描述，不把计划当作实际完成。天气、补给、路况及佩戴可能影响比较，无法由单一数值确定原因。")
                Text("统计与AI使用相同的计算结果。AI接收指标、覆盖、方法、限制和依据记录，不接收这些分析涉及的GPS坐标或设备标识。")
            }
        }.font(.subheadline).navigationTitle("计算依据").navigationBarTitleDisplayMode(.inline)
    }
}

struct AppleHeartRateZonesContent: View {
    let zones: AnalysisAppleHeartRateZones
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("看这次跑步的心率主要落在哪些区间，帮助了解强度分布。")
                .font(.caption).foregroundStyle(.secondary)
            Text(AnalysisReading.appleZones(zones)).font(.subheadline)
            Text(sourceLabel + " · " + (zones.scope == "recorded_workout" ? "运动原始记录" : (zones.scope == "current_preference_reclassified" ? "当前区间重新分类" : "当前区间设置")))
                .font(.caption).foregroundStyle(.secondary)
            if compact {
                DisclosureGroup("查看各区间时长") { zoneRows.padding(.top, 8) }.font(.caption)
            } else { zoneRows }
            Text(zones.scope == "current_preference_reclassified" ? "按当前设置重新分类，不代表当时的历史区间。" : "区间由Apple或运动应用提供，不把区间序号当作负荷权重。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("区间依据与数据覆盖") {
                if let coverage = zones.coverage { Text("区间时长覆盖 \(Int(min(1, max(0, coverage)) * 100))% · 未覆盖部分不补齐").font(.caption2).foregroundStyle(.secondary) }
                if let reason = zones.reason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private var zoneRows: some View {
        VStack(spacing: 10) {
            ForEach(Array(zones.zones.enumerated()), id: \.element.id) { order, zone in
                HStack(spacing: 12) {
                    Text("区间 \(order + 1)").font(.caption.weight(.medium)).frame(width: 48, alignment: .leading)
                    Text(bounds(zone)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let seconds = zone.seconds { Text(String(format: "%.1f 分钟", seconds / 60)).font(.subheadline).monospacedDigit() }
                }
            }
        }
    }
    private var sourceLabel: String {
        switch zones.source { case "system": "Apple自动设置"; case "user": "Apple中手动设置"; case "app": "运动应用设置"; default: "Apple区间 · 来源未知" }
    }
    private func bounds(_ zone: AnalysisAppleHeartRateZone) -> String {
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        let reclassified = zones.scope == "current_preference_reclassified"
        if let lower = zone.lowerBPM, let upper = zone.upperBPM { return number(lower) + (reclassified ? "–<" : "–") + number(upper) + " bpm" }
        if let upper = zone.upperBPM { return reclassified ? "<" + number(upper) + " bpm" : number(upper) + " bpm以下" }
        if let lower = zone.lowerBPM { return reclassified ? "≥" + number(lower) + " bpm" : number(lower) + " bpm以上" }
        return "全部心率"
    }
}

struct AnalysisMetricRow: View {
    let title: String
    let value: AnalysisValue
    var metric: String? = nil
    var showMeaning = false
    private var guide: AnalysisMetricGuide { AnalysisReading.guide(metric ?? value.method) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer(minLength: 12)
                Text(value.value.map { analysisFormatted($0, unit: value.unit) } ?? "暂无结果")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            if showMeaning { Text(guide.meaning).font(.caption).foregroundStyle(.secondary) }
            Text(AnalysisReading.metric(value)).font(.caption).foregroundStyle(.secondary)
            if value.value == nil || !value.complete, let reason = value.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if showMeaning { Text(guide.caution).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("数据说明") {
                VStack(alignment: .leading, spacing: 8) {
                    if !showMeaning { Text(guide.meaning); Text(guide.caution) }
                    Text("有效数据覆盖 \(Int(min(1, max(0, value.coverage)) * 100))%" + (value.estimated == true ? " · 使用估算依据" : ""))
                    if value.complete, let reason = value.reason { Text(reason) }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }
    }
}
private struct AnalysisTrendRow: View {
    let title: String
    let trend: AnalysisTrend
    var showGuide = true
    private var guide: AnalysisMetricGuide { AnalysisReading.guide(trend.metric) }
    private var isRecovery: Bool { ["hrv_sdnn", "resting_heart_rate", "sleep_minutes"].contains(trend.metric) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showGuide { Text(guide.meaning).font(.caption).foregroundStyle(.secondary) }
            if let recent = trend.recent, let baseline = trend.baseline {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isRecovery ? "近7日" : "近28日").font(.caption).foregroundStyle(.secondary)
                        Text(analysisFormatted(recent, unit: trend.unit)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("此前28日").font(.caption).foregroundStyle(.secondary)
                        Text(analysisFormatted(baseline, unit: trend.unit)).font(.subheadline).monospacedDigit()
                    }
                }.accessibilityElement(children: .combine).accessibilityLabel(title)
            }
            Text(AnalysisReading.change(trend)).font(.subheadline)
            if trend.recent == nil || trend.baseline == nil, let reason = trend.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if showGuide { Text(guide.caution).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("比较依据") {
                VStack(alignment: .leading, spacing: 8) {
                    if !showGuide { Text(guide.meaning); Text(guide.caution) }
                    Text("近期 \(trend.recentCount) 个有效\(isRecovery ? "日" : "记录") · 此前 \(trend.baselineCount) 个")
                    if trend.recent != nil && trend.baseline != nil, let reason = trend.reason { Text(reason) }
                    Text("上升或下降只描述测量变化，不单独判定训练效果。")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }
    }
}
// Keep measurement noise from filling the plot when the observed range is tiny.
private func analysisChartDomain(_ values: [Double], minimumSpan: Double) -> ClosedRange<Double> {
    let values = values.filter(\.isFinite)
    guard let lo = values.min(), let hi = values.max() else { return 0...max(1, minimumSpan) }
    let center = (lo + hi) / 2
    let span = max(hi - lo, minimumSpan, abs(center) * 0.1) * 1.2
    return max(0, center - span / 2)...(center + span / 2)
}
private func analysisFormatted(_ value: Double, unit: String) -> String {
    let decimals = unit == "m/beat" ? 3.0 : (unit == "m" ? 2 : 1)
    let displayed = abs(value) < 0.5 * pow(10, -decimals) ? 0 : value
    let label = ["m/beat": "米/次心跳", "min": "分钟", "steps/min": "步/分"][unit] ?? unit
    return String(format: unit == "m/beat" ? "%.3f %@" : (unit == "m" ? "%.2f %@" : "%.1f %@"), displayed, label)
}
private func analysisMessage(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(.secondary) }.nativeCard()
}
private func analysisNumber(_ title: String, _ value: Double, unit: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(String(format: "%.1f", value)).font(.system(size: 28, weight: .semibold, design: .rounded))
        if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
    }
}
private func analysisMetricName(_ metric: String) -> String {
    switch metric {
    case "hrv_sdnn": "HRV · SDNN"
    case "resting_heart_rate": "静息心率"
    case "sleep_minutes": "累计入睡时长"
    default: ExportMetric(rawValue: metric)?.name ?? metric
    }
}
private func analysisTime(_ seconds: Double) -> String {
    let value = Int(max(0, seconds).rounded())
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}
private func analysisPace(_ seconds: Double) -> String { analysisTime(seconds) + " /km" }

struct AIAnalysisEvidenceView: View {
    @EnvironmentObject private var archive: ArchiveStore
    let context: TrainingAnalysisContext
    var selectedIDs: Set<String> = []
    private var evidence: [AnalysisEvidence] { context.evidence.filter { selectedIDs.isEmpty || selectedIDs.contains($0.id) } }
    var body: some View {
        List {
            Section("生成时的本机分析快照") {
                Text(context.as_of.formatted(date: .abbreviated, time: .shortened))
                Text(context.version).font(.caption).foregroundStyle(.secondary)
                Text("此处保留当时发送的结果；之后修改校准或补齐采样不会改写这份计划依据。打开来源记录会显示当前记录。").font(.caption).foregroundStyle(.secondary)
                if let reference = context.heart_rate_reference {
                    Text(reference.bpm == nil ? "最大心率参考不可用" : (reference.estimated ? "最大心率采用年龄公式估算" : "最大心率采用手动参考")).font(.subheadline)
                    Text(reference.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(evidence) { item in
                Section(evidenceTitle(item.metric)) {
                    AnalysisMetricRow(title: "计算结果", value: item.value)
                    Text("方法：\(item.value.method)").font(.caption).foregroundStyle(.secondary)
                    Text(item.start.formatted(date: .abbreviated, time: .omitted) + " – " + item.end.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    if item.metric == "apple_heart_rate_zone_seconds", let zones = context.apple_heart_rate_zones?.first(where: { item.activity_ids.contains($0.activity_id) })?.zones {
                        AppleHeartRateZonesContent(zones: zones)
                    }
                    let runs = archive.activities.filter { item.activity_ids.contains($0.id) }
                    if runs.count > 4 {
                        DisclosureGroup("\(runs.count) 条来源记录") { evidenceLinks(runs) }
                    } else { evidenceLinks(runs) }
                }
            }
            Section("数据限制") {
                ForEach(context.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Section { NavigationLink("公开公式与数据规则") { TrainingAnalysisMethodsView() } }
        }.navigationTitle("本次分析依据").navigationBarTitleDisplayMode(.inline)
    }
    private func evidenceLinks(_ runs: [ArchiveActivity]) -> some View {
        ForEach(runs) { run in
            NavigationLink { ActivityDetailView(activity: run) } label: {
                Text(run.date.formatted(.dateTime.month().day()) + String(format: " · %.2f km", run.distanceKm)).font(.subheadline)
            }
        }
    }
    private func evidenceTitle(_ metric: String) -> String {
        switch metric {
        case "edwards_load": "心率负荷"
        case "efficiency", "speed_heart_efficiency": "速度 / 心率效率"
        case "drift": "前后半程漂移"
        case "speed_cv": "候选片段速度变异"
        case "short_long_load_balance": "短长期负荷差"
        case "apple_heart_rate_zone_seconds": "Apple区间已覆盖时间"
        default: analysisMetricName(metric)
        }
    }
}
