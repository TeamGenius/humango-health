//
//  WorkoutInstanceModel.swift
//  Runner
//
//  Created by Vinay Vudatala on 12/02/26.
//  Copyright © 2026 The Chromium Authors. All rights reserved.
//

// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let workoutInstanceModel = try? JSONDecoder().decode(WorkoutInstanceModel.self, from: jsonData)

import Foundation
import HealthKit

// MARK: - WorkoutInstanceModelElement
struct WorkoutInstanceModelElement: Codable {
    let averageIntensity: Int?
    let date: Date
    let blocks: [WorkoutInstanceModelBlock]?
    let brickSummaries: [JSONAny]?
    let distance: Double?
    let distanceRiAdjusted: Double?
    let duration: Int?
    let durationRiAdjusted: Double?
    let id, index, priority: Int?
    let poolSize: String?
    let sport: Sport
    let summary: Summary?
    let tiz: [Int]?
    let trainingLoad: Int?
    let workoutChart: [WorkoutChartUnion]?
    let workoutID: Int?
    let zoneTarget: String?
    /// Preferred display/goal unit for this sport. All incoming distance values are always in
    /// meters; this field tells WorkoutKit which unit to express goals in on Apple Watch.
    /// e.g. "mile", "km", "meter", "yard". Nil → falls back to per-block measurement_unit.
    /// For SWIMMING, pool_size takes precedence over this field.
    let unit: String?

    enum CodingKeys: String, CodingKey {
        case averageIntensity = "average_intensity"
        case date, blocks
        case brickSummaries = "brick_summaries"
        case distance
        case distanceRiAdjusted = "distance_ri_adjusted"
        case duration
        case durationRiAdjusted = "duration_ri_adjusted"
        case id, index, priority
        case poolSize = "pool_size"
        case sport, summary, tiz
        case trainingLoad = "training_load"
        case workoutChart = "workout_chart"
        case workoutID = "workout_id"
        case zoneTarget = "zone_target"
        case unit
    }

}

// MARK: - WorkoutInstanceModelBlock
struct WorkoutInstanceModelBlock: Codable {
    let description: String?
    let distance : Double?
    let duration: Int?
    let equipmentType, measurementUnit: String?
    let sport: Sport?
    let targetRange: TargetRange?
    let trainingLoad: Int?
    let type: String?
    let zoneTarget: FluffyZoneTarget?
    let zoneUnit: String?
    let blocks: [BlockBlock]?
    let blockRepeat: Int?

    enum CodingKeys: String, CodingKey {
        case description, distance, duration
        case equipmentType = "equipment_type"
        case measurementUnit = "measurement_unit"
        case sport
        case targetRange = "target_range"
        case trainingLoad = "training_load"
        case type
        case zoneTarget = "zone_target"
        case zoneUnit = "zone_unit"
        case blocks
        case blockRepeat = "repeat"
    }
}

// MARK: - BlockBlock
struct BlockBlock: Codable {
    let distance: Double?
    let duration: Int?
    let equipmentType, measurementUnit: String?
    let sport: Sport?
    let targetRange: TargetRange?
    let trainingLoad: Int?
    let type: String?
    let zoneTarget: PurpleZoneTarget?
    let zoneUnit, description: String?

    enum CodingKeys: String, CodingKey {
        case distance, duration
        case equipmentType = "equipment_type"
        case measurementUnit = "measurement_unit"
        case sport
        case targetRange = "target_range"
        case trainingLoad = "training_load"
        case type
        case zoneTarget = "zone_target"
        case zoneUnit = "zone_unit"
        case description
    }
}

