import SwiftUI
import Charts

private extension View {
    func journalCard() -> some View {
        self.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct TrainingHubLinks: View {
    @EnvironmentObject private var journal: TrainingJournal
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("我的跑步手记").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                NavigationLink { PersonalRecordsView() } label: { entry("个人纪录", "成绩与进步", "chart.line.uptrend.xyaxis") }
                NavigationLink { RouteLibraryView() } label: { entry("路线收藏", "常跑路线 · GPX", "map") }
                NavigationLink { RaceGoalsView() } label: { entry("目标赛事", "倒计时与配速", "flag.checkered") }
                NavigationLink { AITrainingView() } label: { entry("训练计划", "本周安排与完成情况", "calendar") }
            }.buttonStyle(.plain)
            NavigationLink { AnalysisExportView() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up").font(.title3).foregroundStyle(RunTheme.route)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("导出分析数据").font(.headline)
                        Text("Excel · 原始采样 · 完整路线").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 20))
            }.buttonStyle(.plain)
            if let next = journal.data.races.filter({ $0.daysRemaining() >= 0 }).min(by: { $0.date < $1.date }) {
                NavigationLink { RaceGoalsView() } label: {
                    HStack {
                        Image(systemName: "flag.checkered").foregroundStyle(RunTheme.accent)
                        Text(next.name).lineLimit(1)
                        Spacer()
                        Text(next.daysRemaining() == 0 ? "今天开跑" : "还有 \(next.daysRemaining()) 天").font(.subheadline.weight(.medium))
                    }.padding(14).background(RunTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
            }
        }
    }
    private func entry(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(RunTheme.route)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 95, alignment: .leading).journalCard()
    }
}

