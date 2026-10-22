import Foundation

struct ExportRawSample {
    let metric: String
    let start: Date
    let end: Date
    let value: Double
    let unit: String
    var source = ""
    var sourceBundle = ""
    var device = ""
    var deviceKey = ""
    var sourcePriority = 0
    var sourceVersion = ""
    var sourceKey: String { sourceBundle + "|" + deviceKey + "|" + device + "|" + sourceVersion }
    var sourceLabel: String { [source, sourceBundle, device, sourceVersion.isEmpty ? "" : "版本 " + sourceVersion].filter { !$0.isEmpty }.joined(separator: " / ") }
}

struct ExportReferenceSample {
    let metric: String
    let date: Date
    let value: Double
    let unit: String
    let source: String
    var method = "来源未提供测量方法"
}
struct ExportReferenceData {
    var samples: [ExportReferenceSample] = []
    var issues: [String: String] = [:]
}

struct ExportWorkout {
    let uuid: String
    let start: Date
    let end: Date
    let distanceKm: Double?
    let duration: Double
    let heartRate: Double?
    let maxHeartRate: Double?
    let power: Double?
    let cadence: Double?
    let energyKcal: Double?
    let elevationGain: Double?
    let indoor: Bool?
    let source: String
    let sourceBundle: String
    let device: String
    let points: [RoutePointPayload]
    let samples: [ExportRawSample]
    let intervals: [WorkoutIntervalPayload]
    var stride: Double? = nil
    var contact: Double? = nil
    var oscillation: Double? = nil
    var elevationLoss: Double? = nil
    var steps: Double? = nil
    var pauses: [DateInterval] = []
    var readIssues: [String: String] = [:]
    var appleHeartRateZones: AnalysisAppleHeartRateZones? = nil
    var preferredAppleHeartRateZones: AnalysisAppleHeartRateZones? = nil
}

struct AnalysisExportOptions {
    let start: Date
    let endExclusive: Date
    let full: Bool
    let includePlanning: Bool
    let timeZone: TimeZone
    var calibration = AnalysisCalibration()
    var preferredAppleHeartRateZones: AnalysisAppleHeartRateZones? = nil
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    func includes(_ date: Date) -> Bool { date >= start && date < endExclusive }
}

struct AnalysisExportResult {
    let url: URL
    let folder: URL
    let count: Int
    let failed: Int
    let partial: Int
    let bytes: Int64
}

struct ExportKilometerSplit {
    let index: Int
    let km: Double
    let start: Double
    let end: Double
    var altitudeStart: Double? = nil
    var altitudeEnd: Double? = nil
    var duration: Double { end - start }
}

enum ExportSplits {
    /// A conservative GPS estimate. A gap or implausible jump invalidates the whole
    /// calculation rather than silently bridging missing distance/time.
    static func calculate(_ points: [RoutePointPayload], start: Date, end: Date? = nil) -> (rows: [ExportKilometerSplit], status: String) {
        guard points.count > 1 else { return ([], "无可用路线") }
        let ordered = points.filter { $0.timestamp >= start && (end == nil || $0.timestamp <= end!) }.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count > 1 else { return ([], "运动时间内无可用路线") }
        guard ordered.allSatisfy({ GeoPoint(latitude: $0.latitude, longitude: $0.longitude).valid }) else { return ([], "GPS 坐标无效，未计算") }
        var distance = 0.0, next = 1000.0, lastBoundary = ordered[0].timestamp.timeIntervalSince(start)
        var rows: [ExportKilometerSplit] = []
        var altitudeStart = ordered.first.flatMap { $0.altitude.isFinite ? $0.altitude : nil }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            let meters = GeoPoint(latitude: a.latitude, longitude: a.longitude).meters(to: GeoPoint(latitude: b.latitude, longitude: b.longitude))
            if seconds == 0 && meters < 1 { continue }
            guard seconds > 0, seconds <= 30, meters / seconds <= 12 else { return ([], "GPS 中断或跳点，未计算") }
            while distance + meters >= next && meters > 0 {
                let boundary = a.timestamp.timeIntervalSince(start) + (next - distance) / meters * seconds
                let altitude = a.altitude.isFinite && b.altitude.isFinite ? a.altitude + (b.altitude - a.altitude) * (next - distance) / meters : nil
                rows.append(ExportKilometerSplit(index: rows.count + 1, km: 1, start: lastBoundary, end: boundary, altitudeStart: altitudeStart, altitudeEnd: altitude))
                altitudeStart = altitude
                lastBoundary = boundary; next += 1000
            }
            distance += meters
        }
        let remainder = distance - Double(rows.count) * 1000
        if remainder > 1, let end = ordered.last?.timestamp.timeIntervalSince(start), end > lastBoundary {
            rows.append(ExportKilometerSplit(index: rows.count + 1, km: remainder / 1000, start: lastBoundary, end: end, altitudeStart: altitudeStart, altitudeEnd: ordered.last.flatMap { $0.altitude.isFinite ? $0.altitude : nil }))
        }
        return (rows, rows.isEmpty ? "GPS 距离不足" : "GPS 估算，包含暂停；起点为首个 GPS 点")
    }
}