enum Sport: String, Codable, CaseIterable {
    case running           = "RUNNING"
    case cycling           = "CYCLING"
    case swimming          = "SWIMMING"
    case strength          = "STRENGTH"
    case hiking            = "HIKING"
    case walking           = "WALKING"
    case yoga              = "YOGA"
    case paddling          = "PADDLING"
    case alpineSkiing      = "ALPINE_SKIING"
    case rowing            = "ROWING"
    case cardio            = "CARDIO"
    case nordicSkiing      = "NORDIC_SKIING"
    case snowshoeing       = "SNOWSHOEING"
    case poolSwimming      = "POOL_SWIMMING"
    case openWaterSwimming = "OPEN_WATER_SWIMMING"
    case hiit              = "HIIT"
    case hyrox             = "HYROX"
    case soccer            = "SOCCER"
    case tennis            = "TENNIS"
    case squash            = "SQUASH"
    case pickleball        = "PICKLEBALL"
    case badminton         = "BADMINTON"
    case baseball          = "BASEBALL"
    case hockey            = "HOCKEY"
    case volleyball        = "VOLLEYBALL"
    case handball          = "HANDBALL"
    case basketball        = "BASKETBALL"
    case multisport        = "MULTISPORT"
}

extension Sport {

    var hkWorkoutType: HKWorkoutActivityType {
        switch self {
        case .running:           return .running
        case .cycling:           return .cycling
        case .swimming,
             .poolSwimming,
             .openWaterSwimming:  return .swimming
        case .strength:          return .traditionalStrengthTraining
        case .hiking:            return .hiking
        case .walking:           return .walking
        case .yoga:              return .yoga
        case .paddling:          return .paddleSports
        case .alpineSkiing:      return .downhillSkiing
        case .rowing:            return .rowing
        case .cardio:            return .mixedCardio
        case .nordicSkiing:      return .crossCountrySkiing
        case .snowshoeing:       return .snowSports
        case .hiit, .hyrox:      return .highIntensityIntervalTraining
        case .soccer:            return .soccer
        case .tennis:            return .tennis
        case .squash:            return .squash
        case .pickleball:        return .pickleball
        case .badminton:         return .badminton
        case .baseball:          return .baseball
        case .hockey:            return .hockey
        case .volleyball:        return .volleyball
        case .handball:          return .handball
        case .basketball:        return .basketball
        case .multisport:        return .swimBikeRun
        }
    }

    /// True for swimming variants that should route to SingleGoalWorkout.
    var isSwimmingType: Bool {
        switch self {
        case .swimming, .poolSwimming, .openWaterSwimming: return true
        default: return false
        }
    }

    /// True for multisport (requires SwimBikeRunWorkout builder — not yet implemented).
    var isMultisport: Bool { self == .multisport }

    /// Explicit location override for swimming variants.
    /// `.poolSwimming` → `.indoor`, `.openWaterSwimming` → `.outdoor`, everything else → `nil`.
    var impliedLocation: HKWorkoutSessionLocationType? {
        switch self {
        case .poolSwimming:      return .indoor
        case .openWaterSwimming:  return .outdoor
        default:                 return nil
        }
    }
}

enum WorkoutLocation: String, Codable {
    case outdoor = "OUTDOOR"
    case indoor = "INDOOR"

    var hkLocationType: HKWorkoutSessionLocationType {
        switch self {
        case .outdoor:
            return .outdoor
        case .indoor:
            return .indoor
        }
    }
}

// MARK: - TargetRange
struct TargetRange: Codable {
    let high, low: Int?
}

// MARK: - PurpleZoneTarget
struct PurpleZoneTarget: Codable {
    let zone: String?
}

// MARK: - FluffyZoneTarget
struct FluffyZoneTarget: Codable {
    let zone: String?
    let range: Range?
}

// MARK: - Range
struct Range: Codable {
    let focusMaxRange, focusMinRange: Int?

    enum CodingKeys: String, CodingKey {
        case focusMaxRange = "focus_max_range"
        case focusMinRange = "focus_min_range"
    }
}

// MARK: - Summary
struct Summary: Codable {

    let authorId: Int?
    let brick: Bool?
    let description: Description?
    let elevation: String?
    let form: Bool?
    let indexMax: Double?
    let measurementUnit: String?
    let name: String?
    let sport: Sport?
    let tags: String?
    let terrain: String?
    let testWorkout: Bool?
    let zoneUnit: String?
    let indoorOutdoor: WorkoutLocation?

