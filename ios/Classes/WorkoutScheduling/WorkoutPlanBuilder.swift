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
    /// SWIMMING + indoor → `CustomWorkout` with `.poolSwimDistanceWithTime` goals (iOS 18+).
    /// SWIMMING + outdoor → `SingleGoalWorkout` with `swimmingLocation: .openWater`.
    /// All other sports → `CustomWorkout`.
    func createCustomWorkouts(
        workouts: [WorkoutInstanceModelElement]
    ) -> [ScheduledWorkoutItem] {

        var scheduledItems: [ScheduledWorkoutItem] = []

        for workout in workouts {
            print("🏗 Building: \(workout.summary?.name ?? "Unnamed") | sport: \(workout.sport.rawValue)")

            let item: ScheduledWorkoutItem?
            if workout.sport.isSwimmingType && !isPoolSwimWorkout(workout) {
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

    /// Returns `true` when the workout should be built as a pool-swim `CustomWorkout`.
    /// Criteria: sport is SWIMMING with indoor location (via `resolveLocation`).
    private func isPoolSwimWorkout(_ workout: WorkoutInstanceModelElement) -> Bool {
        guard workout.sport == .swimming else { return false }
        return resolveLocation(workout) == .indoor
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

    // MARK: - SingleGoalWorkout builder (outdoor swimming)

    /// Builds a `SingleGoalWorkout` for outdoor swimming (SWIMMING + outdoor).
    /// Uses `swimmingLocation: .openWater` so Apple Watch renders "Open Water Swim" UI.
    private func buildSingleGoalSwimItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let activity = workout.sport.hkWorkoutType
        let location = resolveLocation(workout)

        let swimmingLocation: HKWorkoutSwimmingLocationType = .openWater

        let measurementUnit = resolveWorkoutUnit(workout)
        let goal = resolveTopLevelGoal(
            distance: workout.distance,
            duration: workout.duration,
            measurementUnit: measurementUnit
        )

        // Pre-validate goal support; fallback to .open if unsupported
        let validatedGoal: WorkoutGoal
        if SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) {
            validatedGoal = goal
        } else {
            validatedGoal = .open
        }

        let swim = SingleGoalWorkout(
            activity: activity,
            location: location,
            swimmingLocation: swimmingLocation,
            goal: validatedGoal
        )

        return ScheduledWorkoutItem(
            workout: .goal(swim),
            scheduledDate: workout.date,
            workoutModel: workout
        )
    }

    // MARK: - CustomWorkout builder

    private func buildCustomWorkoutItem(
        from workout: WorkoutInstanceModelElement
    ) -> ScheduledWorkoutItem? {

        let sport    = workout.sport.rawValue
        let activity = workout.sport.hkWorkoutType

        // Unified location rule for ALL sports (Swimming, Running, Cycling, Walking, etc.):
        //   summary.indoor_outdoor == "INDOOR"  → .indoor
        //   anything else (OUTDOOR / nil)        → .outdoor
        let location: HKWorkoutSessionLocationType = resolveLocation(workout)

        // Pool swimming detection: SWIMMING with indoor location.
        // Drives `.poolSwimDistanceWithTime` goal usage on iOS 18+.
        let isPoolSwimming: Bool = (workout.sport == .swimming && location == .indoor)

        let allBlocks = workout.blocks ?? []
        // Top-level unit preference derived from metricType:
        // imperial → mile/yard, metric → km/meter, unspecified/nil → fallback to workout.unit
        let workoutUnit: String? = resolveWorkoutUnit(workout)

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
                ? buildWorkoutStep(from: warmupBlocksList.first!, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit, isPoolSwimming: isPoolSwimming)
                : nil
            cooldownStep    = hasCooldown
                ? buildWorkoutStep(from: cooldownBlocksList.last!, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit, isPoolSwimming: isPoolSwimming)
                : nil
            // Keep original block order — only remove the first WARMUP (used as warmupStep)
            // and the last COOLDOWN (used as cooldownStep). Everything else stays in place.
            let firstWarmupIdx  = hasWarmup   ? allBlocks.firstIndex(where: { $0.type?.uppercased() == "WARMUP" })   : nil
            let lastCooldownIdx = hasCooldown ? allBlocks.lastIndex(where:  { $0.type?.uppercased() == "COOLDOWN" }) : nil
            mainForInterval = allBlocks.enumerated().compactMap { idx, block in
                if let wi = firstWarmupIdx,  idx == wi { return nil }
                if let ci = lastCooldownIdx, idx == ci { return nil }
                return block
            }
        } else if hasWarmup && hasCooldown {
            // No interval blocks — keep original order, only remove the last COOLDOWN (cooldownStep).
            let lastCooldownIdx = allBlocks.lastIndex(where: { $0.type?.uppercased() == "COOLDOWN" })
            warmupStep      = nil
            cooldownStep    = buildWorkoutStep(from: cooldownBlocksList.last!, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit, isPoolSwimming: isPoolSwimming)
            mainForInterval = allBlocks.enumerated().compactMap { idx, block in
                if let ci = lastCooldownIdx, idx == ci { return nil }
                return block
            }
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

        var intervalBlocks = buildIntervalBlocks(from: mainForInterval, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit, isPoolSwimming: isPoolSwimming)

        // No blocks: wrap the top-level goal into a single interval block
        if intervalBlocks.isEmpty {
            let topGoal = resolveGoal(
                measurementUnit: workoutUnit,
                distance: workout.distance,
                duration: workout.duration,
                workoutUnit: workoutUnit,
                isPoolSwimming: isPoolSwimming
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
        workoutUnit: String? = nil,
        isPoolSwimming: Bool = false
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
                                              workoutUnit: workoutUnit,
                                              isPoolSwimming: isPoolSwimming,
                                              zoneUnit: block.zoneUnit,
                                              targetRange: block.targetRange)
                step.step.alert = resolveAlert(zoneUnit: block.zoneUnit,
                                               targetRange: block.targetRange,
                                               sport: sport,
                                               activity: activity,
                                               location: location,
                                               workoutUnit: workoutUnit)
                result.append(IntervalBlock(steps: [step], iterations: 1))

            case "REST", "RECOVERY", "WARMUP", "COOLDOWN":
                var step = IntervalStep(.recovery)
                step.step.goal  = resolveGoal(measurementUnit: block.measurementUnit,
                                              distance: block.distance,
                                              duration: block.duration,
                                              workoutUnit: workoutUnit,
                                              isPoolSwimming: isPoolSwimming,
                                              zoneUnit: block.zoneUnit,
                                              targetRange: block.targetRange)
                step.step.alert = resolveAlert(zoneUnit: block.zoneUnit,
                                               targetRange: block.targetRange,
                                               sport: sport,
                                               activity: activity,
                                               location: location,
                                               workoutUnit: workoutUnit)
                // Set displayName so Apple Watch labels the step (iOS 18+/watchOS 11+)
                if #available(iOS 18.0, watchOS 11.0, *) {
                    switch blockType {
                    case "WARMUP":   step.step.displayName = "Warmup"
                    case "COOLDOWN": step.step.displayName = "Cooldown"
                    default: break
                    }
                }
                result.append(IntervalBlock(steps: [step], iterations: 1))

            case "REPEAT":
                let children   = block.blocks ?? []
                let iterations = block.blockRepeat ?? 1

                guard !children.isEmpty else {
                    print("⚠️ REPEAT block has no children — skipping")
                    continue
                }

                let steps: [IntervalStep] = children.map {
                    buildIntervalStep(from: $0, sport: sport, activity: activity, location: location, workoutUnit: workoutUnit, isPoolSwimming: isPoolSwimming)
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
        workoutUnit: String? = nil,
        isPoolSwimming: Bool = false
    ) -> IntervalStep {

        let purpose = intervalStepPurpose(for: block.type)
        var step    = IntervalStep(purpose)

        step.step.goal  = resolveGoal(
            measurementUnit: block.measurementUnit,
            distance: block.distance,
            duration: block.duration,
            workoutUnit: workoutUnit,
            isPoolSwimming: isPoolSwimming,
            zoneUnit: block.zoneUnit,
            targetRange: block.targetRange
        )
        step.step.alert = resolveAlert(
            zoneUnit: block.zoneUnit,
            targetRange: block.targetRange,
            sport: sport,
            activity: activity,
            location: location,
            workoutUnit: workoutUnit
        )

        // Set displayName so Apple Watch labels the step (iOS 18+/watchOS 11+)
        if #available(iOS 18.0, watchOS 11.0, *) {
            let t = block.type?.uppercased() ?? ""
            switch t {
            case "WARMUP":   step.step.displayName = "Warmup"
            case "COOLDOWN": step.step.displayName = "Cooldown"
            default: break
            }
        }

        return step
    }

    // MARK: - WorkoutStep builder (warmup / cooldown)

    private func buildWorkoutStep(
        from block: WorkoutInstanceModelBlock,
        sport: String,
        activity: HKWorkoutActivityType,
        location: HKWorkoutSessionLocationType,
        workoutUnit: String? = nil,
        isPoolSwimming: Bool = false
    ) -> WorkoutStep {

        let goal  = resolveGoal(
            measurementUnit: block.measurementUnit,
            distance: block.distance,
            duration: block.duration,
            workoutUnit: workoutUnit,
            isPoolSwimming: isPoolSwimming,
            zoneUnit: block.zoneUnit,
            targetRange: block.targetRange
        )
        let alert = resolveAlert(
            zoneUnit: block.zoneUnit,
            targetRange: block.targetRange,
            sport: sport,
            activity: activity,
            location: location,
            workoutUnit: workoutUnit
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
        workoutUnit: String? = nil,
        isPoolSwimming: Bool = false,
        zoneUnit: String? = nil,
        targetRange: TargetRange? = nil
    ) -> WorkoutGoal {
        // measurement_unit is the primary discriminator:
        // distance units (meter, yard, km, mile) → distance-based goal
        // time units (second, minute) → duration-based goal

        if isDistanceUnit(measurementUnit), let dist = distance, dist > 0 {
            let unitLength = lengthUnit(for: workoutUnit ?? measurementUnit)

            // Pool swimming → .poolSwimDistanceWithTime (iOS 18+)
            // Swimming distance is already in target unit (yards/meters).
            // Duration is calculated from pace when zone_unit is PACE/SPEED.
            if isPoolSwimming {
                if #available(iOS 18.0, *) {
                    let distMeasurement = Measurement(value: dist, unit: unitLength)
                    let durationSeconds = calculateDurationFromPace(
                        distance: dist,
                        measurementUnit: workoutUnit ?? measurementUnit,
                        zoneUnit: zoneUnit,
                        targetRange: targetRange,
                        fallbackDuration: duration
                    )
                    let timeMeasurement = Measurement(value: durationSeconds, unit: UnitDuration.seconds)
                    return .poolSwimDistanceWithTime(distMeasurement, timeMeasurement)
                }
            }

            // Non-swimming: distance is in meters, convert to target unit
            let convertedValue = Measurement(value: dist, unit: UnitLength.meters)
                .converted(to: unitLength).value
            return .distance(convertedValue, unitLength)
        }

        if isTimeUnit(measurementUnit), let dur = duration, dur > 0 {
            if measurementUnit?.lowercased() == "minute" {
                return .time(Double(dur), .minutes)
            }
            return .time(Double(dur), .seconds)
        }

        return .open
    }

    /// Calculates duration in seconds from pace/speed target range.
    /// Pace values are in seconds per 1000m. Average of low+high gives avg pace.
    /// Duration = distance_in_meters / avg_speed_mps
    private func calculateDurationFromPace(
        distance: Double,
        measurementUnit: String?,
        zoneUnit: String?,
        targetRange: TargetRange?,
        fallbackDuration: Int?
    ) -> Double {
        let unit = zoneUnit?.uppercased() ?? ""
        let isPaceOrSpeed = (unit == "PACE" || unit == "SPEED")

        if isPaceOrSpeed,
           let low = targetRange?.low, let high = targetRange?.high,
           low > 0 || high > 0 {
            let avgPace = Double(low + high) / 2.0
            guard avgPace > 0 else {
                return Double(fallbackDuration ?? 0)
            }
            // Convert distance to meters for speed calculation
            let distInMeters = Measurement(value: distance, unit: lengthUnit(for: measurementUnit))
                .converted(to: .meters).value
            let avgSpeedMps = 1000.0 / avgPace
            return distInMeters / avgSpeedMps
        }

        return Double(fallbackDuration ?? 0)
    }

    // MARK: - Location helper

    /// Unified location resolver for ALL sports (Swimming, Running, Cycling, Walking, etc.).
    /// `summary.indoor_outdoor == "INDOOR"` → `.indoor`, otherwise (OUTDOOR or nil) → `.outdoor`.
    private func resolveLocation(_ workout: WorkoutInstanceModelElement) -> HKWorkoutSessionLocationType {
        let raw = workout.summary?.indoorOutdoor
        return (raw == .indoor) ? .indoor : .outdoor
    }

    // MARK: - Unit resolution

    /// Resolves the preferred display unit for workout goals based on `metricType`.
    /// - `.imperial`: swimming → "yard", non-swimming → "mile"
    /// - `.metric`: swimming → "meter", non-swimming → "km"
    /// - `.unspecified` or nil: falls back to `workout.unit` or "meter"
    private func resolveWorkoutUnit(_ workout: WorkoutInstanceModelElement) -> String? {
        switch workout.metricType {
        case .imperial:
            return workout.sport.isSwimmingType ? "yard" : "mile"
        case .metric:
            return workout.sport.isSwimmingType ? "meter" : "km"
        case .unspecified, .none:
            return workout.unit ?? "meter"
        }
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
        location: HKWorkoutSessionLocationType,
        workoutUnit: String? = nil
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
            // Use milesPerHour for imperial so Apple Watch displays pace as min/mi
            if workoutUnit?.lowercased() == "mile" {
                let slowMph = slowMps * 3600.0 / 1609.344
                let fastMph = fastMps * 3600.0 / 1609.344
                resolved = .speed(slowMph...fastMph, unit: .milesPerHour, metric: .current)
            } else {
                resolved = .speed(slowMps...fastMps, unit: .metersPerSecond, metric: .current)
            }

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

    private func isTimeUnit(_ unit: String?) -> Bool {
        guard let u = unit?.lowercased() else { return false }
        return ["second", "minute"].contains(u)
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
