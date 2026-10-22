import Foundation

@main
struct AnalysisExportTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !value() { fatalError("FAILED: \(message)") }
    }
    static func near(_ a: Double?, _ b: Double, _ message: String) { check(a != nil && abs(a! - b) < 0.00001, message) }
    static func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    static let start = date("2026-09-30T23:00:00Z")
    static func point(_ meters: Double, _ seconds: Double) -> RoutePointPayload {
        RoutePointPayload(timestamp: start.addingTimeInterval(seconds), latitude: 0, longitude: meters / 6_371_000 * 180 / .pi, altitude: 12 + meters / 100, speedMps: 5)
    }
    static func activity(_ id: String, date: Date = start, km: Double = 2.5, seconds: Double = 500.25) -> ArchiveActivity {
        ArchiveActivity(preview: WorkoutPreview(id: id, date: date, distanceKm: km, duration: seconds, avgHeartRate: nil, maxHeartRate: nil, avgPower: nil))
    }
    static func sample(_ metric: ExportMetric, _ start: Double, _ end: Double, _ value: Double, device: String = "watch", priority: Int = 2) -> ExportRawSample {
        ExportRawSample(metric: metric.rawValue, start: Self.start.addingTimeInterval(start), end: Self.start.addingTimeInterval(end), value: value,
            unit: metric == .steps ? "count" : metric.unit, source: "示例来源", sourceBundle: "fixture.only", device: device, deviceKey: device, sourcePriority: priority)
    }
    static func workout(distance: Double? = 2.5, points: [RoutePointPayload] = [], samples: [ExportRawSample]? = nil,
                        pauses: [DateInterval] = [], issues: [String: String] = [:]) -> ExportWorkout {
        ExportWorkout(uuid: "fixture-workout-uuid", start: start, end: start.addingTimeInterval(540.25), distanceKm: distance,
            duration: 500.25, heartRate: nil, maxHeartRate: nil, power: 230, cadence: 170,
            energyKcal: 180, elevationGain: nil, indoor: false, source: "Apple Watch（示例）", sourceBundle: "fixture.only", device: "示例设备",
            points: points, samples: samples ?? [sample(.power,0,10,230.5)], intervals: [], pauses: pauses, readIssues: issues)
    }
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let points = (0...250).map { point(Double($0) * 10, Double($0) * 2) }
        let splits = ExportSplits.calculate(points, start: start)
        check(splits.rows.count == 3, "two complete kilometers and partial last kilometer")
        near(splits.rows.last!.km, 0.5, "partial distance retained")
        near(splits.rows.first!.duration, 200, "distance interpolation")
        near(splits.rows.first!.altitudeEnd, 22, "altitude interpolated at kilometer boundary")
        let paused = points.enumerated().map { index, p in RoutePointPayload(timestamp: p.timestamp.addingTimeInterval(index > 70 ? 20 : 0), latitude: p.latitude, longitude: p.longitude, altitude: p.altitude, speedMps: p.speedMps) }
        near(ExportSplits.calculate(paused, start: start).rows[0].duration, 220, "elapsed pause included")
        var gap = points; gap[10] = point(100, 10_000)
        check(ExportSplits.calculate(gap, start: start).rows.isEmpty, "GPS gaps do not create fabricated splits")
        var spike = points; spike[30] = point(50000, 60)
        check(ExportSplits.calculate(spike, start: start).rows.isEmpty, "GPS spike rejects splits")
        check(ExportSplits.calculate([], start: start).rows.isEmpty, "indoor record has no GPS splits")
        check(ExportText.csv("=SUM(A1)") == "\"'=SUM(A1)\"", "CSV formula injection escaped")
        check(ExportText.csv(" a,\"b\"\n") == "\" a,\"\"b\"\"\n\"", "CSV commas quotes and newlines preserved")
        check(ExportText.column(26) == "AA", "wide worksheet addresses")
        let weighted = ExportObjectiveAnalysis(workout: workout(samples: [sample(.heartRate,0,2,100),sample(.heartRate,2,10,200)]))
        near(weighted.series[.heartRate]!.statistic(start: 0, end: 10).average, 180, "duration weighted, not sample-count average")
        near(weighted.series[.heartRate]!.statistic(start: 0, end: 5).average, 160, "partial interval weighting")
        let overlap = ExportObjectiveAnalysis(workout: workout(samples: [sample(.heartRate,0,10,100),sample(.heartRate,5,15,200)]))
        near(overlap.series[.heartRate]!.statistic(start: 0, end: 20).supportedSeconds, 15, "overlap counted once")
        near(overlap.series[.heartRate]!.statistic(start: 0, end: 20).average, 500.0/3, "latest interval wins overlap")
        let instantaneous = ExportObjectiveAnalysis(workout: workout(samples: [sample(.heartRate,0,0,140),sample(.heartRate,5,5,150),sample(.heartRate,40,40,160)]))
        near(instantaneous.series[.heartRate]!.statistic(start: 0, end: 60).supportedSeconds, 25, "instantaneous hold capped at 10 seconds")
        check(instantaneous.series[.heartRate]!.statistic(start: 20, end: 30).average == nil, "no bridging a data gap")
        let cadence = ExportObjectiveAnalysis(workout: workout(samples: [sample(.steps,0,60,180),sample(.steps,0,60,120,device:"phone",priority:0)]))
        near(cadence.series[.steps]!.statistic(start: 0, end: 30).average,180,"step interval converted to cadence, not summed across devices")
        check(cadence.series[.steps]!.source.contains("watch") && !cadence.series[.steps]!.source.contains("phone"), "preferred source recorded")
        let invalid = ExportObjectiveAnalysis(workout: workout(samples:[sample(.heartRate,0,10,.nan),sample(.steps,0,0,20),sample(.power,0,10,0)]))
        check(invalid.series[.heartRate]!.statistic(start:0,end:10).average == nil, "nonfinite values excluded")
        check(invalid.series[.steps]!.intervals.isEmpty, "zero-duration step count not invented into cadence")
        near(invalid.series[.power]!.statistic(start:0,end:10).average,0,"real zero preserved")
        let fallback = ExportObjectiveAnalysis(workout: workout(samples:[sample(.heartRate,0,10,0),sample(.heartRate,0,10,145,device:"strap",priority:0)]))
        near(fallback.series[.heartRate]!.statistic(start:0,end:10).average,145,"invalid preferred source cannot hide valid alternative")
        check(weighted.activeSeconds(start:0,end:30) == nil,"unknown pause timings cannot produce active split times")
        let pauseSpan = DateInterval(start:start.addingTimeInterval(100),end:start.addingTimeInterval(140))
        let pauseAnalysis = ExportObjectiveAnalysis(workout: workout(pauses:[pauseSpan,pauseSpan]))
        near(pauseAnalysis.activeSeconds(start:90,end:150),20,"duplicate pause intervals merged and reconciled")
        var options = AnalysisExportOptions(start: date("2026-09-01T00:00:00Z"), endExclusive: date("2026-11-01T00:00:00Z"), full: true, includePlanning: true, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        options.calibration = AnalysisCalibration(automaticAge: 40, automaticAgeDate: .now)
        check(options.includes(options.start) && !options.includes(options.endExclusive), "inclusive/exclusive date bounds")
        check(options.calendar.component(.month, from:start) == 10,"local month crossing UTC boundary")
        var journal = JournalData()
        journal.annotations["run-1"] = RunAnnotation(kind: .easy, effort: 3, note: "THIS_PRIVATE_NOTE_MUST_NOT_BE_EXPORTED", favoriteRoute: false, routeName: "主观路线名", excludeFromRecords: false)
        journal.races = [RaceGoal(name: "未来半马（示例）", date: date("2027-03-20T00:00:00Z"), distanceKm: 21.0975, targetSeconds: 6600, note: "THIS_PRIVATE_NOTE_MUST_NOT_BE_EXPORTED")]
        journal.plans = [PlannedRun(date: start, distanceKm: 3, paceMin: 180, paceMax: 300, note: "THIS_PRIVATE_NOTE_MUST_NOT_BE_EXPORTED", activityID: "run-1")]
        var detailed = workout(points: points, samples: [sample(.heartRate,0,200,140),sample(.heartRate,200,500,160),
            sample(.heartRate,0,540.25,200,device:"other",priority:0), sample(.power,0,10,230.5), sample(.speed,0,500,5),sample(.steps,0,500,1500),
            sample(.stride,0,500,1.1),sample(.contact,0,500,250),sample(.oscillation,0,500,8)], pauses:[pauseSpan])
        detailed.appleHeartRateZones = AnalysisAppleHeartRateZones(source: "user", scope: "recorded_workout", zones: [
            .init(index: 0, lowerBPM: nil, upperBPM: 120, seconds: 100),
            .init(index: 1, lowerBPM: 120, upperBPM: 140, seconds: 200),
            .init(index: 2, lowerBPM: 140, upperBPM: 160, seconds: 100),
            .init(index: 3, lowerBPM: 160, upperBPM: 180, seconds: 100),
            .init(index: 4, lowerBPM: 180, upperBPM: nil, seconds: 40.25)])
        let activities = [activity("run-1"), activity("missing", date:date("2026-10-02T00:00:00Z"),km:5,seconds:1600),activity("no-distance"),activity("partial")]
        let references = ExportReferenceData(samples:[ExportReferenceSample(metric:"VO2 max",date:start,value:52.3,unit:"ml/kg/min",source:"fixture.only")])
        let builder = try AnalysisExportBuilder(options: options,journal:journal,activities:activities,folder:output.appendingPathComponent("full"))
        await builder.setReferences(references)
        try await builder.add(activity:activities[0],workout:detailed,error:nil)
        try await builder.add(activity:activities[1],workout:nil,error:"模拟不可用")
        try await builder.add(activity:activities[2],workout:workout(distance:nil),error:nil)
        try await builder.add(activity:activities[3],workout:workout(issues:[ExportMetric.contact.rawValue:"模拟指标失败"]),error:nil)
        let result = try await builder.finish()
        check(result.count == 4 && result.failed == 1 && result.partial == 1 && result.bytes > 1000,"partial failures preserve other metrics")
        let analysis = try AnalysisExportBuilder(options:AnalysisExportOptions(start:options.start,endExclusive:options.endExclusive,full:false,includePlanning:false,timeZone:options.timeZone,calibration:options.calibration),journal:journal,activities:activities,folder:output.appendingPathComponent("analysis"))
        await analysis.setReferences(references)
        try await analysis.add(activity:activities[0],workout:detailed,error:nil)
        _ = try await analysis.finish()
        let empty = try AnalysisExportBuilder(options:options,journal:journal,activities:[],folder:output.appendingPathComponent("empty"))
        do { _ = try await empty.finish(); fatalError("empty export must fail") } catch is ExportError { checks += 1 }
        let cancellation = Task { while !Task.isCancelled { await Task.yield() }; return try await builder.finish() }
        cancellation.cancel()
        do { _ = try await cancellation.value; fatalError("cancelled export must fail") } catch is CancellationError { checks += 1 }
        print("Objective export: \(checks) checks passed; fixtures: \(output.path)")
    }
}
