import SwiftUI
import Charts

struct TrainingExecutionSection: View {
    let session: AITrainingSession
    @EnvironmentObject private var training: AITrainingStore
    @EnvironmentObject private var archive: ArchiveStore
    @State private var selecting = false
    @State private var confirming = false
    @State private var comparison: TrainingExecutionComparison?
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    private let builder = TrainingExecutionBuilder()
    private var link: TrainingSessionAssociation? { training.state.association(for: session) }
    private var activity: ArchiveActivity? { archive.activities.first { $0.id == link?.activityID } }
    private struct LoadKey: Equatable {
        var session: AITrainingSession
        var id: String?
        var signature: String?
        var retry: Int
    }
    private var loadKey: LoadKey {
        .init(session: session, id: activity?.id, signature: activity.map { TrainingExecution.activitySignature($0) }, retry: retry)
    }
    var body: some View {
        Section("计划与实际") {
            if training.state.isCompleted(session) {
                Label("已确认完成", systemImage: "checkmark.circle.fill").foregroundStyle(RunTheme.route)
                Text("由你核对后确认；训练量与强度对照见下方。").font(.caption).foregroundStyle(.secondary)
            } else if activity != nil {
                Label("已关联 · 待确认完成", systemImage: "link")
            } else {
                Label(link?.candidates.isEmpty == false ? "有跑步记录待核对" : "尚未关联实际跑步", systemImage: "questionmark.circle")
                Text("同一天跑过步不等于完成这次训练。请选择实际执行这次安排的记录。").font(.caption).foregroundStyle(.secondary)
            }
            if let activity {
                NavigationLink(value: activity) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(activity.date.formatted(date: .abbreviated, time: .shortened))
                        Text(String(format: "%.2f km · %@ · %@ /km", activity.distanceKm, activity.duration, activity.pace))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if link?.activityID != nil {
                Text("暂时无法读取关联记录，请刷新跑步列表或重新选择。").font(.caption).foregroundStyle(.secondary)
            }
            Button(activity == nil ? "选择实际跑步" : "重新选择跑步") { selecting = true }
                .accessibilityIdentifier("training.execution.select")
            if link?.activityID != nil || link?.candidates.isEmpty == false {
                Button("解除关联", role: .destructive) { perform { try training.associate(session, activity: nil) } }
            }
            if loading { HStack { ProgressView(); Text("正在读取实际训练段…") } }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重新读取") { retry += 1 }
            }
            if let comparison {
                TrainingExecutionComparisonView(comparison: comparison)
                if !training.state.isCompleted(session) {
                    Button("核对后确认完成") { confirming = true }
                        .accessibilityIdentifier("training.execution.confirm")
                }
            }
            if training.state.isCompleted(session) {
                Button("撤销完成确认") { perform { try training.undoCompletion(session) } }
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $selecting) {
            TrainingActivityPicker(session: session, selected: link?.activityID) { chosen in
                do { try training.associate(session, activity: chosen); selecting = false; error = nil }
                catch { self.error = error.localizedDescription; selecting = false }
            }
        }
        .alert("确认这次训练已完成？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }
            Button("已核对，确认完成") {
                guard let activity else { return }
                perform { try training.confirmCompletion(session, activity: activity) }
            }
        } message: {
            Text("请核对主体训练段与实际跑步。即使数据不足或目标存在偏差，也可以由你确认；该标记只更新计划完成状态及 Apple Watch 待跑安排，不代表所有强度目标达标。")
        }
    }
    @MainActor private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
    @MainActor private func load() async {
        comparison = nil; error = nil; loading = false
        guard let activity else { return }
        let key = loadKey
        loading = true
        do {
            let workout = try await archive.exportWorkout(id: activity.id)
            try Task.checkCancellation()
            let result = await builder.compare(session: session, workout: workout)
            try Task.checkCancellation()
            guard key == loadKey else { return }
            comparison = result; loading = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, key == loadKey else { return }
            self.error = "读取未完成：\(error.localizedDescription)"; loading = false
        }
    }
}

private struct TrainingActivityPicker: View {
    let session: AITrainingSession
    let selected: String?
    let choose: (ArchiveActivity) -> Void
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var candidates: [ArchiveActivity] {
        TrainingExecution.candidates(for: session, activities: archive.activities, calendar: AIDate.localCalendar)
    }
    private func matches(_ activity: ArchiveActivity) -> Bool {
        search.isEmpty || (activity.name + " " + AIDate.key(activity.date, calendar: AIDate.localCalendar)).localizedCaseInsensitiveContains(search)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选择一次实际训练。多次跑步不会自动累加为完成量；跨日期执行可从全部记录中选择。").font(.caption).foregroundStyle(.secondary)
                }
                Section("计划当日及跨午夜候选") {
                    if candidates.isEmpty { Text("暂无候选记录").foregroundStyle(.secondary) }
                    ForEach(candidates.filter(matches)) { row($0) }
                }
                Section("其他跑步") {
                    let ids = Set(candidates.map(\.id))
                    ForEach(archive.activities.filter { !ids.contains($0.id) && matches($0) }.sorted { $0.date > $1.date }) { row($0) }
                }
            }.navigationTitle("关联实际跑步").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "名称或日期（2026-10-21）")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    private func row(_ activity: ArchiveActivity) -> some View {
        Button { choose(activity) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.primary)
                    Text(String(format: "%.2f km · %@ · %@ /km", activity.distanceKm, activity.duration, activity.pace))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if activity.id == selected { Image(systemName: "checkmark") }
            }
        }
    }
}

