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
    /// All sports use `CustomWorkout` (supports `displayName`).
    func createCustomWorkouts(
        workouts: [WorkoutInstanceModelElement]
    ) -> [ScheduledWorkoutItem] {

        var scheduledItems: [ScheduledWorkoutItem] = []

        for workout in workouts {
            print("🏗 Building: \(workout.summary?.name ?? "Unnamed") | sport: \(workout.sport.rawValue)")

            let item: ScheduledWorkoutItem?
            if workout.sport.isSwimmingType {
                item = buildSingleGoalSwimItem(from: workout)
            } else {
                item = buildCustomWorkoutItem(from: workout)
            }
            if let item = item {
                scheduledItems.append(item)
            }
        }

        return scheduledItems
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

    // MARK: - SingleGoalWorkout builder (Swimming)

    /// Builds a `SingleGoalWorkout` for swimming so Apple Watch correctly renders
    /// "Pool Swim" or "Open Water Swim". `SingleGoalWorkout` does NOT support
    /// displayName / warmup / interval / cooldown — the workout is flattened
    /// into a single goal derived from the top-level distance or duration.
    private func buildSingleGoalSwimItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let activity = workout.sport.hkWorkoutType

        // Location: INDOOR → .indoor, else → .outdoor
        let location = resolveLocation(workout)

        // Swimming-specific location: indoor → pool, outdoor → openWater
        let swimmingLocation: HKWorkoutSwimmingLocationType
        if let implied = workout.sport.impliedLocation {
            // Honour POOL_SWIMMING / OPEN_WATER_SWIMMING explicit sport overrides
            swimmingLocation = (implied == .indoor) ? .pool : .openWater
        } else {
            swimmingLocation = (location == .indoor) ? .pool : .openWater
        }

        // Build the goal from top-level distance (preferred) or duration.
        // Swimming distances are converted using pool_size to choose meters/yards
        // (resolveSwimmingMeasurementUnit) — falls back to summary.measurement_unit.
        let measurementUnit = resolveSwimmingMeasurementUnit(workout)
        let goal: WorkoutGoal = resolveSwimGoal(
            workout: workout,
            swimmingLocation: swimmingLocation,
            measurementUnit: measurementUnit
        )

        // Pre-validate goal support
        guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else {
            let openGoal: WorkoutGoal = .open
            let swim = SingleGoalWorkout(
                activity: activity,
                location: location,
                swimmingLocation: swimmingLocation,
                goal: openGoal
            )
            return ScheduledWorkoutItem(
                workout: .goal(swim),
                scheduledDate: workout.date,
                workoutModel: workout
            )
        }

        let swim = SingleGoalWorkout(
            activity: activity,
            location: location,
            swimmingLocation: swimmingLocation,
            goal: goal
        )

        return ScheduledWorkoutItem(
            workout: .goal(swim),
            scheduledDate: workout.date,
            workoutModel: workout
        )
    }

    // MARK: - CustomWorkout builder (Non-swimming)

    private func buildCustomWorkoutItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let sport    = workout.sport.rawValue
        let activity = workout.sport.hkWorkoutType

        // Unified location rule for ALL sports (Swimming, Running, Cycling, Walking, etc.):
        //   summary.indoor_outdoor == "INDOOR"  → .indoor
        //   anything else (OUTDOOR / nil)        → .outdoor
        let location: HKWorkoutSessionLocationType = resolveLocation(workout)

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

        var intervalBlocks = buildIntervalBlocks(from: mainForInterval, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit)

        // Swimming (or any sport) with no blocks: wrap the top-level goal into a single interval block
        if intervalBlocks.isEmpty {
            let effectiveMeasurementUnit: String?
            if workout.sport.isSwimmingType {
                effectiveMeasurementUnit = resolveSwimmingMeasurementUnit(workout)
            } else {
                effectiveMeasurementUnit = workoutUnit
            }
            let topGoal = resolveTopLevelGoal(
                distance: workout.distance,
                duration: workout.duration,
                measurementUnit: effectiveMeasurementUnit
            )
            var step = IntervalStep(.work)
            step.step.goal = topGoal
            intervalBlocks = [IntervalBlock(steps: [step], iterations: 1)]
        }

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

    // MARK: - Location helper

    /// Unified location resolver for ALL sports (Swimming, Running, Cycling, Walking, etc.).
    /// `summary.indoor_outdoor == "INDOOR"` → `.indoor`, otherwise (OUTDOOR or nil) → `.outdoor`.
    private func resolveLocation(_ workout: WorkoutInstanceModelElement) -> HKWorkoutSessionLocationType {
        let raw = workout.summary?.indoorOutdoor
        return (raw == .indoor) ? .indoor : .outdoor
    }

    // MARK: - Swimming helpers

    /// Resolves the swimming goal.
    ///
    /// We deliberately do NOT use `.poolSwimDistanceWithTime` (iOS 18 / watchOS 11+),
    /// because:
    ///  • `#available` on the iPhone only guards the iOS process — not the paired watch.
    ///  • If the iPhone is on iOS 18 but the paired watch is still on watchOS 10,
    ///    the goal cannot be decoded on the watch and the workout effectively
    ///    disappears from the Workout app.
    ///  • There is no reliable public API on iOS to read the paired watch's OS
    ///    version, so we cannot safely gate this at runtime.
    ///
    /// To guarantee the workout is **always scheduled and visible** on the watch,
    /// we always fall back to a plain `.distance` / `.time` / `.open` goal via
    /// `resolveTopLevelGoal`. The "Pool Swim" / "Open Water Swim" UI on the watch
    /// is driven by `swimmingLocation` on `SingleGoalWorkout` — independent of
    /// the goal type.
    private func resolveSwimGoal(
        workout: WorkoutInstanceModelElement,
        swimmingLocation: HKWorkoutSwimmingLocationType,
        measurementUnit: String?
    ) -> WorkoutGoal {
        return resolveTopLevelGoal(
            distance: workout.distance,
            duration: workout.duration,
            measurementUnit: measurementUnit
        )
    }

    /// Resolves the measurement unit for swimming workouts based on pool size.
    /// nil or contains "m" (e.g. "25m", "50m") → "meter"; otherwise (e.g. "25y") → "yard".
    private func resolveSwimmingMeasurementUnit(_ workout: WorkoutInstanceModelElement) -> String? {
        if let ps = workout.poolSize {
            return (!ps.isEmpty && !ps.lowercased().contains("m")) ? "yard" : "meter"
        }
        return workout.summary?.measurementUnit
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
