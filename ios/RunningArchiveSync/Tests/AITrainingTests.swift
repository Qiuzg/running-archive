import Foundation

final class DeepSeekMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct AITrainingTests {
    static func main() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = AIDate.parse("2026-10-19", calendar: calendar)!
        var profile = AITrainingProfile()
        profile.availableDays = [1, 3, 5, 7]
        profile.longRunDay = 7
        func plan() -> AITrainingPlan {
            let sessions = (0..<7).map { offset -> AITrainingSession in
                let date = calendar.date(byAdding: .day, value: offset, to: start)!
                let running = profile.availableDays.contains(AIDate.weekday(date, calendar: calendar))
                return AITrainingSession(date: AIDate.key(date, calendar: calendar), kind: running ? .easy : .rest,
                    duration_minutes: running ? 40 : 0, distance_km: nil,
                    intensity: "示例强度", purpose: "示例目的",
                    steps: running ? [AITrainingStep(phase: "热身", minutes: 5, instructions: "步骤一"),
                                      AITrainingStep(phase: "主体", minutes: 30, instructions: "步骤二"),
                                      AITrainingStep(phase: "放松", minutes: 5, instructions: "步骤三")] : [],
                    evidence_ids: ["run-1"])
            }
            return AITrainingPlan(schema_version: 1, stage: "示例阶段", summary: "示例依据",
                run_review: "示例分析", sessions: sessions, adjustments: [], limitations: ["仅测试数据"])
        }
        func validate(_ value: AITrainingPlan) throws {
            try value.validate(profile: profile, start: start, evidenceIDs: ["run-1"], calendar: calendar)
        }
        func rejects(_ edit: (inout AITrainingPlan) -> Void) {
            var value = plan()
            edit(&value)
            do { try validate(value); fatalError("Invalid plan was accepted") } catch {}
        }
        try validate(plan())
        rejects { $0.sessions.removeLast() }
        rejects { $0.sessions[1].date = $0.sessions[0].date }
        rejects { $0.sessions[0].date = "2026-02-30" }
        rejects { $0.sessions[0].duration_minutes = 200 }
        rejects { $0.sessions[0].steps[0].minutes = 9 }
        rejects { $0.sessions[0].steps[0].minutes = -5 }
        rejects { $0.sessions[0].steps[0].phase = "无热身" }
        rejects { $0.sessions[0].distance_km = .nan }
        rejects { $0.sessions[0].evidence_ids = ["invented-run"] }
        rejects { $0.sessions[0].pace_seconds_per_km_min = 300 }
        rejects { $0.sessions[0].pace_seconds_per_km_min = 400; $0.sessions[0].pace_seconds_per_km_max = 300 }
        rejects { $0.sessions[1].kind = .easy; $0.sessions[1].duration_minutes = 40; $0.sessions[1].steps = $0.sessions[0].steps }
        rejects { $0.sessions[1].distance_km = 5 }
        rejects { $0.adjustments = [AITrainingAdjustment(date: "2027-01-01", change: "改变", reason: "原因", evidence_ids: [])] }
        assert(AIDate.weekday(start, calendar: calendar) == 1)
        assert(AIDate.parse("2026-02-30", calendar: calendar) == nil)
        assert(AIDate.parse("2026-1-1", calendar: calendar) == nil)
        assert(AITrainingProfile.targetTime("01:45:00") == 6300)
        assert(AITrainingProfile.targetTime("1:99:00") == nil)
        assert(AITrainingProfile.targetTime("1::00") == nil)
        assert(AITrainingProfile.targetTime("00:00:00") == nil)

        func run(_ date: String, _ km: Double, _ seconds: Double) -> ArchiveActivity {
            ArchiveActivity(preview: WorkoutPreview(id: date + String(km), date: AIDate.parse(date, calendar: calendar)!,
                distanceKm: km, duration: seconds, avgHeartRate: nil, maxHeartRate: nil, avgPower: nil))
        }
        let year = YearlyReport(year: 2024,
            activities: [run("2024-02-29", 10, 3600), run("2024-02-29", 5, 1200), run("2025-01-01", 100, 30000)],
            now: AIDate.parse("2024-06-01", calendar: calendar)!, calendar: calendar)
        assert(year.distance == 15 && year.activeDays == 1 && year.activities.count == 2)
        assert(year.paceText == "5′20″" && year.seconds == 4800)
        assert(year.months.count == 12 && year.months.reduce(0) { $0 + $1.distance } == year.distance)
        let emptyYear = YearlyReport(year: 2023, activities: [], calendar: calendar)
        assert(emptyYear.distance == 0 && emptyYear.paceText == "—")

