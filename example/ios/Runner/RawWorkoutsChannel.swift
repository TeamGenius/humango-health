//
//  RawWorkoutsChannel.swift
//  Runner (example app)
//
//  Queries HealthKit workouts directly — no humango_health library classes used.
//  Returns everything Apple provides: workout fields, workoutActivities (multi-sport),
//  GPS route, and associated quantity samples (HR, pace, power, etc.).
//
//  Channel: "com.humango.example/rawWorkouts"
//  Methods:
//    fetchRawWorkouts({ startDate, endDate })      → [String]  (summary JSONs)
//    fetchRawWorkoutDetail({ uuid })                → String    (full JSON with route + samples)
//

import Flutter
import HealthKit
import CoreLocation
import Foundation

final class RawWorkoutsChannel: NSObject, FlutterPlugin {

    private let healthStore = HKHealthStore()

    /// Cache fetched workouts so we can look up by UUID for detail requests.
    private var cachedWorkouts: [String: HKWorkout] = [:]

    /// Max samples per quantity type when fetching associated samples.
    private static let maxSamplesPerType = 500

    /// Whether we have already requested HealthKit authorization for detail queries.
    private var hasRequestedDetailAuth = false

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.humango.example/rawWorkouts",
            binaryMessenger: registrar.messenger()
        )
        let instance = RawWorkoutsChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - Method dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "fetchRawWorkouts":
            guard
                let args = call.arguments as? [String: Any],
                let startISO = args["startDate"] as? String,
                let endISO   = args["endDate"]   as? String,
                let startDate = Self.parseISO(startISO),
                let endDate   = Self.parseISO(endISO)
            else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "startDate and endDate (ISO8601) are required",
                                    details: nil))
                return
            }
            Task {
                do {
                    let jsons = try await self.fetchWorkouts(from: startDate, to: endDate)
                    DispatchQueue.main.async { result(jsons) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "FETCH_ERROR",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            }

        case "fetchRawWorkoutDetail":
            guard
                let args = call.arguments as? [String: Any],
                let uuid = args["uuid"] as? String,
                let workout = cachedWorkouts[uuid]
            else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "uuid is required and must match a previously fetched workout",
                                    details: nil))
                return
            }
            Task {
                do {
                    let json = try await self.fetchWorkoutDetail(workout)
                    DispatchQueue.main.async { result(json) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DETAIL_ERROR",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Fetch workout list (summaries)

    private func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [String] {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate, end: endDate, options: []
        )

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: HKObjectQueryNoLimit
        )

        let samples = try await descriptor.result(for: healthStore)
        let workouts = samples.compactMap { $0 as? HKWorkout }

        // Cache for later detail lookups.
        cachedWorkouts.removeAll()
        for w in workouts { cachedWorkouts[w.uuid.uuidString] = w }

        let iso = Self.makeISOFormatter()
        var results: [String] = []

        for workout in workouts {
            let dict = buildWorkoutSummary(workout, iso: iso)
            if let json = Self.toJSON(dict) { results.append(json) }
        }

        return results
    }

    // MARK: - Fetch workout detail (route + samples + activities)

    /// Request read authorization for all the types we need for detail queries.
    private func ensureDetailAuthorization() async throws {
        guard !hasRequestedDetailAuth else { return }

        var readTypes: Set<HKObjectType> = [
            HKSeriesType.workoutRoute(),
            HKWorkoutType.workoutType(),
        ]
        for typeId in Self.sampleQueryTypes {
            if let qt = HKQuantityType.quantityType(forIdentifier: typeId) {
                readTypes.insert(qt)
            }
        }

        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        hasRequestedDetailAuth = true
    }

    private func fetchWorkoutDetail(_ workout: HKWorkout) async throws -> String {
        // Ensure we have authorization before querying route/samples.
        try await ensureDetailAuthorization()

        let iso = Self.makeISOFormatter()
        var dict: [String: Any] = [:]

        // 1. Workout activities (multi-sport segments, iOS 16+)
        if #available(iOS 16.0, *) {
            dict["workoutActivities"] = workout.workoutActivities.map { activity -> [String: Any] in
                var a: [String: Any] = [
                    "workoutActivityType":    activityTypeName(activity.workoutConfiguration.activityType),
                    "workoutActivityTypeRaw": activity.workoutConfiguration.activityType.rawValue,
                    "startDate":              iso.string(from: activity.startDate),
                    "endDate":                activity.endDate.map { iso.string(from: $0) } ?? "",
                    "durationSeconds":        activity.endDate.map { $0.timeIntervalSince(activity.startDate) } ?? 0,
                ]
                // Per-activity statistics
                if !activity.allStatistics.isEmpty {
                    var statsDict: [String: Any] = [:]
                    for (qType, stats) in activity.allStatistics {
                        statsDict[qType.identifier] = Self.serializeStatistics(stats, unit: preferredUnit(for: qType))
                    }
                    a["statistics"] = statsDict
                }
                return a
            }
        }

        // 2. GPS route
        dict["route"] = try await fetchRoute(for: workout, iso: iso)

        // 3. Associated quantity samples
        dict["associatedSamples"] = try await fetchAssociatedSamples(for: workout, iso: iso)

        guard let json = Self.toJSON(dict) else {
            throw NSError(domain: "RawWorkoutsChannel", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to serialize detail JSON"])
        }
        return json
    }

    // MARK: - Route fetch (HKWorkoutRoute → CLLocation points)

    private func fetchRoute(for workout: HKWorkout, iso: ISO8601DateFormatter) async throws -> [[String: Any]] {
        // Find HKWorkoutRoute objects associated with this workout.
        let routeType = HKSeriesType.workoutRoute()
        let predicate = HKQuery.predicateForObjects(from: workout)

        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: routeType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        var allPoints: [[String: Any]] = []

        for route in routes {
            let locations: [CLLocation] = try await withCheckedThrowingContinuation { continuation in
                var collected: [CLLocation] = []
                let routeQuery = HKWorkoutRouteQuery(route: route) { _, newLocations, done, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let newLocations = newLocations {
                        collected.append(contentsOf: newLocations)
                    }
                    if done {
                        continuation.resume(returning: collected)
                    }
                }
                self.healthStore.execute(routeQuery)
            }

            for loc in locations {
                allPoints.append([
                    "latitude":            loc.coordinate.latitude,
                    "longitude":           loc.coordinate.longitude,
                    "altitude":            loc.altitude,
                    "speed":               loc.speed,
                    "course":              loc.course,
                    "horizontalAccuracy":  loc.horizontalAccuracy,
                    "verticalAccuracy":    loc.verticalAccuracy,
                    "timestamp":           iso.string(from: loc.timestamp),
                ])
            }
        }

        return allPoints
    }

    // MARK: - Associated quantity samples

    /// Quantity types to query for associated samples.
    private static let sampleQueryTypes: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .activeEnergyBurned,
        .basalEnergyBurned,
        .distanceWalkingRunning,
        .distanceCycling,
        .distanceSwimming,
        .stepCount,
        .swimmingStrokeCount,
        .runningSpeed,
        .runningPower,
        .runningStrideLength,
        .runningGroundContactTime,
        .runningVerticalOscillation,
        .cyclingSpeed,
        .cyclingPower,
        .cyclingCadence,
        .respiratoryRate,
        .vo2Max,
    ]

    private func fetchAssociatedSamples(
        for workout: HKWorkout,
        iso: ISO8601DateFormatter
    ) async throws -> [String: Any] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        var result: [String: Any] = [:]

        for typeId in Self.sampleQueryTypes {
            guard let qType = HKQuantityType.quantityType(forIdentifier: typeId) else { continue }
            let unit = preferredUnit(for: qType)

            let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: qType,
                    predicate: predicate,
                    limit: Self.maxSamplesPerType,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                ) { _, samples, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                    }
                }
                self.healthStore.execute(query)
            }

            if !samples.isEmpty {
                result[typeId.rawValue] = [
                    "count": samples.count,
                    "unit": unit.unitString,
                    "samples": samples.map { sample -> [String: Any] in
                        [
                            "value":     sample.quantity.doubleValue(for: unit),
                            "startDate": iso.string(from: sample.startDate),
                            "endDate":   iso.string(from: sample.endDate),
                        ]
                    },
                ] as [String: Any]
            }
        }

        return result
    }

    // MARK: - Build workout summary dict

    private func buildWorkoutSummary(_ workout: HKWorkout, iso: ISO8601DateFormatter) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["uuid"]                   = workout.uuid.uuidString
        debugPrint("[RawWorkoutsChannel] workoutActivityType: \(workout.workoutActivityType) rawValue: \(workout.workoutActivityType.rawValue) name: \(activityTypeName(workout.workoutActivityType))")
        dict["workoutActivityType"]    = activityTypeName(workout.workoutActivityType)
        dict["workoutActivityTypeRaw"] = workout.workoutActivityType.rawValue
        dict["startDate"]              = iso.string(from: workout.startDate)
        dict["endDate"]                = iso.string(from: workout.endDate)
        dict["durationSeconds"]        = workout.duration

        if let dist = workout.totalDistance {
            dict["totalDistanceMeters"] = dist.doubleValue(for: .meter())
        }
        if let energy = workout.totalEnergyBurned {
            dict["totalEnergyBurnedKcal"] = energy.doubleValue(for: .kilocalorie())
        }
        if let strokes = workout.totalSwimmingStrokeCount {
            dict["totalSwimmingStrokeCount"] = strokes.doubleValue(for: .count())
        }

        dict["sourceName"]     = workout.sourceRevision.source.name
        dict["sourceBundleId"] = workout.sourceRevision.source.bundleIdentifier
        dict["sourceVersion"]  = workout.sourceRevision.version ?? ""

        if let device = workout.device {
            dict["device"] = [
                "name":            device.name ?? "",
                "model":           device.model ?? "",
                "manufacturer":    device.manufacturer ?? "",
                "hardwareVersion": device.hardwareVersion ?? "",
                "softwareVersion": device.softwareVersion ?? "",
            ] as [String: Any]
        }

        if let meta = workout.metadata, !meta.isEmpty {
            var safeMeta: [String: String] = [:]
            for (key, value) in meta { safeMeta[key] = "\(value)" }
            dict["metadata"] = safeMeta
        }

        if let events = workout.workoutEvents, !events.isEmpty {
            dict["workoutEvents"] = events.map { event -> [String: Any] in
                [
                    "type":      event.type.rawValue,
                    "typeName":  Self.eventTypeName(event.type),
                    "startDate": iso.string(from: event.dateInterval.start),
                    "endDate":   iso.string(from: event.dateInterval.end),
                ]
            }
            dict["workoutEventCount"] = events.count
        }

        if !workout.allStatistics.isEmpty {
            var statsDict: [String: Any] = [:]
            for (quantityType, stats) in workout.allStatistics {
                let unit = preferredUnit(for: quantityType)
                statsDict[quantityType.identifier] = Self.serializeStatistics(stats, unit: unit)
            }
            dict["statistics"] = statsDict
        }

        // Workout activities (iOS 16+)
        if #available(iOS 16.0, *) {
            let activities = workout.workoutActivities
            dict["workoutActivityCount"] = activities.count
            if !activities.isEmpty {
                dict["workoutActivities"] = activities.map { activity -> [String: Any] in
                    var a: [String: Any] = [
                        "workoutActivityType":    activityTypeName(activity.workoutConfiguration.activityType),
                        "workoutActivityTypeRaw": activity.workoutConfiguration.activityType.rawValue,
                        "startDate":              iso.string(from: activity.startDate),
                        "endDate":                activity.endDate.map { iso.string(from: $0) } ?? "",
                        "durationSeconds":        activity.endDate.map { $0.timeIntervalSince(activity.startDate) } ?? 0,
                    ]
                    if !activity.allStatistics.isEmpty {
                        var statsDict: [String: Any] = [:]
                        for (qType, stats) in activity.allStatistics {
                            statsDict[qType.identifier] = Self.serializeStatistics(stats, unit: preferredUnit(for: qType))
                        }
                        a["statistics"] = statsDict
                    }
                    return a
                }
            }
        }

        return dict
    }

    // MARK: - Helpers

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func parseISO(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    private static func toJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func serializeStatistics(_ stats: HKStatistics, unit: HKUnit) -> [String: Any] {
        var s: [String: Any] = [:]
        if let sum = stats.sumQuantity()     { s["sum"] = sum.doubleValue(for: unit) }
        if let avg = stats.averageQuantity() { s["avg"] = avg.doubleValue(for: unit) }
        if let min = stats.minimumQuantity() { s["min"] = min.doubleValue(for: unit) }
        if let max = stats.maximumQuantity() { s["max"] = max.doubleValue(for: unit) }
        s["unit"] = unit.unitString
        return s
    }

    private static func eventTypeName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause:          return "Pause"
        case .resume:         return "Resume"
        case .lap:            return "Lap"
        case .marker:         return "Marker"
        case .motionPaused:   return "Motion Paused"
        case .motionResumed:  return "Motion Resumed"
        case .segment:        return "Segment"
        case .pauseOrResumeRequest: return "Pause/Resume Request"
        @unknown default:     return "Unknown(\(type.rawValue))"
        }
    }

    /// Best-effort preferred unit for common quantity types.
    private func preferredUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.runningSpeed.rawValue,
             HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
            return HKUnit.meter().unitDivided(by: .second())
        case HKQuantityTypeIdentifier.runningPower.rawValue,
             HKQuantityTypeIdentifier.cyclingPower.rawValue:
            return .watt()
        case HKQuantityTypeIdentifier.runningStrideLength.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
            return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
            return .meterUnit(with: .centi)
        case HKQuantityTypeIdentifier.cyclingCadence.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        default:
            return .count()
        }
    }

    /// camelCase sport key matching backend mapping — mirrors HKWorkoutActivityType+Extensions.name.
    private func activityTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:                       return "running"
        case .cycling:                       return "cycling"
        case .swimming:                      return "swimming"
        case .walking:                       return "walking"
        case .hiking:                        return "hiking"
        case .yoga:                          return "yoga"
        case .functionalStrengthTraining:    return "functionalStrengthTraining"
        case .traditionalStrengthTraining:   return "traditionalStrengthTraining"
        case .coreTraining:                  return "coreTraining"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .flexibility:                   return "flexibility"
        case .cooldown:                      return "cooldown"
        case .rowing:                        return "rowing"
        case .elliptical:                    return "elliptical"
        case .stairClimbing:                 return "stairClimbing"
        case .mixedCardio:                   return "mixedCardio"
        case .crossTraining:                 return "crossTraining"
        case .dance:                         return "dance"
        case .pilates:                       return "pilates"
        case .golf:                          return "golf"
        case .tennis:                        return "tennis"
        case .basketball:                    return "basketball"
        case .soccer:                        return "soccer"
        case .hockey:                        return "hockey"
        case .rugby:                         return "rugby"
        case .boxing:                        return "boxing"
        case .climbing:                      return "climbing"
        case .paddleSports:                  return "paddleSports"
        case .skatingSports:                 return "skatingSports"
        case .surfingSports:                 return "surfingSports"
        case .snowSports:                    return "snowSports"
        case .waterFitness:                  return "waterFitness"
        case .waterSports:                   return "waterSports"
        case .martialArts:                   return "martialArts"
        case .badminton:                     return "badminton"
        case .pickleball:                    return "pickleball"
        case .jumpRope:                      return "jumpRope"
        case .kickboxing:                    return "kickboxing"
        case .taiChi:                        return "taiChi"
        case .wrestling:                     return "wrestling"
        case .fencing:                       return "fencing"
        case .fitnessGaming:                 return "fitnessGaming"
        case .handball:                      return "handball"
        case .racquetball:                   return "racquetball"
        case .squash:                        return "squash"
        case .tableTennis:                   return "tableTennis"
        case .trackAndField:                 return "trackAndField"
        case .crossCountrySkiing:            return "crossCountrySkiing"
        case .downhillSkiing:                return "downhillSkiing"
        case .snowboarding:                  return "snowboarding"
        case .americanFootball:              return "americanFootball"
        case .baseball:                      return "baseball"
        case .volleyball:                    return "volleyball"
        case .softball:                      return "softball"
        case .lacrosse:                      return "lacrosse"
        case .cricket:                       return "cricket"
        case .equestrianSports:              return "equestrianSports"
        case .barre:                         return "barre"
        case .fishing:                       return "fishing"
        case .hunting:                       return "hunting"
        case .gymnastics:                    return "gymnastics"
        case .handCycling:                   return "handCycling"
        case .waterPolo:                     return "waterPolo"
        case .mindAndBody:                   return "mindAndBody"
        case .play:                          return "play"
        case .preparationAndRecovery:        return "preparationAndRecovery"
        case .wheelchairWalkPace:            return "wheelchairWalkPace"
        case .wheelchairRunPace:             return "wheelchairRunPace"
        case .swimBikeRun:                   return "swimBikeRun"
        case .transition:                    return "transition"
        case .underwaterDiving:              return "underwaterDiving"
        case .sailing:                       return "sailing"
        case .archery:                       return "archery"
        case .bowling:                       return "bowling"
        case .curling:                       return "curling"
        case .stairs:                        return "stairs"
        case .stepTraining:                  return "stepTraining"
        case .discSports:                    return "discSports"
        case .australianFootball:            return "australianFootball"
        case .cardioDance:                   return "cardioDance"
        case .socialDance:                   return "socialDance"
        case .other:                         return "other"
        default:                             return "other"
        }
    }
}
