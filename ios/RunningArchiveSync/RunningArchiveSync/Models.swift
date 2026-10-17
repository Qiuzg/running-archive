import Foundation

struct RoutePointPayload: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speedMps: Double?
}

struct MetricSamplePayload: Codable {
    let elapsedSeconds: Double
    let value: Double
}

struct WorkoutIntervalPayload: Codable {
    let index: Int
    let kind: String
    let activityType: Int?
    let startElapsedSeconds: Double
    let endElapsedSeconds: Double
    let durationSeconds: Double
    let distanceKm: Double?
    let paceSecondsPerKm: Double?
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let avgCadence: Double?
    let avgPower: Double?
    let eventType: String?
    let label: String?
}

struct WorkoutPayload: Codable, Identifiable {
    let id: String
    let name: String
    let startDate: Date
    let distanceKm: Double
    let durationSeconds: Double
    let city: String
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let avgCadence: Double?
    let avgPower: Double?
    let routePoints: [RoutePointPayload]
    let heartRateSamples: [MetricSamplePayload]
    let runningSpeedSamples: [MetricSamplePayload]?
    // Optional keeps payloads cached by older app versions decodable.
    let intervals: [WorkoutIntervalPayload]?
}

struct SyncRequest: Codable {
    let workouts: [WorkoutPayload]
}

struct SyncResult: Codable {
    let id: String
    let status: String
    let routePoints: Int
}

struct SyncResponse: Codable {
    let synced: [SyncResult]
}

struct WorkoutPreview: Identifiable {
    let id: String
    let date: Date
    let distanceKm: Double
    let duration: TimeInterval
    let avgHeartRate: Int?
    let maxHeartRate: Int?
    let avgPower: Double?
    var avgCadence: Double? = nil
}

enum RunningArchiveConfiguration {
    static let defaultServerURL = "https://123.56.181.123/run"
}
