import Foundation
import Combine

// Personal annotations are stored separately from HealthKit's immutable source records.
enum TrainingKind: String, Codable, CaseIterable, Identifiable {
    case unspecified = "未分类", easy = "轻松跑", recovery = "恢复跑", tempo = "节奏跑"
    case intervals = "间歇跑", long = "长距离", race = "比赛"
    var id: Self { self }
}

struct RunAnnotation: Codable, Equatable {
    var kind: TrainingKind = .unspecified
    var effort: Int?
    var note = ""
    var favoriteRoute = false
    var routeName = ""
    var excludeFromRecords = false
}

struct RaceGoal: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var date: Date
    var distanceKm: Double
    var targetSeconds: Double?
    var note = ""
    var targetPace: String { targetSeconds.map { TrainingFormat.pace($0 / distanceKm) } ?? "未设置" }
    func daysRemaining(now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}

struct PlannedRun: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var date: Date
    var kind: TrainingKind = .easy
    var distanceKm: Double
    var paceMin: Double?
    var paceMax: Double?
    var note = ""
    var activityID: String?

    func completion(activity: ArchiveActivity?) -> PlanCompletion {
        guard activityID != nil else { return .unlinked }
        guard let activity else { return .missing }
        let ratio = distanceKm > 0 ? activity.distanceKm / distanceKm : 0
        let seconds = TrainingFormat.seconds(activity.duration)
        let pace = activity.distanceKm > 0 ? seconds / activity.distanceKm : 0
        let intensity: Bool? = paceMin.flatMap { lower in
            guard let upper = paceMax, pace > 0 else { return nil }
            return lower...upper ~= pace
        }
        return .linked(distanceRatio: ratio, paceInRange: intensity)
    }
}

enum PlanCompletion: Equatable {
    case unlinked, missing
    case linked(distanceRatio: Double, paceInRange: Bool?)
}

enum RecordDistance: String, Codable, CaseIterable, Identifiable {
    case five = "5K", ten = "10K", half = "半马", marathon = "全马"
    var id: Self { self }
    var km: Double {
        switch self { case .five: 5; case .ten: 10; case .half: 21.0975; case .marathon: 42.195 }
    }
    var wholeRunRange: ClosedRange<Double> { km...(km * 1.03) }
}

struct DistanceEffort: Codable, Identifiable, Equatable {
    var distance: RecordDistance
    var seconds: Double
    var startElapsed: Double
    var endElapsed: Double
    var id: String { distance.rawValue }
}

struct EffortAnalysis: Codable {
    var analyzedAt: Date
    var efforts: [DistanceEffort]
}

struct JournalData: Codable {
    var version = 1
    var annotations: [String: RunAnnotation] = [:]
    // Symmetric pair overrides: true includes, false excludes, absence uses geometry.
    var routeOverrides: [String: Bool] = [:]
    var races: [RaceGoal] = []
    var plans: [PlannedRun] = []
    var analyses: [String: EffortAnalysis] = [:]
}

enum JournalError: LocalizedError {
    case invalidInput(String), unreadable, noRoute
    var errorDescription: String? {
        switch self {
        case .invalidInput(let text): text
        case .unreadable: "本机训练手记暂时无法读取，已保留原文件。请重试或先备份文件后检查，避免覆盖已有内容。"
        case .noRoute: "这条记录没有可导出的原始路线。"
        }
    }
}

