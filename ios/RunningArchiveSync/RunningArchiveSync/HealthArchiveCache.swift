import Foundation
import SwiftData

@Model
final class CachedHealthWorkout {
    @Attribute(.unique) var workoutID: String
    @Attribute(.externalStorage) var payloadData: Data
    var cachedAt: Date

    init(workoutID: String, payloadData: Data, cachedAt: Date = .now) {
        self.workoutID = workoutID
        self.payloadData = payloadData
        self.cachedAt = cachedAt
    }
}

@Model
final class CachedHealthRoute {
    @Attribute(.unique) var workoutID: String
    @Attribute(.externalStorage) var summaryData: Data
    var hasRoute: Bool
    var cachedAt: Date

    init(workoutID: String, summaryData: Data, hasRoute: Bool, cachedAt: Date = .now) {
        self.workoutID = workoutID
        self.summaryData = summaryData
        self.hasRoute = hasRoute
        self.cachedAt = cachedAt
    }
}

/// Compact derived state; kept separately from the full, immutable HealthKit payloads.
@Model
final class CachedArchiveState {
    @Attribute(.unique) var key: String
    @Attribute(.externalStorage) var data: Data
    var cachedAt: Date

    init(key: String, data: Data, cachedAt: Date = .now) {
        self.key = key
        self.data = data
        self.cachedAt = cachedAt
    }
}

@MainActor
final class HealthArchiveCache {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(context: ModelContext) {
        self.context = context
    }

    func overview() throws -> ArchiveOverviewSnapshot? {
        guard let record = try stateRecord(key: "overview-v1") else { return nil }
        return try decoder.decode(ArchiveOverviewSnapshot.self, from: record.data)
    }

    func save(overview: ArchiveOverviewSnapshot) throws {
        try saveState(key: "overview-v1", data: encoder.encode(overview))
    }

    func metrics(id: String, newerThan cutoff: Date?) throws -> WorkoutMetricPresentation? {
        guard let record = try stateRecord(key: "metrics-v1:" + id),
              cutoff == nil || record.cachedAt >= cutoff! else { return nil }
        return try decoder.decode(WorkoutMetricPresentation.self, from: record.data)
    }

    func save(metrics: WorkoutMetricPresentation, id: String) throws {
        try saveState(key: "metrics-v1:" + id, data: encoder.encode(metrics))
    }

    private func stateRecord(key: String) throws -> CachedArchiveState? {
        let target = key
        var descriptor = FetchDescriptor<CachedArchiveState>(predicate: #Predicate { $0.key == target })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func saveState(key: String, data: Data) throws {
        if let record = try stateRecord(key: key) {
            record.data = data
            record.cachedAt = .now
        } else { context.insert(CachedArchiveState(key: key, data: data)) }
        try context.save()
    }

    func workoutPayload(id: String, newerThan cutoff: Date? = nil) throws -> WorkoutPayload? {
        guard let record = try workoutRecord(id: id) else { return nil }
        if let cutoff, record.cachedAt < cutoff { return nil }
        return try decoder.decode(WorkoutPayload.self, from: record.payloadData)
    }

    func save(payload: WorkoutPayload) throws {
        let data = try encoder.encode(payload)
        if let record = try workoutRecord(id: payload.id) {
            record.payloadData = data
            record.cachedAt = .now
        } else {
            context.insert(CachedHealthWorkout(workoutID: payload.id, payloadData: data))
        }
        try context.save()
    }

    func routeState(id: String) throws -> (scanned: Bool, summary: ArchiveRouteSummary?) {
        guard let record = try routeRecord(id: id) else { return (false, nil) }
        guard record.hasRoute else { return (true, nil) }
        return (true, try decoder.decode(ArchiveRouteSummary.self, from: record.summaryData))
    }

    func allRouteSummaries() throws -> [ArchiveRouteSummary] {
        let descriptor = FetchDescriptor<CachedHealthRoute>(
            predicate: #Predicate { $0.hasRoute == true },
            sortBy: [SortDescriptor(\CachedHealthRoute.cachedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap {
            try? decoder.decode(ArchiveRouteSummary.self, from: $0.summaryData)
        }
    }

    func saveRoute(id: String, summary: ArchiveRouteSummary?) throws {
        let data = try summary.map(encoder.encode) ?? Data()
        if let record = try routeRecord(id: id) {
            record.summaryData = data
            record.hasRoute = summary != nil
            record.cachedAt = .now
        } else {
            context.insert(CachedHealthRoute(
                workoutID: id,
                summaryData: data,
                hasRoute: summary != nil
            ))
        }
        try context.save()
    }

    private func workoutRecord(id: String) throws -> CachedHealthWorkout? {
        let target = id
        var descriptor = FetchDescriptor<CachedHealthWorkout>(
            predicate: #Predicate { $0.workoutID == target }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func routeRecord(id: String) throws -> CachedHealthRoute? {
        let target = id
        var descriptor = FetchDescriptor<CachedHealthRoute>(
            predicate: #Predicate { $0.workoutID == target }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