        let recordRun = run("2024-04-01", 5.1, 1000)
        let fasterRun = run("2024-05-01", 5.0, 900)
        let tooLong = run("2024-06-01", 5.2, 800)
        var journal = JournalData()
        journal.annotations[fasterRun.id] = RunAnnotation(excludeFromRecords: true)
        journal.analyses[recordRun.id] = EffortAnalysis(analyzedAt: start, efforts: [
            DistanceEffort(distance: .five, seconds: 880, startElapsed: 20, endElapsed: 900)
        ])
        let personalRecords = AIPersonalRecord.collect(activities: [recordRun, fasterRun, tooLong], journal: journal, calendar: calendar)
        assert(personalRecords.count == 2)
        assert(personalRecords[0].activity_id == recordRun.id && personalRecords[0].seconds == 1000)
        assert(personalRecords[0].recorded_activity_distance_km == 5.1)
        assert(personalRecords[1].seconds == 880 && personalRecords[1].method.hasPrefix("gps_best_segment"))
        assert(personalRecords.allSatisfy { !$0.official_result_verified && $0.date == "2024-04-01" })
        let overview = ArchiveOverviewSnapshot(summary: ArchiveSummary(totalDistanceKm: 5.1, yearlyDistanceKm: 5.1,
            marathonPb: nil, marathonPbName: nil, halfMarathonPb: nil, halfMarathonPbName: nil, raceCount: 0, marathonCount: 0),
            activities: [recordRun])
        let restoredOverview = try JSONDecoder().decode(ArchiveOverviewSnapshot.self, from: JSONEncoder().encode(overview))
        assert(restoredOverview.activities == overview.activities && restoredOverview.summary.totalDistanceKm == 5.1)

