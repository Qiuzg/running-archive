import CoreLocation
import Foundation
import SwiftData

enum LocalArchiveError: LocalizedError {
    case workoutUnavailable
    case imageRenderFailed

    var errorDescription: String? {
        switch self {
        case .workoutUnavailable: return "无法从 Apple Health 读取这条跑步"
        case .imageRenderFailed: return "分享图片生成失败"
        }
    }
}

@MainActor
final class ArchiveStore: ObservableObject {
    @Published var summary: ArchiveSummary?
    @Published var routes: [ArchiveRouteSummary] = []
    @Published var activities: [ArchiveActivity] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var routeScanStatus: String?

    private let health = HealthKitService()
    private var cache: HealthArchiveCache?
    private var detailCache: [String: ArchiveRouteDetail] = [:]
    private var routeScanTask: Task<Void, Never>?

    func configureCache(_ context: ModelContext) {
        if cache == nil { cache = HealthArchiveCache(context: context) }
    }

    func load(force: Bool = false) async {
        if isLoading || (!force && summary != nil && !activities.isEmpty) { return }
        isLoading = true
        errorMessage = nil
        do {
            try await health.requestAuthorization()
            let previews = try await health.runningWorkoutPreviews()
            let marathonPB = fastest(in: previews, distance: 41...44)
            let halfPB = fastest(in: previews, distance: 20...23)
            let pbIDs = Set([marathonPB?.id, halfPB?.id].compactMap { $0 })

            activities = previews.map { ArchiveActivity(preview: $0, isPb: pbIDs.contains($0.id)) }
            summary = makeSummary(previews: previews, marathonPB: marathonPB, halfPB: halfPB)

            if let cache {
                let activeIDs = Set(previews.map(\.id))
                routes = try cache.allRouteSummaries().filter { activeIDs.contains($0.id) }
                sortRoutes()
            }
            isLoading = false
            startRouteScan(for: activities)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func routeDetail(id: String) async throws -> ArchiveRouteDetail {
        if let detail = detailCache[id] { return detail }

        let activity = activities.first { $0.id == id }
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let cacheCutoff = (activity?.date ?? .distantPast) > recentCutoff
            ? Date.now.addingTimeInterval(-6 * 60 * 60)
            : nil
        let payload: WorkoutPayload
        if let cached = try cache?.workoutPayload(id: id, newerThan: cacheCutoff) {
            payload = cached
        } else {
            guard let loaded = try await health.payload(forWorkoutID: id) else {
                throw LocalArchiveError.workoutUnavailable
            }
            payload = loaded
            try cache?.save(payload: loaded)
        }

        let detail = makeDetail(payload: payload, name: activity?.name ?? payload.name)
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index] = ArchiveActivity(activity: activities[index], payload: payload)
        }
        detailCache[id] = detail
        let route = makeRouteSummary(
            id: id,
            name: activity?.name ?? payload.name,
            distanceKm: payload.distanceKm,
            points: payload.routePoints
        )
        try cache?.saveRoute(id: id, summary: route)
        if let route { upsertRoute(route) }
        return detail
    }

    func routeSummary(id: String?) -> ArchiveRouteSummary? {
        guard let id else { return nil }
        return routes.first { $0.id == id }
    }

    private func startRouteScan(for activities: [ArchiveActivity]) {
        routeScanTask?.cancel()
        routeScanTask = Task { [weak self] in
            await self?.warmRoutePreviews(activities)
        }
    }

    private func warmRoutePreviews(_ candidates: [ArchiveActivity]) async {
        guard let cache else { return }
        var remaining = 0
        for activity in candidates {
            if (try? cache.routeState(id: activity.id).scanned) != true { remaining += 1 }
        }
        guard remaining > 0 else { routeScanStatus = nil; return }

        var completed = 0
        for activity in candidates {
            if Task.isCancelled { return }
            do {
                let state = try cache.routeState(id: activity.id)
                if state.scanned {
                    if let summary = state.summary { upsertRoute(summary) }
                    continue
                }
                routeScanStatus = "正在整理 Apple Health 路线 \(completed + 1)/\(remaining)"
                let points = try await health.routePoints(forWorkoutID: activity.id) ?? []
                let summary = makeRouteSummary(
                    id: activity.id,
                    name: activity.name,
                    distanceKm: activity.distanceKm,
                    points: points
                )
                let recentCutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
                let isRecent = activity.date > recentCutoff
                if summary != nil || !isRecent {
                    try cache.saveRoute(id: activity.id, summary: summary)
                }
                if let summary { upsertRoute(summary) }
                completed += 1
            } catch {
                // Keep this workout unmarked so a later launch can retry it.
                completed += 1
            }
        }
        routeScanStatus = nil
    }