@MainActor
final class TrainingJournal: ObservableObject {
    @Published private(set) var data = JournalData()
    @Published var errorMessage: String?
    private let fileURL: URL
    private var readable = true

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupportDirectory
            .appending(path: "RunningArchive", directoryHint: .isDirectory)
            .appending(path: "training-journal-v1.json")
        reload()
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let decoded = try JSONDecoder().decode(JournalData.self, from: Data(contentsOf: fileURL))
                guard decoded.version == 1 else { throw JournalError.unreadable }
                data = decoded
            }
            readable = true
            errorMessage = nil
        } catch {
            readable = false
            errorMessage = JournalError.unreadable.localizedDescription
        }
    }

    func annotation(_ id: String) -> RunAnnotation { data.annotations[id] ?? RunAnnotation() }
    func routeName(_ activity: ArchiveActivity) -> String {
        let name = annotation(activity.id).routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? activity.name : name
    }
    static func pairKey(_ a: String, _ b: String) -> String { [a, b].sorted().joined(separator: "|") }
    func override(_ a: String, _ b: String) -> Bool? { data.routeOverrides[Self.pairKey(a, b)] }

    @discardableResult func saveAnnotation(_ value: RunAnnotation, id: String) -> Bool {
        guard value.effort == nil || (1...10).contains(value.effort!) else { return reject("体感请输入 1–10。") }
        var cleaned = value
        cleaned.note = String(value.note.prefix(2000))
        cleaned.routeName = String(value.routeName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return commit { $0.annotations[id] = cleaned }
    }
    @discardableResult func setOverride(_ value: Bool?, a: String, b: String) -> Bool {
        commit { $0.routeOverrides[Self.pairKey(a, b)] = value }
    }
    @discardableResult func saveRace(_ value: RaceGoal) -> Bool {
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.distanceKm.isFinite, (0.1...300).contains(value.distanceKm),
              value.targetSeconds == nil || (value.targetSeconds!.isFinite && (60...604800).contains(value.targetSeconds!)) else {
            return reject("请填写赛事名称、有效距离与目标用时。")
        }
        return commit { state in
            state.races.removeAll { $0.id == value.id }; state.races.append(value)
        }
    }
    @discardableResult func deleteRace(_ id: String) -> Bool { commit { $0.races.removeAll { $0.id == id } } }
    @discardableResult func savePlan(_ value: PlannedRun) -> Bool {
        guard value.distanceKm.isFinite, (0.1...300).contains(value.distanceKm),
              (value.paceMin == nil && value.paceMax == nil) ||
                (value.paceMin != nil && value.paceMax != nil && (120...1800).contains(value.paceMin!) && (value.paceMin!...1800).contains(value.paceMax!)) else {
            return reject("距离需为 0.1–300 km；目标配速需为 2:00–30:00，最快配速不能大于最慢配速。")
        }
        if let id = value.activityID, data.plans.contains(where: { $0.id != value.id && $0.activityID == id }) {
            return reject("这次跑步已经关联另一项计划，请先解除原关联。")
        }
        return commit { state in state.plans.removeAll { $0.id == value.id }; state.plans.append(value) }
    }
    @discardableResult func deletePlan(_ id: String) -> Bool { commit { $0.plans.removeAll { $0.id == id } } }
    @discardableResult func saveAnalysis(_ efforts: [DistanceEffort], id: String) -> Bool {
        commit { $0.analyses[id] = EffortAnalysis(analyzedAt: .now, efforts: efforts) }
    }
    private func reject(_ message: String) -> Bool { errorMessage = message; return false }
    private func commit(_ change: (inout JournalData) -> Void) -> Bool {
        guard readable else { return reject(JournalError.unreadable.localizedDescription) }
        var next = data
        change(&next)
        do {
            let bytes = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: fileURL, options: .atomic)
            data = next
            errorMessage = nil
            return true
        } catch { return reject("保存失败，内容尚未保存：\(error.localizedDescription)") }
    }
}

enum TrainingFormat {
    static func seconds(_ duration: String) -> Double {
        let parts = duration.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
    static func pace(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "—" }
        let n = Int(seconds.rounded())
        return String(format: "%d′%02d″", n / 60, n % 60)
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "—" }
        let n = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
    }
    static func decimal(_ value: String) -> Double? { Double(value.replacingOccurrences(of: ",", with: ".")) }
    static func parsePace(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]),
              m.isFinite, s.isFinite, m >= 0, s >= 0, s < 60 else { return nil }
        return m * 60 + s
    }
}