struct ActivityJournalSection: View {
    @EnvironmentObject private var journal: TrainingJournal
    @EnvironmentObject private var store: ArchiveStore
    let activity: ArchiveActivity
    @State private var editing = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var showExport = false
    @State private var message: String?
    private var annotation: RunAnnotation { journal.annotation(activity.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("跑后手记", systemImage: "square.and.pencil").font(.headline)
                Spacer()
                Button("编辑") { editing = true }
            }
            HStack(spacing: 12) {
                if annotation.kind != .unspecified { Text(annotation.kind.rawValue).font(.subheadline.weight(.medium)) }
                if let effort = annotation.effort { Text("体感 \(effort)/10").font(.subheadline).foregroundStyle(.secondary) }
            }
            Text(annotation.note.isEmpty ? "备注为可选项。路线收藏、历史对比及 GPX 导出可在下方使用。" : annotation.note)
                .font(.subheadline).foregroundStyle(annotation.note.isEmpty ? .secondary : .primary)
            if store.routeSummary(id: activity.routeId) != nil {
                Divider()
                NavigationLink { RouteComparisonView(activity: activity) } label: {
                    Label("同路线历史对比", systemImage: "chart.xyaxis.line")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button {
                        var value = annotation; value.favoriteRoute.toggle()
                        journal.saveAnnotation(value, id: activity.id)
                    } label: {
                        Label(annotation.favoriteRoute ? "已收藏路线" : "收藏路线", systemImage: annotation.favoriteRoute ? "bookmark.fill" : "bookmark")
                    }
                    Spacer()
                    Button { export() } label: {
                        if exporting { ProgressView() } else { Label("导出 GPX", systemImage: "square.and.arrow.up") }
                    }.disabled(exporting)
                }.font(.subheadline)
                if !annotation.routeName.isEmpty { Text(annotation.routeName).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .journalCard()
        .sheet(isPresented: $editing) { AnnotationEditor(activity: activity) }
        .sheet(isPresented: $showExport, onDismiss: {
            if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
            exportURL = nil
        }) { if let exportURL { ShareSheet(items: [exportURL]) } }
        .alert("路线导出", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func export() {
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                let points = try await store.fullRoutePoints(id: activity.routeId ?? activity.id)
                let name = journal.routeName(activity)
                let xml = try await Task.detached(priority: .userInitiated) { try GPXExporter.document(name: name, points: points) }.value
                let directory = FileManager.default.temporaryDirectory.appending(path: "route-export-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: "Running-Archive-\(DateFormatter.archiveDay.string(from: activity.date)).gpx")
                try xml.write(to: url, atomically: true, encoding: .utf8)
                exportURL = url; showExport = true
            } catch { message = error.localizedDescription }
        }
    }
}

struct AnnotationEditor: View {
    @EnvironmentObject private var journal: TrainingJournal
    @Environment(\.dismiss) private var dismiss
    let activity: ArchiveActivity
    @State private var value = RunAnnotation()
    var body: some View {
        NavigationStack {
            Form {
                if let error = journal.errorMessage { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section {
                    TextEditor(text: $value.note).frame(minHeight: 130)
                        .onChange(of: value.note) { _, text in if text.count > 2000 { value.note = String(text.prefix(2000)) } }
                } header: { Text("跑后备注") } footer: { Text("\(value.note.count)/2000 · 仅保存在本机") }
                Section("路线名称") {
                    TextField("例如：滨江晨跑环线", text: $value.routeName)
                        .onChange(of: value.routeName) { _, text in if text.count > 60 { value.routeName = String(text.prefix(60)) } }
                }
                Section {
                    Toggle("不计入个人纪录", isOn: $value.excludeFromRecords)
                } footer: { Text("用于排除误记录或异常 GPS；原始跑步记录仍保留。") }
            }
            .navigationTitle("跑后手记").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if journal.saveAnnotation(value, id: activity.id) { dismiss() } } }
            }
            .onAppear { value = journal.annotation(activity.id) }
        }
    }
}

struct RouteComparisonView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    let activity: ArchiveActivity
    @State private var automaticIDs: Set<String> = []
    @State private var matching = false
    @State private var correcting = false
    @State private var selectedDate: Date?
    private var matches: [ArchiveActivity] {
        store.activities.filter { other in
            other.id == activity.id || (journal.override(activity.id, other.id) ?? automaticIDs.contains(other.id))
        }.sorted { $0.date < $1.date }
    }
    private var valid: [ArchiveActivity] { matches.filter { $0.distanceKm > 0 && TrainingFormat.seconds($0.duration) > 0 } }
    private func pace(_ a: ArchiveActivity) -> Double { TrainingFormat.seconds(a.duration) / a.distanceKm }
    private var paceBounds: ClosedRange<Double> {
        let values = valid.map(pace)
        let low = max(0, floor(((values.min() ?? 300) - 15) / 15) * 15)
        let high = ceil(((values.max() ?? 330) + 15) / 15) * 15
        return low...max(low + 30, high)
    }
    private var selected: ArchiveActivity? {
        guard let selectedDate else { return valid.first { $0.id == activity.id } }
        return valid.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(journal.routeName(activity)).font(.title2.weight(.semibold))
                    Text("\(matches.count) 次跑过 · 比较相近方向、距离与轨迹").font(.subheadline).foregroundStyle(.secondary)
                    if matching { ProgressView("正在匹配路线") }
                    if let status = store.routeScanStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                if valid.count > 1 {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("配速变化").font(.headline)
                            Spacer()
                            Text("数值越小，配速越快").font(.caption).foregroundStyle(.secondary)
                        }
                        Chart {
                            ForEach(valid) { run in
                                LineMark(x: .value("日期", run.date), y: .value("秒/公里", pace(run)))
                                    .interpolationMethod(.monotone).foregroundStyle(RunTheme.route.opacity(0.6))
                                PointMark(x: .value("日期", run.date), y: .value("秒/公里", pace(run)))
                                    .foregroundStyle(run.id == activity.id ? RunTheme.accent : RunTheme.route)
                            }
                            if selectedDate != nil, let selected {
                                RuleMark(x: .value("选中日期", selected.date))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(RunTheme.ink.opacity(0.3))
                            }
                        }
                        .chartYScale(domain: paceBounds)
                        .chartXScale(range: .plotDimension(padding: 12))
                        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in AxisGridLine(); AxisValueLabel { if let s = value.as(Double.self) { Text(TrainingFormat.pace(s)) } } } }
                        .chartXSelection(value: $selectedDate).frame(height: 190)
                        if let selected { comparisonRow(selected) }
                        Text("左右拖动查看；橙色为当前记录。天气、路况和训练目的也会影响表现。").font(.caption).foregroundStyle(.secondary)
                    }.journalCard()
                } else if !matching {
                    ContentUnavailableView("暂未找到相似记录", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("可通过右上角“校正”手动加入同路线记录。"))
                }
                Text("历次记录").font(.headline)
                ForEach(matches.reversed()) { run in
                    NavigationLink { ActivityDetailView(activity: run) } label: { comparisonRow(run).journalCard() }.buttonStyle(.plain)
                }
            }.padding(18)
        }
        .background(RunTheme.page).navigationTitle("同路线对比").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("校正") { correcting = true } }
        .sheet(isPresented: $correcting) { RouteMatchEditor(activity: activity, automaticIDs: automaticIDs) }
        .task(id: store.routes.map(\.id)) {
            guard let base = store.routeSummary(id: activity.routeId) else { return }
            matching = true
            let candidates = store.routes
            let ids = await Task.detached(priority: .userInitiated) {
                Set(candidates.filter { RouteMatcher.matches(base, $0) }.map(\.id))
            }.value
            guard !Task.isCancelled else { return }
            automaticIDs = Set(store.activities.filter { ids.contains($0.routeId ?? $0.id) }.map(\.id))
            matching = false
        }
    }
    private func comparisonRow(_ run: ArchiveActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(run.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.weight(.medium))
                Spacer()
                if run.id == activity.id { Text("当前").font(.caption).foregroundStyle(RunTheme.accent) }
            }
            HStack {
                Text("\(run.pace) /km").font(.title3.weight(.medium)).monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(String(format: "%.2f", run.distanceKm)) km · \(run.duration)")
                    Text(run.avgHeartRate.map { "平均心率 \($0) bpm" } ?? "无心率数据")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RouteMatchEditor: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @Environment(\.dismiss) private var dismiss
    let activity: ArchiveActivity
    let automaticIDs: Set<String>
    @State private var search = ""
    private var candidates: [ArchiveActivity] {
        store.activities.filter { $0.id != activity.id && store.routeSummary(id: $0.routeId) != nil &&
            (search.isEmpty || journal.routeName($0).localizedCaseInsensitiveContains(search) || DateFormatter.archiveDay.string(from: $0.date).contains(search)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("按单对记录校正。自动匹配会考虑起终点、方向、距离和轨迹；手动调整会持续保留。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(candidates) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(run.date.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%.2f", run.distanceKm)) km").font(.subheadline)
                        Text(journal.routeName(run)).font(.caption).foregroundStyle(.secondary)
                        Picker("匹配方式", selection: Binding(get: {
                            journal.override(activity.id, run.id).map { $0 ? 1 : 2 } ?? 0
                        }, set: { mode in journal.setOverride(mode == 0 ? nil : mode == 1, a: activity.id, b: run.id) })) {
                            Text(automaticIDs.contains(run.id) ? "自动：匹配" : "自动：不匹配").tag(0)
                            Text("加入").tag(1); Text("排除").tag(2)
                        }.pickerStyle(.segmented)
                    }.padding(.vertical, 5)
                }
            }
            .searchable(text: $search, prompt: "搜索路线名称或日期")
            .navigationTitle("校正同路线记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct RouteLibraryView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var search = ""
    @State private var editing: ArchiveActivity?
    private var favorites: [ArchiveActivity] {
        store.activities.filter { journal.annotation($0.id).favoriteRoute &&
            (search.isEmpty || journal.routeName($0).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("把想再跑的路线留下来").font(.title2.weight(.semibold))
                Text("在跑步详情中收藏路线。进入记录可查看完整路线、同路线历史和导出 GPX。").font(.subheadline).foregroundStyle(.secondary)
                if favorites.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "还没有收藏路线" : "没有匹配路线", systemImage: "bookmark", description: Text("从一条喜欢的跑步记录开始。"))
                }
                ForEach(favorites) { run in
                    VStack(alignment: .leading, spacing: 14) {
                        NavigationLink { ActivityDetailView(activity: run) } label: {
                            HStack(spacing: 18) {
                                if let route = store.routeSummary(id: run.routeId) {
                                    MiniRouteView(coordinates: route.coordinates, color: RunTheme.route).frame(width: 86, height: 80)
                                } else { Image(systemName: "map").frame(width: 86, height: 80).foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(journal.routeName(run)).font(.headline)
                                    Text("\(String(format: "%.2f", run.distanceKm)) km · \(run.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                        HStack {
                            Button("编辑名称") { editing = run }
                            Spacer()
                            Button("取消收藏") {
                                var value = journal.annotation(run.id); value.favoriteRoute = false
                                journal.saveAnnotation(value, id: run.id)
                            }.foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }.journalCard()
                }
            }.padding(18)
        }.background(RunTheme.page).navigationTitle("路线收藏").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索收藏路线")
            .sheet(item: $editing) { AnnotationEditor(activity: $0) }
    }
}

struct PersonalRecordsView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @State private var category: RecordDistance = .five
    @State private var gps = false
    @State private var year = 0
    @State private var analysisTask: Task<Void, Never>?
    @State private var progress = ""
    @State private var resultMessage: String?
    @State private var showExcluded = false
    private var years: [Int] { Set(store.activities.map { Calendar.current.component(.year, from: $0.date) }).sorted(by: >) }
    private var records: [RunRecord] { RunRecord.history(activities: store.activities, category: category, gps: gps, journal: journal.data, year: year == 0 ? nil : year) }
    private var best: RunRecord? { records.min { $0.seconds < $1.seconds } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Picker("成绩口径", selection: $gps) { Text("整次跑步").tag(false); Text("GPS 最快片段").tag(true) }.pickerStyle(.segmented)
                HStack {
                    Picker("距离", selection: $category) { ForEach(RecordDistance.allCases) { Text($0.rawValue).tag($0) } }
                    Spacer()
                    Picker("年份", selection: $year) { Text("全部年份").tag(0); ForEach(years, id: \.self) { Text(String($0)).tag($0) } }
                }
                if let best {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(year == 0 ? "历史" : "年度")最佳 · \(category.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                        Text(TrainingFormat.duration(best.seconds)).font(.system(size: 42, weight: .medium, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
                        Text(best.activity.date.formatted(date: .long, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                    }.journalCard()
                }
                Text(gps ? "根据原始 GPS 轨迹估算，不等同于官方比赛成绩。按经过时间计算（包含停留）；超过 30 秒的采样断点和异常跳点不会跨越。" : "显示 \(String(format: "%.2f", category.km))–\(String(format: "%.2f", category.km * 1.03)) km 的整次活动原始用时，不按均速折算标准距离。")
                    .font(.caption).foregroundStyle(.secondary)
                if gps {
                    VStack(alignment: .leading, spacing: 10) {
                        if analysisTask != nil {
                            ProgressView(progress)
                            Button("停止分析") { analysisTask?.cancel() }
                        } else {
                            Button { analyze() } label: { Label("分析 / 更新原始路线", systemImage: "waveform.path") }
                            Text("手动读取至少 5 km 的跑步路线并计算四种距离。已完成的结果会保存，可中途停止。").font(.caption).foregroundStyle(.secondary)
                        }
                        if let resultMessage { Text(resultMessage).font(.caption).foregroundStyle(.secondary) }
                    }.journalCard()
                }
                if records.isEmpty {
                    ContentUnavailableView("暂无符合条件的成绩", systemImage: "chart.line.uptrend.xyaxis", description: Text(gps ? "先分析原始路线，或切换距离和年份。" : "切换距离或年份查看其他记录。"))
                } else {
                    Text("成绩时间线").font(.headline)
                    let breakthroughs = RunRecord.breakthroughs(records)
                    ForEach(records.reversed()) { record in
                        NavigationLink { ActivityDetailView(activity: record.activity) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.activity.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
                                    Text("\(String(format: "%.2f", record.activity.distanceKm)) km 活动\(breakthroughs.contains(record.id) ? " · 当期新纪录" : "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(TrainingFormat.duration(record.seconds)).font(.headline).monospacedDigit().foregroundStyle(record.id == best?.id ? RunTheme.accent : RunTheme.ink)
                            }.journalCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(18)
        }.background(RunTheme.page).navigationTitle("个人纪录").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("排除管理") { showExcluded = true } }
            .sheet(isPresented: $showExcluded) { RecordExclusionsView() }
            .onDisappear { analysisTask?.cancel() }
    }
    private func analyze() {
        let candidates = store.activities.filter { $0.distanceKm >= 5 && $0.date <= .now && !journal.annotation($0.id).excludeFromRecords }
        resultMessage = nil
        analysisTask = Task { @MainActor in
            var completed = 0, failures = 0, empty = 0
            defer { analysisTask = nil; resultMessage = "已分析 \(completed) 条，\(empty) 条无完整距离片段，\(failures) 条读取失败\(Task.isCancelled ? " · 已停止" : "")" }
            for (index, run) in candidates.enumerated() {
                if Task.isCancelled { break }
                progress = "正在分析 \(index + 1)/\(candidates.count)"
                do {
                    let points = try await store.fullRoutePoints(id: run.routeId ?? run.id)
                    try Task.checkCancellation()
                    let efforts = await Task.detached(priority: .utility) { BestEffortAnalyzer.analyze(points: points, start: run.date) }.value
                    try Task.checkCancellation()
                    guard journal.saveAnalysis(efforts, id: run.id) else { break }
                    completed += 1
                    if efforts.isEmpty { empty += 1 }
                } catch is CancellationError { break }
                catch { failures += 1 }
                await Task.yield()
            }
        }
    }
}

private struct RecordExclusionsView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var journal: TrainingJournal
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Section { Text("打开开关可排除异常记录；关闭可恢复。仅影响个人纪录，不删除 Apple Health 数据。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(store.activities.filter { search.isEmpty || DateFormatter.archiveDay.string(from: $0.date).contains(search) || $0.name.localizedCaseInsensitiveContains(search) }) { run in
                    Toggle(isOn: Binding(get: { journal.annotation(run.id).excludeFromRecords }, set: { excluded in
                        var value = journal.annotation(run.id); value.excludeFromRecords = excluded; journal.saveAnnotation(value, id: run.id)
                    })) {
                        Text("\(run.date.formatted(date: .abbreviated, time: .omitted)) · \(String(format: "%.2f", run.distanceKm)) km").font(.subheadline)
                    }
                }
            }.searchable(text: $search, prompt: "搜索日期或记录名称")
                .navigationTitle("排除异常纪录").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

struct RaceGoalsView: View {
    @EnvironmentObject private var journal: TrainingJournal
    @State private var editing: RaceGoal?
    @State private var deleting: RaceGoal?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("给下一场比赛一个目标").font(.title2.weight(.semibold))
                Text("记录日期和期待的成绩，按自己的节奏准备。").font(.subheadline).foregroundStyle(.secondary)
                if journal.data.races.isEmpty {
                    ContentUnavailableView("还没有目标赛事", systemImage: "flag.checkered", description: Text("点击右上角添加比赛，也可以先不填写目标成绩。"))
                }
                ForEach(journal.data.races.sorted { $0.date < $1.date }) { goal in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(goal.name).font(.title3.weight(.semibold))
                                Text(goal.date.formatted(date: .long, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("编辑赛事") { editing = goal }
                                Button("删除赛事", role: .destructive) { deleting = goal }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        }
                        let days = goal.daysRemaining()
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(days < 0 ? "已结束" : (days == 0 ? "今天开跑" : "\(days)"))
                                .font(.system(size: days > 0 ? 44 : 28, weight: .medium, design: .rounded)).foregroundStyle(RunTheme.accent)
                            if days > 0 { Text("天后出发").foregroundStyle(.secondary) }
                        }
                        HStack(alignment: .top) {
                            goalMetric("距离", "\(String(format: "%g", goal.distanceKm)) km")
                            goalMetric("目标成绩", goal.targetSeconds.map(TrainingFormat.duration) ?? "未设置")
                            goalMetric("目标配速", goal.targetSeconds == nil ? "—" : "\(goal.targetPace)/km")
                        }
                        if !goal.note.isEmpty { Text(goal.note).font(.subheadline).foregroundStyle(.secondary) }
                        NavigationLink { AITrainingView() } label: { Label("安排备赛训练", systemImage: "calendar.badge.plus") }.font(.subheadline)
                    }.journalCard()
                }
            }.padding(18)
        }.background(RunTheme.page).navigationTitle("目标赛事").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { editing = RaceGoal(name: "", date: .now, distanceKm: 21.0975) } label: { Image(systemName: "plus").accessibilityLabel("添加赛事") } }
            .sheet(item: $editing) { RaceGoalEditor(goal: $0) }
            .confirmationDialog("删除这个目标赛事？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除赛事", role: .destructive) { if let deleting { journal.deleteRace(deleting.id) }; deleting = nil }
            }
    }
    private func goalMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RaceGoalEditor: View {
    @EnvironmentObject private var journal: TrainingJournal
    @Environment(\.dismiss) private var dismiss
    let goal: RaceGoal
    @State private var name = ""
    @State private var date = Date.now
    @State private var distance = "21.0975"
    @State private var hasTarget = false
    @State private var hours = 1
    @State private var minutes = 45
    @State private var seconds = 0
    @State private var note = ""
    private var km: Double? { TrainingFormat.decimal(distance) }
    private var target: Double { Double(hours * 3600 + minutes * 60 + seconds) }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && km != nil && km!.isFinite && (0.1...300).contains(km!) && (!hasTarget || target >= 60) }
    var body: some View {
        NavigationStack {
            Form {
                if let error = journal.errorMessage { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section("赛事") {
                    TextField("赛事名称", text: $name).onChange(of: name) { _, text in name = String(text.prefix(80)) }
                    DatePicker("比赛日期", selection: $date, displayedComponents: .date)
                    HStack { Text("距离（km）"); TextField("21.0975", text: $distance).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    HStack {
                        ForEach(RecordDistance.allCases) { category in
                            Button(category.rawValue) { distance = String(category.km) }.buttonStyle(.bordered)
                        }
                    }
                }
                Section {
                    Toggle("设置目标成绩", isOn: $hasTarget)
                    if hasTarget {
                        Stepper("\(hours) 小时", value: $hours, in: 0...99)
                        Stepper("\(minutes) 分钟", value: $minutes, in: 0...59)
                        Stepper("\(seconds) 秒", value: $seconds, in: 0...59)
                        if let km, km > 0 { LabeledContent("目标配速", value: "\(TrainingFormat.pace(target / km)) /km") }
                    }
                } header: { Text("期待的成绩") } footer: { Text("目标配速根据你填写的距离和用时计算，不是完赛预测。") }
                Section("备赛备注") { TextEditor(text: $note).frame(minHeight: 90).onChange(of: note) { _, text in note = String(text.prefix(2000)) } }
            }
            .navigationTitle("目标赛事").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    guard let km else { return }
                    var updated = goal; updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.date = date; updated.distanceKm = km; updated.targetSeconds = hasTarget ? target : nil; updated.note = note
                    if journal.saveRace(updated) { dismiss() }
                }.disabled(!valid) }
            }
            .onAppear {
                name = goal.name; date = goal.date; distance = String(goal.distanceKm); note = goal.note
                hasTarget = goal.targetSeconds != nil
                if let t = goal.targetSeconds { hours = Int(t) / 3600; minutes = Int(t) / 60 % 60; seconds = Int(t) % 60 }
            }
        }
    }
}

