import Foundation

final class FeedbackMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct TrainingFeedbackTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ text: String) {
        precondition(value(), text); checks += 1
    }
    static func rejects(_ text: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure(text) } catch { checks += 1 }
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                result.append(bytes, count: count)
            }
            data = result
        }
        return try JSONSerialization.jsonObject(with: data!) as! [String: Any]
    }
    @MainActor static func main() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = AIDate.parse("2026-10-22", calendar: calendar)!
        let now = day.addingTimeInterval(12 * 3600), t1 = day.addingTimeInterval(3600), t2 = day.addingTimeInterval(7200)
        let root = URL(fileURLWithPath: "/private/tmp/feedback-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ id: String, date: Date = day, seconds: Double = 1800) -> ArchiveActivity {
            ArchiveActivity(preview: WorkoutPreview(id: id, date: date, distanceKm: 5, duration: seconds,
                avgHeartRate: 145, maxHeartRate: 160, avgPower: nil, endDate: date.addingTimeInterval(seconds)))
        }
        let a = run("a"), b = run("b", date: day.addingTimeInterval(-86400))
        let activities = [a,b]
        func shared(_ data: JournalData, runs: [ArchiveActivity]? = nil) -> [RunSubjectiveFeedback] {
            TrainingFeedback.shared(activities: runs ?? activities, journal: data, now: now, calendar: calendar)
        }
        let legacyJSON = #"{"kind":"轻松跑","effort":7,"note":"private legacy note","favoriteRoute":true,"routeName":"private route","excludeFromRecords":false}"#
        let legacy = try JSONDecoder().decode(RunAnnotation.self, from: Data(legacyJSON.utf8))
        check(legacy.effort == 7 && legacy.sharing == .localOnly && legacy.feeling == nil && legacy.fatigue == nil, "legacy feedback retains value with no cloud consent or invented fatigue")
        check(legacy.feedbackRecordedAt == nil && legacy.feedbackUpdatedAt == nil, "legacy collection time stays unknown")
        var initial = JournalData(); initial.annotations[a.id] = legacy
        check(shared(initial).isEmpty, "legacy private notes never become cloud input")
        let url = root.appendingPathComponent("journal.json")
        try JSONEncoder().encode(initial).write(to: url)
        let journal = TrainingJournal(fileURL: url)
        var events = 0, lastOld = JournalData(), lastNew = JournalData()
        journal.onFeedbackChange = { old, new in events += 1; lastOld = old; lastNew = new }
        var value = journal.annotation(a.id)
        value.favoriteRoute.toggle(); value.routeName = "route changed"; value.feedbackUpdatedAt = now
        check(journal.saveAnnotation(value, id: a.id, now: t1), "route edit saves")
        check(events == 0 && journal.annotation(a.id).feedbackUpdatedAt == nil, "metadata edit cannot refresh stale feedback time or trigger cloud work")
        value = journal.annotation(a.id); value.feedbackSharing = .ratings
        check(journal.saveAnnotation(value, id: a.id, now: t1), "ratings-only consent saves")
        check(events == 1 && shared(lastOld).isEmpty && shared(lastNew).count == 1, "callback receives committed consent transition")
        var payload = shared(journal.data)
        check(payload[0].effort_1_to_10 == 7 && payload[0].note == nil && payload[0].ratings_recorded_at == nil, "ratings consent does not fabricate time or include old notes")
        let beforePrivateEdit = payload
        value = journal.annotation(a.id); value.note = "PRIVATE_NOTE_DO_NOT_SEND"
        check(journal.saveAnnotation(value, id: a.id, now: t1), "private note updated")
        check(shared(journal.data) == beforePrivateEdit, "private note edits leave AI input and trigger fingerprint unchanged")
        value = journal.annotation(a.id); value.effort = 8; value.feeling = .poor; value.fatigue = .high
        check(journal.saveAnnotation(value, id: a.id, now: t1), "ratings save")
        check(journal.annotation(a.id).feedbackRecordedAt == t1 && journal.annotation(a.id).feedbackUpdatedAt == t1, "new structured feedback has collection and update times")
        value = journal.annotation(a.id); value.fatigue = .mild
        check(journal.saveAnnotation(value, id: a.id, now: t2), "fatigue edit saves")
        check(journal.annotation(a.id).feedbackRecordedAt == t1 && journal.annotation(a.id).feedbackUpdatedAt == t2, "fatigue edit preserves original collection time")
        check(journal.annotation(a.id).noteUpdatedAt == t1, "rating edits don't refresh note time")
        value = journal.annotation(a.id); value.note = "Second PRIVATE note"
        check(journal.saveAnnotation(value, id: a.id, now: t2), "second private note saves")
        check(journal.annotation(a.id).feedbackUpdatedAt == t2, "note edit leaves rating clock unchanged")
        let eventCount = events
        check(journal.saveAnnotation(journal.annotation(a.id), id: a.id, now: now), "unchanged save succeeds")
        check(events == eventCount && journal.annotation(a.id).feedbackUpdatedAt == t2, "unchanged save neither retriggers nor rejuvenates feedback")
        let restored = TrainingJournal(fileURL: url)
        check(restored.annotation(a.id) == journal.annotation(a.id), "all optional feedback fields and consent round-trip")
        value = journal.annotation(a.id); value.effort = 11
        check(!journal.saveAnnotation(value, id: a.id, now: now) && events == eventCount, "invalid RPE rejected before notification")
        value.effort = 0
        check(!journal.saveAnnotation(value, id: a.id, now: now), "RPE zero isn't missing or valid")
        value = journal.annotation(a.id); value.feedbackSharing = .ratingsAndNote
        check(journal.saveAnnotation(value, id: a.id, now: t2), "explicit note consent saves")
        payload = shared(journal.data)
        check(payload.count == 1 && payload[0].note == value.note && payload[0].note_updated_at == t2, "only explicitly consented note is included")
        let bytes = try JSONEncoder().encode(payload)
        let json = String(decoding: bytes, as: UTF8.self)
        check(!json.contains("route changed") && !json.contains("favoriteRoute") && !json.contains("excludeFromRecords"), "feedback payload is an allowlist, not full annotations")
        value.feedbackSharing = .localOnly
        check(journal.saveAnnotation(value, id: a.id, now: now), "consent withdrawal saves")
        check(shared(journal.data).isEmpty && TrainingFeedback.stale(snapshot: payload, activities: activities, journal: journal.data, now: now, calendar: calendar), "withdrawal removes input and makes old plan stale")
        check(payload[0].note != nil, "historical snapshot is immutable rather than silently rewritten")
        value = RunAnnotation(); value.note = "note only"; value.feedbackSharing = .ratings
        check(journal.saveAnnotation(value, id: b.id, now: t1), "note-only record saves")
        check(shared(journal.data).isEmpty, "ratings-only consent sends nothing if there are no ratings")
        value.feedbackSharing = .ratingsAndNote
        check(journal.saveAnnotation(value, id: b.id, now: t1), "note-only consent saves")
        check(shared(journal.data).first?.effort_1_to_10 == nil && shared(journal.data).first?.note == "note only", "missing rating is absent, never zero")
        value = RunAnnotation(); value.effort = 2; value.feeling = .great; value.fatigue = .high; value.feedbackSharing = .ratings
        check(journal.saveAnnotation(value, id: a.id, now: t1), "different subjective axes can coexist")
        payload = shared(journal.data)
        check(payload.last?.effort_1_to_10 == 2 && payload.last?.feeling == .great && payload.last?.post_run_fatigue == .high, "no inferred fatigue from low RPE or good feeling")
        check(payload.map(\.activity_id) == [b.id, a.id] && shared(journal.data, runs: activities.reversed()) == payload, "stable ordering independent of archive delivery order")
        var ranged = journal.data
        let cutoff = calendar.date(byAdding: .day, value: -42, to: day)!
        let boundary = run("boundary", date: cutoff), expired = run("expired", date: cutoff.addingTimeInterval(-1))
        let future = run("future", date: now.addingTimeInterval(1)), unfinished = run("unfinished", date: now.addingTimeInterval(-60))
        for item in [boundary,expired,future,unfinished] { ranged.annotations[item.id] = journal.annotation(a.id) }
        ranged.annotations["orphan"] = journal.annotation(a.id)
        check(shared(ranged, runs: [boundary,expired,future,unfinished]).map(\.activity_id) == [boundary.id], "42-day local boundary, future/unfinished and orphan filtering")
        var futureNote = journal.data; futureNote.annotations[a.id]?.feedbackUpdatedAt = now.addingTimeInterval(1)
        check(!shared(futureNote).contains { $0.activity_id == a.id }, "future-dated rating evidence is not treated as current")
        futureNote = journal.data; futureNote.annotations[a.id]?.noteUpdatedAt = now.addingTimeInterval(1)
        check(shared(futureNote) == payload, "unshared note timestamp cannot affect scoring input")
        var longNote = RunAnnotation(); longNote.note = String(repeating: "好", count: 2200); longNote.feedbackSharing = .ratingsAndNote
        check(journal.saveAnnotation(longNote, id: "long", now: t1), "long note saved within bound")
        check(journal.annotation("long").note.count == 2000, "persisted notes bounded")
        check(shared(journal.data, runs: [run("long")]).first?.note?.count == 2000, "cloud notes bounded")
        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: corruptURL)
        let broken = TrainingJournal(fileURL: corruptURL)
        var falseNotifications = 0; broken.onFeedbackChange = { _, _ in falseNotifications += 1 }
        check(!broken.saveAnnotation(value, id: a.id, now: t1) && falseNotifications == 0, "failed persistence never triggers model work")
        let corruptBytes = try Data(contentsOf: corruptURL)
        check(String(decoding: corruptBytes, as: UTF8.self) == "invalid", "corrupt original file retained")
        let blocked = TrainingJournal(fileURL: corruptURL.appendingPathComponent("unwritable.json"))
        blocked.onFeedbackChange = { _, _ in falseNotifications += 1 }
        check(!blocked.saveAnnotation(value, id: a.id) && blocked.data.annotations.isEmpty && falseNotifications == 0, "write failure keeps memory and downstream unchanged")
        var input = AITrainingInput(task: "analyze_runs_and_generate_plan", time_zone: calendar.timeZone.identifier,
            today: "2026-10-22", plan_start: "2026-10-23", plan_end: "2026-10-29", profile: AITrainingProfile(),
            lookback_start: "2026-09-10", workouts: [], weeks: [], latest_details: [], references: [], data_notes: [], subjective_feedback: payload)
        check(input.evidenceIDs.contains("feedback:a") && input.evidenceIDs.contains("feedback:b"), "feedback reference IDs allowed independently of objective metrics")
        let hash = try input.fingerprint()
        var changed = input; changed.subjective_feedback?[1].post_run_fatigue = .mild
        let fatigueHash = try changed.fingerprint()
        check(fatigueHash != hash, "fatigue-only update invalidates plan fingerprint")
        changed = input; changed.subjective_feedback = []
        let withdrawnHash = try changed.fingerprint()
        check(withdrawnHash != hash, "withdrawal changes fingerprint even without a new run")
        check(!TrainingFeedback.stale(snapshot: payload, activities: activities, journal: journal.data, now: now, calendar: calendar), "unchanged feedback does not continuously re-plan")
        var plan = AITrainingPlan(schema_version: 2, stage: "恢复安排", summary: "依据跑后反馈", run_review: "自述疲劳",
            sessions: (23...29).map { .rest(on: "2026-10-\($0)") }, adjustments: [], limitations: [])
        rejects("missing feedback explanation rejected") { try plan.validateFeedback(payload) }
        plan.feedback_review = [.init(evidence_ids: ["feedback:a"], observation: "用户自述这次结束后疲劳很强", plan_response: "10月23日安排休息，随后结合反馈复核")]
        try plan.validateFeedback(payload); checks += 1
        let decodedPlan = try JSONDecoder().decode(AITrainingPlan.self, from: JSONEncoder().encode(plan))
        check(decodedPlan == plan && decodedPlan.feedback_review?.count == 1, "feedback review survives custom plan decoding and encoding")
        var oldPlanJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        oldPlanJSON.removeValue(forKey: "feedback_review")
        let oldPlan = try JSONDecoder().decode(AITrainingPlan.self, from: JSONSerialization.data(withJSONObject: oldPlanJSON))
        check(oldPlan.feedback_review == nil, "old plan revisions remain readable")
        var invalid = plan; invalid.feedback_review?[0].evidence_ids = ["feedback:missing"]
        rejects("unprovided feedback ID rejected") { try invalid.validateFeedback(payload) }
        invalid = plan; invalid.feedback_review?[0].evidence_ids = ["feedback:b"]
        rejects("latest feedback cannot be silently ignored") { try invalid.validateFeedback(payload) }
        invalid = plan; invalid.feedback_review?[0].observation = " "
        rejects("empty observation rejected") { try invalid.validateFeedback(payload) }
        invalid = plan; invalid.feedback_review?[0].plan_response = " "
        rejects("empty response rejected") { try invalid.validateFeedback(payload) }
        rejects("invented feedback when no input rejected") { try plan.validateFeedback([]) }
        invalid = oldPlan; invalid.feedback_review = []; try invalid.validateFeedback([]); checks += 1
        let revision = AIPlanRevision(createdAt: now, model: "test", promptVersion: AITrainingPrompt.version,
            inputFingerprint: hash, plan: plan, feedbackContext: payload)
        let restoredRevision = try JSONDecoder().decode(AIPlanRevision.self, from: JSONEncoder().encode(revision))
        check(restoredRevision.feedbackContext == payload && restoredRevision.plan.feedback_review == plan.feedback_review, "plan history preserves exact used feedback and explanation")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FeedbackMockProtocol.self]
        let service = DeepSeekTrainingService(session: URLSession(configuration: configuration))
        var observed = false
        FeedbackMockProtocol.handler = { request in
            let sent = try Self.body(request), messages = sent["messages"] as! [[String: String]]
            let user = messages[1]["content"]!, system = messages[0]["content"]!
            let object = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
            precondition((object["subjective_feedback"] as? [[String: Any]])?.count == 2)
            precondition(!user.contains("PRIVATE") && !user.contains("route changed") && object["current_plan"] == nil)
            precondition(system.contains("不可把旧跑步的补填") && system.contains("feedback_review") && system.contains("不能改算 Edwards"))
            observed = true
            let content = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        }
        let result = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "mock")
        check(observed && result.feedback_review == plan.feedback_review, "real client sends authorized evidence and decodes traceable model response")
        FeedbackMockProtocol.handler = { _ in
            let content = String(decoding: try JSONEncoder().encode(oldPlan), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        }
        do { _ = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "mock"); preconditionFailure("model ignoring feedback accepted") }
        catch { checks += 1 }
        input.subjective_feedback = []
        _ = try await service.generate(input: input, configuration: AITrainingConfiguration(), key: "mock"); checks += 1
        value = journal.annotation(a.id); value.effort = nil; value.feeling = nil; value.fatigue = nil; value.note = ""; value.feedbackSharing = .localOnly
        check(journal.saveAnnotation(value, id: a.id, now: now), "clear feedback saves")
        check(!journal.annotation(a.id).hasFeedback && journal.annotation(a.id).feedbackRecordedAt == nil, "clearing removes subjective values without zero defaults")
        print("PASS: \(checks) subjective feedback checks: legacy/privacy scopes, timestamp provenance, durable callbacks, missing/late/future reports, request fingerprints, evidence validation and mocked API round-trip")
    }
}