private struct TrainingExecutionComparisonView: View {
    let comparison: TrainingExecutionComparison
    @State private var selected = 1
    @State private var heartChart = false
    @State private var showSupporting = false
    init(comparison: TrainingExecutionComparison) {
        self.comparison = comparison
        let first = comparison.mainRows.first ?? comparison.rows.first
        _selected = State(initialValue: first?.id ?? 0)
        _heartChart = State(initialValue: first?.step.goal.heart_rate_min != nil)
    }
    private var row: TrainingExecutionRow? { comparison.rows.first { $0.id == selected } ?? comparison.rows.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(comparison.quantityText).font(.headline)
            Text(comparison.recordedBoundaries ? "记录分段 · 按顺序对照" : "按计划推算 · 仅供核对")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(comparison.note).font(.caption).foregroundStyle(.secondary)
            if !comparison.rows.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(comparison.rows) { item in
                            Button { select(item) } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(item.id == selected ? RunTheme.accent : Color.secondary.opacity(0.22))
                                        .frame(width: 54, height: item.step.phase == .work ? 44 : 26)
                                    Text(item.step.title).font(.caption2).foregroundStyle(.primary)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("选择\(item.step.title)")
                                .accessibilityAddTraits(item.id == selected ? .isSelected : [])
                        }
                    }
                }
                Text("主体训练").font(.subheadline.bold())
                ForEach(comparison.mainRows) { item in rowButton(item) }
                DisclosureGroup("热身、恢复与放松", isExpanded: $showSupporting) {
                    ForEach(comparison.rows.filter { $0.step.phase != .work }) { item in rowButton(item) }
                }.font(.subheadline)
                if let row {
                    Divider()
                    Text("\(row.step.title) · 详细对照").font(.headline)
                    LabeledContent("计划", value: row.step.goal.goalText)
                    LabeledContent("实际窗口", value: quantity(row))
                    if let start = row.start, let end = row.end {
                        LabeledContent("起跑后", value: "\(time(start))–\(time(end))")
                    }
                    if let target = row.step.goal.targetText {
                        LabeledContent("目标范围", value: target)
                        LabeledContent("目标内时长", value: row.supportedSeconds > 0 ? time(row.targetSeconds ?? 0) : "数据不足")
                        LabeledContent("目标内占比", value: row.supportedSeconds > 0
                            ? String(format: "%.0f%%（已测时段）", (row.targetSeconds ?? 0) / row.supportedSeconds * 100) : "—")
                        LabeledContent("目标指标覆盖", value: row.coverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        if (row.coverage ?? 0) < 0.9 {
                            Text("覆盖不足，未测时段不计为达标，也不计为偏离；不据此判断整段强度。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else { Text("本段未设定配速或心率目标，不判定强度达标。").font(.caption).foregroundStyle(.secondary) }
                    LabeledContent("实测平均配速", value: row.pace.map { TrainingFormat.pace($0) + " /km" } ?? "—")
                    LabeledContent("实测平均心率", value: row.heartRate.map { String(format: "%.0f bpm", $0) } ?? "—")
                    Text("配速覆盖 \(percent(row.paceCoverage)) · 心率覆盖 \(percent(row.heartCoverage))").font(.caption).foregroundStyle(.secondary)
                    Text("均值仅包含有数据的运动时段，不用全程均值补齐缺失。速度积分距离为估算，记录分段的距离优先。").font(.caption).foregroundStyle(.secondary)
                    Picker("图表指标", selection: $heartChart) {
                        Text("配速").tag(false); Text("心率").tag(true)
                    }.pickerStyle(.segmented)
                    if let start = row.start, let end = row.end, end > start {
                        trace(row, start: start, end: end)
                        Text("横轴为起跑后的经过时间，暂停和缺失时段留空。每条短线为 30 秒窗口均值，目标内时长按原始采样计算。").font(.caption).foregroundStyle(.secondary)
                    } else { Text("无法定位本段，暂无可展示曲线。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(.vertical, 6)
    }
    private func select(_ item: TrainingExecutionRow) {
        selected = item.id
        heartChart = item.step.goal.heart_rate_min != nil
    }
    private func rowButton(_ item: TrainingExecutionRow) -> some View {
        Button { select(item) } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.step.title) · 目标 \(item.step.goal.goalText)").font(.subheadline)
                    Text("实际 \(quantity(item))").font(.caption).foregroundStyle(.secondary)
                    if let target = item.step.goal.targetText { Text(target).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: item.id == selected ? "chevron.down.circle.fill" : "chevron.right.circle")
            }.foregroundStyle(.primary).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func quantity(_ row: TrainingExecutionRow) -> String {
        guard let q = row.quantity else { return "数据不足" }
        return row.step.goal.goal == .time ? time(q) : String(format: "%.0f 米", q)
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    @ViewBuilder private func trace(_ row: TrainingExecutionRow, start: Double, end: Double) -> some View {
        let points = (heartChart ? comparison.heartPoints : comparison.pacePoints).filter { $0.end > start && $0.start < end }
        let lower = heartChart ? row.step.goal.heart_rate_min : row.step.goal.pace_min
        let upper = heartChart ? row.step.goal.heart_rate_max : row.step.goal.pace_max
        if points.isEmpty { Text("本段没有可用\(heartChart ? "心率" : "配速")采样。").font(.caption).foregroundStyle(.secondary) }
        else {
            Chart {
                if let lower, let upper {
                    RectangleMark(xStart: .value("开始", start), xEnd: .value("结束", end),
                        yStart: .value("下限", lower), yEnd: .value("上限", upper))
                        .foregroundStyle(RunTheme.accent.opacity(0.12))
                }
                ForEach(points) { point in
                    RuleMark(xStart: .value("开始", max(start, point.start)), xEnd: .value("结束", min(end, point.end)),
                        y: .value(heartChart ? "心率" : "配速", point.value))
                        .foregroundStyle(heartChart ? Color.red : RunTheme.accent).lineStyle(StrokeStyle(lineWidth: 2))
                }
            }.chartXScale(domain: start...end).chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text(time(v)) } }
                } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(); AxisValueLabel {
                        if let v = value.as(Double.self) { Text(heartChart ? String(format: "%.0f", v) : TrainingFormat.pace(v)) }
                    }
                } }.frame(height: 160)
                .accessibilityLabel("\(row.step.title)实际\(heartChart ? "心率" : "配速")与目标范围")
        }
    }
}
