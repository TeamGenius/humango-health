//
//  HuSleepSession.swift
//  humango_health
//
//  Strongly-typed model for a processed sleep session delivered by SleepDataManager.
//
//  Mirrors the flat aggregated payload shape produced by buildAggregatedPayload, with
//  the addition of a typed sample array (populated by fetchSleepData / fetchSleep).
//  Use toDict() / toJson() to serialise for backend upload — key names are preserved
//  from the legacy [String: Any] payload so no backend changes are required.
//

import Foundation

// MARK: - HuSleepDevice

/// Device information attached to a single sleep sample.
public struct HuSleepDevice {
    public let name: String?
    public let model: String?
    public let manufacturer: String?
    public let hardwareVersion: String?
    public let softwareVersion: String?
    public let localIdentifier: String?

    public init(
        name: String?,
        model: String?,
        manufacturer: String?,
        hardwareVersion: String?,
        softwareVersion: String?,
        localIdentifier: String?
    ) {
        self.name             = name
        self.model            = model
        self.manufacturer     = manufacturer
        self.hardwareVersion  = hardwareVersion
        self.softwareVersion  = softwareVersion
        self.localIdentifier  = localIdentifier
    }

    public func toDict() -> [String: Any] {
        var d = [String: Any]()
        if let v = name             { d["name"]             = v }
        if let v = model            { d["model"]            = v }
        if let v = manufacturer     { d["manufacturer"]     = v }
        if let v = hardwareVersion  { d["hardwareVersion"]  = v }
        if let v = softwareVersion  { d["softwareVersion"]  = v }
        if let v = localIdentifier  { d["localIdentifier"]  = v }
        return d
    }
}

// MARK: - HuSleepSample

/// A single HealthKit sleep-analysis sample within a session.
public struct HuSleepSample {
    /// HealthKit UUID for the sample.
    public let uuid: String
    public let startDate: Date
    public let endDate: Date
    /// Raw `HKCategoryValueSleepAnalysis` integer value.
    public let value: Int
    /// Human-readable stage name: `inBed`, `asleepUnspecified`, `awake`,
    /// `asleepCore`, `asleepDeep`, `asleepREM`, or `unknown`.
    public let sleepStage: String
    public let durationSeconds: Double
    public let sourceName: String
    public let sourceBundle: String
    public let device: HuSleepDevice?
    public let metadata: [String: Any]?

    /// Convenience — duration in minutes.
    public var durationMinutes: Double { durationSeconds / 60.0 }

    public init(
        uuid: String,
        startDate: Date,
        endDate: Date,
        value: Int,
        sleepStage: String,
        durationSeconds: Double,
        sourceName: String,
        sourceBundle: String,
        device: HuSleepDevice?,
        metadata: [String: Any]?
    ) {
        self.uuid            = uuid
        self.startDate       = startDate
        self.endDate         = endDate
        self.value           = value
        self.sleepStage      = sleepStage
        self.durationSeconds = durationSeconds
        self.sourceName      = sourceName
        self.sourceBundle    = sourceBundle
        self.device          = device
        self.metadata        = metadata
    }

    public func toDict(formatter: ISO8601DateFormatter) -> [String: Any] {
        var d: [String: Any] = [
            "uuid":            uuid,
            "startDate":       formatter.string(from: startDate),
            "endDate":         formatter.string(from: endDate),
            "value":           value,
            "sleepStage":      sleepStage,
            "durationSeconds": durationSeconds,
            "durationMinutes": durationMinutes,
            "sourceName":      sourceName,
            "sourceBundle":    sourceBundle,
        ]
        if let dev = device                     { d["device"]   = dev.toDict() }
        if let meta = metadata, !meta.isEmpty   { d["metadata"] = meta }
        return d
    }
}

// MARK: - HuSleepSession

/// Aggregated sleep session produced by `SleepDataManager`.
///
/// Delivered to the host app via `HumangoHealthDataDelegate.onSleepSessionReady(_:)`.
/// Also returned directly from `HumangoHealthPlugin.shared?.fetchSleep(startDate:endDate:)`.
///
/// Call `toJson()` to serialise for backend upload — key names match the legacy
/// flat payload (`SOURCE`, `TOTAL_SLEEP`, `BED_TIME`, etc.) so no backend changes
/// are required when migrating from the old JSON-string delegate API.
public struct HuSleepSession {

    // MARK: Source

    /// Human-readable source name (e.g. "Apple Watch").
    public let source: String
    /// Bundle identifier of the winning source (e.g. `com.apple.health.<uuid>`).
    public let sourceBundle: String
    /// IANA timezone identifier (e.g. `"America/New_York"`).
    public let timezone: String

    // MARK: Durations (seconds)