actor AnalysisExportBuilder {
    private let options: AnalysisExportOptions
    private let journal: JournalData
    private let allActivities: [ArchiveActivity]
    private let folder: URL
    private var references = ExportReferenceData()
    private var files: [(name: String, url: URL)] = []
    private var rows: [[ExportCell]] = [], splitRows: [[ExportCell]] = [], processRows: [[ExportCell]] = []
    private var heartRows: [[ExportCell]] = [], qualityRows: [[ExportCell]] = [], intervalRows: [[ExportCell]] = []
    private var trainingRows: [[ExportCell]] = []
    private var appleZoneRows: [[ExportCell]] = []
    private var failures = 0, partialIssues = 0
    private let generated = Date.now
    private static let bucketSeconds = 30.0
    private static let headers = ["记录 ID", "开始时间（本地）", "距离（km）", "运动计时（s）", "总经过时间（s）", "暂停差值（s）", "平均配速（s/km）", "平均心率（bpm）", "最高心率（bpm）", "平均步频（步/min）", "平均功率（W）", "平均步长（m）", "平均触地时间（ms）", "平均垂直振幅（cm）", "总步数", "活动能量（kcal）", "累计爬升（m）", "累计下降（m）", "心率均值来源", "步频均值来源", "功率均值来源", "跑姿均值来源", "场景", "来源 App", "来源标识", "设备", "HealthKit UUID", "开始时间 UTC", "结束时间 UTC", "读取状态", "公里分段口径 / 状态", "GPS 点数", "原始采样数", "暂停事件校验", "原始采样 CSV", "路线 CSV", "路线 GPX / 状态"]
    private static let metricHeaders = ExportMetric.allCases.flatMap { ["平均\($0.name)（\($0.unit)）", "\($0.name)覆盖比例（0–1，估算）"] }

    init(options: AnalysisExportOptions, journal: JournalData, activities: [ArchiveActivity], folder: URL) throws {
        self.options = options; self.journal = journal; self.allActivities = activities; self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func setReferences(_ data: ExportReferenceData) { references = data }

    func add(activity: ArchiveActivity, workout: ExportWorkout?, error: String?) throws {
        try Task.checkCancellation()
        let distance = workout?.distanceKm ?? (workout == nil && activity.distanceKm > 0 ? activity.distanceKm : nil)
        let duration = workout?.duration ?? TrainingFormat.seconds(activity.duration)
        let analysis = workout.map(ExportObjectiveAnalysis.init)
        let split = workout.map { ExportSplits.calculate($0.points, start: $0.start, end: $0.end) } ?? (rows: [], status: "读取失败")
        let stats = analysis.map { $0.statistics(start: 0, end: $0.elapsed) } ?? [:]
        var rawPath = "", routePath = "", gpxStatus = "完整版可导出"
        if workout == nil { failures += 1; gpxStatus = "读取失败" }
        if var workout, let analysis {
            workout.preferredAppleHeartRateZones = options.preferredAppleHeartRateZones ?? workout.preferredAppleHeartRateZones
            let derived = TrainingAnalysisMath.calculate(workout, activity: activity, calibration: options.calibration, now: generated, calendar: options.calendar)
            let metrics = [("心率负荷", derived.load), ("速度/心率效率", derived.efficiency), ("前后半程漂移", derived.drift), ("候选片段速度变异", derived.speedVariation)]
                + derived.form.map { (ExportMetric(rawValue: $0.metric)?.name ?? $0.metric, $0.value) }
            for (name, value) in metrics {
                trainingRows.append([.text(activity.id), .text(name), .optional(value.value), .text(value.unit), .number(value.coverage),
                    .text(value.complete ? "条件满足" : "条件不足或部分数据"), .text(value.reason ?? ""), .text(value.method), .text(derived.version),
                    .optional(derived.heartRateReference?.bpm), .text(derived.heartRateReference?.explanation ?? ""), .text(derived.structure),
                    .text(value.estimated == true ? "是" : "否")])
            }
            if let zones = derived.appleHeartRateZones {
                for (order, zone) in zones.zones.enumerated() {
                    appleZoneRows.append([.text(activity.id), .number(Double(order + 1)), .optional(zone.lowerBPM), .optional(zone.upperBPM),
                        .optional(zone.seconds), .text(zones.source), .text(zones.scope), .optional(zones.coverage), .text(zones.reason ?? "")])
                }
            }
            partialIssues += workout.readIssues.count
            for metric in ExportMetric.allCases {
                let series = analysis.series[metric]!, stat = stats[metric]!
                qualityRows.append([.text(activity.id), .text(metric.name), .text(metric.unit), .text(series.status),
                    .number(Double(series.sampleCount)), .number(Double(series.invalidCount)), .number(stat.supportedSeconds),
                    .optional(stat.fraction), .number(Double(series.pointEstimateCount)), .text(series.source)])
            }
            qualityRows.append([.text(activity.id), .text("GPS"), .text("WGS-84"), .text(workout.readIssues["gps"].map { "读取失败：\($0)" } ?? split.status),
                .number(Double(workout.points.count)), .blank, .blank, .blank, .blank, .text(workout.source)])
            for item in split.rows {
                var cells: [ExportCell] = [.text(activity.id), .number(Double(item.index)), .number(item.km), .number(item.start), .number(item.end),
                    .number(item.duration), .optional(analysis.activeSeconds(start: item.start, end: item.end)), .number(item.duration / item.km),
                    .optional(item.altitudeStart), .optional(item.altitudeEnd), .optional(item.altitudeStart.flatMap { a in item.altitudeEnd.map { $0 - a } })]
                cells += metricCells(analysis.statistics(start: item.start, end: item.end))
                cells += [.optional(analysis.series[.heartRate]?.statistic(start: item.start, end: item.end).maximum), .text(item.km < 1 ? "最后不足 1 公里" : "完整公里")]
                splitRows.append(cells)
            }
            var start = 0.0
            while start < analysis.elapsed {
                try Task.checkCancellation()
                let end = min(analysis.elapsed, start + Self.bucketSeconds)
                processRows.append([.text(activity.id), .number(start), .number(end), .number(end - start), .optional(analysis.activeSeconds(start: start, end: end))]
                    + metricCells(analysis.statistics(start: start, end: end)))
                start = end
            }
            let distribution = analysis.heartRateDistribution(), known = distribution.reduce(0, +)
            if known > 0 {
                let labels = ["<100", "100–119", "120–139", "140–159", "160–179", "≥180"]
                for index in labels.indices {
                    heartRows.append([.text(activity.id), .text(labels[index]), .number(distribution[index]), .number(distribution[index] / known), .optional(analysis.elapsed > 0 ? distribution[index] / analysis.elapsed : nil)])
                }
            }
            heartRows.append([.text(activity.id), .text("未覆盖"), .number(max(0, analysis.elapsed - known)), .blank, .optional(analysis.elapsed > 0 ? max(0, analysis.elapsed - known) / analysis.elapsed : nil)])
            for item in workout.intervals {
                intervalRows.append([.text(activity.id), .number(Double(item.index)), .text(item.kind), .text(item.eventType ?? ""),
                    .number(item.startElapsedSeconds), .number(item.endElapsedSeconds), .number(item.durationSeconds), .optional(item.distanceKm),
                    .optional(item.paceSecondsPerKm), .integer(item.avgHeartRate), .integer(item.maxHeartRate), .optional(item.avgCadence), .optional(item.avgPower)])
            }
            if options.full {
                let prefix = String(format: "%05d", rows.count + 1)
                rawPath = "samples/\(prefix).csv"
                try writeCSV(rawPath, headers: ["activity_id", "healthkit_uuid", "metric", "start_utc", "end_utc", "start_elapsed_s", "end_elapsed_s", "value", "unit", "source", "source_bundle", "device"], rows: workout.samples.map {
                    [.text(activity.id), .text(workout.uuid), .text($0.metric), .text(ExportText.iso($0.start)), .text(ExportText.iso($0.end)),
                        .number($0.start.timeIntervalSince(workout.start)), .number($0.end.timeIntervalSince(workout.start)), .number($0.value), .text($0.unit), .text($0.source), .text($0.sourceBundle), .text($0.device)]
                })
                gpxStatus = "无可用路线"
                if !workout.points.isEmpty {
                    routePath = "routes/\(prefix).csv"
                    try writeCSV(routePath, headers: ["activity_id", "timestamp_utc", "elapsed_s", "latitude", "longitude", "altitude_m", "speed_mps"], rows: workout.points.map {
                        [.text(activity.id), .text(ExportText.iso($0.timestamp)), .number($0.timestamp.timeIntervalSince(workout.start)), .number($0.latitude), .number($0.longitude), .number($0.altitude), .optional($0.speedMps)]
                    })
                    do {
                        let gpx = try GPXExporter.document(name: activity.name, points: workout.points)
                        try writeText("routes/\(prefix).gpx", gpx); gpxStatus = "routes/\(prefix).gpx"
                    } catch let error as JournalError { gpxStatus = error.localizedDescription }
                }
            }
        } else {
            qualityRows.append([.text(activity.id), .text("整条运动"), .text(""), .text("读取失败：\(error ?? "未知原因")"), .blank, .blank, .blank, .blank, .blank, .text("本地摘要回退")])
        }
        let hr = workout?.heartRate ?? (workout == nil ? activity.avgHeartRate.map(Double.init) : stats[.heartRate]?.average)
        let cadence = workout?.cadence ?? stats[.steps]?.average
        let power = workout?.power ?? (workout == nil ? activity.avgPower : stats[.power]?.average)
        let hrSource = workout == nil ? "本地摘要" : (workout?.heartRate != nil ? "HealthKit 运动统计" : "采样区间加权估算")
        let cadenceSource = workout?.cadence != nil ? "运动关联步数 / 运动分钟" : "步数采样区间推算"
        let powerSource = workout == nil ? "本地摘要" : (workout?.power != nil ? "HealthKit 运动统计" : "采样区间加权估算")
        let runningFormSource = "优先 HealthKit 运动统计，缺失时使用采样区间加权；分别查看指标覆盖率"
        let issue = workout?.readIssues.sorted(by: { $0.key < $1.key }).map { "\($0.key)：\($0.value)" }.joined(separator: "；") ?? ""
        rows.append([
            .text(activity.id), .date(workout?.start ?? activity.date), .optional(distance), .number(duration),
            .optional(analysis?.elapsed), .optional(analysis.map { max(0, $0.elapsed - duration) }), .optional(distance.flatMap { $0 > 0 ? duration / $0 : nil }),
            .optional(hr), .optional(workout?.maxHeartRate ?? (workout == nil ? activity.maxHeartRate.map(Double.init) : stats[.heartRate]?.maximum)),
            .optional(cadence), .optional(power), .optional(workout?.stride ?? stats[.stride]?.average), .optional(workout?.contact ?? stats[.contact]?.average),
            .optional(workout?.oscillation ?? stats[.oscillation]?.average), .optional(workout?.steps), .optional(workout?.energyKcal), .optional(workout?.elevationGain), .optional(workout?.elevationLoss),
            .text(hr == nil ? "" : hrSource), .text(cadence == nil ? "" : cadenceSource), .text(power == nil ? "" : powerSource), .text(workout == nil ? "" : runningFormSource),
            .text(workout?.indoor.map { $0 ? "室内" : "室外" } ?? "未知"), .text(workout?.source ?? "本地摘要回退"), .text(workout?.sourceBundle ?? ""), .text(workout?.device ?? ""),
            .text(workout?.uuid ?? ""), .text(ExportText.iso(workout?.start ?? activity.date)), .text(workout.map { ExportText.iso($0.end) } ?? ""),
            .text(workout == nil ? "读取失败，保留摘要：\(error ?? "未知原因")" : (issue.isEmpty ? "已读取；缺失值留空" : "部分指标读取失败：\(issue)")),
            .text(split.status), .optional(workout.map { Double($0.points.count) }), .optional(workout.map { Double($0.samples.count) }),
            .text(analysis.map { $0.pauseTimingKnown ? "可还原暂停时段" : "暂停事件与总计时不一致，段内运动计时留空" } ?? ""),
            .text(rawPath), .text(routePath), .text(gpxStatus)
        ])
    }

    private func metricCells(_ stats: [ExportMetric: ExportMetricStatistic]) -> [ExportCell] {
        ExportMetric.allCases.flatMap { [.optional(stats[$0]?.average), .optional(stats[$0]?.fraction)] }
    }

    func finish() throws -> AnalysisExportResult {
        try Task.checkCancellation()
        guard !rows.isEmpty else { throw ExportError.invalid("所选范围没有跑步记录") }
        var widths = Array(repeating: 24.0, count: Self.headers.count)
        for index in [18,19,20,21,29,30,33] { widths[index] = 58 }
        widths[0] = 28; widths[1] = 25; widths[26] = 42; widths[27] = 30; widths[28] = 30
        let overview = ExportSheet(name: "逐次跑步", headers: Self.headers, rows: rows, widths: widths)
        var sheets = [overview,
            ExportSheet(name: "公里分段", headers: ["记录 ID", "段序号", "GPS 距离（km）", "起点经过（s）", "终点经过（s）", "经过时间（s）", "运动计时（s，事件校验后）", "经过配速（s/km，含暂停）", "起点海拔（m）", "终点海拔（m）", "海拔变化（m，GPS估算）"] + Self.metricHeaders + ["最高心率（bpm）", "说明"], rows: splitRows),
            ExportSheet(name: "过程数据", headers: ["记录 ID", "起点经过（s）", "终点经过（s）", "区间长度（s）", "运动计时（s，事件校验后）"] + Self.metricHeaders, rows: processRows),
            ExportSheet(name: "心率分布", headers: ["记录 ID", "心率范围（bpm）", "支持时长（s，估算）", "占已覆盖时长比例（0–1）", "占总经过时间比例（0–1）"], rows: heartRows, widths: [28,24,30,34,36])]
        if !intervalRows.isEmpty { sheets.append(ExportSheet(name: "Apple原有分段", headers: ["记录 ID", "段序号", "分段类型", "事件类型", "起点经过（s）", "终点经过（s）", "运动计时（s）", "距离（km）", "配速（s/km）", "平均心率（bpm）", "最高心率（bpm）", "平均步频（步/min）", "平均功率（W）"], rows: intervalRows)) }
        let referenceRows: [[ExportCell]] = references.samples.sorted { $0.date < $1.date }.map {
            [.text($0.metric), .date($0.date), .number($0.value), .text($0.unit), .text($0.source), .text($0.method + "；按测量时间提供，未强行关联某次跑步")]
        }
        sheets.append(ExportSheet(name: "体能参考", headers: ["指标", "测量时间（本地）", "数值", "单位", "来源", "说明"], rows: referenceRows, widths: [38,26,20,22,64,55]))
        for metric in ["VO2 max", "1 分钟心率恢复（系统记录）"] where references.issues[metric] == nil {
            let values = references.samples.filter { $0.metric == metric }
            qualityRows.append([.text("全局"), .text(metric), .text(metric == "VO2 max" ? "ml/kg/min" : "bpm"),
                .text(values.isEmpty ? "未获得数据（未记录或未授权）" : "已读取，按测量时间提供"), .number(Double(values.count)),
                .blank, .blank, .blank, .blank, .text(Set(values.map(\.source)).sorted().joined(separator: "；"))])
        }
        for (name, issue) in references.issues.sorted(by: { $0.key < $1.key }) {
            qualityRows.append([.text("全局"), .text(name), .text(""), .text("读取失败：\(issue)"), .blank, .blank, .blank, .blank, .blank, .blank])
        }
        sheets.append(ExportSheet(name: "指标可用性", headers: ["记录 ID", "指标", "分析单位", "读取状态", "采用来源采样数", "无效采样数", "有效支持时长（s，估算）", "覆盖比例（0–1，估算）", "瞬时值延展数量", "采用来源"], rows: qualityRows, widths: [28,28,20,65,25,22,35,33,26,80]))
        sheets.append(ExportSheet(name: "训练指标", headers: ["记录 ID", "指标", "数值", "单位", "有效覆盖比例", "适用状态", "原因与限制", "计算方法", "算法版本", "参考最大心率", "最大心率依据", "过程结构候选", "是否采用估算依据"], rows: trainingRows))
        sheets.append(ExportSheet(name: "Apple心率区间", headers: ["记录 ID", "区间序号", "心率下界（bpm）", "心率上界（bpm）", "区间时长（s）", "配置来源", "使用口径", "覆盖比例", "说明"], rows: appleZoneRows))
        if options.includePlanning { sheets += planningSheets() }
        let instructions = documentation
        sheets.append(ExportSheet(name: "导出说明", headers: ["项目 / 字段", "含义 / 来源 / 单位"], rows: instructions.map { [.text($0.0), .text($0.1)] }, widths: [32,115]))
        let workbook = folder.appendingPathComponent("跑步分析.xlsx")
        try ExportWorkbook.write(sheets, to: workbook, timeZone: options.timeZone)
        var result = workbook
        if options.full {
            files.append(("跑步分析.xlsx", workbook))
            for sheet in sheets where sheet.name != "导出说明" {
                try writeCSV(sheet.name + ".csv", headers: sheet.headers.map { $0.replacingOccurrences(of: "（本地）", with: "（UTC）") }, rows: sheet.rows)
            }
            try writeText("README.txt", instructions.map { "\($0.0)：\($0.1)" }.joined(separator: "\n\n"))
            let metadata: [String: Any] = ["schema_version": 2, "created_utc": ExportText.iso(generated), "start_utc": ExportText.iso(options.start), "end_exclusive_utc": ExportText.iso(options.endExclusive), "timezone": options.timeZone.identifier, "activity_count": rows.count, "failed_count": failures, "partial_metric_failures": partialIssues + references.issues.count, "planning_included": options.includePlanning, "process_bucket_seconds": Self.bucketSeconds, "files": files.map(\.name)]
            let manifest = folder.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
            files.append(("manifest.json", manifest))
            result = folder.appendingPathComponent("跑步分析完整数据包.zip")
            try ExportZIP.write(files: files, to: result)
            for file in files { try? FileManager.default.removeItem(at: file.url) }
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: result.path)[.size] as? NSNumber)?.int64Value ?? 0
        return AnalysisExportResult(url: result, folder: folder, count: rows.count, failed: failures, partial: partialIssues + references.issues.count, bytes: bytes)
    }

    private func planningSheets() -> [ExportSheet] {
        let byID = Dictionary(allActivities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plans: [[ExportCell]] = journal.plans.sorted { $0.date < $1.date }.map { plan in
            let actual = plan.activityID.flatMap { byID[$0] }
            return [.text(plan.id), .date(plan.date), .number(plan.distanceKm), .optional(plan.paceMin), .optional(plan.paceMax), .text(plan.activityID ?? ""),
                .optional(actual?.distanceKm), .optional(actual.map { TrainingFormat.seconds($0.duration) }), .optional(actual.flatMap { plan.distanceKm > 0 ? $0.distanceKm / plan.distanceKm : nil })]
        }
        let races: [[ExportCell]] = journal.races.sorted { $0.date < $1.date }.map { race in
            [.text(race.id), .text(race.name), .date(race.date), .number(race.distanceKm), .optional(race.targetSeconds), .optional(race.targetSeconds.flatMap { seconds in race.distanceKm > 0 ? seconds / race.distanceKm : nil })]
        }
        return [ExportSheet(name: "训练计划", headers: ["计划 ID", "日期", "计划距离（km）", "配速下限（s/km）", "配速上限（s/km）", "关联记录 ID", "实际距离（km）", "实际计时（s，整秒）", "距离完成比"], rows: plans), ExportSheet(name: "目标赛事", headers: ["目标 ID", "赛事", "日期", "距离（km）", "目标计时（s）", "目标配速（s/km）"], rows: races)]
    }

    private var documentation: [(String, String)] {
        [
            ("导出版本", "Running Archive 客观跑步分析 v2；分析版与完整版的 Excel 内容相同。固定历史快照，不随 Excel 编辑重新计算。"),
            ("生成时间 UTC", ExportText.iso(generated)),
            ("记录范围", "\(ExportText.iso(options.start)) ≤ 运动开始时间 < \(ExportText.iso(options.endExclusive))；保留每次跑步日期以便模型还原顺序，无额外周月/连续训练历史表。"),
            ("本地时间", "Excel 日期采用 \(options.timeZone.identifier)；CSV 和 UTC 列采用 UTC。"),
            ("数据覆盖", "\(rows.count) 次跑步；\(failures) 次整条读取失败；\(partialIssues + references.issues.count) 项指标读取失败。逐次跑步与指标可用性表保留具体原因。"),
            ("缺失值", "空白表示未获得或无法可靠计算，不是 0；未授权与未记录无法区分。查询报错单独标注，不丢弃其他已读指标。"),
            ("分析内容", "逐次跑步、公里分段、30 秒过程数据、心率数值分布、体能参考、指标可用性；不导出 RPE、训练备注、疲劳、睡眠和天气。"),
            ("距离 / 运动计时", "距离取 HealthKit totalDistance（km）；运动计时取 workout.duration（s）；回退摘要仅保留整秒计时。"),
            ("暂停 / 配速", "总经过时间 = 结束 − 开始；暂停差值 = max(0,总经过 − 运动计时)；全程平均配速 = 运动计时 / 距离。"),
            ("段内运动计时", "从手动/自动暂停事件扣除暂停，仅当事件时段与运动计时相符（误差≤max(2秒,总经过×0.5%)）才输出，否则留空。"),
            ("分段配速", "公里分段的经过配速 = GPS 分段经过时间 / GPS 分段距离，包含暂停；与全程运动配速的计时口径不同。"),
            ("心率 / 功率 / 跑姿", "全程均值优先 HealthKit 运动统计；缺失时由选定来源的采样区间加权估算；字段标明来源。步长 m、触地 ms、垂直振幅 cm。"),
            ("步频", "全程优先运动关联步数 / 运动分钟；分段和过程步频由 step_count 原始区间步数 / 区间秒数 × 60 推算。区间内按均匀步率估算，不代表逐步瞬时测量。"),
            ("采样来源", "原始采样按运动时间窗读取并保留来源；每项指标优先运动设备，其次运动来源 App，否则采用支持时长最大的单一来源；不把不同设备重叠值相加。"),
            ("区间加权", "均值 = Σ数值×重叠秒数 / Σ重叠秒数。同一来源重叠区间在较新采样开始时截断，不重复计算；原始区间数据在完整版保留。"),
            ("瞬时采样处理", "起止时间相同的非步数采样向后延展至下一样本或最多 10 秒，作为统计支持区间；不跨越更长空缺。指标可用性记录延展数量。"),
            ("覆盖比例", "有效支持时长 / 相应经过时长，范围 0–1；包含上述瞬时延展估算。无支持时均值/覆盖比例留空；支持不足时不要把局部均值当全程表现。"),
            ("过程数据", "每 30 秒一个区间，末区间保留实际长度；包括暂停时段，段内运动计时经暂停事件校验后输出。没有采样的区间保留空值。"),
            ("心率分布", "按 <100、100–119、120–139、140–159、160–179、≥180 bpm 统计支持时长，另列未覆盖时长；这是数值区间，不是个人训练分区。"),
            ("公里分段", "从首个有效 GPS 点累计距离，线性插值公里边界；末段>1米时保留。GPS 距离可能与 HealthKit 运动距离不同，海拔变化只是 GPS 端点差。"),
            ("GPS 质量", "间隔>30秒、非递增时间、坐标无效或点间速度>12m/s时整次不计算公里分段；无路线的室内跑仍保留过程指标。"),
            ("Apple原有分段", "仅在原记录存在活动段或圈/事件时添加；不将缺失距离推算成正式公里分段。"),
            ("体能参考", "按测量时间列出导出范围内的 VO2 max 与系统 1 分钟心率恢复，未强行绑定某次跑步。VO2 max 来源可能是设备估算，需结合来源理解；无数据时表为空。"),
            ("训练指标", "与App详情及AI采用相同的版本化计算。最大心率优先采用手动覆盖，否则为Tanaka成人年龄估计208−0.7×年龄；估计与有效采样矛盾时不计算Edwards负荷。标注估算依据，不将估计视为实测。"),
            ("Apple心率区间", "优先使用每次运动保存的Apple区间和系统原始时长（recorded_workout，保留系统计时口径）；历史缺少时，按当前Apple设置重新分类已知有效运动心率（current_preference_reclassified）。开区间端点留空，覆盖不足不外推。当前区间重分类采用左闭右开边界，系统原始时长保持不变。来源system/user/app分别为系统、用户、运动应用。不同配置不合并，不用于Edwards区间权重，不由区间边界反推最大心率。"),
            ("使用方式", "模型先检查来源、覆盖率、暂停与缺失值，再比较分段和趋势；本文件不输出恢复评分、乳酸阈值或保证性的马拉松预测。"),
            ("目标与计划", options.includePlanning ? "按用户选项附带全部已保存目标/计划（含未来），仅保留客观目标与完成数值，不含训练备注或 RPE。" : "本次未附带目标与计划。"),
            ("完整数据包", "附同一份分析 Excel、各分析表 CSV、原始采样 CSV、完整路线 CSV/GPX、README、manifest；分析版无需附加文件即可读取全部分析表。"),
            ("完整路线", "完整版保留原始 WGS-84 起终点。GPX 会过滤无效点，并对>120秒中断分段；CSV保留完整原始点。"),
            ("CSV 文本", "文本以 =、+、-、@ 开头时加单引号，避免作为公式执行；Excel 字符串保持原文。")
        ]
    }

    private func writeText(_ name: String, _ text: String) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8); files.append((name, url))
    }
    private func writeCSV(_ name: String, headers: [String], rows: [[ExportCell]]) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data([0xEF, 0xBB, 0xBF]))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        func emit(_ values: [String]) throws { try handle.write(contentsOf: Data((values.joined(separator: ",") + "\r\n").utf8)) }
        try emit(headers.map(ExportText.csv))
        for row in rows {
            try Task.checkCancellation()
            try emit(row.map {
                switch $0 {
                case .blank: return ""
                case .number(let value): return value.isFinite ? String(value) : ""
                case .date(let date): return ExportText.csv(ExportText.iso(date))
                case .text(let text): return ExportText.csv(text)
                }
            })
        }
        files.append((name, url))
    }
}
