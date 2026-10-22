import Foundation

@MainActor final class UIApplication {
    enum State { case active }
    static let shared = UIApplication()
    var applicationState: State = .active
}
enum KeychainStore {
    static func read(_ account: String) -> String { "mock-key" }
    static func writeChecked(_ value: String, account: String, backgroundAccessible: Bool) throws { }
}
@MainActor final class ArchiveStore {
    var activities: [ArchiveActivity] = []
    var beforeContext: (() -> Void)?
    func load(force: Bool, authorize: Bool) async { }
    func requestAIContextAccess() async throws { }
    func exportWorkout(id: String) async throws -> ExportWorkout { throw CocoaError(.fileReadNoSuchFile) }
    func exportReferences(start: Date, end: Date) async throws -> ExportReferenceData { .init() }
    func trainingContext(now: Date, calendar: Calendar, days: Int) async -> AIRecoveryContext {
        beforeContext?(); beforeContext = nil
        return .init()
    }
}
@MainActor final class FeedbackFakeAnalytics {
    var calibration = AnalysisCalibration()
    func prepareHeartRateProfile(archive: ArchiveStore, authorize: Bool = false) async { }
    func updateSummaries(_ activities: [ArchiveActivity]) { }
    func analyze(activity: ArchiveActivity, archive: ArchiveStore, provided: ExportWorkout) async throws { }
    func ingestRecovery(_ context: AIRecoveryContext) { }
    func flush() { }
    func context(activities: [ArchiveActivity], now: Date, recovery: AIRecoveryContext) -> TrainingAnalysisContext {
        .init(version: AnalysisMethod.version, as_of: now, calibration_method: "fixture", evidence: [], weeks: [],
            load_days: [], recovery: [], aerobic: [], form: [], performances: [], limitations: [])
    }
}
@MainActor final class FeedbackFakeWatch {
    var syncs = 0
    func sync(sessions: [AITrainingSession], completed: Set<String>, requestAuthorization: Bool) async { syncs += 1 }
}
@MainActor final class RunningArchiveRuntime {
    static let shared = RunningArchiveRuntime()
    let analytics = FeedbackFakeAnalytics(), watch = FeedbackFakeWatch()
    var scheduled = 0
    func scheduleAnalysis(force: Bool = false) { scheduled += 1 }
}
final class FeedbackStoreProtocol: URLProtocol {
    static var onRequest: ((URLRequest, @escaping (Data) -> Void) -> Void)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onRequest(request) { data in
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}
@main @MainActor struct TrainingFeedbackStoreTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }
    static func input(_ request: URLRequest) throws -> AITrainingInput {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), all = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; all.append(bytes, count: n)
            }
            data = all
        }
        let object = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
        let messages = object["messages"] as! [[String: String]]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AITrainingInput.self, from: Data(messages[1]["content"]!.utf8))
    }
    static func response(_ input: AITrainingInput, includeReview: Bool = true) throws -> Data {
        let calendar = AIDate.localCalendar, start = AIDate.parse(input.plan_start, calendar: calendar)!
        let sessions = (0..<7).map { AITrainingSession.rest(on: AIDate.key(calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar)) }
        var plan = AITrainingPlan(schema_version: 2, stage: "mock", summary: "mock", run_review: "mock", sessions: sessions, adjustments: [], limitations: [])
        if includeReview, let feedback = input.subjective_feedback?.last {
            plan.feedback_review = [.init(evidence_ids: [feedback.id], observation: "用户自述", plan_response: "本周休息，待进一步确认")]
        }
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(decoding: JSONEncoder().encode(plan), as: UTF8.self)], "finish_reason": "stop"]]])
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/feedback-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now, calendar = AIDate.localCalendar
        let run = ArchiveActivity(preview: WorkoutPreview(id: "run", date: now.addingTimeInterval(-7200), distanceKm: 5,
            duration: 1800, avgHeartRate: 140, maxHeartRate: 155, avgPower: nil))
        let archive = ArchiveStore(); archive.activities = [run]
        let journal = TrainingJournal(fileURL: root.appendingPathComponent("journal.json"))
        var annotation = RunAnnotation(); annotation.effort = 8; annotation.fatigue = .high; annotation.feedbackSharing = .ratings
        check(journal.saveAnnotation(annotation, id: run.id), "seed shared feedback")
        var disk = AITrainingDiskState(); disk.configuration.enabled = true
        let file = root.appendingPathComponent("plans.json")
        try JSONEncoder().encode(disk).write(to: file)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FeedbackStoreProtocol.self]
        let service = DeepSeekTrainingService(session: URLSession(configuration: configuration))
        let store = AITrainingStore(fileURL: file, service: service)
        var requests = 0
        var mutateDuringResponse: (() -> Void)?
        var includeReview = true
        FeedbackStoreProtocol.onRequest = { request, reply in
            Task { @MainActor in
                requests += 1
                let sent = try! Self.input(request)
                mutateDuringResponse?(); mutateDuringResponse = nil
                reply(try! Self.response(sent, includeReview: includeReview))
            }
        }
        await store.generate(archive: archive, journal: journal)
        check(requests == 1 && store.state.revisions.count == 1, "actual store builds/sends feedback and persists valid plan")
        check(store.current?.feedbackContext?.first?.post_run_fatigue == .high && store.current?.plan.feedback_review?.count == 1, "used snapshot and model rationale persisted together")
        let signature = store.state.lastFingerprint
        check(store.current?.profileContext == store.state.profile, "actual store persists generation profile for phase provenance")
        var saved = journal.annotation(run.id); saved.note = "private edit"
        check(journal.saveAnnotation(saved, id: run.id), "private note edit")
        await store.generate(archive: archive, journal: journal)
        check(requests == 1 && store.state.lastFingerprint == signature, "private note update does not send another request")
        saved = journal.annotation(run.id); saved.fatigue = .mild
        check(journal.saveAnnotation(saved, id: run.id), "fatigue-only change")
        await store.generate(archive: archive, journal: journal)
        check(requests == 2 && store.state.revisions.count == 2 && store.state.lastFingerprint != signature, "fatigue-only changes regenerate without a new run")
        check(store.current?.feedbackContext?.first?.post_run_fatigue == .mild, "latest revision uses latest fatigue")
        let count = store.state.revisions.count
        mutateDuringResponse = {
            var value = journal.annotation(run.id); value.feedbackSharing = .localOnly
            check(journal.saveAnnotation(value, id: run.id), "withdraw while request in flight")
        }
        await store.generate(archive: archive, journal: journal, force: true)
        check(store.state.revisions.count == count && RunningArchiveRuntime.shared.scheduled > 0, "late response with revoked evidence cannot overwrite plan even without explicit cancellation")
        await store.generate(archive: archive, journal: journal)
        check(store.current?.feedbackContext?.isEmpty == true && store.state.revisions.count == count + 1, "withdrawal replans with no old snapshot re-sent")
        saved = journal.annotation(run.id); saved.feedbackSharing = .ratings
        check(journal.saveAnnotation(saved, id: run.id), "allow ratings again")
        let beforeContextRequests = requests
        archive.beforeContext = {
            var value = journal.annotation(run.id); value.fatigue = .noticeable
            check(journal.saveAnnotation(value, id: run.id), "edit during HealthKit input preparation")
        }
        await store.generate(archive: archive, journal: journal, force: true)
        check(requests == beforeContextRequests, "stale data is stopped before network send")
        includeReview = false
        let beforeInvalid = store.state.revisions.count
        await store.generate(archive: archive, journal: journal, force: true)
        check(store.state.revisions.count == beforeInvalid && store.errorMessage != nil, "model ignoring latest report keeps previous plan and reports error")
        includeReview = true
        await store.generate(archive: archive, journal: journal, force: true)
        check(store.current?.feedbackContext?.first?.post_run_fatigue == .noticeable && store.errorMessage == nil, "explicit retry uses latest feedback")
        var settings = store.state.configuration; settings.automatic = false
        try store.save(profile: store.state.profile, configuration: settings, key: "mock-key")
        saved = journal.annotation(run.id); saved.effort = 9
        check(journal.saveAnnotation(saved, id: run.id), "edit with automatic generation off")
        let beforeDisabled = requests
        await store.generate(archive: archive, journal: journal)
        check(requests == beforeDisabled, "automatic-off preference prevents feedback-triggered requests")
        await store.generate(archive: archive, journal: journal, force: true)
        check(requests == beforeDisabled + 1 && store.current?.feedbackContext?.first?.effort_1_to_10 == 9, "manual update still honors latest feedback")
        let reloaded = AITrainingStore(fileURL: file, service: service)
        check(reloaded.current?.profileContext == store.state.profile, "phase profile snapshot survives actual store restore")
        check(reloaded.current?.feedbackContext == store.current?.feedbackContext, "feedback evidence survives actual store cold restore")
        check(!TrainingFeedback.stale(snapshot: store.current?.feedbackContext, activities: [run], journal: journal.data, now: .now, calendar: calendar), "latest accepted plan no longer shown as stale")
        print("PASS: \(checks) real AITrainingStore feedback integration checks; fake OS/HealthKit and HTTP only")
    }
}
