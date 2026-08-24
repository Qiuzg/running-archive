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

struct ArchiveRouteSummary: Decodable, Identifiable, Hashable {
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
}

extension DateFormatter {
    static let archiveDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