    enum CodingKeys: String, CodingKey {
        case authorId = "author_id"
        case brick
        case description
        case elevation
        case form
        case indexMax = "index_max"
        case measurementUnit = "measurement_unit"
        case name
        case sport
        case tags
        case terrain
        case testWorkout = "test_workout"
        case zoneUnit = "zone_unit"
        case indoorOutdoor = "indoor_outdoor"
    }
}

// MARK: - Description
struct Description: Codable {
    let execution, fueling, general, purpose: String?
    let tips: String?
}

enum WorkoutChartUnion: Codable {
    case workoutChartClass(WorkoutChartClass)
    case workoutChartClassArray([WorkoutChartClass])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode([WorkoutChartClass].self) {
            self = .workoutChartClassArray(x)
            return
        }
        if let x = try? container.decode(WorkoutChartClass.self) {
            self = .workoutChartClass(x)
            return
        }
        throw DecodingError.typeMismatch(WorkoutChartUnion.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for WorkoutChartUnion"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .workoutChartClass(let x):
            try container.encode(x)
        case .workoutChartClassArray(let x):
            try container.encode(x)
        }
    }
}

// MARK: - WorkoutChartClass
struct WorkoutChartClass: Codable {
    let duration, intensity: Int?
    let sport: Sport?
    let value: Double?
}

typealias WorkoutInstanceModel = [WorkoutInstanceModelElement]

// MARK: - Encode/decode helpers

class JSONNull: Codable, Hashable {

    public static func == (lhs: JSONNull, rhs: JSONNull) -> Bool {
            return true
    }

    public var hashValue: Int {
            return 0
    }

    public init() {}

    public required init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if !container.decodeNil() {
                    throw DecodingError.typeMismatch(JSONNull.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONNull"))
            }
    }

    public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
    }
}

class JSONCodingKey: CodingKey {
    let key: String

    required init?(intValue: Int) {
            return nil
    }

    required init?(stringValue: String) {
            key = stringValue
    }

    var intValue: Int? {
            return nil
    }

    var stringValue: String {
            return key
    }
}

class JSONAny: Codable {

    let value: Any

    static func decodingError(forCodingPath codingPath: [CodingKey]) -> DecodingError {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode JSONAny")
            return DecodingError.typeMismatch(JSONAny.self, context)
    }

    static func encodingError(forValue value: Any, codingPath: [CodingKey]) -> EncodingError {
            let context = EncodingError.Context(codingPath: codingPath, debugDescription: "Cannot encode JSONAny")
            return EncodingError.invalidValue(value, context)
    }

