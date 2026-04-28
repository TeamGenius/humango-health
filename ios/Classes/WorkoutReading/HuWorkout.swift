import Foundation
import HealthKit
import CoreLocation

// MARK: - HuRouteData

@available(iOS 16.0, *)
public struct HuRouteData {
    public let samples: [[HKQuantitySample]]
    public let locations: [CLLocation]

    public init(samples: [[HKQuantitySample]], locations: [CLLocation]) {
        self.samples = samples
        self.locations = locations
    }

    public static func empty() -> HuRouteData {
        HuRouteData(samples: [], locations: [])
    }

    public func toDict() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let populatedSamples = samples.filter { !$0.isEmpty }
        let formattedSamples: [[String: Any]] = populatedSamples.map { group in
            [
                "type": group[0].quantityType.identifier,
                "series": group.map { sample -> [String: Any] in
                    [
                        "value":     getSampleValue(sample: sample),
                        "timestamp": formatter.string(from: sample.startDate)
                    ]
                }
            ]
        }

        let locationsArr: [[String: Any]] = locations.map { loc in
            [
                "timestamp": formatter.string(from: loc.timestamp),
                "latitude":  loc.coordinate.latitude,
                "longitude": loc.coordinate.longitude,
                "altitude":  loc.altitude,
                "speed":     loc.speed
            ]
        }

        return [
            "samples":   formattedSamples,
            "locations": locationsArr
        ]
    }
}

// MARK: - HuWorkout

@available(iOS 16.0, *)
public struct HuWorkout {
    public let distance: HKQuantity?
    public let duration: TimeInterval
    public let sport: HKWorkoutActivityType
    public let start_time: Date
    public let routeData: HuRouteData
    public let deviceActivityId: String
    public let statistics: [HKQuantityType: HKStatistics]
    /// Filtered to pause / resume / lap only.
    public let events: [HKWorkoutEvent]
    public let workoutActivities: [HKWorkoutActivity]?
    public let metadata: [String: Any]?

    public init(
        distance: HKQuantity?,
        duration: TimeInterval,
        sport: HKWorkoutActivityType,
        start_time: Date,
        routeData: HuRouteData,
        deviceActivityId: String,
        statistics: [HKQuantityType: HKStatistics],
        events: [HKWorkoutEvent]?,
        workoutActivities: [HKWorkoutActivity]?,
        metadata: [String: Any]?
    ) {
        let allowedEventTypes: [Int] = [
            HKWorkoutEventType.pause.rawValue,
            HKWorkoutEventType.resume.rawValue,
            HKWorkoutEventType.lap.rawValue
        ]
        self.distance          = distance
        self.duration          = duration
        self.sport             = sport
        self.start_time        = start_time
        self.routeData         = routeData
        self.deviceActivityId  = deviceActivityId
        self.statistics        = statistics
        self.events            = events?.filter { allowedEventTypes.contains($0.type.rawValue) } ?? []
        self.workoutActivities = workoutActivities
        self.metadata          = metadata
    }