    private func makeSummary(
        previews: [WorkoutPreview],
        marathonPB: WorkoutPreview?,
        halfPB: WorkoutPreview?
    ) -> ArchiveSummary {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: .now)
        let races = previews.filter { isMorningRace($0) }
        return ArchiveSummary(
            totalDistanceKm: previews.reduce(0) { $0 + $1.distanceKm },
            yearlyDistanceKm: previews.filter {
                calendar.component(.year, from: $0.date) == currentYear
            }.reduce(0) { $0 + $1.distanceKm },
            marathonPb: marathonPB.map { durationText($0.duration) },
            marathonPbName: nil,
            halfMarathonPb: halfPB.map { durationText($0.duration) },
            halfMarathonPbName: nil,
            raceCount: races.count,
            marathonCount: races.filter { 41...44 ~= $0.distanceKm }.count
        )
    }

    private func fastest(in previews: [WorkoutPreview], distance: ClosedRange<Double>) -> WorkoutPreview? {
        previews.filter { distance.contains($0.distanceKm) && isMorning($0.date) }
            .min { $0.duration < $1.duration }
    }

    private func isMorningRace(_ preview: WorkoutPreview) -> Bool {
        ((41...44 ~= preview.distanceKm) || (20...23 ~= preview.distanceKm)) && isMorning(preview.date)
    }

    private func isMorning(_ date: Date) -> Bool {
        Calendar.current.component(.hour, from: date) < 12
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private func makeRouteSummary(
        id: String,
        name: String,
        distanceKm: Double,
        points: [RoutePointPayload]
    ) -> ArchiveRouteSummary? {
        guard points.count > 1 else { return nil }
        let sampled = sample(points: points, limit: 300)
        return ArchiveRouteSummary(
            id: id,
            name: name,
            city: "",
            distanceKm: distanceKm,
            elevationGain: elevationGain(points.map(\.altitude)),
            previewCoordinates: sampled.map { [$0.longitude, $0.latitude] }
        )
    }

    private func makeDetail(payload: WorkoutPayload, name: String) -> ArchiveRouteDetail {
        let points = payload.routePoints.sorted { $0.timestamp < $1.timestamp }
        let elapsed = points.map { max(0, $0.timestamp.timeIntervalSince(payload.startDate)) }
        let pace = points.enumerated().map { index, point -> Double? in
            var speed = point.speedMps
            if (speed ?? 0) <= 0.4, index > 0 {
                let previous = points[index - 1]
                let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
                if seconds > 0 {
                    let start = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    let end = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    speed = end.distance(from: start) / seconds
                }
            }
            guard let speed, speed > 0.4 else { return nil }
            let value = 1000 / speed / 60
            return (2...30).contains(value) ? value : nil
        }
        let heart = payload.heartRateSamples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        let series = ArchiveTimeSeries(
            elapsed: elapsed,
            pace: pace,
            elevation: points.map(\.altitude),
            heartRate: heart.map(\.value),
            heartRateElapsed: heart.map(\.elapsedSeconds)
        )
        return ArchiveRouteDetail(
            id: payload.id,
            name: name,
            city: payload.city,
            distanceKm: payload.distanceKm,
            elevationGain: elevationGain(points.map(\.altitude)),
            previewCoordinates: sample(points: points, limit: 300).map { [$0.longitude, $0.latitude] },
            coordinates: points.map { [$0.longitude, $0.latitude] },
            elevations: points.map(\.altitude),
            timeSeries: series
        )
    }

    private func sample(points: [RoutePointPayload], limit: Int) -> [RoutePointPayload] {
        guard points.count > limit, limit > 1 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }

    private func elevationGain(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        return values.dropFirst().enumerated().reduce(0) { result, pair in
            let change = pair.element - values[pair.offset]
            return result + ((0.2...30).contains(change) ? change : 0)
        }
    }

    private func upsertRoute(_ route: ArchiveRouteSummary) {
        routes.removeAll { $0.id == route.id }
        routes.append(route)
        sortRoutes()
    }

    private func sortRoutes() {
        let order = Dictionary(uniqueKeysWithValues: activities.enumerated().map { ($1.id, $0) })
        routes.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }
}