struct TrainingPlansView: View {
    @EnvironmentObject private var journal: TrainingJournal
    @EnvironmentObject private var store: ArchiveStore
    @State private var focus: Date
    @State private var editing: PlannedRun?
    @State private var linking: PlannedRun?
    @State private var deleting: PlannedRun?
    init(initialDate: Date = .now) { _focus = State(initialValue: initialDate) }
    private var calendar: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    private var week: DateInterval { calendar.dateInterval(of: .weekOfYear, for: focus)! }
    private var plans: [PlannedRun] { journal.data.plans.filter { $0.date >= week.start && $0.date < week.end }.sorted { $0.date < $1.date } }
    private var activityLookup: [String: ArchiveActivity] { Dictionary(uniqueKeysWithValues: store.activities.map { ($0.id, $0) }) }
    private var linkedCount: Int { plans.filter { $0.activityID.flatMap { activityLookup[$0] } != nil }.count }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { moveWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上一周")
                    Spacer()
                    VStack(spacing: 4) {
                        Text("\(week.start.formatted(.dateTime.month().day())) — \(week.end.addingTimeInterval(-1).formatted(.dateTime.month().day()))").font(.headline)
                        Text(String(calendar.component(.year, from: week.start))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { moveWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下一周")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("计划 \(String(format: "%g", plans.reduce(0) { $0 + $1.distanceKm })) km").font(.title2.weight(.medium))
                        Text("\(plans.count) 项安排 · \(linkedCount) 项已关联跑步").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("本周") { focus = .now }.font(.subheadline)
                }.journalCard()
                if plans.isEmpty {
                    ContentUnavailableView("这一周还没有安排", systemImage: "calendar", description: Text("添加一项训练，跑完后关联实际记录查看完成情况。"))
                }
                ForEach(plans) { plan in planCard(plan) }
                Text("完成情况以你关联的实际跑步为准。同一次跑步只能关联一项计划；配速只比较整次平均值，不代表间歇段完成质量。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }.background(RunTheme.page).navigationTitle("训练计划").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { editing = PlannedRun(date: focus, distanceKm: 8) } label: { Image(systemName: "plus").accessibilityLabel("添加训练") } }
            .sheet(item: $editing) { PlanEditor(plan: $0) }
            .sheet(item: $linking) { PlanActivityPicker(plan: $0) }
            .confirmationDialog("删除这项训练计划？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除计划", role: .destructive) { if let deleting { journal.deletePlan(deleting.id) }; deleting = nil }
            }
    }
    private func moveWeek(_ amount: Int) { focus = calendar.date(byAdding: .weekOfYear, value: amount, to: focus) ?? focus }
    private func planCard(_ plan: PlannedRun) -> some View {
        let activity = plan.activityID.flatMap { activityLookup[$0] }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(plan.date.formatted(.dateTime.weekday(.wide).month().day())).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("编辑计划") { editing = plan }
                    if plan.activityID != nil { Button("解除跑步关联") { var p = plan; p.activityID = nil; journal.savePlan(p) } }
                    Button("删除计划", role: .destructive) { deleting = plan }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 32) }
            }
            Text("\(plan.kind.rawValue) · \(String(format: "%g", plan.distanceKm)) km").font(.title3.weight(.semibold))
            if let low = plan.paceMin, let high = plan.paceMax {
                Text("目标均速 \(TrainingFormat.pace(low))–\(TrainingFormat.pace(high)) /km").font(.subheadline).foregroundStyle(.secondary)
            }
            if !plan.note.isEmpty { Text(plan.note).font(.subheadline).foregroundStyle(.secondary) }
            switch plan.completion(activity: activity) {
            case .unlinked:
                Label(plan.date < calendar.startOfDay(for: .now) ? "待补充完成记录" : "待关联跑步", systemImage: "circle.dashed").font(.subheadline).foregroundStyle(.secondary)
            case .missing:
                Label("关联记录暂不可用，请刷新健康数据或重新选择", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
            case .linked(let ratio, let intensity):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("距离完成 \(Int((ratio * 100).rounded()))%")
                        Spacer()
                        if let activity { Text("\(String(format: "%.2f", activity.distanceKm)) / \(String(format: "%g", plan.distanceKm)) km") }
                    }.font(.subheadline)
                    ProgressView(value: min(1, max(0, ratio))).tint(RunTheme.route)
                    if let intensity { Text(intensity ? "平均配速在目标范围内" : "平均配速不在目标范围内").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button(plan.activityID == nil ? "关联实际跑步" : "更换关联") { linking = plan }
                Spacer()
                if let activity { NavigationLink("查看记录") { ActivityDetailView(activity: activity) } }
            }.font(.subheadline)
        }.journalCard()
    }
}

