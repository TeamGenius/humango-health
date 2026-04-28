//
//  WorkoutPlanBuilder.swift
//  Runner
//
//  Created by Vinay Vudatala on 12/02/26.
//  Copyright © 2026 The Chromium Authors. All rights reserved.
//

import Foundation
import WorkoutKit
import HealthKit


// MARK: - WorkoutPlanBuilder

class WorkoutPlanBuilder {

    // MARK: - Public entry point

    /// Converts decoded JSON workouts into `ScheduledWorkoutItem` objects.
    /// • SWIMMING  → `SingleGoalWorkout`  (WorkoutKit limitation pre-watchOS 11)
    /// • Everything else → `CustomWorkout` wrapped in StateError handling
    func createCustomWorkouts(
        workouts: [WorkoutInstanceModelElement]
    ) -> [ScheduledWorkoutItem] {

        var scheduledItems: [ScheduledWorkoutItem] = []

        for workout in workouts {
            print("🏗 Building: \(workout.summary?.name ?? "Unnamed") | sport: \(workout.sport.rawValue)")

            if workout.sport.isMultisport {
                // ── Multisport: requires SwimBikeRunWorkout builder (not yet implemented) ──
                print("⚠️ [Humango Health] MULTISPORT not yet supported for scheduling — skipping")
                continue

            } else if workout.sport.isSwimmingType {
                // ── Swimming variants: route to SingleGoalWorkout ────────────
                let item = buildSingleGoalItem(from: workout)
                if item != nil {
                    scheduledItems.append(item!)
                }
               
            } else {
                // ── All other sports: CustomWorkout, with SingleGoal fallback ─
                let item = try buildCustomWorkoutItem(from: workout)
                if let item = item {
                    scheduledItems.append(item)
                } else if let fallback = buildGenericSingleGoalItem(from: workout) {
                    print("  ↩️ CustomWorkout failed — falling back to SingleGoalWorkout for \(workout.sport.rawValue)")
                    scheduledItems.append(fallback)
                }
            }
        }

        return scheduledItems
    }

    // MARK: - SingleGoalWorkout builder (Swimming)

    /// Creates a `SingleGoalWorkout` for swimming.
    /// Goal priority: total distance (meters) → total duration (seconds) → open.
    private func buildSingleGoalItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let activity = workout.sport.hkWorkoutType   // .swimming

        // Location resolution:
        // • Sport.impliedLocation present (POOL_SWIMMING → .indoor, OPEN_WATER_SWIMMING → .outdoor)
        // • pool_size present  → WorkoutLocation.indoor — skips the "Pool or Open Water?" Watch prompt
        // • pool_size absent   → derive from summary.indoor_outdoor, fall back to .unknown
        let location: HKWorkoutSessionLocationType
        if let implied = workout.sport.impliedLocation {
            location = implied
        } else if workout.poolSize != nil {
            location = WorkoutLocation.indoor.hkLocationType
        } else {
            location = workout.summary?.indoorOutdoor?.hkLocationType ?? .unknown
        }

        // Mirror Flutter poolSize logic:
        // nil or contains "m" (e.g. "25m", "50m") → meters; otherwise (e.g. "25y") → yards.
        // Prefer explicit poolSize over summary.measurementUnit so the caller's intent wins.
        let effectiveMeasurementUnit: String?
        if let ps = workout.poolSize {
            effectiveMeasurementUnit = (!ps.isEmpty && !ps.lowercased().contains("m")) ? "yard" : "meter"
            print("  → pool_size='\(ps)' resolved to measurement unit: \(effectiveMeasurementUnit!)")
        } else {
            effectiveMeasurementUnit = workout.summary?.measurementUnit
        }

        // Derive a meaningful top-level goal from the workout summary fields
        let goal = resolveTopLevelGoal(
            distance: workout.distance,
            duration: workout.duration,
            measurementUnit: effectiveMeasurementUnit
        )

        print("  → SingleGoalWorkout | goal=\(goal) | location=\(location)")

