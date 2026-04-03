//
//  HealthMetricType.swift
//  humango_health
//
//  Swift mirror of the Dart HealthMetricType enum.
//  Single source of truth for all quantity-metric configuration across the iOS layer:
//  HKQuantityTypeIdentifier, HKUnit, unit label, and observer fetch tuning.
//

import HealthKit

/// Quantity-metric types supported by the plugin.
/// Mirrors the Dart `HealthMetricType` enum (case names are identical to the Dart enum `.name` / `.key`).
public enum HealthMetricType: String, CaseIterable {
    case heartRateVariabilitySDNN
    case restingHeartRate
    case bodyFatPercentage
    case bodyMass
    case height

    // MARK: - Identification

    /// String key used on the method channel. Matches Dart enum `.name`.
    public var key: String { rawValue }

    /// Human-readable display name for logging and UI.
    public var displayName: String {
        switch self {
        case .heartRateVariabilitySDNN: return "HRV (SDNN)"
        case .restingHeartRate:         return "Resting Heart Rate"
        case .bodyFatPercentage:        return "Body Fat %"
        case .bodyMass:                 return "Weight"
        case .height:                   return "Height"
        }
    }

    // MARK: - HealthKit

    /// Corresponding `HKQuantityTypeIdentifier`.
    public var identifier: HKQuantityTypeIdentifier {
        switch self {
        case .heartRateVariabilitySDNN: return .heartRateVariabilitySDNN
        case .restingHeartRate:         return .restingHeartRate
        case .bodyFatPercentage:        return .bodyFatPercentage
        case .bodyMass:                 return .bodyMass
        case .height:                   return .height
        }
    }

    /// Preferred `HKUnit` for value extraction.
    public var unit: HKUnit {
        switch self {
        case .heartRateVariabilitySDNN: return HKUnit.secondUnit(with: .milli)
        case .restingHeartRate:         return HKUnit.count().unitDivided(by: .minute())
        case .bodyFatPercentage:        return HKUnit.percent()
        case .bodyMass:                 return HKUnit.gramUnit(with: .kilo)
        case .height:                   return HKUnit.meterUnit(with: .centi)
        }
    }

    /// Human-readable unit string returned in payloads.
    public var unitLabel: String {
        switch self {
        case .heartRateVariabilitySDNN: return "ms"
        case .restingHeartRate:         return "bpm"
        case .bodyFatPercentage:        return "%"
        case .bodyMass:                 return "kg"
        case .height:                   return "cm"
        }
    }

    /// Resolved `HKQuantityType`. Returns `nil` only if the identifier is unavailable on the device
    /// (should not happen for any case in this enum on a supported OS).
    public var quantityType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: identifier)
    }

    // MARK: - Observer Tuning

    /// Lookback window (in days) used when the quantity observer fires.
    var observerLookbackDays: Int {
        switch self {
        case .heartRateVariabilitySDNN: return 7
        case .restingHeartRate:         return 7
        case .bodyFatPercentage:        return 30
        case .bodyMass:                 return 30
        case .height:                   return 365
        }
    }

    /// Maximum number of samples returned per observer fetch.
    var observerSampleLimit: Int {
        switch self {
        case .heartRateVariabilitySDNN: return 100
        case .restingHeartRate:         return 100
        case .bodyFatPercentage:        return 100
        case .bodyMass:                 return 100
        case .height:                   return 50
        }
    }

    // MARK: - Init from key

    /// Initialise from a method-channel key string (Dart enum `.name`). Returns `nil` if unknown.
    public init?(key: String) {
        self.init(rawValue: key)
    }
}