private struct PlanEditor: View {
    @EnvironmentObject private var journal: TrainingJournal
    @Environment(\.dismiss) private var dismiss
    let plan: PlannedRun
    @State private var date = Date.now
    @State private var kind: TrainingKind = .easy
    @State private var distance = "8"
    @State private var hasPace = false
    @State private var fastest = "5:00"
    @State private var slowest = "6:00"
    @State private var note = ""
    private var km: Double? { TrainingFormat.decimal(distance) }
    private var low: Double? { TrainingFormat.parsePace(fastest) }
    private var high: Double? { TrainingFormat.parsePace(slowest) }
    private var valid: Bool {
        guard let km, km.isFinite, (0.1...300).contains(km) else { return false }
        if hasPace { guard let low, let high, (120...1800).contains(low), (low...1800).contains(high) else { return false } }
        return true
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error = journal.errorMessage { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section("这次想怎么跑") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    Picker("类型", selection: $kind) { ForEach(TrainingKind.allCases.filter { $0 != .unspecified }) { Text($0.rawValue).tag($0) } }
                    HStack { Text("目标公里数"); TextField("8", text: $distance).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                }
                Section {
                    Toggle("设置整次平均配速范围", isOn: $hasPace)
                    if hasPace {
                        TextField("最快配速，如 5:00", text: $fastest).keyboardType(.numbersAndPunctuation)
                        TextField("最慢配速，如 6:00", text: $slowest).keyboardType(.numbersAndPunctuation)
                    }
                } footer: { Text("格式为 分:秒，支持 2:00–30:00 /km。间歇跑可只设距离，将具体安排写在备注中。") }
                Section("训练备注") { TextEditor(text: $note).frame(minHeight: 100).onChange(of: note) { _, text in note = String(text.prefix(2000)) } }
            }
            .navigationTitle("训练安排").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    guard let km else { return }
                    var p = plan; p.date = date; p.kind = kind; p.distanceKm = km; p.note = note
                    p.paceMin = hasPace ? low : nil; p.paceMax = hasPace ? high : nil
                    if journal.savePlan(p) { dismiss() }
                }.disabled(!valid) }
            }
            .onAppear {
                date = plan.date; kind = plan.kind; distance = String(plan.distanceKm); note = plan.note
                hasPace = plan.paceMin != nil
                if let low = plan.paceMin, let high = plan.paceMax {
                    fastest = String(format: "%d:%02d", Int(low) / 60, Int(low) % 60)
                    slowest = String(format: "%d:%02d", Int(high) / 60, Int(high) % 60)
                }
            }
        }
    }
}