        // Validate goal before constructing
        guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else {
            print("  ⚠️ SingleGoalWorkout does not support goal \(goal) for \(activity)/\(location) — falling back to .open")
            let fallbackGoal: WorkoutGoal = .open
            let swimWorkout = SingleGoalWorkout(activity: activity, location: location, goal: fallbackGoal)
            return ScheduledWorkoutItem(
                workout: .goal(swimWorkout),
                scheduledDate: workout.date,
                workoutModel: workout
            )
        }

        let swimWorkout = SingleGoalWorkout(
            activity: activity,
            location: location,
            goal: goal
        )

        return ScheduledWorkoutItem(
            workout: .goal(swimWorkout),
            scheduledDate: workout.date,
            workoutModel: workout
        )
    }

    // MARK: - Generic SingleGoalWorkout fallback (non-swimming)

    /// Fallback for sports where CustomWorkout throws a StateError (e.g., ball sports).
    /// Creates a simple SingleGoalWorkout using the sport's native HKWorkoutActivityType.
    private func buildGenericSingleGoalItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let activity = workout.sport.hkWorkoutType
        let location = workout.summary?.indoorOutdoor?.hkLocationType ?? .unknown

        let goal = resolveTopLevelGoal(
            distance: workout.distance,
            duration: workout.duration,
            measurementUnit: workout.unit ?? workout.summary?.measurementUnit
        )

        print("  → Generic SingleGoalWorkout fallback | sport=\(workout.sport.rawValue) goal=\(goal) location=\(location)")

        guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else {
            print("  ⚠️ SingleGoalWorkout does not support goal \(goal) for \(activity)/\(location) — falling back to .open")
            let fallbackGoal: WorkoutGoal = .open
            let sgWorkout = SingleGoalWorkout(activity: activity, location: location, goal: fallbackGoal)
            return ScheduledWorkoutItem(
                workout: .goal(sgWorkout),
                scheduledDate: workout.date,
                workoutModel: workout
            )
        }

        let sgWorkout = SingleGoalWorkout(activity: activity, location: location, goal: goal)
        return ScheduledWorkoutItem(
            workout: .goal(sgWorkout),
            scheduledDate: workout.date,
            workoutModel: workout
        )
    }

    /// Derives a top-level `WorkoutGoal` from workout-level distance/duration fields.
    private func resolveTopLevelGoal(
        distance: Double?,
        duration: Int?,
        measurementUnit: String?
    ) -> WorkoutGoal {
        // Prefer distance if available
        if let dist = distance, dist > 0 {
            let unit   = lengthUnit(for: measurementUnit)
            let meters = Measurement(value: dist, unit: UnitLength.meters)
            let converted = meters.converted(to: unit).value
            return .distance(converted, unit)
        }
        // Fallback to time
        if let dur = duration, dur > 0 {
            return .time(Double(dur), .seconds)
        }
        return .open
    }

    // MARK: - CustomWorkout builder (Non-swimming)

    private func buildCustomWorkoutItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let sport    = workout.sport.rawValue
        let activity = workout.sport.hkWorkoutType
        let location = workout.summary?.indoorOutdoor?.hkLocationType ?? .unknown
        let allBlocks = workout.blocks ?? []
        // Top-level unit preference: all incoming distances are meters; this drives the
        // WorkoutKit goal/display unit (e.g. "mile", "km"). Per-block measurement_unit
        // still decides whether a step goal is time-based or distance-based.
        let workoutUnit = workout.unit

        // ── Split by type ────────────────────────────────────────────────
        let warmupBlocksList   = allBlocks.filter { $0.type?.uppercased() == "WARMUP"   }
        let cooldownBlocksList = allBlocks.filter { $0.type?.uppercased() == "COOLDOWN" }
        let intervalBlocksList = allBlocks.filter {
            let t = $0.type?.uppercased() ?? ""
            return t != "WARMUP" && t != "COOLDOWN"
        }

        let hasWarmup   = !warmupBlocksList.isEmpty
        let hasCooldown = !cooldownBlocksList.isEmpty
        let hasInterval = !intervalBlocksList.isEmpty

        // ── Assign sections based on what is present ─────────────────────
        //
        // warmup + interval + cooldown → warmupStep, intervals, cooldownStep
        // warmup + interval            → warmupStep, intervals, no cooldown
        // interval + cooldown          → no warmup,  intervals, cooldownStep
        // interval only                → no warmup,  intervals, no cooldown
        // warmup + cooldown (no interval) → intervals=warmup, no warmupStep, cooldownStep
        // warmup only                  → intervals=warmup,    no warmupStep, no cooldownStep
        // cooldown only                → intervals=cooldown,  no warmupStep, no cooldownStep
        let warmupStep:   WorkoutStep?
        let cooldownStep: WorkoutStep?
        let mainForInterval: [WorkoutInstanceModelBlock]

        if hasInterval {
            warmupStep      = hasWarmup
                ? buildWorkoutStep(from: warmupBlocksList.first!, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit)
                : nil
            cooldownStep    = hasCooldown
                ? buildWorkoutStep(from: cooldownBlocksList.last!, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit)
                : nil
            mainForInterval = intervalBlocksList
        } else if hasWarmup && hasCooldown {
            // No interval blocks — warmup fills the interval section, cooldown stays in its slot
            warmupStep      = nil
            cooldownStep    = buildWorkoutStep(from: cooldownBlocksList.last!, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit)
            mainForInterval = warmupBlocksList
        } else if hasCooldown {
            // No interval, no warmup — cooldown fills the interval section
            warmupStep      = nil
            cooldownStep    = nil
            mainForInterval = cooldownBlocksList
        } else {
            // Only warmup (or nothing) — warmup fills the interval section
            warmupStep      = nil
            cooldownStep    = nil
            mainForInterval = warmupBlocksList
        }

        let intervalBlocks = buildIntervalBlocks(from: mainForInterval, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit)

        print("  warmup=\(warmupStep != nil) blocks=\(intervalBlocks.count) cooldown=\(cooldownStep != nil)")

        // ── CustomWorkout init throws StateError — always use try ────────
        do {
            let customWorkout = try CustomWorkout(
                activity:    activity,
                location:    location,
                displayName: workout.summary?.name,
                warmup:      warmupStep,
                blocks:      intervalBlocks,
                cooldown:    cooldownStep
            )

            return ScheduledWorkoutItem(
                workout: .custom(customWorkout),
                scheduledDate: workout.date,
                workoutModel: workout
            )

        } catch let stateError as StateError {
            // Re-throw so the Manager can send it back to Flutter
            let errorDesc = "StateError: \(stateError.localizedDescription) Raw: \(stateError)"
           // throw NSError(domain: "WorkoutBuilder", code: 1, userInfo: [NSLocalizedDescriptionKey: errorDesc])
        } catch {
           // throw error
        }
    }

    // MARK: - StateError handler

    private func handleStateError(
        _ error: StateError,
        workoutName: String?,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType
    ) {
        let name = workoutName ?? "Unnamed"

        // StateError has no .description and no enum cases.
        // Use localizedDescription (from Error) + string interpolation to inspect it.
        let desc = error.localizedDescription
        let raw  = "\(error)"

        print("❌ StateError for '\(name)'")
        print("   localizedDescription : \(desc)")
        print("   raw                  : \(raw)")
        print("   activity=\(activity.rawValue) location=\(location.rawValue)")

        // Combine both strings for keyword matching
        let d = (desc + raw).lowercased()

        if d.contains("activity") {
            print("   → Activity \(activity.rawValue) is not supported by CustomWorkout.")
            print("   → Route this sport to SingleGoalWorkout or PacerWorkout instead.")
        } else if d.contains("goal") {
            print("   → A step goal is incompatible with this activity/location.")
            print("   → Use CustomWorkout.supportsGoal(_:activity:location:) to pre-validate.")
        } else if d.contains("alert") {
            print("   → An alert (pace/HR/power) is incompatible with this activity.")
            print("   → Use CustomWorkout.supportsAlert(_:activity:location:) to pre-validate.")
        } else if d.contains("location") {
            print("   → Location \(location.rawValue) is not valid for this activity.")
            print("   → Try passing .unknown to let the user choose on Watch.")
        } else {
            print("   → Unrecognised StateError — see raw output above.")
        }
    }

    // MARK: - IntervalBlock builder

    private func buildIntervalBlocks(
        from blocks: [WorkoutInstanceModelBlock],
        sport: String,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType,
        workoutUnit: String? = nil
    ) -> [IntervalBlock] {

        var result: [IntervalBlock] = []

        for block in blocks {
            let blockType = block.type?.uppercased() ?? ""

            switch blockType {

            case "INTERVAL":
                var step = IntervalStep(.work)
                step.step.goal  = resolveGoal(measurementUnit: block.measurementUnit,
                                              distance: block.distance,
                                              duration: block.duration,
                                              workoutUnit: workoutUnit)
                step.step.alert = resolveAlert(zoneUnit: block.zoneUnit,
                                               targetRange: block.targetRange,
                                               sport: sport,
                                               activity: activity,
                                               location: location)
                result.append(IntervalBlock(steps: [step], iterations: 1))

            case "REST", "RECOVERY", "WARMUP", "COOLDOWN":
                var step = IntervalStep(.recovery)
                step.step.goal  = resolveGoal(measurementUnit: block.measurementUnit,
                                              distance: block.distance,
                                              duration: block.duration,
                                              workoutUnit: workoutUnit)
                step.step.alert = resolveAlert(zoneUnit: block.zoneUnit,
                                               targetRange: block.targetRange,
                                               sport: sport,
                                               activity: activity,
                                               location: location)
                result.append(IntervalBlock(steps: [step], iterations: 1))

            case "REPEAT":
                let children   = block.blocks ?? []
                let iterations = block.blockRepeat ?? 1

                guard !children.isEmpty else {
                    print("⚠️ REPEAT block has no children — skipping")
                    continue
                }

                let steps: [IntervalStep] = children.map {
                    buildIntervalStep(from: $0, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit)
                }
                result.append(IntervalBlock(steps: steps, iterations: iterations))

            default:
                print("⚠️ Unknown block type '\(blockType)' — skipping")
            }
        }

        return result
    }

    // MARK: - IntervalStep from child BlockBlock

    private func buildIntervalStep(
        from block: BlockBlock,
        sport: String,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType,
        workoutUnit: String? = nil
    ) -> IntervalStep {

        let purpose = intervalStepPurpose(for: block.type)
        var step    = IntervalStep(purpose)

        step.step.goal  = resolveGoal(
            measurementUnit: block.measurementUnit,
            distance: block.distance,
            duration: block.duration,
            workoutUnit: workoutUnit
        )
        step.step.alert = resolveAlert(
            zoneUnit: block.zoneUnit,
            targetRange: block.targetRange,
            sport: sport,
            activity: activity,
            location: location
        )

        print("    [child \(block.type ?? "?")] purpose=\(purpose) goal=\(step.step.goal)")
        return step
    }

    // MARK: - WorkoutStep builder (warmup / cooldown)

    private func buildWorkoutStep(
        from block: WorkoutInstanceModelBlock,
        sport: String,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType,
        workoutUnit: String? = nil
    ) -> WorkoutStep {

        let goal  = resolveGoal(
            measurementUnit: block.measurementUnit,
            distance: block.distance,
            duration: block.duration,
            workoutUnit: workoutUnit
        )
        let alert = resolveAlert(
            zoneUnit: block.zoneUnit,
            targetRange: block.targetRange,
            sport: sport,
            activity: activity,
            location: location
        )
        return WorkoutStep(goal: goal, alert: alert)
    }

    // MARK: - Purpose mapping

    private func intervalStepPurpose(for type: String?) -> IntervalStep.Purpose {
        switch type?.uppercased() {
        case "RECOVERY", "REST", "WARMUP", "COOLDOWN":
            return .recovery
        case "INTERVAL", _:
            return .work
        }
    }

    // MARK: - Goal resolution

    private func resolveGoal(
        measurementUnit: String?,
        distance: Double?,
        duration: Int?,
        workoutUnit: String? = nil
    ) -> WorkoutGoal {
        // All incoming distances are in meters. measurement_unit decides goal TYPE
        // (distance vs time). workoutUnit (top-level) overrides the output UnitLength
        // so Apple Watch displays the goal in the caller's preferred unit.
        if isDistanceUnit(measurementUnit), let dist = distance, dist > 0 {
            let unitLength     = lengthUnit(for: workoutUnit ?? measurementUnit)
            let convertedValue = Measurement(value: dist, unit: UnitLength.meters)
                .converted(to: unitLength).value
            return .distance(convertedValue, unitLength)
        }

        if let dur = duration, dur > 0 {
            if measurementUnit?.lowercased() == "minute" {
                return .time(Double(dur), .minutes)
            }
            return .time(Double(dur), .seconds)
        }

        return .open
    }

    // MARK: - Alert resolution (with pre-validation)

    /// Resolves an alert from JSON, then validates it against the actual activity
    /// and location using `CustomWorkout.supportsAlert(_:activity:location:)`.
    /// Returns nil silently if the alert is unsupported — preventing StateError.unsupportedAlert.
    private func resolveAlert(
        zoneUnit: String?,
        targetRange: TargetRange?,
        sport: String,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType
    ) -> WorkoutAlert? {

        guard var low  = targetRange?.low.map({ Double($0) }),
              var high = targetRange?.high.map({ Double($0) })
        else { return nil }

        guard low > 0 || high > 0 else { return nil }

        var unit = zoneUnit?.uppercased() ?? ""
        if unit == "HEART_RATE" || unit == "HEART RATE" { unit = "HR"    }
        if unit == "SPEED"                              { unit = "PACE"  }
        if unit == "WATTS"                              { unit = "POWER" }
        if unit == "DEFAULT" || unit == "NONE" || unit == "RPE" || unit.isEmpty {
            return nil
        }

        let resolved: WorkoutAlert?

        switch unit {

        case "PACE":
            guard low > 0, high > 0 else { return nil }
            if low < high { swap(&low, &high) }
            if low == high { low *= 1.05; high *= 0.95 }
            let slowMps = 1000.0 / low
            let fastMps = 1000.0 / high
            guard slowMps > 0, fastMps > 0, slowMps <= fastMps else { return nil }
            resolved = .speed(slowMps...fastMps, unit: .metersPerSecond, metric: .current)

        case "HR":
            if low > high { swap(&low, &high) }
            if low == high { low -= 5; high += 5 }
            guard low > 0 else { return nil }
            resolved = .heartRate(low...high)

        case "POWER":
            if low > high { swap(&low, &high) }
            if low == high { low *= 0.95; high *= 1.05 }
            guard low > 0 else { return nil }
            if #available(iOS 17.4, *) {
                resolved = .power(low...high, unit: .watts, metric: .current)
            } else {
                return nil
            }

        default:
            return nil
        }

        // ── Pre-validate before returning ────────────────────────────────
        // This prevents CustomWorkout init from throwing StateError.unsupportedAlert
        if let alert = resolved {
            guard CustomWorkout.supportsAlert(alert, activity: activity, location: location) else {
                print("  ⚠️ Alert '\(unit)' not supported for \(activity)/\(location) — dropping")
                return nil
            }
        }

        return resolved
    }

    // MARK: - Unit helpers

    private func isDistanceUnit(_ unit: String?) -> Bool {
        guard let u = unit?.lowercased() else { return false }
        return ["meter", "km", "mile", "yard"].contains(u)
    }

    private func lengthUnit(for unit: String?) -> UnitLength {
        switch unit?.lowercased() {
        case "mile":  return .miles
        case "km":    return .kilometers
        case "yard":  return .yards
        default:      return .meters
        }
    }

    func convertedDistance(meters: Double, to unit: UnitLength) -> Measurement<UnitLength> {
        Measurement(value: meters, unit: UnitLength.meters).converted(to: unit)
    }
}