    /// Returns `true` when the workout contains multiple sub-activities
    /// (e.g. Triathlon: Run → Transition → Bike → Transition → Swim).
    public var isMultisport: Bool {
        if #available(iOS 16.0, *), let activities = workoutActivities, activities.count > 1 {
            return true
        }
        return false
    }

    public func toDict() -> [String: Any]? {
        // Multisport workouts (Triathlon etc.) use a sessions-based format
        if isMultisport {
            return toMultisportDict()
        }
        return toSingleSportDict()
    }

    // MARK: - Single-sport serialization (existing behaviour)

    private func toSingleSportDict() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Build event list: workoutActivities as SEGMENT events (iOS 17+, multi-sport)
        // followed by standard filtered events (pause / resume / lap)
        var eventList: [[String: Any]] = []
        if #available(iOS 17.0, *), let activities = workoutActivities, activities.count > 1 {
            eventList = activities.map { activity in
                [
                    "type":       getEventName(val: HKWorkoutEventType.segment.rawValue),
                    "metadata":   formatMetadata(metadata: activity.metadata),
                    "start_time": formatter.string(from: activity.startDate),
                    "end_time":   formatter.string(from: activity.endDate ?? Date())
                ]
            }
        }
        eventList += events.map { event in
            [
                "type":       getEventName(val: event.type.rawValue),
                "metadata":   formatMetadata(metadata: event.metadata),
                "start_time": formatter.string(from: event.dateInterval.start),
                "end_time":   formatter.string(from: event.dateInterval.end)
            ]
        }

        return [
            "distance":           Int(round(distance?.doubleValue(for: .meter()) ?? 0.0)),
            "duration":           Int(round(duration)),
            "sport":              sport.name,
            "start_time":         formatter.string(from: start_time),
            "serial":             deviceActivityId,
            "series_data":        routeData.toDict(),
            "device_activity_id": deviceActivityId,
            "statistics":         formatStatistics(statistics: statistics),
            "events":             eventList,
            "metadata":           formatMetadata(metadata: metadata)
        ]
    }

    // MARK: - Multisport serialization (sessions-based)

    private func toMultisportDict() -> [String: Any]? {
        guard #available(iOS 16.0, *), let activities = workoutActivities, activities.count > 1 else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let endTime = start_time.addingTimeInterval(duration)
        let seriesData = routeData.toDict()

        var sessions: [[String: Any]] = []
        for (index, activity) in activities.enumerated() {
            let activityEndDate = activity.endDate ?? endTime
            let activityDuration = activity.duration

            // Extract per-activity distance from its statistics
            let activityDistance: Int
            if #available(iOS 16.0, *) {
                activityDistance = extractDistance(from: activity.allStatistics)
            } else {
                activityDistance = 0
            }

            // Format per-activity events
            let activityEvents: [[String: Any]] = (activity.workoutEvents ?? []).map { event in
                [
                    "type":       getEventName(val: event.type.rawValue),
                    "metadata":   formatMetadata(metadata: event.metadata),
                    "start_time": formatter.string(from: event.dateInterval.start),
                    "end_time":   formatter.string(from: event.dateInterval.end)
                ]
            }

            // Format per-activity statistics
            let activityStats: [[String: Double]]
            if #available(iOS 16.0, *) {
                activityStats = formatStatistics(statistics: activity.allStatistics)
            } else {
                activityStats = []
            }

            let session: [String: Any] = [
                "session_id":         "\(deviceActivityId)_\(index)",
                "device_activity_id": deviceActivityId,
                "start_time":         formatter.string(from: activity.startDate),
                "end_time":           formatter.string(from: activityEndDate),
                "type":               "session",
                "sport":              activity.workoutConfiguration.activityType.name,
                "distance":           activityDistance,
                "duration":           Int(round(activityDuration)),
                "events":             activityEvents,
                "metadata":           formatMetadata(metadata: activity.metadata),
                "statistics":         activityStats
            ]
            sessions.append(session)
        }

        return [
            "start_time":         formatter.string(from: start_time),
            "end_time":           formatter.string(from: endTime),
            "activity_id":        deviceActivityId,
            "device_activity_id": deviceActivityId,
            "serial":             deviceActivityId,
            "sport":              sport.name,
            "statistics":         formatStatistics(statistics: statistics),
            "metadata":           formatMetadata(metadata: metadata),
            "series_data":        seriesData,
            "sessions":           sessions
        ]
    }

    /// Sums distance statistics (walking/running + cycling + swimming) from an activity's statistics.
    private func extractDistance(from stats: [HKQuantityType: HKStatistics]) -> Int {
        let distanceIds: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming
        ]
        var total: Double = 0
        for id in distanceIds {
            if let qType = HKObjectType.quantityType(forIdentifier: id),
               let stat = stats[qType],
               let sum = stat.sumQuantity() {
                total += sum.doubleValue(for: .meter())
            }
        }
        return Int(round(total))
    }

    public func toJson() -> Data? {
        guard let dict = toDict() else { return nil }
        return try? JSONSerialization.data(withJSONObject: dict, options: [])
    }
}

// MARK: - Statistics formatter

func formatStatistics(statistics: [HKQuantityType: HKStatistics]) -> [[String: Double]] {
    var hkUnits: [HKUnit] = [
        .meter(), .count(), .kilocalorie(), .gram(), .degreeCelsius(), .hertz(), .second()
    ]
    if #available(iOS 16.0, *) { hkUnits.append(.watt()) }

    var result = [[String: Double]]()
    for (quantityType, statistic) in statistics {
        guard let quantity = statistic.averageQuantity() else { continue }
        for unit in hkUnits where quantity.is(compatibleWith: unit) {
            result.append([quantityType.identifier: quantity.doubleValue(for: unit)])
            break
        }
    }
    return result
}

// MARK: - Metadata formatter

