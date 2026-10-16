import CoreLocation
import Foundation
import SwiftData

enum LocalArchiveError: LocalizedError {
    case workoutUnavailable
    case imageRenderFailed
    case mapRenderFailed
    case routeUnavailable
    case cartoConfigurationMissing

    var errorDescription: String? {
        switch self {
        case .workoutUnavailable: return "无法从 Apple Health 读取这条跑步"
        case .imageRenderFailed: return "分享图片生成失败"
        case .mapRenderFailed: return "地图未完整加载，请检查网络或切换地图源后重试"
        case .routeUnavailable: return "这条跑步没有可用的路线，无法生成路线分享图"
        case .cartoConfigurationMissing: return "Leaflet 的 CARTO API Key 未配置，无法生成正确的地图风格"
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
    private var routeLookup: [String: ArchiveRouteSummary] = [:]
    private var routeScanTask: Task<Void, Never>?

    private let chartPointLimit = 480
    private let detailMapPointLimit = 900

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
                setRoutes(orderedRoutes(try cache.allRouteSummaries().filter { activeIDs.contains($0.id) }))
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
        if let cached = try cache?.workoutPayload(id: id, newerThan: cacheCutoff),
           cached.runningSpeedSamples != nil {
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
        return routeLookup[id]
    }

    /// Raw WGS-84 samples for GPX and distance efforts; never use reduced display points.
    func fullRoutePoints(id: String) async throws -> [RoutePointPayload] {
        let activity = activities.first { $0.id == id }
        let recent = (activity?.date ?? .distantPast) > Date.now.addingTimeInterval(-7 * 86400)
        let cutoff = recent ? Date.now.addingTimeInterval(-6 * 3600) : nil
        if let payload = try cache?.workoutPayload(id: id, newerThan: cutoff), !payload.routePoints.isEmpty {
            return payload.routePoints
        }
        guard let points = try await health.routePoints(forWorkoutID: id), points.count > 1 else {
            throw JournalError.noRoute
        }
        return points
    }

    func prepareAnalysisExport() async throws {
        try await health.requestAuthorization(includeExportMetrics: true)
        // Refresh HKWorkout statistics after any newly granted read permissions.
        _ = try await health.runningWorkoutPreviews()
    }

    func exportWorkout(id: String) async throws -> ExportWorkout {
        try await health.exportWorkout(id: id)
    }

    func exportReferences(start: Date, end: Date) async throws -> ExportReferenceData {
        try await health.exportReferences(start: start, end: end)
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
        for (index, activity) in candidates.enumerated() {
            if (try? cache.routeState(id: activity.id).scanned) != true { remaining += 1 }
            if index % 20 == 19 { await Task.yield() }
        }
        guard remaining > 0 else { routeScanStatus = nil; return }

        var completed = 0
        var discovered = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        for activity in candidates {
            if Task.isCancelled { return }
            do {
                let state = try cache.routeState(id: activity.id)
                if state.scanned {
                    if let summary = state.summary { discovered[summary.id] = summary }
                    completed += 1
                    if completed % 20 == 0 { await Task.yield() }
                    continue
                }
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
                if let summary { discovered[summary.id] = summary }
                completed += 1

                // Do not publish and rebuild the overview map for every HealthKit route.
                // Larger batches reduce main-thread overlay churn while preserving progress.
                if completed == 1 || completed % 16 == 0 {
                    setRoutes(orderedRoutes(Array(discovered.values)))
                    routeScanStatus = "正在整理 Apple Health 路线 \(completed)/\(remaining)"
                    await Task.yield()
                }
            } catch {
                // Keep this workout unmarked so a later launch can retry it.
                completed += 1
            }
        }
        setRoutes(orderedRoutes(Array(discovered.values)))
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
        let chartPoints = sample(points: points, limit: chartPointLimit)
        let elapsed = chartPoints.map { max(0, $0.timestamp.timeIntervalSince(payload.startDate)) }
        let pace = paceValues(payload: payload, points: points, targetElapsed: elapsed)
        let heart = sample(
            items: payload.heartRateSamples.sorted { $0.elapsedSeconds < $1.elapsedSeconds },
            limit: chartPointLimit
        )
        let series = ArchiveTimeSeries(
            elapsed: elapsed,
            pace: pace,
            elevation: chartPoints.map(\.altitude),
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
            coordinates: sample(points: points, limit: detailMapPointLimit).map { [$0.longitude, $0.latitude] },
            elevations: points.map(\.altitude),
            timeSeries: series
        )
    }

    private func paceValues(
        payload: WorkoutPayload,
        points: [RoutePointPayload],
        targetElapsed: [Double]
    ) -> [Double?] {
        let routeSpeeds = rollingRouteSpeeds(
            points: points,
            workoutStart: payload.startDate,
            targetElapsed: targetElapsed
        )
        let healthSpeeds = nearestHealthSpeeds(
            samples: payload.runningSpeedSamples ?? [],
            targetElapsed: targetElapsed
        )
        let merged = zip(healthSpeeds, routeSpeeds).map { health, route in
            validRunningSpeed(health) ? health : route
        }
        return medianSmoothed(merged, radius: 2).map { speed in
            guard let speed, validRunningSpeed(speed) else { return nil }
            let minutesPerKm = 1000 / speed / 60
            return (2...30).contains(minutesPerKm) ? minutesPerKm : nil
        }
    }

    private func nearestHealthSpeeds(
        samples: [MetricSamplePayload],
        targetElapsed: [Double]
    ) -> [Double?] {
        let ordered = samples
            .filter { $0.elapsedSeconds.isFinite && validRunningSpeed($0.value) }
            .sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard !ordered.isEmpty else { return Array(repeating: nil, count: targetElapsed.count) }

        var index = 0
        return targetElapsed.map { elapsed -> Double? in
            while index + 1 < ordered.count,
                  abs(ordered[index + 1].elapsedSeconds - elapsed) <= abs(ordered[index].elapsedSeconds - elapsed) {
                index += 1
            }
            let sample = ordered[index]
            return abs(sample.elapsedSeconds - elapsed) <= 30 ? sample.value : nil
        }
    }

    private func rollingRouteSpeeds(
        points: [RoutePointPayload],
        workoutStart: Date,
        targetElapsed: [Double]
    ) -> [Double?] {
        guard points.count > 1 else { return Array(repeating: nil, count: targetElapsed.count) }
        let elapsed = points.map { max(0, $0.timestamp.timeIntervalSince(workoutStart)) }
        var cumulative = Array(repeating: 0.0, count: points.count)
        for index in 1..<points.count {
            let seconds = elapsed[index] - elapsed[index - 1]
            let distance = routeDistanceMeters(points[index - 1], points[index])
            let plausible = seconds > 0 && seconds <= 120 && distance / seconds <= 12
            cumulative[index] = cumulative[index - 1] + (plausible ? distance : 0)
        }

        return targetElapsed.map { target -> Double? in
            let duration = elapsed.last ?? target
            var start = max(0, target - 15)
            var end = min(duration, target + 15)
            if end - start < 24 {
                if start <= 0 { end = min(duration, 30) }
                else if end >= duration { start = max(0, duration - 30) }
            }
            let lower = lowerBound(elapsed, value: start)
            let upper = min(lowerBound(elapsed, value: end), elapsed.count - 1)
            guard upper > lower else { return nil }
            let seconds = elapsed[upper] - elapsed[lower]
            guard seconds > 0 else { return nil }
            let speed = (cumulative[upper] - cumulative[lower]) / seconds
            return validRunningSpeed(speed) ? speed : nil
        }
    }

    private func lowerBound(_ values: [Double], value: Double) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if values[middle] < value { lower = middle + 1 }
            else { upper = middle }
        }
        return min(lower, max(values.count - 1, 0))
    }

