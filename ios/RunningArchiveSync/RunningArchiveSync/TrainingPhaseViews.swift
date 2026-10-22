import SwiftUI

struct TrainingPhaseGoalCard: View {
    let profile: AITrainingProfile
    var configure: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("训练目标", systemImage: "flag.checkered").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("选择 / 修改", action: configure).font(.subheadline)
            }
            Text(profile.goal).font(.title2.bold())
            if let date = profile.targetDate {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let days = AIDate.localCalendar.dateComponents([.day], from: AIDate.localCalendar.startOfDay(for: context.date),
                        to: AIDate.localCalendar.startOfDay(for: date)).day ?? 0
                    Text(date.formatted(.dateTime.year().month().day()) + " · " + (days < 0 ? "目标日期已过" : days == 0 ? "比赛日" : "还有 \(days) 天"))
                        .font(.subheadline).foregroundStyle(RunTheme.accent)
                }
            }
            if profile.targetDistanceKm != nil || profile.targetSeconds != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { targetMetrics }
                    VStack(alignment: .leading, spacing: 10) { targetMetrics }
                }
            }
            Text("赛事目标可从已有赛事选取；保存后用于后续计划，已生成安排会保留到更新成功。")
                .font(.caption).foregroundStyle(.secondary)
        }.nativeCard()
    }
    @ViewBuilder private var targetMetrics: some View {
        if let km = profile.targetDistanceKm { Label(String(format: "%g km", km), systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
        if let seconds = profile.targetSeconds { Label("目标 " + TrainingFormat.duration(seconds), systemImage: "stopwatch") }
    }
}

struct TrainingPhaseDashboard: View {
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var archive: ArchiveStore
    @State private var window: TrainingPhaseOverview.Window = .plan
    @State private var selectedDay: String?
    let revision: AIPlanRevision

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let overview = TrainingPhaseOverview(state: training.state, activities: archive.activities, window: window, now: context.date)
            VStack(alignment: .leading, spacing: 16) {
                phaseCard(overview)
                calendarCard(overview, now: context.date)
                WatchPlanSyncCard()
                analysisCard
            }
        }
    }
    private func phaseCard(_ overview: TrainingPhaseOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(overview.expired || overview.profileChanged ? "上次生成的训练阶段" : "当前训练阶段").font(.subheadline).foregroundStyle(.secondary)
            Text(revision.plan.stage).font(.title2.bold())
            Text(revision.plan.summary).font(.subheadline)
            if let start = overview.planStart, let end = overview.planEnd {
                Label("本期安排 " + range(start, end), systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            }
            if overview.profileChanged {
                Label("目标或可训练时间已修改，阶段说明尚未更新。", systemImage: "arrow.clockwise").font(.subheadline)
                if let profile = revision.profileContext { Text("生成时目标：" + profile.goal).font(.caption).foregroundStyle(.secondary) }
            }
            if overview.profileUnknown {
                Text("这版旧计划未保存目标快照，暂不能核对它与当前目标是否一致。下次更新会保存目标依据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if overview.expired {
                Text("本期安排已结束，可回看执行记录并生成后续七天。").font(.subheadline)
            }
            if overview.expired || overview.profileChanged {
                Button("更新阶段与七天安排") { RunningArchiveRuntime.shared.scheduleAnalysis(force: true) }
                    .disabled(training.isWorking || !training.configured)
            }
            DisclosureGroup("阶段依据与变化") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("阶段名称与重点来自每次计划分析。日期表示这版七天安排的范围，尚未生成的长期阶段不作推算。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(training.state.revisions.suffix(5).reversed())) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(item.plan.stage).font(.subheadline.bold())
                            if let profile = item.profileContext { Text(profile.goal).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink("查看完整计划历史") { AITrainingHistoryView() }.font(.subheadline)
                }.padding(.top, 8)
            }
        }.nativeCard()
    }
    private func calendarCard(_ overview: TrainingPhaseOverview, now: Date) -> some View {
        let today = AIDate.key(now, calendar: AIDate.localCalendar)
        let selected = overview.days.first { $0.id == selectedDay }
            ?? overview.days.first { $0.id == today } ?? overview.days[0]
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("计划与实际执行").font(.headline)
                Spacer()
                Menu {
                    Picker("七天范围", selection: $window) {
                        ForEach(TrainingPhaseOverview.Window.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label(window.rawValue, systemImage: "calendar").font(.subheadline) }
            }
            Text(range(overview.days.first!.date, overview.days.last!.date)).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { totals(overview) }
                VStack(alignment: .leading, spacing: 12) { totals(overview) }
            }
            Text("已确认 \(overview.confirmedCount) / \(overview.plannedCount) 课 · 跑步次数与完成课数分别统计")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(overview.days) { day in
                            dayButton(day, selected: day.id == selected.id, today: today).id(day.id)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                .onChange(of: selected.id) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
            if let next = training.current?.plan.sessions.sorted(by: { $0.date < $1.date }).first(where: {
                $0.date >= today && $0.kind != .rest && !training.state.isCompleted($0)
            }) {
                NavigationLink { AITrainingSessionView(session: next, editable: true) } label: {
                    Label("下一课 · " + next.date + " · " + next.kind.title, systemImage: "arrow.right.circle")
                        .font(.subheadline)
                }
            }
            Divider()
            dayDetail(selected)
            Text("实际按跑步开始日汇总，包含本期课程以外的跑步；跨日关联不会重复计入总量。未读取到记录不等于没有训练。")
                .font(.caption).foregroundStyle(.secondary)
        }.nativeCard()
        .onChange(of: window) { _, _ in selectedDay = nil }
        .onChange(of: revision.id) { _, _ in selectedDay = nil }
    }
    private func dayButton(_ day: TrainingPhaseOverview.Day, selected: Bool, today: String) -> some View {
        let title = day.session?.kind.title ?? "未安排"
        let actual = day.actual.isEmpty ? (day.id == today ? "今天" : "—") : "\(day.actual.count) 次跑步"
        let accessibility = day.date.formatted(date: .complete, time: .omitted) + "，" + title + "，" + day.status.rawValue + "，" + actual
        return Button { selectedDay = day.id } label: {
            VStack(spacing: 7) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                Text(day.date.formatted(.dateTime.day())).font(.title3.bold())
                Image(systemName: symbol(day)).frame(height: 20)
                Text(title).font(.caption2)
                Text(actual).font(.caption2)
            }
            .frame(minWidth: 58, minHeight: 114).padding(8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? RunTheme.accent : RunTheme.page, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
            .accessibilityLabel(accessibility)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func totals(_ overview: TrainingPhaseOverview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("当前计划 · \(overview.plannedCount) 课").font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%g 分钟", overview.plannedMinutes)).font(.headline)
            if overview.specifiedDistanceCount > 0 {
                Text(String(format: "参考 %.1f km（%d 课有距离）", overview.plannedDistance, overview.specifiedDistanceCount)).font(.caption)
            } else { Text("未设参考总距离").font(.caption).foregroundStyle(.secondary) }
            Text("时长含距离课预计用时").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 5) {
            Text("实际跑步 · \(overview.actual.count) 次").font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.0f 分钟", overview.actualMinutes)).font(.headline)
            Text(String(format: "%.2f km", overview.actualDistance)).font(.caption)
        }
    }
    private func dayDetail(_ day: TrainingPhaseOverview.Day) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(day.date.formatted(.dateTime.month().day().weekday())).font(.headline)
            if let session = day.session {
                HStack(alignment: .top) {
                    Label(session.kind.title, systemImage: session.kind == .rest ? "moon" : "figure.run").font(.headline)
                    Spacer()
                    if day.manuallyEdited { Text("手动修改").font(.caption).foregroundStyle(.secondary) }
                }
                Text(day.status.rawValue).font(.subheadline).foregroundStyle(day.status == .confirmed ? RunTheme.route : .secondary)
                if session.kind != .rest {
                    Text(session.plannedDurationText + (session.distance_km.map { String(format: " · 参考 %.1f km", $0) } ?? "")).font(.subheadline)
                    Text(session.intensity).font(.subheadline)
                }
                Text(session.purpose).font(.subheadline).foregroundStyle(.secondary)
                NavigationLink { AITrainingSessionView(session: session, editable: true) } label: {
                    Label(session.kind == .rest ? "查看 / 调整休息日" : "查看课程 · 核对执行 / 改课", systemImage: "chevron.right")
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).tint(RunTheme.accent)
            } else { Text("这一天不在本期计划中，实际跑步仍可查看。").font(.subheadline).foregroundStyle(.secondary) }
            if let linked = day.linked, !day.actual.contains(where: { $0.id == linked.id }) {
                Text("跨日关联的跑步（计入其开始日）").font(.caption).foregroundStyle(.secondary)
                activityRow(linked, linked: true)
            }
            if day.actual.isEmpty { Text("当天暂无已读取的跑步记录").font(.subheadline).foregroundStyle(.secondary) }
            else {
                Text("当天实际跑步").font(.subheadline.bold())
                ForEach(day.actual) { activity in activityRow(activity, linked: day.linked?.id == activity.id) }
            }
        }
    }
    private func activityRow(_ activity: ArchiveActivity, linked: Bool) -> some View {
        NavigationLink(value: activity) {
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.date.formatted(.dateTime.hour().minute()) + String(format: " · %.2f km · ", activity.distanceKm) + activity.duration)
                    .font(.subheadline).foregroundStyle(.primary)
                if linked { Text("已关联本课").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
        }
    }
    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if training.state.manualOverrides?.contains(where: { entry in revision.plan.sessions.contains(entry.session) }) == true {
                Text("本期含手动修改，总量与日历以修改后的课程为准；以下 AI 解读保留生成时的判断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !revision.plan.run_review.isEmpty {
                Text("跑步分析").font(.headline)
                Text(revision.plan.run_review).font(.subheadline).foregroundStyle(.secondary)
            }
            if let context = revision.analysisContext {
                NavigationLink("生成时的分析依据") { AIAnalysisEvidenceView(context: context) }.font(.subheadline)
            }
            NavigationLink("跑后反馈如何影响计划") { FeedbackPlanEvidenceView(revision: revision) }.font(.subheadline)
        }.nativeCard()
    }
    private func symbol(_ day: TrainingPhaseOverview.Day) -> String {
        switch day.status {
        case .confirmed: "checkmark.circle.fill"
        case .linked, .candidate, .changed, .missing: "exclamationmark.circle"
        case .rest: "moon"
        case .unplanned: "minus"
        default: "figure.run"
        }
    }
    private func range(_ start: Date, _ end: Date) -> String {
        start.formatted(.dateTime.month().day()) + " – " + end.formatted(.dateTime.month().day())
    }
}
