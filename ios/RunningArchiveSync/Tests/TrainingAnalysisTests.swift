import Foundation

@main struct TrainingAnalysisTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAIL: " + message) }
    }
    static func near(_ actual: Double?, _ expected: Double, _ message: String, tolerance: Double = 1e-7) {
        check(actual != nil && abs(actual! - expected) <= tolerance, message + " actual=\(String(describing: actual)) expected=\(expected)")
    }
    static func main() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; c.firstWeekday = 2
        let now = c.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
        let date = now.addingTimeInterval(-86400)
        func activity(id: String = "run", start: Date? = nil, seconds: Double = 2400, km: Double = 7.2) -> ArchiveActivity {
            ArchiveActivity(preview: WorkoutPreview(id: id, date: start ?? date, distanceKm: km, duration: seconds, avgHeartRate: 140, maxHeartRate: 140, avgPower: 200))
        }
        func workout(id: String = "run", start: Date? = nil, seconds: Double = 2400, active: Double? = nil,
                     heart: Double = 140, speed: Double = 3, missingAfter: Double? = nil,
                     pauses: [DateInterval] = [], source: String = "watch", slope: Double = 0,
                     speedChanges: ((Double) -> Double)? = nil, heartChanges: ((Double) -> Double)? = nil) -> ExportWorkout {
            let start = start ?? date
            var samples: [ExportRawSample] = [], points: [RoutePointPayload] = []
            for t in stride(from: 0.0, to: seconds, by: 5) {
                let end = min(t + 5, seconds)
                for (metric, value, unit) in [("heart_rate", heartChanges?(t) ?? heart, "bpm"), ("running_speed", speedChanges?(t) ?? speed, "m/s"), ("running_power", 200.0, "W")] {
                    if metric == "heart_rate", let missingAfter, t >= missingAfter { continue }
                    samples.append(ExportRawSample(metric: metric, start: start.addingTimeInterval(t), end: start.addingTimeInterval(end), value: value, unit: unit, source: source, sourceBundle: "example.bundle", deviceKey: source))
                }
            }
            for t in stride(from: 0.0, through: seconds, by: 5) {
                points.append(RoutePointPayload(timestamp: start.addingTimeInterval(t), latitude: 31,
                    longitude: 121 + t * speed / (111195 * cos(31 * .pi / 180)), altitude: t * speed * slope, speedMps: speed, verticalAccuracy: 3, horizontalAccuracy: 3))
            }
            return ExportWorkout(uuid: id, start: start, end: start.addingTimeInterval(seconds), distanceKm: seconds * speed / 1000,
                duration: active ?? seconds, heartRate: heart, maxHeartRate: heart, power: 200, cadence: nil, energyKcal: nil,
                elevationGain: nil, indoor: false, source: source, sourceBundle: "example.bundle", device: source,
                points: points, samples: samples, intervals: [], pauses: pauses)
        }
        let calibration = AnalysisCalibration(maximumHeartRate: 200, source: "known test", confirmedAt: now)
        let run = activity()
        func analyze(_ w: ExportWorkout, cal: AnalysisCalibration? = nil, run a: ArchiveActivity? = nil) -> RunTrainingAnalysis {
            TrainingAnalysisMath.calculate(w, activity: a ?? run, calibration: cal ?? calibration, now: now, calendar: c)
        }
        for (hr, expected) in [(99.0, 0),(100,1),(119.999,1),(120,2),(140,3),(160,4),(180,5),(200,5)] {
            check(TrainingAnalysisMath.edwardsZone(hr, maximum: 200) == expected, "Edwards boundary \(hr)")
        }
        check(TrainingAnalysisMath.edwardsZone(201, maximum: 200) == nil, "beyond calibrated maximum invalid")
        check(TrainingAnalysisMath.edwardsZone(.nan, maximum: 200) == nil, "NaN rejected")
        let basic = analyze(workout())
        near(basic.load.value, 120, "published Edwards: 40min entirely 70-80%=120AU")
        near(basic.load.coverage, 1, "full time support")
        check(basic.load.complete, "complete heart load")
        near(basic.efficiency.value, 180.0 / 140, "speed(m/min)/heart, not pace/heart")
        near(basic.drift.value, 0, "constant trace no drift")
        near(basic.speedVariation.value, 0, "constant speed zero CV")
        check(basic.efficiency.usable, "known flat low-intensity trace eligible")
        var unknownSourceWorkout = workout()
        unknownSourceWorkout = ExportWorkout(uuid: unknownSourceWorkout.uuid, start: unknownSourceWorkout.start, end: unknownSourceWorkout.end,
            distanceKm: unknownSourceWorkout.distanceKm, duration: unknownSourceWorkout.duration, heartRate: 140, maxHeartRate: 140,
            power: nil, cadence: nil, energyKcal: nil, elevationGain: nil, indoor: false, source: "", sourceBundle: "", device: "",
            points: unknownSourceWorkout.points, samples: unknownSourceWorkout.samples.map {
                ExportRawSample(metric: $0.metric, start: $0.start, end: $0.end, value: $0.value, unit: $0.unit, sourceVersion: ":")
            }, intervals: [])
        check(analyze(unknownSourceWorkout).sourceGroups.values.allSatisfy(\.isEmpty), "version-only unknown source cannot establish comparable sensor identity")
        let payload = WorkoutPayload(id: run.id, name: run.name, startDate: run.date, distanceKm: run.distanceKm,
            durationSeconds: 2400, city: "", avgHeartRate: 145, maxHeartRate: 175, avgCadence: 178, avgPower: 233,
            routePoints: [], heartRateSamples: [], runningSpeedSamples: [], intervals: [])
        let enriched = ArchiveActivity(activity: run, payload: payload)
        check(TrainingAnalysisMath.signature(enriched) == TrainingAnalysisMath.signature(run), "detail presentation enrichment must not invalidate raw analysis")
        let edited = activity(seconds: 2500)
        check(TrainingAnalysisMath.signature(edited) != TrainingAnalysisMath.signature(run), "real HealthKit summary edits invalidate raw analysis")
        let restoredEnriched = try JSONDecoder().decode(ArchiveActivity.self, from: JSONEncoder().encode(enriched))
        check(TrainingAnalysisMath.signature(restoredEnriched) == TrainingAnalysisMath.signature(run), "stable summary identity survives cold-launch cache")
        var oldActivity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as! [String: Any]
        oldActivity.removeValue(forKey: "workoutSummarySignature")
        let legacyActivity = try JSONDecoder().decode(ArchiveActivity.self, from: JSONSerialization.data(withJSONObject: oldActivity))
        check(legacyActivity.workoutSummarySignature == nil && !TrainingAnalysisMath.signature(legacyActivity).isEmpty, "old overview without stable identity remains readable")
        let noCalibration = analyze(workout(), cal: AnalysisCalibration())
        check(noCalibration.load.value == nil && !noCalibration.efficiency.complete, "uncalibrated load absent and aerobic intensity uncertain")
        let absentLoad = TrainingAnalysisMath.loadCoverage([AnalysisRunSummary(run)], analyses: [noCalibration])
        check(absentLoad.processed == 1 && absentLoad.calculated == 0 && absentLoad.reasons.first?.reason.contains("未获得成人年龄") == true, "read completed is not load calculated; preserve uncalibrated reason")
        let pendingLoad = TrainingAnalysisMath.loadCoverage([AnalysisRunSummary(run)], analyses: [])
        check(pendingLoad.pending == 1 && pendingLoad.calculated == 0 && pendingLoad.reasons.isEmpty, "not-yet-read workouts distinguished from unavailable load")
        let emptyLoad = TrainingAnalysisMath.loadCoverage([], analyses: [basic])
        check(emptyLoad.expected == 0 && emptyLoad.calculated == 0, "out-of-range results cannot imply current-range load")
        let zeroLoad = analyze(workout(heart: 90))
        let zeroCoverage = TrainingAnalysisMath.loadCoverage([AnalysisRunSummary(run)], analyses: [zeroLoad])
        check(zeroCoverage.calculated == 1 && zeroCoverage.complete == 1 && zeroLoad.load.value == 0, "real observed below-zone zero distinguished from missing load")

        var futureCalibration = calibration; futureCalibration.confirmedAt = now.addingTimeInterval(1)
        check(analyze(workout(), cal: futureCalibration).load.value == nil, "future calibration cannot leak")
        let partial = analyze(workout(missingAfter: 1200))
        near(partial.load.value, 60, "observed load, no extrapolation")
        near(partial.load.coverage, 0.5, "missing half has 50% support")
        check(!partial.load.complete && partial.efficiency.value == nil, "partial is not complete / stable continuous support insufficient")
        let partialCoverage = TrainingAnalysisMath.loadCoverage([AnalysisRunSummary(run)], analyses: [partial])
        check(partialCoverage.calculated == 1 && partialCoverage.complete == 0, "partial observed load counted separately from complete calculation")
        let unavailableTimer = analyze(workout(active: 2100))
        let unavailableCoverage = TrainingAnalysisMath.loadCoverage([AnalysisRunSummary(run)], analyses: [unavailableTimer])
        check(unavailableCoverage.calculated == 0 && unavailableCoverage.reasons.first?.reason.contains("暂停") == true, "timer mismatch must remain visible after processing completes")

        check(analyze(workout(heart: 205)).load.value == nil, "reference maximum breach never clamped to zone5")
        let pause = DateInterval(start: date.addingTimeInterval(600), end: date.addingTimeInterval(900))
        let paused = analyze(workout(active: 2100, pauses: [pause]))
        near(paused.load.value, 105, "five-minute pause excluded")
        near(paused.load.coverage, 1, "pause excluded from support denominator")
        let unknownPause = analyze(workout(active: 2100))
        check(unknownPause.load.value == nil && unknownPause.drift.value == nil, "unknown pause timing not invented")
        let unequal = TrainingAnalysisMath.pairStatistics([
            .init(start: 0, end: 10, speed: 2, heart: 100), .init(start: 10, end: 40, speed: 4, heart: 200)
        ])
        near(unequal.efficiency, 1.2, "joint time weighted efficiency")
        let disjoint = TrainingAnalysisMath.paired([.init(start: 0, end: 10, value: 3)], [.init(start: 10, end: 20, value: 140)])
        check(disjoint.isEmpty, "nonconcurrent heart/speed do not pair")
        let clipped = TrainingAnalysisMath.subtractPauses([.init(start: 0, end: 100, value: 140)], pauses: [.init(start: 20, end: 30, value: 0), .init(start: 60, end: 90, value: 0)])
        near(clipped.reduce(0) { $0 + $1.seconds }, 60, "subtract separated pause spans")
        let drifted = analyze(workout(heartChanges: { $0 < 1350 ? 140 : 154 }))
        near(drifted.drift.value, 100.0 * (1 - 140.0 / 154), "equal-time halves signed drift")
        check(analyze(workout(slope: 0.05)).efficiency.value == nil, "hill not flat-normalized by made-up formula")
        let variable = analyze(workout(speedChanges: { Int($0 / 120).isMultiple(of: 2) ? 2 : 4 }))
        check(variable.efficiency.value == nil, "variable trace excluded from steady analysis")
        check(variable.structure == "间歇候选", "repeated fast/recovery candidate")
        let short = analyze(workout(seconds: 1800), run: activity(seconds: 1800, km: 5.4))
        check(short.drift.value == nil, "insufficient stable period excluded")
        let midnight = c.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23, minute: 40))!
        let cross = analyze(workout(start: midnight), run: activity(start: midnight))
        check(cross.loadParts.count == 2, "cross-day allocation")
        near(cross.loadParts[0].value, 60, "20minutes previous day")
        near(cross.loadParts[1].value, 60, "20minutes following day")
        near(TrainingAnalysisMath.danielsIndex(distanceKm: 10, seconds: 2400), 51.94, "10K40min published rounded score anchor", tolerance: 0.005)
        let index = TrainingAnalysisMath.danielsIndex(distanceKm: 10, seconds: 2400)!
        near(TrainingAnalysisMath.equivalentSeconds(index: index, distanceKm: 10), 2400, "model inversion", tolerance: 0.001)
        let half = TrainingAnalysisMath.equivalentSeconds(index: index, distanceKm: 21.0975)!
        check(half > 5280 && half < 5340, "published anchor ~1h28min half")
        check(TrainingAnalysisMath.danielsIndex(distanceKm: .nan, seconds: 2400) == nil, "invalid distance rejected")
        check(basic.performance != nil && !basic.performance!.fullEffortConfirmed, "completed trace never automatically declared maximal effort")
        check(paused.performance == nil, "paused result excluded from ability reference")
        var verified = calibration; verified.performanceActivityID = run.id; verified.performanceConfirmedAt = now
        check(analyze(workout(), cal: verified).performance?.fullEffortConfirmed == true, "explicit recent performance confirmation")
        let old = now.addingTimeInterval(-100 * 86400)
        check(analyze(workout(start: old), cal: verified, run: activity(start: old)).performance?.fullEffortConfirmed == false, "old confirmed reference not current")
        var records: [RunTrainingAnalysis] = [], summaries: [AnalysisRunSummary] = []
        for offset in 0..<126 {
            let start = c.startOfDay(for: now).addingTimeInterval(Double(-125 + offset) * 86400 + 3600)
            let a = activity(id: "d\(offset)", start: start)
            let r = analyze(workout(id: a.id, start: start), run: a)
            records.append(r); summaries.append(AnalysisRunSummary(a))
        }
        let loadDays = TrainingAnalysisMath.loadDays(summaries, analyses: records, now: now, calendar: c)
        // Closed-form response to a constant 120 AU/day input, independent of recurrence implementation.
        near(loadDays.last!.shortLoad, 120 * (1 - exp(-126.0 / 7)), "EWMA constant-input short closed form")
        near(loadDays.last!.longLoad, 120 * (1 - exp(-126.0 / 42)), "EWMA constant-input long closed form")
        check(loadDays.last!.completeHistory && loadDays.last!.warmedUp, "126 days complete warmup")
        let missing = TrainingAnalysisMath.loadDays(summaries, analyses: Array(records.dropLast()), now: now, calendar: c)
        check(!missing.last!.completeHistory, "unread workout makes history incomplete, not rest")
        let boundaryStart = c.date(byAdding: .day, value: -126, to: c.startOfDay(for: now))!.addingTimeInterval(23 * 3600 + 40 * 60)
        let unreadCross = AnalysisRunSummary(activity(id: "unread-cross", start: boundaryStart))
        let crossHistory = TrainingAnalysisMath.loadDays(summaries + [unreadCross], analyses: records, now: now, calendar: c)
        check(!crossHistory.last!.completeHistory, "unread cross-midnight workout also marks day inside warmup window incomplete")
        let weeks = TrainingAnalysisMath.weeks(summaries, analyses: records, now: now, calendar: c)
        near(weeks.reduce(0) { $0 + $1.kilometers }, 126 * 7.2, "weekly distance conserved")
        near(weeks.reduce(0) { $0 + $1.classifiedSeconds }, 126 * 2400, "zone time conserved")
        let future = AnalysisRunSummary(activity(id: "future", start: now.addingTimeInterval(86400)))
        near(TrainingAnalysisMath.weeks(summaries + [future], analyses: records, now: now, calendar: c).reduce(0) { $0 + $1.kilometers }, 126 * 7.2, "future workout excluded")
        var observations: [AnalysisObservation] = []
        for n in 1...35 {
            observations.append(AnalysisObservation(metric: "hrv_sdnn", date: c.startOfDay(for: now).addingTimeInterval(Double(-n) * 86400), value: n <= 7 ? 60 : 50, sourceGroup: "source1", context: "00-06"))
        }
        let recovery = TrainingAnalysisMath.recovery(observations, now: now, calendar: c).first!
        near(recovery.recent, 60, "recent 7 complete days")
        near(recovery.baseline, 50, "baseline excludes recent7")
        near(recovery.percent, 20, "personal baseline change")
        let changedSource = observations.map { p -> AnalysisObservation in var p = p; if p.value == 60 { p.sourceGroup = "source2" }; return p }
        check(TrainingAnalysisMath.recovery(changedSource, now: now, calendar: c).first!.recent == nil, "source change cannot produce apparent improvement")
        let changedClock = observations.map { p -> AnalysisObservation in var p = p; if p.value == 60 { p.context = "12-18" }; return p }
        check(TrainingAnalysisMath.recovery(changedClock, now: now, calendar: c).first!.recent == nil, "sampling clock contexts not mixed")
        let incomplete = observations.map { p -> AnalysisObservation in var p = p; p.complete = false; return p }
        check(TrainingAnalysisMath.recovery(incomplete, now: now, calendar: c).first!.baseline == nil, "partial windows excluded")
        var cohort: [RunTrainingAnalysis] = []
        for day in [5, 10, 15, 35, 40, 45] {
            var item = basic
            item.id = "cohort-\(day)"; item.date = now.addingTimeInterval(Double(-day) * 86400)
            item.stableHeartRate = 142; item.stableSpeed = 3
            item.efficiency.value = day < 28 ? 1.26 : 1.2
            item.stableForm = [AnalysisFormValue(metric: "running_power", value: AnalysisValue(value: 200, unit: "W", method: "stable", coverage: 1, complete: true), sourceGroup: "one-sensor")]
            item.form = [AnalysisFormValue(metric: "running_power", value: AnalysisValue(value: day < 28 ? 300 : 200, unit: "W", method: "full-run", coverage: 1, complete: true), sourceGroup: "one-sensor")]
            cohort.append(item)
        }
        let trend = TrainingAnalysisMath.aerobicTrend(cohort, now: now, calendar: c)
        near(trend.percent, 5, "matched-cohort median improvement")
        check(trend.recentCount == 3 && trend.baselineCount == 3, "independent runs count, not samples")
        let formTrend = TrainingAnalysisMath.formTrends(cohort, now: now, calendar: c).first(where: { $0.metric == "running_power" })!
        near(formTrend.percent, 0, "stable-form comparison not full-run warmup confound")
        var differentSensor = cohort
        for i in 0..<3 { differentSensor[i].sourceGroups["heart_rate"] = "new-sensor" }
        check(TrainingAnalysisMath.aerobicTrend(differentSensor, now: now, calendar: c).recent == nil, "sensor swap not aerobic gain")
        let noGPSQuality = workout()
        let untrustedPoints = noGPSQuality.points.map { p -> RoutePointPayload in var p = p; p.verticalAccuracy = nil; return p }
        check(TrainingAnalysisMath.flatFraction(untrustedPoints, start: date, end: date.addingTimeInterval(2400)) == nil, "missing vertical accuracy cannot confirm flatness")
        let youngCalibration = AnalysisCalibration(maximumHeartRate: 250, source: "outside supported range", confirmedAt: now)
        check(youngCalibration.validMaximum(at: now) == nil, "unsupported calibration not silently accepted")
        var ny = c; ny.timeZone = TimeZone(identifier: "America/New_York")!
        let dstNow = ny.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let dstDays = TrainingAnalysisMath.loadDays([], analyses: [], now: dstNow, calendar: ny)
        check(dstDays.count == 126 && Set(dstDays.map(\.date)).count == 126, "calendar days across daylight saving remain distinct")
        check(zip(dstDays, dstDays.dropFirst()).contains(where: { $1.date.timeIntervalSince($0.date) == 90000 }), "25-hour day kept, not fixed86400 day buckets")
        check(TrainingAnalysisMath.ageYears(healthBirth: DateComponents(year: 1986, month: 10, day: 18), now: now, timeZone: c.timeZone) == 40, "birthday included in Gregorian health age")
        check(TrainingAnalysisMath.ageYears(healthBirth: DateComponents(year: 1986, month: 10, day: 19), now: now, timeZone: c.timeZone) == 39, "before birthday does not round up age")
        check(TrainingAnalysisMath.ageYears(healthBirth: DateComponents(year: 2030, month: 1, day: 1), now: now, timeZone: c.timeZone) == nil, "future birth date rejected")
        check(TrainingAnalysisMath.ageYears(healthBirth: DateComponents(year: 1986, month: 2, day: 30), now: now, timeZone: c.timeZone) == nil, "invalid calendar components not normalized into plausible age")
        check(TrainingAnalysisMath.ageYears(healthBirth: DateComponents(year: 1986), now: now, timeZone: c.timeZone) == nil, "missing date components not treated as January1")
        let automatic = AnalysisCalibration(automaticAge: 40, automaticAgeDate: now)
        near(automatic.validMaximum(at: now), 180, "Tanaka published equation age40=180")
        check(automatic.reference(at: now).estimated && automatic.reference(at: now).method == "tanaka_208_minus_0_7_age", "automatic is explicitly population estimate")
        var manualOverride = automatic
        manualOverride.maximumHeartRate = 195; manualOverride.source = "known test"; manualOverride.confirmedAt = now
        near(manualOverride.validMaximum(at: now), 195, "manual reference takes precedence")
        check(!manualOverride.reference(at: now).estimated, "manual reference not mislabeled automatic")
        manualOverride.maximumHeartRate = nil
        near(manualOverride.validMaximum(at: now), 180, "clearing manual returns to automatic")
        check(AnalysisCalibration(automaticAge: 17, automaticAgeDate: now).validMaximum(at: now) == nil, "adult formula not applied to children")
        check(AnalysisCalibration(automaticAge: 101, automaticAgeDate: now).validMaximum(at: now) == nil, "out-of-range age unavailable")
        check(AnalysisCalibration(automaticAge: 40, automaticAgeDate: now.addingTimeInterval(1)).validMaximum(at: now) == nil, "future age profile rejected")
        check(AnalysisCalibration(automaticAge: 40, automaticAgeDate: now.addingTimeInterval(-367*86400)).validMaximum(at: now) == nil, "stale annual age not silently reused")
        check(automatic.key == AnalysisCalibration(automaticAge: 40, automaticAgeDate: now.addingTimeInterval(-1)).key, "profile refresh time alone does not invalidate all records")
        check(automatic.key != AnalysisCalibration(automaticAge: 41, automaticAgeDate: now).key, "age change invalidates reference")
        let automaticRun = analyze(workout(), cal: automatic)
        near(automaticRun.load.value, 120, "Edwards uses its own percentage boundaries with estimated max")
        check(automaticRun.load.estimated == true && automaticRun.load.reason?.contains("Tanaka") == true, "load carries estimate basis")
        let aboveAgeEstimate = analyze(workout(heart: 190), cal: automatic)
        check(aboveAgeEstimate.load.value == nil && aboveAgeEstimate.load.reason?.contains("年龄估算") == true, "observed/age contradiction not clamped or hidden")
        let preferred = AnalysisAppleHeartRateZones(source: "system", scope: "current_preference", zones: [
            .init(index: 0, lowerBPM: nil, upperBPM: 120), .init(index: 1, lowerBPM: 120, upperBPM: 140),
            .init(index: 2, lowerBPM: 140, upperBPM: 160), .init(index: 3, lowerBPM: 160, upperBPM: 180),
            .init(index: 4, lowerBPM: 180, upperBPM: nil)])
        check(TrainingAnalysisMath.validAppleZones(preferred), "Apple contiguous open-ended zones accepted")
        var appleWorkout = workout(); appleWorkout.preferredAppleHeartRateZones = preferred
        let reclassified = analyze(appleWorkout, cal: automatic)
        near(reclassified.appleHeartRateZones?.zones[2].seconds, 2400, "exact Apple boundary assigned once to lower-inclusive zone")
        check(reclassified.appleHeartRateZones?.scope == "current_preference_reclassified", "current settings not mislabeled historical")
        near(reclassified.appleHeartRateZones?.coverage, 1, "reclassification support matches active timer")
        var saved = preferred; saved.scope = "recorded_workout"; saved.source = "user"
        for i in saved.zones.indices { saved.zones[i].seconds = [300.0,600,900,600,0][i] }
        appleWorkout.appleHeartRateZones = saved
        let recorded = analyze(appleWorkout, cal: automatic)
        check(recorded.appleHeartRateZones?.source == "user" && recorded.appleHeartRateZones?.scope == "recorded_workout", "prefer recorded workout zones over current preferences")
        near(recorded.appleHeartRateZones?.zones[0].seconds, 300, "native duration preserved rather than reweighted/recomputed")
        near(recorded.load.value, 120, "native zone indices never become Edwards weights")
        check(analyze(appleWorkout, cal: AnalysisCalibration()).appleHeartRateZones != nil, "Apple zones independent of age or manual maximum")
        var invalid = preferred; invalid.zones[1].lowerBPM = 119
        check(!TrainingAnalysisMath.validAppleZones(invalid), "overlap configuration rejected")
        invalid = preferred; invalid.zones[1].lowerBPM = 121
        check(!TrainingAnalysisMath.validAppleZones(invalid), "zone gap rejected")
        invalid = preferred; invalid.zones[1].upperBPM = .nan
        check(!TrainingAnalysisMath.validAppleZones(invalid), "nonfinite boundary rejected")
        var badSaved = saved; badSaved.zones[0].seconds = 10000
        appleWorkout.appleHeartRateZones = badSaved
        check(analyze(appleWorkout).appleHeartRateZones?.scope == "current_preference_reclassified", "invalid saved durations fall back to labeled reclassification")
        var unknownTimerZones = workout(active: 2100); unknownTimerZones.preferredAppleHeartRateZones = preferred
        check(analyze(unknownTimerZones).appleHeartRateZones?.zones.allSatisfy { $0.seconds == nil } == true, "unknown pause timer cannot produce fake zero zone times")
        var pausedZones = workout(active: 2100, pauses: [pause]); pausedZones.preferredAppleHeartRateZones = preferred
        near(analyze(pausedZones).appleHeartRateZones?.zones[2].seconds, 2100, "reclassified Apple zones exclude validated pauses")
        var legacyResult = try JSONSerialization.jsonObject(with: JSONEncoder().encode(basic)) as! [String: Any]
        legacyResult.removeValue(forKey: "heartRateReference"); legacyResult.removeValue(forKey: "appleHeartRateZones")
        let legacyAnalysis = try JSONDecoder().decode(RunTrainingAnalysis.self, from: JSONSerialization.data(withJSONObject: legacyResult))
        check(legacyAnalysis.appleHeartRateZones == nil, "old cache optional zone/reference fields remain decodable")
        let encodedReference = String(decoding: try JSONEncoder().encode(automatic.reference(at: now)), as: UTF8.self)
        check(!encodedReference.contains("birth") && !encodedReference.contains("known test"), "reference snapshot contains no birth date or manual free text")
        let roundtrip = try JSONDecoder().decode(RunTrainingAnalysis.self, from: JSONEncoder().encode(basic))
        near(roundtrip.load.value, 120, "derived cache roundtrip")
        // Presentation must preserve uncertainty and sign, without inventing readiness or fitness claims.
        check(AnalysisReading.metric(partial.load).contains("部分数据"), "partial observed load cannot get a confident training interpretation")
        check(AnalysisReading.metric(noCalibration.load).contains("没有可用"), "missing load is unavailable rather than zero or easy")
        check(AnalysisReading.metric(zeroLoad.load).contains("已记录"), "valid measured zero still has an interpretation")
        check(AnalysisReading.metric(automaticRun.load).contains("年龄估算"), "estimated maximum stays visible in load interpretation")
        var displayedDrift = basic.drift; displayedDrift.value = 6.25
        check(AnalysisReading.metric(displayedDrift).contains("低6.2%"), "positive drift describes lower late efficiency, not HR percent rise")
        displayedDrift.value = -6.25
        check(AnalysisReading.metric(displayedDrift).contains("高6.2%"), "negative drift describes higher late efficiency without calling it better")
        displayedDrift.value = -0.01
        check(AnalysisReading.metric(displayedDrift).contains("0.0%"), "tiny drift avoids a negative-zero directional claim")
        displayedDrift.complete = false
        check(!AnalysisReading.metric(displayedDrift).contains("后半段"), "ineligible drift never claims an applicable aerobic change")
        var readableTrend = trend
        readableTrend.recent = 1.1; readableTrend.baseline = 1
        check(AnalysisReading.change(readableTrend).contains("高了10.0%"), "trend change uses actual reference and plain direction")
        readableTrend.recent = 0.9
        check(AnalysisReading.change(readableTrend).contains("低了10.0%"), "decline direction preserved without a bad-fitness label")
        readableTrend.recent = 1.0001
        check(AnalysisReading.change(readableTrend).contains("0.0%"), "tiny trend change not described as an increase of zero")
        readableTrend.baseline = 0
        check(AnalysisReading.change(readableTrend).contains("无法比较"), "zero baseline never generates infinite change")
        readableTrend.baseline = nil
        check(AnalysisReading.change(readableTrend).contains("无法比较"), "missing baseline never replaced with zero")
        readableTrend.baseline = 1; readableTrend.recent = .nan
        check(AnalysisReading.change(readableTrend).contains("无法比较"), "nonfinite measurements cannot produce a confident summary")
        readableTrend.metric = "sleep_minutes"; readableTrend.recent = 360; readableTrend.baseline = 400
        check(AnalysisReading.change(readableTrend).contains("少了10.0%"), "sleep compares duration without a readiness conclusion")
        var readableLoad = AnalysisLoadDay(date: now, observedLoad: 100, shortLoad: 30, longLoad: 20, completeHistory: true, warmedUp: true)
        check(AnalysisReading.load(readableLoad).contains("高50.0%"), "short long interpretation compares weighted levels, not weekly sums")
        readableLoad.completeHistory = false
        check(AnalysisReading.load(readableLoad).contains("暂不判断"), "missing history suppresses load comparison")
        readableLoad.completeHistory = true; readableLoad.warmedUp = false
        check(AnalysisReading.load(readableLoad).contains("暂不判断"), "unwarmed load cannot imply usual training level")
        check(AnalysisReading.appleZones(preferred).contains("尚无"), "zone settings alone cannot imply zero or easy training")
        var zeroZones = saved
        for i in zeroZones.zones.indices { zeroZones.zones[i].seconds = 0 }
        check(AnalysisReading.appleZones(zeroZones).contains("均为0"), "recorded zero durations distinguished from absent zone timing")
        check(AnalysisReading.appleZones(saved).contains("区间3最多"), "Apple dominant zone is based on original times not ordinal intensity weights")
        for metric in ["step_count", "stride_length", "ground_contact_time", "vertical_oscillation", "running_power"] {
            check(!AnalysisReading.guide(metric).meaning.contains("这是已记录数据"), "every supported form metric has a specific plain explanation")
        }
        func needsRead(_ a: ArchiveActivity = run, saved: RunTrainingAnalysis? = basic, failed: AnalysisReadAttempt? = nil, at: Date = now, force: Bool = false) -> Bool {
            AnalysisRefreshPolicy.shouldRead(a, saved: saved, failed: failed, calibrationKey: calibration.key, timeZone: c.timeZone.identifier, now: at, force: force)
        }
        check(!needsRead(at: now.addingTimeInterval(301)), "recent complete result no longer expires after five minutes")
        check(needsRead(at: now.addingTimeInterval(6*3600)), "recent result rechecks after six hours for late deliveries")
        check(!needsRead(saved: partial, at: now.addingTimeInterval(301)), "recent incomplete result not re-read every five minutes")
        check(needsRead(saved: nil), "new workout requires initial raw data")
        check(needsRead(force: true), "manual refresh always bypasses a fresh cache")
        check(needsRead(edited), "edited summary bypasses existing cache immediately")
        var oldAnalysis = basic
        let historicalActivity = activity(start: now.addingTimeInterval(-10*86400))
        oldAnalysis.date = historicalActivity.date; oldAnalysis.inputSignature = TrainingAnalysisMath.signature(historicalActivity)
        check(!needsRead(historicalActivity, saved: oldAnalysis, at: now.addingTimeInterval(86400)), "complete older result survives a daily revisit")
        oldAnalysis.load.coverage = 0.5
        check(!needsRead(historicalActivity, saved: oldAnalysis, at: now.addingTimeInterval(86399)), "older missing data gets a full-day retry interval")
        check(needsRead(historicalActivity, saved: oldAnalysis, at: now.addingTimeInterval(86400)), "older missing data eventually rechecks")
        var staleVersion = basic; staleVersion.version = "old"
        check(needsRead(saved: staleVersion), "algorithm version changes bypass the time cache")
        staleVersion = basic; staleVersion.calibrationKey = "old calibration"
        check(needsRead(saved: staleVersion), "reference changes bypass the time cache")
        staleVersion = basic; staleVersion.timeZone = "other"
        check(needsRead(saved: staleVersion), "timezone changes bypass the time cache")
        staleVersion = basic; staleVersion.calculatedAt = now.addingTimeInterval(1)
        check(needsRead(saved: staleVersion), "future cache timestamps do not stay fresh indefinitely")
        let failedAttempt = AnalysisReadAttempt(date: now, signature: TrainingAnalysisMath.signature(run), calibrationKey: calibration.key, timeZone: c.timeZone.identifier)
        check(!needsRead(saved: nil, failed: failedAttempt, at: now.addingTimeInterval(3599)), "automatic failures back off for an hour")
        check(needsRead(saved: nil, failed: failedAttempt, at: now.addingTimeInterval(3600)), "failed reads eventually retry")
        check(needsRead(saved: nil, failed: failedAttempt, force: true), "explicit retry bypasses failure backoff")
        check(needsRead(edited, saved: nil, failed: failedAttempt), "edited workout does not inherit the old failure backoff")
        let insightDay = AnalysisLoadDay(date: now, observedLoad: 100, shortLoad: 30, longLoad: 20, completeHistory: true, warmedUp: true)
        check(AnalysisInsights.load(insightDay, hasMeasurements: true).headline.contains("更多"), "load insight leads with relative personal training meaning")
        check(AnalysisInsights.load(insightDay, hasMeasurements: true).detail.contains("50.0%"), "load insight uses measured difference rather than a fabricated status score")
        var missingInsightDay = insightDay; missingInsightDay.completeHistory = false
        check(!AnalysisInsights.load(missingInsightDay, hasMeasurements: true).headline.contains("更多"), "missing history prevents a confident load label")
        check(AnalysisInsights.load(nil, hasMeasurements: false).headline.contains("跑量"), "no load falls back to usable training facts")
        check(AnalysisInsights.session(partial, history: []).headline.contains("先看"), "partial run never receives a strong training assessment")
        check(AnalysisInsights.session(basic, history: []).detail.contains("不够"), "no personal history never pretends to have a personalized intensity band")
        var personalHistory: [RunTrainingAnalysis] = []
        for i in 1...6 {
            var h = basic; h.id = "personal-\(i)"; h.date = basic.date.addingTimeInterval(-Double(i)*86400); h.load.value = 60
            personalHistory.append(h)
        }
        check(AnalysisInsights.session(basic, history: personalHistory).headline.contains("更重"), "complete single run is interpreted against past personal training")
        check(AnalysisInsights.session(basic, history: personalHistory).detail.contains("100.0%"), "single-run comparison has an independent median anchor")
        for i in personalHistory.indices { personalHistory[i].date = basic.date.addingTimeInterval(86400) }
        check(AnalysisInsights.session(basic, history: personalHistory).detail.contains("不够"), "future runs never become a personal reference")
        for i in personalHistory.indices { personalHistory[i].date = basic.date.addingTimeInterval(-86400); personalHistory[i].calibrationKey = "other" }
        check(AnalysisInsights.session(basic, history: personalHistory).detail.contains("不够"), "incompatible reference cannot label single-run stimulus")
        let excluded = AnalysisInsights.aerobicExclusions([basic, partial, noCalibration])
        check(excluded.reduce(0) { $0 + $1.count } == 2, "aerobic exclusions are aggregated without excluding valid records")
        var wellness = readableTrend; wellness.metric = "sleep_minutes"; wellness.recent = 360; wellness.baseline = 420
        check(AnalysisInsights.recovery(wellness)?.headline.contains("少约60分钟") == true, "sleep interpretation uses meaningful duration rather than a raw percent")
        check(AnalysisInsights.recovery(wellness)?.detail.contains("6小时0分钟") == true, "sleep is rendered in familiar hours and minutes")
        wellness.metric = "resting_heart_rate"; wellness.recent = 55; wellness.baseline = 50
        check(AnalysisInsights.recovery(wellness)?.headline.contains("高5.0次") == true, "resting pulse change is an absolute personal comparison")
        wellness.recent = nil
        check(AnalysisInsights.recovery(wellness) == nil, "missing wellness data never generates a recovered/not-recovered label")
        let impulseDate = c.startOfDay(for: now.addingTimeInterval(-160*86400))
        let impulseActivity = activity(id: "canonical-impulse", start: impulseDate)
        var impulseAnalysis = basic
        impulseAnalysis.id = impulseActivity.id; impulseAnalysis.date = impulseDate
        impulseAnalysis.end = impulseDate.addingTimeInterval(2400)
        impulseAnalysis.loadParts = [AnalysisLoadPart(date: impulseDate, value: 120)]
        let canonical = TrainingAnalysisMath.loadTimeline([AnalysisRunSummary(impulseActivity)], analyses: [impulseAnalysis], now: now, calendar: c)
        check(canonical.count == 161, "canonical history begins at known first training, with full warmup")
        near(canonical.last?.longLoad, 120 * (1-exp(-1.0/42)) * exp(-160.0/42), "canonical impulse uses one known history origin, independent closed form")
        let chartCrop = canonical.filter { $0.date >= now.addingTimeInterval(-28*86400) }
        near(chartCrop.last?.longLoad, canonical.last!.longLoad, "changing chart range crops values without restarting smoothing")
        // Dashboard presentation must not reinterpret missing data, reset EWMA, or compare an unfinished week with a full week.
        let monday = c.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        var sundayCalendar = c; sundayCalendar.firstWeekday = 1
        let dashboardRuns = [AnalysisRunSummary(run), AnalysisRunSummary(activity(id: "pending", start: now)),
                             AnalysisRunSummary(activity(id: "last-week", start: monday.addingTimeInterval(-1))), future]
        let dashboard = TrainingDashboard(summaries: dashboardRuns, records: [basic], timeline: canonical, now: now, calendar: sundayCalendar)
        check(dashboard.weeks.count == 8 && dashboard.current.start == monday, "dashboard explicitly uses eight Monday-based weeks regardless of locale")
        check(dashboard.current.count == 2 && dashboard.previous.count == 1, "week boundaries exclude future workouts")
        check(dashboard.current.measured == 1 && !dashboard.current.complete, "pending load cannot appear as complete zero")
        near(dashboard.current.knownLoad, basic.load.value!, "weekly load sums original usable scores without rescaling")
        check(dashboard.latest?.id == "pending" && dashboard.latestAnalysis == nil, "latest run stays pending rather than displaying an older analysis")
        check(dashboard.recentCount == 3 && dashboard.measuredCount == 1, "dashboard coverage only includes eligible current summaries")
        near(dashboard.loadDay?.longLoad, canonical.last!.longLoad, "dashboard uses full canonical history, not chart-range recalculation")
        let completeDay = AnalysisLoadDay(date: now, observedLoad: 0, shortLoad: 20, longLoad: 10, completeHistory: true, warmedUp: true)
        func ratio(_ day: AnalysisLoadDay) -> Double? {
            TrainingDashboard(summaries: [], records: [], timeline: [day], now: now, calendar: c).loadRatio
        }
        near(ratio(completeDay), 2, "transparent short/long ratio has no proprietary scale")
        var incompleteDay = completeDay; incompleteDay.completeHistory = false
        check(ratio(incompleteDay) == nil, "missing history suppresses ratio")
        incompleteDay = completeDay; incompleteDay.warmedUp = false
        check(ratio(incompleteDay) == nil, "warmup suppresses ratio")
        incompleteDay = completeDay; incompleteDay.longLoad = 0
        check(ratio(incompleteDay) == nil, "zero denominator is not infinite fitness")
        incompleteDay = completeDay; incompleteDay.shortLoad = .infinity
        check(ratio(incompleteDay) == nil, "nonfinite load suppressed")
        let emptyDashboard = TrainingDashboard(summaries: [], records: [], timeline: [], now: now, calendar: c)
        check(emptyDashboard.current.count == 0 && emptyDashboard.latest == nil && emptyDashboard.loadRatio == nil, "empty dashboard has no fabricated state")
        var dstCalendar = c; dstCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let dashboardDSTNow = dstCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0))!
        let dstRun = AnalysisRunSummary(activity(id: "dst", start: dashboardDSTNow.addingTimeInterval(-1)))
        let dstDashboard = TrainingDashboard(summaries: [dstRun], records: [], timeline: [], now: dashboardDSTNow, calendar: dstCalendar)
        check(dstDashboard.previous.count == 1 && dstDashboard.current.count == 0, "DST weekend respects calendar week instead of fixed seconds")
        print("PASS: \(checks) independent checks — published load/score anchors, boundaries, weighted support, pauses, joint sampling, signed drift, hills/intervals, calibration, day allocation, EWMA closed form, missing history, source/time-context baselines, future exclusion and persistence")
    }
}