    private func medianSmoothed(_ values: [Double?], radius: Int) -> [Double?] {
        values.indices.map { index in
            guard values[index] != nil else { return nil }
            let lower = max(values.startIndex, index - radius)
            let upper = min(values.index(before: values.endIndex), index + radius)
            let window = values[lower...upper].compactMap { $0 }.sorted()
            guard !window.isEmpty else { return nil }
            return window[window.count / 2]
        }
    }

    private func validRunningSpeed(_ speed: Double?) -> Bool {
        guard let speed else { return false }
        return speed.isFinite && (0.4...10).contains(speed)
    }

    private func routeDistanceMeters(_ first: RoutePointPayload, _ second: RoutePointPayload) -> Double {
        let latitude1 = first.latitude * .pi / 180
        let latitude2 = second.latitude * .pi / 180
        let deltaLatitude = (second.latitude - first.latitude) * .pi / 180
        let deltaLongitude = (second.longitude - first.longitude) * .pi / 180
        let value = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 6_371_000 * 2 * atan2(sqrt(value), sqrt(max(0, 1 - value)))
    }

    private func sample(points: [RoutePointPayload], limit: Int) -> [RoutePointPayload] {
        guard points.count > limit, limit > 1 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }

    private func sample<T>(items: [T], limit: Int) -> [T] {
        guard items.count > limit, limit > 1 else { return items }
        let step = Double(items.count - 1) / Double(limit - 1)
        return (0..<limit).map { items[Int((Double($0) * step).rounded())] }
    }

    private func elevationGain(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        return values.dropFirst().enumerated().reduce(0) { result, pair in
            let change = pair.element - values[pair.offset]
            return result + ((0.2...30).contains(change) ? change : 0)
        }
    }

    private func upsertRoute(_ route: ArchiveRouteSummary) {
        var updated = routes.filter { $0.id != route.id }
        updated.append(route)
        setRoutes(orderedRoutes(updated))
    }

    private func setRoutes(_ newRoutes: [ArchiveRouteSummary]) {
        routes = newRoutes
        routeLookup = Dictionary(uniqueKeysWithValues: newRoutes.map { ($0.id, $0) })
    }

    private func orderedRoutes(_ candidates: [ArchiveRouteSummary]) -> [ArchiveRouteSummary] {
        let order = Dictionary(uniqueKeysWithValues: activities.enumerated().map { ($1.id, $0) })
        return candidates.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }
}
