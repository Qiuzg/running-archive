import CoreLocation
import Foundation
import HealthKit

enum HealthSyncError: LocalizedError {
    case unavailable
    case missingType(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "这台设备无法使用健康数据"
        case let .missingType(name): return "系统不支持健康数据类型：\(name)"
        }
    }
}

final class HealthKitService {
    private struct QuantitySeriesPoint {
        let quantity: HKQuantity
        let dateInterval: DateInterval
    }

    private let store = HKHealthStore()
    private var workoutByID: [String: HKWorkout] = [:]

    private var heartRateType: HKQuantityType {
        get throws {
            guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
                throw HealthSyncError.missingType("心率")
            }
            return type
        }
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSyncError.unavailable }
        var readTypes: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        readTypes.insert(try heartRateType)
        if let power = HKQuantityType.quantityType(forIdentifier: .runningPower) { readTypes.insert(power) }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { readTypes.insert(steps) }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func runningWorkoutPreviews(limit: Int = HKObjectQueryNoLimit) async throws -> [WorkoutPreview] {
        let workouts = try await runningWorkouts(limit: limit)
        workoutByID.removeAll(keepingCapacity: true)
        for workout in workouts {
            workoutByID[workoutID(workout)] = workout
        }
        return workouts.map {
            WorkoutPreview(id: workoutID($0), date: $0.startDate,
                           distanceKm: workoutDistanceKm($0), duration: $0.duration)
        }
    }

    func payload(forWorkoutID id: String) async throws -> WorkoutPayload? {
        let workout: HKWorkout
        if let cached = workoutByID[id] {
            workout = cached
        } else {
            guard let found = try await runningWorkouts(limit: HKObjectQueryNoLimit)
                .first(where: { workoutID($0) == id }) else { return nil }
            workoutByID[id] = found
            workout = found
        }
        async let locations = routeLocations(for: workout)
        let heartType = try heartRateType
        async let heartSamples = quantitySeriesPoints(type: heartType, workout: workout)
        async let powerSamples = powerSamples(for: workout)
        async let stepCount = stepCount(for: workout)
        let (route, heart, power, steps) = try await (locations, heartSamples, powerSamples, stepCount)
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let heartValues = heart.map { $0.quantity.doubleValue(for: heartUnit) }
        let heartPayload = metricPayload(
            from: heart,
            unit: heartUnit,
            workoutStart: workout.startDate
        )
        let points = route.map {
            RoutePointPayload(timestamp: $0.timestamp, latitude: $0.coordinate.latitude,
                              longitude: $0.coordinate.longitude, altitude: $0.altitude,
                              speedMps: $0.speed >= 0 ? $0.speed : nil)
        }
        let avgPower = power.isEmpty ? nil : power.reduce(0, +) / Double(power.count)
        let cadence = steps.map { $0 / max(workout.duration / 60, 1) }
        let heartStatistics = workout.statistics(for: heartType)
        let averageHeartRate = heartStatistics?.averageQuantity()?.doubleValue(for: heartUnit)
            ?? average(heartValues)
        let maximumHeartRate = heartStatistics?.maximumQuantity()?.doubleValue(for: heartUnit)
            ?? heartValues.max()
        return WorkoutPayload(
            id: workoutID(workout), name: "户外跑步", startDate: workout.startDate,
            distanceKm: workoutDistanceKm(workout), durationSeconds: workout.duration, city: "",
            avgHeartRate: averageHeartRate.map { Int($0.rounded()) },
            maxHeartRate: maximumHeartRate.map { Int($0.rounded()) },
            avgCadence: cadence, avgPower: avgPower, routePoints: points,
            heartRateSamples: heartPayload
        )
    }

    private func runningWorkouts(limit: Int) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForWorkouts(with: .running)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: limit,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    if HealthKitService.isNoData(error) { continuation.resume(returning: []) }
                    else { continuation.resume(throwing: error) }
                    return
                }
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }
    }

    private func routeLocations(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error {
                    if HealthKitService.isNoData(error) { continuation.resume(returning: []) }
                    else { continuation.resume(throwing: error) }
                    return
                }
                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }
            store.execute(query)
        }
        var all: [CLLocation] = []
        for route in routes {
            let values: [CLLocation] = try await withCheckedThrowingContinuation { continuation in
                var collected: [CLLocation] = []
                var resumed = false
                let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    if resumed { return }
                    if let error {
                        resumed = true
                        if HealthKitService.isNoData(error) { continuation.resume(returning: collected) }
                        else { continuation.resume(throwing: error) }
                        return
                    }
                    collected.append(contentsOf: locations ?? [])
                    if done { resumed = true; continuation.resume(returning: collected) }
                }
                store.execute(query)
            }
            all.append(contentsOf: values)
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    private func quantitySeriesPoints(type: HKQuantityType, workout: HKWorkout) async throws -> [QuantitySeriesPoint] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [QuantitySeriesPoint] = []
            var resumed = false
            let query = HKQuantitySeriesSampleQuery(
                quantityType: type,
                predicate: samplePredicate(for: workout)
            ) { _, quantity, interval, _, done, error in
                if resumed { return }
                if let error {
                    resumed = true
                    if HealthKitService.isNoData(error) {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let quantity, let interval {
                    collected.append(QuantitySeriesPoint(quantity: quantity, dateInterval: interval))
                }
                if done {
                    resumed = true
                    continuation.resume(returning: collected.sorted {
                        $0.dateInterval.start < $1.dateInterval.start
                    })
                }
            }
            query.orderByQuantitySampleStartDate = true
            store.execute(query)
        }
    }

    private func powerSamples(for workout: HKWorkout) async throws -> [Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .runningPower) else { return [] }
        return try await quantitySeriesPoints(type: type, workout: workout)
            .map { $0.quantity.doubleValue(for: .watt()) }
    }

    private func stepCount(for workout: HKWorkout) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: samplePredicate(for: workout),
                                          options: .cumulativeSum) { _, result, error in
                if let error {
                    if HealthKitService.isNoData(error) { continuation.resume(returning: nil) }
                    else { continuation.resume(throwing: error) }
                    return
                }
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count()))
            }
            store.execute(query)
        }
    }

    private func samplePredicate(for workout: HKWorkout) -> NSPredicate {
        HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: [.strictStartDate, .strictEndDate]
        )
    }

    private func metricPayload(
        from points: [QuantitySeriesPoint],
        unit: HKUnit,
        workoutStart: Date
    ) -> [MetricSamplePayload] {
        var payload: [MetricSamplePayload] = []
        for point in points {
            let value = point.quantity.doubleValue(for: unit)
            payload.append(MetricSamplePayload(
                elapsedSeconds: max(0, point.dateInterval.start.timeIntervalSince(workoutStart)),
                value: value
            ))
            // Condensed HealthKit values can represent a continuous interval.
            // Preserve both ends so the chart stays flat over that interval
            // instead of drawing a misleading diagonal between containers.
            if point.dateInterval.duration > 0.1 {
                payload.append(MetricSamplePayload(
                    elapsedSeconds: max(0, point.dateInterval.end.timeIntervalSince(workoutStart)),
                    value: value
                ))
            }
        }
        return payload.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
    }

    private func workoutDistanceKm(_ workout: HKWorkout) -> Double {
        workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)) ?? 0
    }

    private func workoutID(_ workout: HKWorkout) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let workoutTimeZone = (workout.metadata?[HKMetadataKeyTimeZone] as? String)
            .flatMap(TimeZone.init(identifier:))
        formatter.timeZone = workoutTimeZone ?? .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "apple-\(formatter.string(from: workout.startDate))"
    }

    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func isNoData(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == HKErrorDomain && value.code == HKError.Code.errorNoData.rawValue
    }
}
