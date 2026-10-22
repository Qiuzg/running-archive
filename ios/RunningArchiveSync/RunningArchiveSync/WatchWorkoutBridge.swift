import Foundation
import WorkoutKit

@MainActor
struct AppleWatchWorkoutTransport: WatchWorkoutTransport {
    var isSupported: Bool { WorkoutScheduler.isSupported }
    var maximumCount: Int { WorkoutScheduler.maxAllowedScheduledWorkoutCount }

    func authorize(request: Bool) async -> Bool {
        await Self.authorizationAllowed(request: request)
    }

    // Keep the SDK's non-Sendable authorization enum off the main actor boundary.
    nonisolated private static func authorizationAllowed(request: Bool) async -> Bool {
        if await WorkoutScheduler.shared.authorizationState == .authorized { return true }
        guard request else { return false }
        return await WorkoutScheduler.shared.requestAuthorization() == .authorized
    }

    func entries() async -> [WatchScheduledEntry] {
        await WorkoutScheduler.shared.scheduledWorkouts.compactMap { entry in
            guard let data = try? entry.plan.dataRepresentation else { return nil }
            return WatchScheduledEntry(id: entry.plan.id, date: entry.date, complete: entry.complete, data: data)
        }
    }

    func prepare(_ session: AITrainingSession, id: UUID) throws -> Data {
        try Self.plan(session, id: id).dataRepresentation
    }

    static func plan(_ session: AITrainingSession, id: UUID) throws -> WorkoutPlan {
        let structure = try session.resolvedWorkout()
        func step(_ value: RunWorkoutStep) throws -> WorkoutStep {
            let goal: WorkoutGoal = value.goal == .time ? .time(value.value, .seconds) : .distance(value.value, .meters)
            var alert: (any WorkoutAlert)?
            if let fastest = value.pace_min, let slowest = value.pace_max {
                // Pace order reverses when converting seconds/km to meters/second.
                alert = SpeedRangeAlert.speed((1000 / slowest)...(1000 / fastest), unit: .metersPerSecond)
            } else if let low = value.heart_rate_min, let high = value.heart_rate_max {
                alert = HeartRateRangeAlert.heartRate(low...high)
            }
            guard CustomWorkout.supportsGoal(goal, activity: .running, location: .outdoor),
                  alert.map({ CustomWorkout.supportsAlert($0, activity: .running, location: .outdoor) }) ?? true else {
                throw AITrainingError.invalid("这段训练的目标或提醒不受 Apple Watch 跑步支持，请修改后重试。")
            }
            return WorkoutStep(goal: goal, alert: alert, displayName: String(value.instructions.prefix(40)))
        }
        let workout = CustomWorkout(activity: .running, location: .outdoor, displayName: session.kind.title,
            warmup: try step(structure.warmup),
            blocks: try structure.blocks.map { block in
                IntervalBlock(steps: try block.steps.map { interval in
                    IntervalStep(interval.purpose == .work ? .work : .recovery, step: try step(interval.step))
                }, iterations: block.repetitions)
            }, cooldown: try step(structure.cooldown))
        return WorkoutPlan(.custom(workout), id: id)
    }

    func equivalent(_ lhs: Data, _ rhs: Data) throws -> Bool { try WorkoutPlan(from: lhs) == WorkoutPlan(from: rhs) }
    func schedule(data: Data, date: DateComponents) async throws {
        await WorkoutScheduler.shared.schedule(try WorkoutPlan(from: data), at: date)
    }
    func remove(_ entry: WatchScheduledEntry) async throws {
        await WorkoutScheduler.shared.remove(try WorkoutPlan(from: entry.data), at: entry.date)
    }
}
