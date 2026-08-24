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
        async let heartSamples = quantitySamples(type: try heartRateType, workout: workout)
        async let powerSamples = powerSamples(for: workout)
        async let stepCount = stepCount(for: workout)
        let (route, heart, power, steps) = try await (locations, heartSamples, powerSamples, stepCount)
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let heartValues = heart.map { $0.quantity.doubleValue(for: heartUnit) }
        let heartPayload = heart.map {
            MetricSamplePayload(elapsedSeconds: max(0, $0.startDate.timeIntervalSince(workout.startDate)),
                                value: $0.quantity.doubleValue(for: heartUnit))
        }
        let points = route.map {
            RoutePointPayload(timestamp: $0.timestamp, latitude: $0.coordinate.latitude,
                              longitude: $0.coordinate.longitude, altitude: $0.altitude,
                              speedMps: $0.speed >= 0 ? $0.speed : nil)
        }
        let avgPower = power.isEmpty ? nil : power.reduce(0, +) / Double(power.count)
        let cadence = steps.map { $0 / max(workout.duration / 60, 1) }
        return WorkoutPayload(
            id: workoutID(workout), name: "户外跑步", startDate: workout.startDate,
            distanceKm: workoutDistanceKm(workout), durationSeconds: workout.duration, city: "",
            avgHeartRate: average(heartValues).map(Int.init), maxHeartRate: heartValues.max().map(Int.init),
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

    private func quantitySamples(type: HKQuantityType, workout: HKWorkout) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            // Older Apple Watch workouts do not always associate every quantity sample
            // with the HKWorkout object. Querying the workout's exact time window keeps
            // the historical heart-rate and power series complete.
            let predicate = samplePredicate(for: workout)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    if HealthKitService.isNoData(error) { continuation.resume(returning: []) }
                    else { continuation.resume(throwing: error) }
                    return
                }
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    private func powerSamples(for workout: HKWorkout) async throws -> [Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .runningPower) else { return [] }
        return try await quantitySamples(type: type, workout: workout).map { $0.quantity.doubleValue(for: .watt()) }
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