        var input = AITrainingInput(task: "analyze_runs_and_generate_plan", time_zone: calendar.timeZone.identifier,
            today: "2026-10-18", plan_start: "2026-10-19", plan_end: "2026-10-25",
            profile: profile, lookback_start: "2026-09-06", workouts: [
                AIWorkoutSummary(id: "run-1", start: start, date: "2026-10-18", distance_km: 10, active_seconds: 3600,
                    pace_seconds_per_km: 360, average_heart_rate_bpm: nil, max_heart_rate_bpm: nil,
                    average_power_watts: nil, average_cadence_spm: nil)
            ], weeks: [], latest_details: [], references: [], data_notes: ["心率未记录"])
        input.personal_records = personalRecords
        assert(input.evidenceIDs.contains(recordRun.id))
        let firstHash = try input.fingerprint()
        let secondHash = try input.fingerprint()
        assert(firstHash == secondHash)
        var changed = input
        changed.profile.goal = "不同目标"
        let changedHash = try changed.fingerprint()
        assert(firstHash != changedHash)
        let day = AIDate.parse("2026-10-16", calendar: calendar)!
        let daily = AIRecoveryContext.daily([
            AIBackgroundPoint(date: day.addingTimeInterval(3600), value: 55, source: "private.watch.source"),
            AIBackgroundPoint(date: day.addingTimeInterval(3600), value: 55, source: "private.watch.source"),
            AIBackgroundPoint(date: day.addingTimeInterval(7200), value: 65, source: "private.watch.source"),
            AIBackgroundPoint(date: day.addingTimeInterval(3600), value: 35, source: "second.importer"),
            AIBackgroundPoint(date: day.addingTimeInterval(9000), value: .nan, source: "private.watch.source")
        ], metric: "resting_heart_rate", unit: "bpm", calendar: calendar)
        assert(daily.count == 1 && daily[0].median == 60 && daily[0].sample_count == 2)
        let sleepStart = AIDate.parse("2026-10-15", calendar: calendar)!.addingTimeInterval(12 * 3600)
        let nightStart = AIDate.parse("2026-10-15", calendar: calendar)!.addingTimeInterval(23 * 3600)
        let morning = day.addingTimeInterval(7 * 3600)
        let latestStart = day.addingTimeInterval(23 * 3600)
        let latestEnd = calendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(7 * 3600)
        let sleep = AIRecoveryContext.sleep([
            AISleepInterval(start: nightStart, end: morning, source: "private.watch.source"),
            AISleepInterval(start: nightStart, end: day.addingTimeInterval(3 * 3600), source: "private.watch.source"),
            AISleepInterval(start: nightStart, end: morning.addingTimeInterval(-3600), source: "second.importer"),
            AISleepInterval(start: latestStart, end: latestEnd, source: "private.watch.source")
        ], start: sleepStart, end: latestEnd.addingTimeInterval(2 * 3600), calendar: calendar)
        assert(sleep.count == 2 && sleep[0].asleep_minutes == 480 && sleep[1].asleep_minutes == 480)
        assert(!sleep[0].partial_window && sleep[1].partial_window)
        let emptySleep = AIRecoveryContext.sleep([], start: sleepStart, end: latestEnd, calendar: calendar)
        assert(emptySleep.isEmpty)
        input.recovery_context = AIRecoveryContext(daily_metrics: daily, sleep_windows: sleep,
            latest_body_mass: AIBodyMeasurement(date: day, kilograms: 65),
            other_workouts: [AIOtherWorkout(date: day, kind: "cycling", active_seconds: 1800, energy_kcal: 250)], notes: [])
        let inputJSON = String(decoding: try input.encoded(), as: UTF8.self)
        assert(!inputJSON.contains("private.watch.source") && !inputJSON.contains("second.importer"))
        assert(inputJSON.contains("recovery_context") && inputJSON.contains("partial_window"))
        assert(!inputJSON.contains("latitude") && !inputJSON.contains("longitude") && !inputJSON.contains("apiKey"))
        assert(!inputJSON.contains("\"average_heart_rate_bpm\":0"))
        let payload = try JSONSerialization.jsonObject(with: input.encoded()) as! [String: Any]
        assert(payload["current_plan"] == nil && payload["completed"] == nil)
        assert(!AITrainingPrompt.system.contains("completed") && !AITrainingPrompt.system.contains("相较原计划"))
        assert(!AITrainingPrompt.system.contains("adjustments"))
        assert(AITrainingConfiguration().endpoint?.absoluteString == "https://api.deepseek.com/chat/completions")
        var invalidURL = AITrainingConfiguration()
        invalidURL.baseURL = "http://api.deepseek.com"
        assert(invalidURL.endpoint == nil)
        invalidURL.baseURL = "https://api.deepseek.com?key=secret"
        assert(invalidURL.endpoint == nil)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepSeekMockProtocol.self]
        let service = DeepSeekTrainingService(session: URLSession(configuration: config))
        DeepSeekMockProtocol.handler = { request in
            assert(request.httpMethod == "GET" && request.httpBody == nil)
            assert(request.url?.absoluteString == "https://api.deepseek.com/models")
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer models-test-key")
            return (200, Data("{\"data\":[{\"id\":\"deepseek-flash\",\"owned_by\":\"deepseek\"},{\"id\":\"another-chat-model\",\"name\":\"Provider Model Name\"},{\"id\":\"deepseek-flash\"}]}".utf8))
        }
        let models = try await service.availableModels(configuration: AITrainingConfiguration(), key: "models-test-key")
        assert(models.map(\.id) == ["another-chat-model", "deepseek-flash"])
        assert(models[0].displayName == "Provider Model Name")
        var v1 = AITrainingConfiguration()
        v1.baseURL += "/v1"
        assert(v1.modelsEndpoint?.absoluteString == "https://api.deepseek.com/v1/models")
        DeepSeekMockProtocol.handler = { _ in (200, Data("{\"data\":[]}".utf8)) }
        do {
            _ = try await service.availableModels(configuration: AITrainingConfiguration(), key: "test-key")
            fatalError("Empty model list accepted")
        } catch {}
        DeepSeekMockProtocol.handler = { _ in (401, Data("do-not-echo-token".utf8)) }
        do {
            _ = try await service.availableModels(configuration: AITrainingConfiguration(), key: "test-key")
            fatalError("Unauthorized model listing accepted")
        } catch { assert(!error.localizedDescription.contains("do-not-echo-token")) }
        let responsePlan = plan()
        var freshResponse = try JSONSerialization.jsonObject(with: JSONEncoder().encode(responsePlan)) as! [String: Any]
        freshResponse.removeValue(forKey: "adjustments")
        let planJSON = String(decoding: try JSONSerialization.data(withJSONObject: freshResponse), as: UTF8.self)
        let freshDecoded = try JSONDecoder().decode(AITrainingPlan.self, from: Data(planJSON.utf8))
        assert(freshDecoded == responsePlan && freshDecoded.adjustments.isEmpty)
        var legacy = responsePlan
        legacy.adjustments = [AITrainingAdjustment(date: "2026-10-19", change: "历史版本的调整", reason: "原先的依据", evidence_ids: ["run-1"])]
        let restoredLegacy = try JSONDecoder().decode(AITrainingPlan.self, from: JSONEncoder().encode(legacy))
        assert(restoredLegacy == legacy)
        func completion(_ text: String, finish: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": finish]]])
        }
        DeepSeekMockProtocol.handler = { request in
            assert(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var result = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    result.append(bytes, count: count)
                }
                data = result
            }
            let body = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
            assert(body["model"] as? String == "deepseek-flash")
            assert((body["response_format"] as? [String: String])?["type"] == "json_object")
            assert(body["stream"] as? Bool == false)
            let messages = body["messages"] as! [[String: String]]
            let sent = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
            assert(sent["current_plan"] == nil && sent["completed"] == nil)
            return (200, try completion(planJSON))
        }
        let result = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "test-key")
        assert(result == responsePlan)
        try validate(result)
        DeepSeekMockProtocol.handler = { _ in (200, try completion("not json")) }
        do {
            _ = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "test-key")
            fatalError("Malformed JSON was accepted")
        } catch {}
        DeepSeekMockProtocol.handler = { _ in (200, try completion(planJSON, finish: "length")) }
        do {
            _ = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "test-key")
            fatalError("Truncated response was accepted")
        } catch {}
        DeepSeekMockProtocol.handler = { _ in (401, Data("sensitive upstream body".utf8)) }
        do {
            _ = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "test-key")
            fatalError("Unauthorized response was accepted")
        } catch { assert(!error.localizedDescription.contains("sensitive")) }
        DeepSeekMockProtocol.handler = { _ in (200, try completion("{\"ok\":true}")) }
        try await service.test(configuration: AITrainingConfiguration(), key: "test-key")
        DeepSeekMockProtocol.handler = { _ in (200, try completion("{\"ok\":false}")) }
        do {
            try await service.test(configuration: AITrainingConfiguration(), key: "test-key")
            fatalError("Failed connection test was accepted")
        } catch {}
        var disk = AITrainingDiskState()
        disk.revisions = [AIPlanRevision(createdAt: start, model: "deepseek-flash", promptVersion: AITrainingPrompt.version,
            inputFingerprint: firstHash, plan: result)]
        disk.completed = [AICompletedSession(session: result.sessions[0], activityIDs: ["run-1"])]
        let restored = try JSONDecoder().decode(AITrainingDiskState.self, from: JSONEncoder().encode(disk))
        assert(restored.revisions[0].plan == result && restored.completed[0].activityIDs == ["run-1"])
        print("PASS: recovery daily medians/source dedup, overlapping/multi-source sleep union, partial windows/missing values/privacy, fresh-plan payload excludes old plans/completion, new response without adjustments, legacy history decoding, PB methods/exclusions/evidence IDs, persistent overview round-trip, authenticated model listing/dedup/errors, seven-day schema, dates, schedule/time limits, steps, references, pace, missing data, annual totals, privacy payload, model/endpoint, mocked DeepSeek success/errors, plan history round-trip")
    }
}