struct GeoPoint: Sendable {
    var latitude: Double
    var longitude: Double
    var valid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
    func meters(to b: Self) -> Double {
        let aLat = latitude * .pi / 180, bLat = b.latitude * .pi / 180
        let lat = (b.latitude - latitude) * .pi / 180, lon = (b.longitude - longitude) * .pi / 180
        let h = pow(sin(lat / 2), 2) + cos(aLat) * cos(bLat) * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

enum RouteMatcher {
    static func signature(_ coordinates: [[Double]], count: Int = 40) -> [GeoPoint] {
        let points = coordinates.compactMap { pair -> GeoPoint? in
            guard pair.count >= 2 else { return nil }
            let p = GeoPoint(latitude: pair[1], longitude: pair[0]); return p.valid ? p : nil
        }
        guard points.count > 1, count > 1 else { return [] }
        var distances = [0.0]
        for i in 1..<points.count { distances.append(distances[i-1] + points[i-1].meters(to: points[i])) }
        guard let total = distances.last, total > 100 else { return [] }
        var cursor = 1
        return (0..<count).map { i in
            let target = total * Double(i) / Double(count - 1)
            while cursor < points.count - 1 && distances[cursor] < target { cursor += 1 }
            let span = distances[cursor] - distances[cursor - 1]
            let t = span > 0 ? (target - distances[cursor - 1]) / span : 0
            let a = points[cursor - 1], b = points[cursor]
            return GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
        }
    }
    static func matches(_ a: ArchiveRouteSummary, _ b: ArchiveRouteSummary) -> Bool {
        guard a.distanceKm > 0, b.distanceKm > 0,
              abs(a.distanceKm - b.distanceKm) / max(a.distanceKm, b.distanceKm) <= 0.08 else { return false }
        let lhs = signature(a.previewCoordinates), rhs = signature(b.previewCoordinates)
        guard lhs.count == rhs.count, lhs.count > 1,
              lhs[0].meters(to: rhs[0]) <= 250,
              lhs.last!.meters(to: rhs.last!) <= 250 else { return false }
        let distances = zip(lhs, rhs).map { $0.meters(to: $1) }
        return distances.reduce(0, +) / Double(distances.count) <= 130 && (distances.max() ?? .infinity) <= 350
    }
}

struct RunRecord: Identifiable {
    var activity: ArchiveActivity
    var seconds: Double
    var id: String { activity.id }
    static func history(activities: [ArchiveActivity], category: RecordDistance, gps: Bool, journal: JournalData, year: Int? = nil) -> [Self] {
        activities.compactMap { a in
            guard a.date <= .now, !((journal.annotations[a.id]?.excludeFromRecords) ?? false),
                  year == nil || Calendar.current.component(.year, from: a.date) == year else { return nil }
            if gps {
                guard let effort = journal.analyses[a.id]?.efforts.first(where: { $0.distance == category }) else { return nil }
                return Self(activity: a, seconds: effort.seconds)
            }
            let duration = TrainingFormat.seconds(a.duration)
            guard category.wholeRunRange.contains(a.distanceKm), duration > 0 else { return nil }
            return Self(activity: a, seconds: duration)
        }.sorted { $0.activity.date == $1.activity.date ? $0.id < $1.id : $0.activity.date < $1.activity.date }
    }
    static func breakthroughs(_ records: [Self]) -> Set<String> {
        var best = Double.infinity
        return Set(records.compactMap { r in
            guard r.seconds < best else { return nil }; best = r.seconds; return r.id
        })
    }
}

// GPS estimates use raw WGS-84 points, never chart samples or whole-run mean pace.
// Elapsed time includes pauses. Missing GPS gaps/jumps split independent segments.
enum BestEffortAnalyzer {
    private struct Sample { var distance: Double; var elapsed: Double }
    static func analyze(points: [RoutePointPayload], start: Date) -> [DistanceEffort] {
        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        var segments: [[Sample]] = []
        var current: [Sample] = []
        var previous: RoutePointPayload?
        for p in ordered {
            let geo = GeoPoint(latitude: p.latitude, longitude: p.longitude)
            guard geo.valid, p.timestamp.timeIntervalSince(start).isFinite else {
                if current.count > 1 { segments.append(current) }; current = []; previous = nil; continue
            }
            let elapsed = p.timestamp.timeIntervalSince(start)
            if let prev = previous {
                let dt = p.timestamp.timeIntervalSince(prev.timestamp)
                let meters = geo.meters(to: GeoPoint(latitude: prev.latitude, longitude: prev.longitude))
                if dt <= 0 { continue }
                if dt > 30 || meters / dt > 12 {
                    if current.count > 1 { segments.append(current) }; current = []
                }
                current.append(Sample(distance: (current.last?.distance ?? -meters) + meters, elapsed: elapsed))
            } else { current.append(Sample(distance: 0, elapsed: elapsed)) }
            previous = p
        }
        if current.count > 1 { segments.append(current) }
        return RecordDistance.allCases.compactMap { category in
            var best: DistanceEffort?
            let target = category.km * 1000
            func consider(_ begin: Double, _ end: Double) {
                let seconds = end - begin
                guard seconds > 0, best == nil || seconds < best!.seconds else { return }
                best = DistanceEffort(distance: category, seconds: seconds, startElapsed: begin, endElapsed: end)
            }
            for segment in segments where (segment.last?.distance ?? 0) >= target {
                var right = 1
                // Minimum of a piecewise linear elapsed/distance window lies at a start or end vertex.
                for left in segment.indices {
                    let endDistance = segment[left].distance + target
                    while right < segment.count && segment[right].distance < endDistance { right += 1 }
                    guard right < segment.count else { break }
                    let a = segment[right - 1], b = segment[right]
                    guard b.distance > a.distance else { continue }
                    let end = a.elapsed + (b.elapsed - a.elapsed) * (endDistance - a.distance) / (b.distance - a.distance)
                    consider(segment[left].elapsed, end)
                }
                var left = 0
                for right in segment.indices where segment[right].distance >= target {
                    let startDistance = segment[right].distance - target
                    while left + 1 < right && segment[left + 1].distance <= startDistance { left += 1 }
                    let a = segment[left], b = segment[left + 1]
                    guard b.distance > a.distance else { continue }
                    let begin = a.elapsed + (b.elapsed - a.elapsed) * (startDistance - a.distance) / (b.distance - a.distance)
                    consider(begin, segment[right].elapsed)
                }
            }
            return best
        }
    }
}

enum GPXExporter {
    static func document(name: String, points: [RoutePointPayload]) throws -> String {
        let valid = points.filter { GeoPoint(latitude: $0.latitude, longitude: $0.longitude).valid && $0.timestamp.timeIntervalSince1970.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        guard valid.count > 1 else { throw JournalError.noRoute }
        let formatter = ISO8601DateFormatter()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Running Archive\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(escape(name))</name><trkseg>\n"
        var previous: Date?
        for p in valid {
            if let previous, p.timestamp.timeIntervalSince(previous) > 120 { xml += "</trkseg><trkseg>\n" }
            let lat = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), p.latitude)
            let lon = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), p.longitude)
            xml += "<trkpt lat=\"\(lat)\" lon=\"\(lon)\">"
            if p.altitude.isFinite { xml += "<ele>\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), p.altitude))</ele>" }
            xml += "<time>\(formatter.string(from: p.timestamp))</time></trkpt>\n"
            previous = p.timestamp
        }
        return xml + "</trkseg></trk></gpx>\n"
    }
    private static func escape(_ value: String) -> String {
        let cleaned = String(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        })
        return cleaned.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