private struct PlanActivityPicker: View {
    @EnvironmentObject private var journal: TrainingJournal
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    let plan: PlannedRun
    @State private var search = ""
    private var used: Set<String> { Set(journal.data.plans.filter { $0.id != plan.id }.compactMap(\.activityID)) }
    private var candidates: [ArchiveActivity] {
        store.activities.filter { !used.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || DateFormatter.archiveDay.string(from: $0.date).contains(search)) }
            .sorted { abs($0.date.timeIntervalSince(plan.date)) < abs($1.date.timeIntervalSince(plan.date)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("优先显示接近计划日期的记录。已关联其他计划的跑步不会重复出现。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(candidates) { run in
                    Button {
                        var p = plan; p.activityID = run.id
                        if journal.savePlan(p) { dismiss() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                Text("\(String(format: "%.2f", run.distanceKm)) km · \(run.pace) /km").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if run.id == plan.activityID { Image(systemName: "checkmark") }
                        }
                    }.tint(.primary)
                }
                if candidates.isEmpty { ContentUnavailableView("没有可关联的记录", systemImage: "figure.run", description: Text("请先读取 Apple Health 跑步，或调整搜索条件。")) }
            }.searchable(text: $search, prompt: "搜索日期或跑步名称")
                .navigationTitle("关联实际跑步").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("取消") { dismiss() } }
        }
    }
}
