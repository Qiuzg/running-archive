import CoreLocation
import Foundation

struct ArchiveSummary: Decodable {
    let totalDistanceKm: Double
    let yearlyDistanceKm: Double
    let marathonPb: String?
    let marathonPbName: String?
    let halfMarathonPb: String?
    let halfMarathonPbName: String?
    let raceCount: Int
    let marathonCount: Int
}

struct ArchiveRouteSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let city: String
    let distanceKm: Double
    let elevationGain: Double
    let previewCoordinates: [[Double]]

    var coordinates: [CLLocationCoordinate2D] {
        previewCoordinates.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ArchiveRouteDetail: Decodable, Identifiable {
    let id: String
    let name: String
    let city: String
    let distanceKm: Double
    let elevationGain: Double
    let previewCoordinates: [[Double]]
    let coordinates: [[Double]]
    let elevations: [Double]
    let timeSeries: ArchiveTimeSeries?

    var mapCoordinates: [CLLocationCoordinate2D] {
        coordinates.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }
}

struct ArchiveTimeSeries: Decodable {
    let elapsed: [Double]
    let pace: [Double?]
    let elevation: [Double]
    let heartRate: [Double]
    let heartRateElapsed: [Double]?

    enum CodingKeys: String, CodingKey {
        case elapsed, pace, elevation, heartRate, heartRateElapsed
        case heartRateSnake = "heart_rate"
        case heartRateElapsedSnake = "heart_rate_elapsed"
    }

    init(
        elapsed: [Double],
        pace: [Double?],
        elevation: [Double],
        heartRate: [Double],
        heartRateElapsed: [Double]?
    ) {
        self.elapsed = elapsed
        self.pace = pace
        self.elevation = elevation
        self.heartRate = heartRate
        self.heartRateElapsed = heartRateElapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        elapsed = try container.decodeIfPresent([Double].self, forKey: .elapsed) ?? []
        pace = try container.decodeIfPresent([Double?].self, forKey: .pace) ?? []
        elevation = try container.decodeIfPresent([Double].self, forKey: .elevation) ?? []
        heartRate = try container.decodeIfPresent([Double].self, forKey: .heartRate)
            ?? container.decodeIfPresent([Double].self, forKey: .heartRateSnake)
            ?? []
        heartRateElapsed = try container.decodeIfPresent([Double].self, forKey: .heartRateElapsed)
            ?? container.decodeIfPresent([Double].self, forKey: .heartRateElapsedSnake)
    }
}

struct ArchiveRun: Decodable, Identifiable {
    let id: String
    let name: String
    let date: Date
    let city: String?
    let distanceKm: Double
    let duration: String
    let pace: String
    let routeId: String?
    let avgHeartRate: Int?
    let avgPower: Double?
}

struct ArchiveRace: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
    let date: Date
    let city: String
    let country: String
    let distanceKm: Double
    let finishTime: String
    let pace: String
    let bibNumber: String
    let isPb: Bool
    let routeId: String?
    let notes: String
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let avgPower: Double?
}

struct ArchiveActivity: Identifiable, Hashable {
    enum Kind: String { case run, race }

    let id: String
    let kind: Kind
    let name: String
    let date: Date
    let city: String
    let distanceKm: Double
    let duration: String
    let pace: String
    let routeId: String?
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let avgPower: Double?
    let isPb: Bool

    init(run: ArchiveRun) {
        id = run.id
        kind = .run
        name = run.name.isEmpty ? "户外跑步" : run.name
        date = run.date
        city = run.city ?? ""
        distanceKm = run.distanceKm
        duration = run.duration
        pace = run.pace
        routeId = run.routeId
        avgHeartRate = run.avgHeartRate
        maxHeartRate = nil
        avgPower = run.avgPower
        isPb = false
    }

    init(race: ArchiveRace) {
        id = race.id
        kind = .race
        name = race.name
        date = race.date
        city = race.city
        distanceKm = race.distanceKm
        duration = race.finishTime
        pace = race.pace
        routeId = race.routeId
        avgHeartRate = race.avgHeartRate
        maxHeartRate = race.maxHeartRate
        avgPower = race.avgPower
        isPb = race.isPb
    }

    init(preview: WorkoutPreview, isPb: Bool = false) {
        id = preview.id
        let morning = Calendar.current.component(.hour, from: preview.date) < 12
        let marathon = (41.0...44.0).contains(preview.distanceKm) && morning
        let halfMarathon = (20.0...23.0).contains(preview.distanceKm) && morning
        kind = (marathon || halfMarathon) ? .race : .run
        name = marathon ? "全程马拉松" : (halfMarathon ? "半程马拉松" : "户外跑步")
        date = preview.date
        city = ""
        distanceKm = preview.distanceKm
        duration = Self.durationText(preview.duration)
        pace = Self.paceText(distanceKm: preview.distanceKm, duration: preview.duration)
        routeId = preview.id
        avgHeartRate = preview.avgHeartRate
        maxHeartRate = preview.maxHeartRate
        avgPower = preview.avgPower
        self.isPb = isPb
    }

    init(activity: ArchiveActivity, payload: WorkoutPayload) {
        id = activity.id
        kind = activity.kind
        name = activity.name
        date = activity.date
        city = activity.city
        distanceKm = activity.distanceKm
        duration = activity.duration
        pace = activity.pace
        routeId = activity.routeId
        avgHeartRate = payload.avgHeartRate ?? activity.avgHeartRate
        maxHeartRate = payload.maxHeartRate ?? activity.maxHeartRate
        avgPower = payload.avgPower ?? activity.avgPower
        isPb = activity.isPb
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func paceText(distanceKm: Double, duration: TimeInterval) -> String {
        guard distanceKm > 0 else { return "--" }
        let seconds = max(0, Int((duration / distanceKm).rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

extension DateFormatter {
    static let archiveDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
