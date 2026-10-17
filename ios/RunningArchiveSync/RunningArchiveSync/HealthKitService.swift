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
        var sample: HKQuantitySample? = nil
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

    func requestAuthorization(includeExportMetrics: Bool = false, includeTrainingContext: Bool = false) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSyncError.unavailable }
        var readTypes: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        readTypes.insert(try heartRateType)
        if let power = HKQuantityType.quantityType(forIdentifier: .runningPower) { readTypes.insert(power) }
        if let speed = HKQuantityType.quantityType(forIdentifier: .runningSpeed) { readTypes.insert(speed) }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { readTypes.insert(energy) }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { readTypes.insert(steps) }
        if includeExportMetrics {
            for identifier: HKQuantityTypeIdentifier in [.runningStrideLength, .runningGroundContactTime,
                .runningVerticalOscillation, .vo2Max, .heartRateRecoveryOneMinute] {
                if let type = HKQuantityType.quantityType(forIdentifier: identifier) { readTypes.insert(type) }
            }
        }
        if includeTrainingContext {
            for identifier: HKQuantityTypeIdentifier in [.restingHeartRate, .heartRateVariabilitySDNN, .bodyMass] {
                if let type = HKQuantityType.quantityType(forIdentifier: identifier) { readTypes.insert(type) }
            }
            if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { readTypes.insert(sleep) }
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func runningWorkoutPreviews(limit: Int = HKObjectQueryNoLimit) async throws -> [WorkoutPreview] {
        let workouts = try await runningWorkouts(limit: limit)
        workoutByID.removeAll(keepingCapacity: true)
        var uniqueWorkouts: [HKWorkout] = []
        var seenIDs = Set<String>()
        for workout in workouts {
            let id = workoutID(workout)
            guard seenIDs.insert(id).inserted else { continue }
            workoutByID[id] = workout
            uniqueWorkouts.append(workout)
        }
        let heartType = try heartRateType
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let powerType = HKQuantityType.quantityType(forIdentifier: .runningPower)
        return uniqueWorkouts.map { workout in
            let heart = workout.statistics(for: heartType)
            let power = powerType.flatMap { workout.statistics(for: $0) }
            return WorkoutPreview(
                id: workoutID(workout),
                date: workout.startDate,
                distanceKm: workoutDistanceKm(workout),
                duration: workout.duration,
                avgHeartRate: heart?.averageQuantity().map { Int($0.doubleValue(for: heartUnit).rounded()) },
                maxHeartRate: heart?.maximumQuantity().map { Int($0.doubleValue(for: heartUnit).rounded()) },
                avgPower: power?.averageQuantity()?.doubleValue(for: .watt()),
                avgCadence: HKQuantityType.quantityType(forIdentifier: .stepCount)
                    .flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .count()) }
                    .flatMap { workout.duration > 0 ? $0 / (workout.duration / 60) : nil }
            )
        }
    }

    func routePoints(forWorkoutID id: String) async throws -> [RoutePointPayload]? {
        guard let workout = try await workout(forID: id) else { return nil }
        return try await routeLocations(for: workout).map {
            RoutePointPayload(
                timestamp: $0.timestamp,
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                altitude: $0.altitude,
                speedMps: $0.speed >= 0 ? $0.speed : nil
            )
        }
    }

    func payload(forWorkoutID id: String) async throws -> WorkoutPayload? {
        guard let workout = try await workout(forID: id) else { return nil }
        async let locations = routeLocations(for: workout)
        let heartType = try heartRateType
        async let heartSamples = quantitySeriesPoints(type: heartType, workout: workout)
        async let powerSamples = powerSamples(for: workout)
        async let speedSamples = runningSpeedSamples(for: workout)
        async let stepCount = stepCount(for: workout)
        let (route, heart, power, speed, steps) = try await (locations, heartSamples, powerSamples, speedSamples, stepCount)
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
        let intervals = workoutIntervals(for: workout)
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
            heartRateSamples: heartPayload,
            runningSpeedSamples: speed,
            intervals: intervals
        )
    }

    /// Read full native intervals for both export formats. Only the file packaging differs.
    func exportWorkout(id: String) async throws -> ExportWorkout {
        guard let workout = try await workout(forID: id) else { throw LocalArchiveError.workoutUnavailable }
        try Task.checkCancellation()
        let heartType = try heartRateType
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let heart = workout.statistics(for: heartType)
        func statistics(_ identifier: HKQuantityTypeIdentifier) -> HKStatistics? {
            HKQuantityType.quantityType(forIdentifier: identifier).flatMap { workout.statistics(for: $0) }
        }
        let steps = statistics(.stepCount)?.sumQuantity()?.doubleValue(for: .count())
        var samples: [ExportRawSample] = [], issues: [String: String] = [:]
        var points: [RoutePointPayload] = []
        let metrics: [(HKQuantityTypeIdentifier, ExportMetric, HKUnit, String)] = [
            (.heartRate, .heartRate, heartUnit, "bpm"),
            (.runningSpeed, .speed, .meter().unitDivided(by: .second()), "m/s"),
            (.runningPower, .power, .watt(), "W"),
            (.stepCount, .steps, .count(), "count"),
            (.runningStrideLength, .stride, .meter(), "m"),
            (.runningGroundContactTime, .contact, .secondUnit(with: .milli), "ms"),
            (.runningVerticalOscillation, .oscillation, .meterUnit(with: .centi), "cm")
        ]
        async let locations = routeLocations(for: workout)
        // Run independent quantity queries together instead of a seven-query waterfall.
        try await withThrowingTaskGroup(of: (ExportMetric, [ExportRawSample], String?).self) { group in
            for (identifier, metric, unit, symbol) in metrics {
                guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let raw = try await self.quantitySeriesPoints(type: type, workout: workout, forExport: true)
                        let samples = raw.filter { $0.dateInterval.end >= workout.startDate && $0.dateInterval.start < workout.endDate }.map { point in
                            let sample = point.sample
                            let bundle = sample?.sourceRevision.source.bundleIdentifier ?? ""
                            let sameSource = bundle == workout.sourceRevision.source.bundleIdentifier
                            let sameDevice = sample?.device?.localIdentifier != nil && sample?.device?.localIdentifier == workout.device?.localIdentifier
                            return ExportRawSample(metric: metric.rawValue, start: point.dateInterval.start,
                                end: point.dateInterval.end, value: point.quantity.doubleValue(for: unit), unit: symbol,
                                source: sample?.sourceRevision.source.name ?? "未知来源", sourceBundle: bundle,
                                device: [sample?.device?.manufacturer, sample?.device?.model, sample?.device?.name].compactMap { $0 }.joined(separator: " / "),
                                deviceKey: sample?.device?.localIdentifier ?? "", sourcePriority: sameDevice ? 2 : (sameSource ? 1 : 0))
                        }
                        return (metric, samples, nil)
                    } catch is CancellationError { throw CancellationError() }
                    catch { return (metric, [], error.localizedDescription) }
                }
            }
            for try await (metric, values, issue) in group {
                samples += values
                if let issue { issues[metric.rawValue] = issue }
            }
        }
        do {
            points = (try await locations).map {
                RoutePointPayload(timestamp: $0.timestamp, latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude, altitude: $0.altitude, speedMps: $0.speed >= 0 ? $0.speed : nil)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { issues["gps"] = error.localizedDescription }
        try Task.checkCancellation()
        return ExportWorkout(uuid: workout.uuid.uuidString, start: workout.startDate, end: workout.endDate,
            distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)), duration: workout.duration,
            heartRate: heart?.averageQuantity()?.doubleValue(for: heartUnit),
            maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: heartUnit),
            power: statistics(.runningPower)?.averageQuantity()?.doubleValue(for: .watt()),
            cadence: steps.flatMap { workout.duration > 0 ? $0 / (workout.duration / 60) : nil },
            energyKcal: statistics(.activeEnergyBurned)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            elevationGain: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            indoor: (workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue,
            source: workout.sourceRevision.source.name, sourceBundle: workout.sourceRevision.source.bundleIdentifier,
            device: [workout.device?.manufacturer, workout.device?.model, workout.device?.name].compactMap { $0 }.joined(separator: " / "),
            points: points, samples: samples, intervals: workoutIntervals(for: workout),
            stride: statistics(.runningStrideLength)?.averageQuantity()?.doubleValue(for: .meter()),
            contact: statistics(.runningGroundContactTime)?.averageQuantity()?.doubleValue(for: .secondUnit(with: .milli)),
            oscillation: statistics(.runningVerticalOscillation)?.averageQuantity()?.doubleValue(for: .meterUnit(with: .centi)),
            elevationLoss: (workout.metadata?[HKMetadataKeyElevationDescended] as? HKQuantity)?.doubleValue(for: .meter()),
            steps: steps, pauses: exportPauses(workout), readIssues: issues)
    }

    func exportReferences(start: Date, end: Date) async throws -> ExportReferenceData {
        var result = ExportReferenceData()
        for (identifier, label, unit, symbol): (HKQuantityTypeIdentifier, String, HKUnit, String) in [
            (.vo2Max, "VO2 max", .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute())), "ml/kg/min"),
            (.heartRateRecoveryOneMinute, "1 分钟心率恢复（系统记录）", .count().unitDivided(by: .minute()), "bpm")
        ] {
            try Task.checkCancellation()
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            do {
                let values: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                    let query = HKSampleQuery(sampleType: type,
                        predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                        limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                        if let error, !Self.isNoData(error) { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: samples as? [HKQuantitySample] ?? []) }
                    }
                    store.execute(query)
                }
                result.samples += values.filter { $0.startDate >= start && $0.startDate < end }.map {
                    ExportReferenceSample(metric: label, date: $0.startDate, value: $0.quantity.doubleValue(for: unit), unit: symbol,
                        source: $0.sourceRevision.source.name + " / " + $0.sourceRevision.source.bundleIdentifier,
                        method: ($0.metadata?[HKMetadataKeyWasTakenInLab] as? NSNumber)?.boolValue == true ? "来源标注为实验室测量" : "未标注为实验室测量，可能为设备估算")
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.issues[label] = error.localizedDescription }
        }
        return result
    }

    func trainingContext(now: Date, calendar: Calendar) async -> AIRecoveryContext {
        let since = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: now))!
        var result = AIRecoveryContext()
        for (identifier, metric, unit, symbol): (HKQuantityTypeIdentifier, String, HKUnit, String) in [
            (.restingHeartRate, "resting_heart_rate", .count().unitDivided(by: .minute()), "bpm"),
            (.heartRateVariabilitySDNN, "hrv_sdnn", .secondUnit(with: .milli), "ms")
        ] {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            do {
                let samples = try await contextSamples(type: type, start: since, end: now) as? [HKQuantitySample] ?? []
                let points = samples.map { AIBackgroundPoint(date: $0.startDate, value: $0.quantity.doubleValue(for: unit), source: $0.sourceRevision.source.bundleIdentifier) }
                let daily = AIRecoveryContext.daily(points, metric: metric, unit: symbol, calendar: calendar)
                result.daily_metrics += daily
                if daily.isEmpty { result.notes.append("\(metric)：未获得记录，可能未记录或未授权。") }
            } catch { result.notes.append("\(metric)：暂时不可读取。") }
        }
        if let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            do {
                let samples = try await contextSamples(type: type, start: since, end: now) as? [HKCategorySample] ?? []
                let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue])
                let intervals = samples.filter { asleep.contains($0.value) }.map {
                    AISleepInterval(start: $0.startDate, end: $0.endDate, source: $0.sourceRevision.source.bundleIdentifier)
                }
                result.sleep_windows = AIRecoveryContext.sleep(intervals, start: since, end: now, calendar: calendar)
                if result.sleep_windows.isEmpty { result.notes.append("sleep：未获得入睡记录，不能将卧床时间当作睡眠。") }
            } catch { result.notes.append("sleep：暂时不可读取。") }
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            do {
                let start = calendar.date(byAdding: .day, value: -180, to: now)!
                let values = try await contextSamples(type: type, start: start, end: now) as? [HKQuantitySample] ?? []
                if let latest = values.filter({ $0.quantity.doubleValue(for: .gramUnit(with: .kilo)).isFinite && $0.quantity.doubleValue(for: .gramUnit(with: .kilo)) > 0 }).max(by: { $0.startDate < $1.startDate }) {
                    result.latest_body_mass = AIBodyMeasurement(date: latest.startDate, kilograms: latest.quantity.doubleValue(for: .gramUnit(with: .kilo)))
                }
            } catch { result.notes.append("body_mass：暂时不可读取。") }
        }
        do {
            let start = calendar.date(byAdding: .day, value: -42, to: calendar.startOfDay(for: now))!
            let workouts = try await contextSamples(type: .workoutType(), start: start, end: now) as? [HKWorkout] ?? []
            let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
            var seen = Set<String>()
            result.other_workouts = workouts.filter {
                $0.workoutActivityType != .running && $0.endDate <= now &&
                    seen.insert("\($0.workoutActivityType.rawValue):\($0.startDate.timeIntervalSince1970):\($0.duration)").inserted
            }
                .sorted { $0.startDate < $1.startDate }.suffix(100).map { workout in
                    let kind: String
                    switch workout.workoutActivityType {
                    case .walking: kind = "walking"
                    case .cycling: kind = "cycling"
                    case .swimming: kind = "swimming"
                    case .hiking: kind = "hiking"
                    case .traditionalStrengthTraining, .functionalStrengthTraining: kind = "strength_training"
                    case .yoga: kind = "yoga"
                    default: kind = "other_\(workout.workoutActivityType.rawValue)"
                    }
                    return AIOtherWorkout(date: workout.startDate, kind: kind, active_seconds: workout.duration,
                        energy_kcal: energy.flatMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) })
                }
        } catch { result.notes.append("other_workouts：暂时不可读取。") }
        return result
    }

    private func contextSamples(type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error, !Self.isNoData(error) { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (samples ?? []).filter { $0.startDate <= end && $0.endDate >= start }) }
            }
            store.execute(query)
        }
    }

    private func exportPauses(_ workout: HKWorkout) -> [DateInterval] {
        var manual = false, motion = false, pausedAt: Date?, result: [DateInterval] = []
        for event in (workout.workoutEvents ?? []).sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
            switch event.type {
            case .pause: manual = true
            case .resume: manual = false
            case .motionPaused: motion = true
            case .motionResumed: motion = false
            default: continue
            }
            let date = min(workout.endDate, max(workout.startDate, event.dateInterval.start))
            if manual || motion { if pausedAt == nil { pausedAt = date } }
            else if let start = pausedAt { result.append(DateInterval(start: start, end: max(start, date))); pausedAt = nil }
        }
        if let start = pausedAt { result.append(DateInterval(start: start, end: workout.endDate)) }
        return result
    }

    private func workoutIntervals(for workout: HKWorkout) -> [WorkoutIntervalPayload] {
        let activities = workout.workoutActivities
        if activities.count > 1 {
            let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)
            let heartType = try? heartRateType
            let powerType = HKQuantityType.quantityType(forIdentifier: .runningPower)
            let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)
            let heartUnit = HKUnit.count().unitDivided(by: .minute())

            return activities.enumerated().map { offset, activity in
                let start = max(0, activity.startDate.timeIntervalSince(workout.startDate))
                let endDate = activity.endDate ?? activity.startDate.addingTimeInterval(activity.duration)
                let end = max(start, endDate.timeIntervalSince(workout.startDate))
                let duration = max(0, activity.duration)
                let distanceKm = distanceType
                    .flatMap { activity.statistics(for: $0)?.sumQuantity() }
                    .map { $0.doubleValue(for: .meter()) / 1000 }
                let pace = distanceKm.flatMap { distance in
                    distance > 0 ? duration / distance : nil
                }
                let heartStatistics = heartType.flatMap { activity.statistics(for: $0) }
                let averageHeartRate = heartStatistics?.averageQuantity()
                    .map { Int($0.doubleValue(for: heartUnit).rounded()) }
                let maximumHeartRate = heartStatistics?.maximumQuantity()
                    .map { Int($0.doubleValue(for: heartUnit).rounded()) }
                let averagePower = powerType
                    .flatMap { activity.statistics(for: $0)?.averageQuantity() }
                    .map { $0.doubleValue(for: .watt()) }
                let steps = stepType
                    .flatMap { activity.statistics(for: $0)?.sumQuantity() }
                    .map { $0.doubleValue(for: .count()) }
                let cadence = steps.map { $0 / max(duration / 60, 1) }

                return WorkoutIntervalPayload(
                    index: offset + 1,
                    kind: "activity",
                    activityType: Int(activity.workoutConfiguration.activityType.rawValue),
                    startElapsedSeconds: start,
                    endElapsedSeconds: end,
                    durationSeconds: duration,
                    distanceKm: distanceKm,
                    paceSecondsPerKm: pace,
                    avgHeartRate: averageHeartRate,
                    maxHeartRate: maximumHeartRate,
                    avgCadence: cadence,
                    avgPower: averagePower,
                    eventType: nil,
                    label: nil
                )
            }
        }

        // Some apps record laps/segments as workout events without creating
        // multiple HKWorkoutActivity objects. Preserve their timing as a
        // fallback; activity-level metrics are not available for these rows.
        return (workout.workoutEvents ?? [])
            .filter { $0.type == .lap || $0.type == .segment }
            .enumerated()
            .map { offset, event in
                let start = max(0, event.dateInterval.start.timeIntervalSince(workout.startDate))
                let end = max(start, event.dateInterval.end.timeIntervalSince(workout.startDate))
                let eventType = event.type == .lap ? "lap" : "segment"
                return WorkoutIntervalPayload(
                    index: offset + 1,
                    kind: "event",
                    activityType: nil,
                    startElapsedSeconds: start,
                    endElapsedSeconds: end,
                    durationSeconds: max(0, event.dateInterval.duration),
                    distanceKm: nil,
                    paceSecondsPerKm: nil,
                    avgHeartRate: nil,
                    maxHeartRate: nil,
                    avgCadence: nil,
                    avgPower: nil,
                    eventType: eventType,
                    label: nil
                )
            }
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

    private func workout(forID id: String) async throws -> HKWorkout? {
        if let cached = workoutByID[id] { return cached }
        guard let found = try await runningWorkouts(limit: HKObjectQueryNoLimit)
            .first(where: { workoutID($0) == id }) else { return nil }
        workoutByID[id] = found
        return found
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

    private func quantitySeriesPoints(type: HKQuantityType, workout: HKWorkout, forExport: Bool = false) async throws -> [QuantitySeriesPoint] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [QuantitySeriesPoint] = []
            var resumed = false
            let query = HKQuantitySeriesSampleQuery(
                quantityType: type,
                predicate: forExport ? HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []) : samplePredicate(for: workout)
            ) { _, quantity, interval, sample, done, error in
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
                    collected.append(QuantitySeriesPoint(quantity: quantity, dateInterval: interval, sample: sample))
                }
                if done {
                    resumed = true
                    continuation.resume(returning: collected.sorted {
                        $0.dateInterval.start < $1.dateInterval.start
                    })
                }
            }
            query.includeSample = forExport
            query.orderByQuantitySampleStartDate = true
            store.execute(query)
        }
    }

    private func powerSamples(for workout: HKWorkout) async throws -> [Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .runningPower) else { return [] }
        return try await quantitySeriesPoints(type: type, workout: workout)
            .map { $0.quantity.doubleValue(for: .watt()) }
    }

    private func runningSpeedSamples(for workout: HKWorkout) async throws -> [MetricSamplePayload] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .runningSpeed) else { return [] }
        let unit = HKUnit.meter().unitDivided(by: .second())
        let points = try await quantitySeriesPoints(type: type, workout: workout)
        return metricPayload(from: points, unit: unit, workoutStart: workout.startDate)
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