    static func decode(from container: SingleValueDecodingContainer) throws -> Any {
            if let value = try? container.decode(Bool.self) {
                    return value
            }
            if let value = try? container.decode(Int64.self) {
                    return value
            }
            if let value = try? container.decode(Double.self) {
                    return value
            }
            if let value = try? container.decode(String.self) {
                    return value
            }
            if container.decodeNil() {
                    return JSONNull()
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout UnkeyedDecodingContainer) throws -> Any {
            if let value = try? container.decode(Bool.self) {
                    return value
            }
            if let value = try? container.decode(Int64.self) {
                    return value
            }
            if let value = try? container.decode(Double.self) {
                    return value
            }
            if let value = try? container.decode(String.self) {
                    return value
            }
            if let value = try? container.decodeNil() {
                    if value {
                            return JSONNull()
                    }
            }
            if var container = try? container.nestedUnkeyedContainer() {
                    return try decodeArray(from: &container)
            }
            if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self) {
                    return try decodeDictionary(from: &container)
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout KeyedDecodingContainer<JSONCodingKey>, forKey key: JSONCodingKey) throws -> Any {
            if let value = try? container.decode(Bool.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(Int64.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(String.self, forKey: key) {
                    return value
            }
            if let value = try? container.decodeNil(forKey: key) {
                    if value {
                            return JSONNull()
                    }
            }
            if var container = try? container.nestedUnkeyedContainer(forKey: key) {
                    return try decodeArray(from: &container)
            }
            if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key) {
                    return try decodeDictionary(from: &container)
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decodeArray(from container: inout UnkeyedDecodingContainer) throws -> [Any] {
            var arr: [Any] = []
            while !container.isAtEnd {
                    let value = try decode(from: &container)
                    arr.append(value)
            }
            return arr
    }

    static func decodeDictionary(from container: inout KeyedDecodingContainer<JSONCodingKey>) throws -> [String: Any] {
            var dict = [String: Any]()
            for key in container.allKeys {
                    let value = try decode(from: &container, forKey: key)
                    dict[key.stringValue] = value
            }
            return dict
    }

    static func encode(to container: inout UnkeyedEncodingContainer, array: [Any]) throws {
            for value in array {
                    if let value = value as? Bool {
                            try container.encode(value)
                    } else if let value = value as? Int64 {
                            try container.encode(value)
                    } else if let value = value as? Double {
                            try container.encode(value)
                    } else if let value = value as? String {
                            try container.encode(value)
                    } else if value is JSONNull {
                            try container.encodeNil()
                    } else if let value = value as? [Any] {
                            var container = container.nestedUnkeyedContainer()
                            try encode(to: &container, array: value)
                    } else if let value = value as? [String: Any] {
                            var container = container.nestedContainer(keyedBy: JSONCodingKey.self)
                            try encode(to: &container, dictionary: value)
                    } else {
                            throw encodingError(forValue: value, codingPath: container.codingPath)
                    }
            }
    }

    static func encode(to container: inout KeyedEncodingContainer<JSONCodingKey>, dictionary: [String: Any]) throws {
            for (key, value) in dictionary {
                    let key = JSONCodingKey(stringValue: key)!
                    if let value = value as? Bool {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? Int64 {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? Double {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? String {
                            try container.encode(value, forKey: key)
                    } else if value is JSONNull {
                            try container.encodeNil(forKey: key)
                    } else if let value = value as? [Any] {
                            var container = container.nestedUnkeyedContainer(forKey: key)
                            try encode(to: &container, array: value)
                    } else if let value = value as? [String: Any] {
                            var container = container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key)
                            try encode(to: &container, dictionary: value)
                    } else {
                            throw encodingError(forValue: value, codingPath: container.codingPath)
                    }
            }
    }

    static func encode(to container: inout SingleValueEncodingContainer, value: Any) throws {
            if let value = value as? Bool {
                    try container.encode(value)
            } else if let value = value as? Int64 {
                    try container.encode(value)
            } else if let value = value as? Double {
                    try container.encode(value)
            } else if let value = value as? String {
                    try container.encode(value)
            } else if value is JSONNull {
                    try container.encodeNil()
            } else {
                    throw encodingError(forValue: value, codingPath: container.codingPath)
            }
    }

    public required init(from decoder: Decoder) throws {
            if var arrayContainer = try? decoder.unkeyedContainer() {
                    self.value = try JSONAny.decodeArray(from: &arrayContainer)
            } else if var container = try? decoder.container(keyedBy: JSONCodingKey.self) {
                    self.value = try JSONAny.decodeDictionary(from: &container)
            } else {
                    let container = try decoder.singleValueContainer()
                    self.value = try JSONAny.decode(from: container)
            }
    }

    public func encode(to encoder: Encoder) throws {
            if let arr = self.value as? [Any] {
                    var container = encoder.unkeyedContainer()
                    try JSONAny.encode(to: &container, array: arr)
            } else if let dict = self.value as? [String: Any] {
                    var container = encoder.container(keyedBy: JSONCodingKey.self)
                    try JSONAny.encode(to: &container, dictionary: dict)
            } else {
                    var container = encoder.singleValueContainer()
                    try JSONAny.encode(to: &container, value: self.value)
            }
    }
}
