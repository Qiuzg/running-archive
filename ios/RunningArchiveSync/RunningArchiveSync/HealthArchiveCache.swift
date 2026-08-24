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

@MainActor
final class HealthArchiveCache {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(context: ModelContext) {
        self.context = context
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
