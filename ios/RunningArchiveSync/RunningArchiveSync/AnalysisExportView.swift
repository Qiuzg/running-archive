import SwiftUI

struct AnalysisExportView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var range = ExportRange.recent
    @State private var start = Calendar.current.date(byAdding: .day, value: -89, to: .now) ?? .now
    @State private var end = Date.now
    @State private var full = false
    @State private var includePlanning = false
    @State private var task: Task<Void, Never>?
    @State private var completed = 0
    @State private var total = 0
    @State private var progressText = ""
    @State private var cancelling = false
    @State private var result: AnalysisExportResult?
    @State private var message: String?
    @State private var showShare = false

    private enum ExportRange: String, CaseIterable, Identifiable {
        case recent = "最近 90 天", year = "今年", all = "全部", custom = "自定义"
        var id: Self { self }
    }
    private var options: AnalysisExportOptions {
        let calendar = Calendar.current
        let lower: Date
        let upper: Date
        switch range {
        case .recent: lower = calendar.date(byAdding: .day, value: -89, to: calendar.startOfDay(for: .now))!; upper = .now
        case .year: lower = calendar.dateInterval(of: .year, for: .now)!.start; upper = .now
        case .all: lower = calendar.startOfDay(for: store.activities.map(\.date).min() ?? .now); upper = .now
        case .custom: lower = calendar.startOfDay(for: start); upper = end
        }
        return AnalysisExportOptions(start: lower, endExclusive: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: upper))!, full: full, includePlanning: includePlanning, timeZone: .current)
    }
    private var selected: [ArchiveActivity] { store.activities.filter { options.includes($0.date) }.sorted { $0.date < $1.date } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(RunTheme.route)
                        Text("把跑步积累，变成下一步的依据").font(.title3.weight(.semibold))
                        Text("一份 Excel，包含跑步概况、公里分段和过程表现，方便专家模型分析。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("选择记录") {
                    Picker("时间范围", selection: $range) { ForEach(ExportRange.allCases) { Text($0.rawValue).tag($0) } }
                    if range == .custom {
                        DatePicker("开始日期", selection: $start, in: ...Date.now, displayedComponents: .date)
                        DatePicker("结束日期", selection: $end, in: ...Date.now, displayedComponents: .date)
                    }
                    LabeledContent("包含记录", value: "\(selected.count) 次跑步")
                    if options.start >= options.endExclusive { Text("结束日期不能早于开始日期").foregroundStyle(.red) }
                }.disabled(task != nil)
                Section {
                    formatOption(title: "分析版 Excel", subtitle: "推荐 · 客观指标、公里分段、30 秒过程数据", selected: !full) { full = false }
                    formatOption(title: "完整数据包", subtitle: "同一份分析 Excel + 原始采样 CSV + 路线 GPX", selected: full) { full = true }
                } header: { Text("导出格式") } footer: {
                    Text(full ? "附带原始采样与完整路线，适合备份或进一步核算。日常交给模型分析，使用分析版即可。" : "包含可获得的心率、速度、功率、步频、步长、触地时间、垂直振幅及体能参考。导出会逐条读取，请保持页面打开。")
                }.disabled(task != nil)
                Section {
                    Toggle("附带赛事目标与训练计划", isOn: $includePlanning)
                } footer: {
                    Text("默认只导出客观运动数据；开启后附带已保存目标和计划的数值。未获得的指标留空，并说明数据覆盖情况。文件仅在本机生成。")
                }.disabled(task != nil)
                if let message {
                    Section { Text(message).font(.subheadline).foregroundStyle(.red) }
                }
                if let result {
                    Section("文件已生成") {
                        LabeledContent("记录", value: "\(result.count) 次")
                        LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                        if result.failed > 0 {
                            Text("\(result.failed) 条读取失败，已保留本地摘要。请查看 Excel 的“读取状态”列；可检查健康权限后重新导出。")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                        if result.partial > 0 {
                            Text("\(result.partial) 项指标读取失败，其他数据已保留。请查看“指标可用性”表。")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                        Button("重新生成", action: beginExport).disabled(task != nil)
                    }
                }
            }
            exportControls
        }
        .navigationTitle("导出分析数据")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(result == nil ? "导出" : "分享", action: exportOrShare)
                    .fontWeight(.semibold)
                    .disabled(task != nil || (result == nil && exportUnavailableReason != nil))
                    .accessibilityIdentifier("analysisExport.toolbarAction")
            }
        }
        .sheet(isPresented: $showShare) { if let result { ShareSheet(items: [result.url]) } }
        .onDisappear {
            task?.cancel()
            if !showShare { removeResult() }
        }
        .onChange(of: range) { _, _ in removeResult() }
        .onChange(of: start) { _, _ in removeResult() }
        .onChange(of: end) { _, _ in removeResult() }
        .onChange(of: full) { _, _ in removeResult() }
        .onChange(of: includePlanning) { _, _ in removeResult() }
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            if task != nil {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                Text(progressText).font(.caption).foregroundStyle(.secondary)
                Button(cancelling ? "正在取消…" : "取消导出", role: .cancel) {
                    cancelling = true; progressText = "正在结束当前读取并清理临时文件…"; task?.cancel()
                }.disabled(cancelling)
            } else {
                Button(action: exportOrShare) {
                    Label(result != nil ? "保存到文件 / 分享" : (full ? "导出完整数据包" : "导出 Excel"), systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(RunTheme.route)
                .disabled(result == nil && exportUnavailableReason != nil)
                .accessibilityIdentifier("analysisExport.primaryAction")
                if result == nil, let reason = exportUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
    }

    private var exportUnavailableReason: String? {
        if store.isLoading { return "正在读取跑步记录，请稍候" }
        if options.start >= options.endExclusive { return "请将结束日期设为开始日期当天或之后" }
        if selected.isEmpty { return "所选时间范围没有跑步记录，请调整时间范围" }
        return nil
    }

    private func exportOrShare() {
        if result != nil { showShare = true } else { beginExport() }
    }

    private func formatOption(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title2)
                    .foregroundStyle(selected ? RunTheme.route : .secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 5)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func removeResult() {
        if let result { try? FileManager.default.removeItem(at: result.folder) }
        result = nil
    }

    private func beginExport() {
        let selection = selected, settings = options, annotations = journal.data, activities = store.activities
        guard task == nil, exportUnavailableReason == nil, !selection.isEmpty, settings.start < settings.endExclusive else { return }
        removeResult(); message = nil; completed = 0; total = selection.count; cancelling = false
        progressText = "准备读取 \(total) 次跑步…"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("running-analysis-\(UUID().uuidString)")
        task = Task { @MainActor in
            defer { task = nil }
            do {
                progressText = "正在准备健康数据权限…"
                try await store.prepareAnalysisExport()
                try Task.checkCancellation()
                let builder = try AnalysisExportBuilder(options: settings, journal: annotations, activities: activities, folder: folder)
                progressText = "正在读取体能参考指标…"
                let references = try await store.exportReferences(start: settings.start, end: settings.endExclusive)
                await builder.setReferences(references)
                for (index, activity) in selection.enumerated() {
                    try Task.checkCancellation()
                    progressText = "正在读取 \(index + 1)/\(selection.count) · \(activity.date.formatted(date: .abbreviated, time: .omitted))"
                    let workout: ExportWorkout?
                    let failure: String?
                    do {
                        workout = try await store.exportWorkout(id: activity.id); failure = nil
                    } catch is CancellationError { throw CancellationError() }
                    catch { workout = nil; failure = error.localizedDescription }
                    try Task.checkCancellation()
                    try await builder.add(activity: activity, workout: workout, error: failure)
                    completed = index + 1
                }
                progressText = "正在整理 Excel 和导出文件…"
                let output = try await builder.finish()
                try Task.checkCancellation()
                result = output
            } catch {
                try? FileManager.default.removeItem(at: folder)
                message = error is CancellationError ? "已取消，临时文件已清理。" : "导出未完成：\(error.localizedDescription)"
            }
        }
    }
}
