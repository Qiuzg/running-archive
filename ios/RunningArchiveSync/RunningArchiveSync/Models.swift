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
}

enum RunningArchiveConfiguration {
    static let defaultServerURL = "https://123.56.181.123/run"
}