    /// Total sleep = `sleepLightSeconds + sleepDeepSeconds + sleepREMSeconds`.
    public let totalSleepSeconds: Double
    public let sleepInBedSeconds: Double
    public let sleepLightSeconds: Double
    public let sleepDeepSeconds: Double
    public let sleepREMSeconds: Double
    public let sleepUnspecifiedSeconds: Double
    public let sleepAwakeSeconds: Double

    // MARK: Computed convenience

    public var totalSleepMinutes: Double { totalSleepSeconds / 60.0 }
    public var totalSleepHours: Double   { totalSleepSeconds / 3600.0 }

    // MARK: Timestamps

    /// ISO8601 start of the earliest sample in the winning source group.
    public let bedTime: Date?
    /// ISO8601 end of the latest sample in the winning source group.
    public let wakeTime: Date?
    /// HealthKit query window start.
    public let queryStart: Date
    /// HealthKit query window end.
    public let queryEnd: Date

    // MARK: Session identity

    /// Stable session identifier — ISO8601 string of `bedTime`, or `queryStart` when absent.
    public let sessionId: String

    // MARK: Samples

    /// Per-sample breakdown. Populated by `fetchSleep(startDate:endDate:)`.
    /// Empty when the session is delivered via `onSleepSessionReady` (background monitoring).
    public let samples: [HuSleepSample]

    // MARK: - Init

    public init(
        source: String,
        sourceBundle: String,
        timezone: String,
        totalSleepSeconds: Double,
        sleepInBedSeconds: Double,
        sleepLightSeconds: Double,
        sleepDeepSeconds: Double,
        sleepREMSeconds: Double,
        sleepUnspecifiedSeconds: Double,
        sleepAwakeSeconds: Double,
        bedTime: Date?,
        wakeTime: Date?,
        queryStart: Date,
        queryEnd: Date,
        sessionId: String,
        samples: [HuSleepSample] = []
    ) {
        self.source                  = source
        self.sourceBundle            = sourceBundle
        self.timezone                = timezone
        self.totalSleepSeconds       = totalSleepSeconds
        self.sleepInBedSeconds       = sleepInBedSeconds
        self.sleepLightSeconds       = sleepLightSeconds
        self.sleepDeepSeconds        = sleepDeepSeconds
        self.sleepREMSeconds         = sleepREMSeconds
        self.sleepUnspecifiedSeconds = sleepUnspecifiedSeconds
        self.sleepAwakeSeconds       = sleepAwakeSeconds
        self.bedTime                 = bedTime
        self.wakeTime                = wakeTime
        self.queryStart              = queryStart
        self.queryEnd                = queryEnd
        self.sessionId               = sessionId
        self.samples                 = samples
    }

    // MARK: - Serialisation

    private static var isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Returns a flat dictionary preserving all legacy backend key names.
    ///
    /// Keys: `SOURCE`, `SOURCE_BUNDLE`, `TIMEZONE`, `TOTAL_SLEEP`, `SLEEP_IN_BED`,
    /// `SLEEP_LIGHT`, `SLEEP_DEEP`, `SLEEP_REM`, `SLEEP_UNSPECIFIED`, `SLEEP_AWAKE`,
    /// `BED_TIME`, `WAKE_TIME`, `START_DATE`, `END_DATE`.
    ///
    /// Additional keys (not in the legacy payload): `SESSION_ID`, `samples`, `sampleCount`,
    /// `totalSleepMinutes`, `totalSleepHours`.
    public func toDict() -> [String: Any] {
        let fmt = HuSleepSession.isoFormatter
        var d: [String: Any] = [
            "SOURCE":            source,
            "SOURCE_BUNDLE":     sourceBundle,
            "TIMEZONE":          timezone,
            "TOTAL_SLEEP":       totalSleepSeconds,
            "SLEEP_IN_BED":      sleepInBedSeconds,
            "SLEEP_LIGHT":       sleepLightSeconds,
            "SLEEP_DEEP":        sleepDeepSeconds,
            "SLEEP_REM":         sleepREMSeconds,
            "SLEEP_UNSPECIFIED": sleepUnspecifiedSeconds,
            "SLEEP_AWAKE":       sleepAwakeSeconds,
            "START_DATE":        fmt.string(from: queryStart),
            "END_DATE":          fmt.string(from: queryEnd),
            "SESSION_ID":        sessionId,
            "totalSleepMinutes": totalSleepMinutes,
            "totalSleepHours":   totalSleepHours,
            "sampleCount":       samples.count,
            "samples":           samples.map { $0.toDict(formatter: fmt) },
        ]
        if let bt = bedTime  { d["BED_TIME"]   = fmt.string(from: bt) }
        if let wt = wakeTime { d["WAKE_TIME"]  = fmt.string(from: wt) }
        return d
    }

    /// Serialises `toDict()` to a JSON string. Returns `nil` if serialisation fails.
    public func toJson() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: toDict(), options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
