import Charts
import SwiftUI

struct WorkoutMetricPoint: Codable {
    var seconds: Double
    var value: Double
}

struct WorkoutMetricPresentation: Codable {
    var series: [ExportMetric: [WorkoutMetricPoint]]
    var averages: [ExportMetric: Double]
    var coverage: [ExportMetric: Double]
    var elevationGain: Double?
    var energy: Double?

    init(workout: ExportWorkout) {
        let analysis = ExportObjectiveAnalysis(workout: workout)
        var lines: [ExportMetric: [WorkoutMetricPoint]] = [:]
        var averages: [ExportMetric: Double] = [:], coverage: [ExportMetric: Double] = [:]
        for metric in ExportMetric.allCases {
            guard let source = analysis.series[metric] else { continue }
            let statistic = source.statistic(start: 0, end: analysis.elapsed)
            if let average = statistic.average { averages[metric] = average }
            if let fraction = statistic.fraction { coverage[metric] = fraction }
            let width = max(10, analysis.elapsed / 400)
            lines[metric] = stride(from: 0.0, to: analysis.elapsed, by: width).compactMap { start in
                let end = min(start + width, analysis.elapsed)
                guard let average = source.statistic(start: start, end: end).average else { return nil }
                return WorkoutMetricPoint(seconds: (start + end) / 2, value: average)
            }
        }
        self.series = lines
        let summaries: [(ExportMetric, Double?)] = [(.stride, workout.stride), (.contact, workout.contact), (.oscillation, workout.oscillation)]
        for (metric, value) in summaries {
            if averages[metric] == nil, let value, value.isFinite, value > 0 { averages[metric] = value }
        }
        self.averages = averages
        self.coverage = coverage
        elevationGain = workout.elevationGain
        energy = workout.energyKcal
    }
}

struct RunningFormMetricsView: View {
    let metrics: WorkoutMetricPresentation
    private var available: [ExportMetric] {
        [.stride, .contact, .oscillation].filter { metrics.averages[$0] != nil }
    }
    var body: some View {
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                Text("跑姿指标").font(.headline)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(available, id: \.self) { metric in
                        LabeledContent(metric == .stride ? "平均步幅" : metric.name,
                            value: String(format: metric == .stride ? "%.2f %@" : "%.1f %@", metrics.averages[metric]!, metric.unit))
                            .font(.subheadline)
                    }
                    DisclosureGroup("数据覆盖与说明") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(available, id: \.self) { metric in
                                if let fraction = metrics.coverage[metric] {
                                    Text("\(metric.name)：采样覆盖经过时长的 \(Int((fraction * 100).rounded()))%")
                                }
                            }
                            Text("在相近配速与路况下比较；这些指标不单独用于判断跑姿好坏。")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                    }.font(.caption).tint(.secondary)
                }
            }
        }
    }
}

struct ReferenceMetricTrendsView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @State private var references = ExportReferenceData()
    @State private var selected = "VO2 max"
    @State private var loading = true
    @State private var error: String?
    private var types: [String] { Array(Set(references.samples.map(\.metric))).sorted() }
    private var samples: [ExportReferenceSample] { references.samples.filter { $0.metric == selected }.sorted { $0.date < $1.date } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading { HStack { ProgressView(); Text("正在读取健康记录…") }.nativeCard() }
                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                    }.nativeCard()
                }
                if !types.isEmpty {
                    Picker("指标", selection: $selected) {
                        ForEach(types, id: \.self) { Text($0 == "VO2 max" ? "VO₂ max" : "一分钟心率恢复").tag($0) }
                    }.pickerStyle(.segmented)
                    if let latest = samples.last {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(format: "%.1f %@", latest.value, latest.unit)).font(.system(size: 32, weight: .bold)).foregroundStyle(RunTheme.route)
                            Text(latest.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if samples.count > 1 {
                                Chart(Array(samples.enumerated()), id: \.offset) { _, sample in
                                    LineMark(x: .value("日期", sample.date), y: .value(selected, sample.value)).foregroundStyle(RunTheme.route)
                                    PointMark(x: .value("日期", sample.date), y: .value(selected, sample.value)).foregroundStyle(RunTheme.route)
                                }.frame(height: 200).chartYScale(domain: .automatic(includesZero: false))
                            }
                            Text(latest.method).font(.caption).foregroundStyle(.secondary)
                        }.nativeCard()
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近记录").font(.headline)
                            ForEach(Array(samples.suffix(30).reversed().enumerated()), id: \.offset) { _, sample in
                                VStack(alignment: .leading, spacing: 5) {
                                    LabeledContent(sample.date.formatted(date: .abbreviated, time: .shortened),
                                        value: String(format: "%.1f %@", sample.value, sample.unit)).font(.subheadline)
                                    Text(sample.source).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.nativeCard()
                    }
                } else if !loading && error == nil {
                    ContentUnavailableView("暂无可用记录", systemImage: "heart.text.clipboard", description: Text("健康 App 中有 VO₂ max 或一分钟心率恢复记录后，会在这里显示；未记录不代表数值为零。"))
                }
                Text("按系统记录的测量日期展示，不强行归属于某次跑步。").font(.caption).foregroundStyle(.secondary)
                ForEach(references.issues.keys.sorted(), id: \.self) { metric in
                    Text("\(metric)：暂时不可读取").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        }.background(RunTheme.page).navigationTitle("体能趋势").navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let earliest = archive.activities.map(\.date).min() ?? Calendar.current.date(byAdding: .year, value: -3, to: .now)!
            references = try await archive.exportReferences(start: earliest, end: .now)
            if !types.contains(selected) { selected = types.first ?? "VO2 max" }
        } catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}