func formatMetadata(metadata: [String: Any]?) -> [String: Any] {
    guard let metadata = metadata else { return [:] }
    var out = [String: Any]()
    for (key, value) in metadata {
        switch key {
        case HKMetadataKeySwimmingLocationType:
            out["SWIMMING_LOCATION_TYPE"] = getSwimmingLocationName(val: value as? Int ?? 0)
        case HKMetadataKeySwimmingStrokeStyle:
            out["SWIMMING_STROKE_TYPE"]   = getSwimmingStrokeName(val: value as? Int ?? 0)
        case HKMetadataKeyLapLength:
            if let q = value as? HKQuantity { out["LAP_LENGTH"] = q.doubleValue(for: .meter()) }
        case "FeedbackRpe":        out["FEEDBACK_RPE"]          = value as? Int    ?? -1
        case "FeedbackMood":       out["FEEDBACK_MOOD"]         = value as? Int    ?? -1
        case "WorkoutName":        out["WORKOUT_NAME"]          = value as? String ?? ""
        case "ScheduledWorkoutId": out["SCHEDULED_WORKOUT_ID"]  = value as? Int    ?? 0
        case "dataSource":         out["SOURCE_NAME"]           = value as? String ?? ""
        case "appVersion":         out["APP_VERSION"]           = value as? String ?? ""
        case "appBuild":           out["APP_BUILD"]             = value as? String ?? ""
        case "iosVersion":         out["IOS_VERSION"]           = value as? String ?? ""
        case "isScheduledWorkout":  out["IS_SCHEDULED_WORKOUT"]   = value as? Bool   ?? false
        case "isUserEnteredWorkout": out["IS_USER_ENTERED_WORKOUT"] = value as? Bool   ?? false
        case "scheduledWorkoutId":  out["SCHEDULED_WORKOUT_ID"]   = value as? String ?? ""
        default: break
        }
        if #available(iOS 16.0, *) {
            if key == HKMetadataKeySWOLFScore, let v = value as? Double {
                out["SWOLF_SCORE"] = v
            }
        }
    }
    return out
}

// MARK: - Enum name helpers

func getSwimmingLocationName(val: Int) -> String {
    switch val {
    case HKWorkoutSwimmingLocationType.openWater.rawValue: return "OPEN_WATER"
    case HKWorkoutSwimmingLocationType.pool.rawValue:      return "POOL"
    default:                                               return "UNKNOWN"
    }
}

func getSwimmingStrokeName(val: Int) -> String {
    switch val {
    case HKSwimmingStrokeStyle.backstroke.rawValue:   return "BACKSTROKE"
    case HKSwimmingStrokeStyle.breaststroke.rawValue: return "BREASTSTROKE"
    case HKSwimmingStrokeStyle.butterfly.rawValue:    return "BUTTERFLY"
    case HKSwimmingStrokeStyle.freestyle.rawValue:    return "FREESTYLE"
    case HKSwimmingStrokeStyle.mixed.rawValue:        return "MIXED"
    default:                                          return "UNKNOWN"
    }
}

func getEventName(val: Int) -> String {
    switch val {
    case HKWorkoutEventType.pause.rawValue:                return "PAUSE"
    case HKWorkoutEventType.resume.rawValue:               return "RESUME"
    case HKWorkoutEventType.motionPaused.rawValue:         return "MOTION_PAUSED"
    case HKWorkoutEventType.motionResumed.rawValue:        return "MOTION_RESUMED"
    case HKWorkoutEventType.pauseOrResumeRequest.rawValue: return "PAUSE_OR_RESUME_REQUEST"
    case HKWorkoutEventType.lap.rawValue:                  return "LAP"
    case HKWorkoutEventType.segment.rawValue:              return "SEGMENT"
    case HKWorkoutEventType.marker.rawValue:               return "MARKER"
    default:                                               return "UNKNOWN"
    }
}

// MARK: - Sample value extractor

func getSampleValue(sample: HKQuantitySample) -> Double {
    if #available(iOS 17.0, *) {
        switch sample.sampleType.identifier {
        case HKQuantityTypeIdentifier.cyclingCadence.rawValue:
            return sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        case HKQuantityTypeIdentifier.cyclingPower.rawValue:
            return sample.quantity.doubleValue(for: .watt())
        default: break
        }
    }
    if #available(iOS 16.0, *) {
        switch sample.sampleType.identifier {
        case HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
            return sample.quantity.doubleValue(for: .second())
        case HKQuantityTypeIdentifier.runningPower.rawValue:
            return sample.quantity.doubleValue(for: .watt())
        case HKQuantityTypeIdentifier.runningSpeed.rawValue:
            return sample.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: .second()))
        case HKQuantityTypeIdentifier.runningStrideLength.rawValue:
            return sample.quantity.doubleValue(for: .meter())
        case HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
            return sample.quantity.doubleValue(for: .meter())
        default: break
        }
    }
    switch sample.sampleType.identifier {
    case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
        return sample.quantity.doubleValue(for: .smallCalorie())
    case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
        return sample.quantity.doubleValue(for: .meter())
    case HKQuantityTypeIdentifier.heartRate.rawValue:
        return sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
    case HKQuantityTypeIdentifier.stepCount.rawValue:
        return sample.quantity.doubleValue(for: .count())
    case HKQuantityTypeIdentifier.distanceCycling.rawValue:
        return sample.quantity.doubleValue(for: .meter())
    case HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue:
        return sample.quantity.doubleValue(for: .count())
    case HKQuantityTypeIdentifier.distanceSwimming.rawValue:
        return sample.quantity.doubleValue(for: .meter())
    case HKQuantityTypeIdentifier.vo2Max.rawValue:
        return sample.quantity.doubleValue(for: HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())))
    default:
        return 0.0
    }
}
