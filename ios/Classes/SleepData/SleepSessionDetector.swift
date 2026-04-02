//
//  SleepSessionDetector.swift
//  humango_health
//
//  Detects sleep session boundaries using a freeze window approach.
//  Freeze window: 12:00 AM → 12:00 PM local time.
//  During this window, sleep data accumulates without declaring session end.
//  After the window (or using multi-factor scoring), the session is finalized.
//
//  Pattern analysis (from real Apple Watch data):
//  - Deep sleep concentrates in the first 30-50% of the night
//  - Last ~3-4 hours are Core ↔ REM cycling only
//  - All sessions end between 06:00-08:00 IST (local morning)
//  - Segments within a session are perfectly contiguous (endDate[i] == startDate[i+1])
//  - Inter-session gaps are 15+ hours
//

import Foundation
import HealthKit

// MARK: - Sleep Session Configuration

/// Configuration for the sleep session freeze window and detection parameters.
struct SleepSessionConfig {
    /// Freeze window start hour in local time (inclusive). Default: 0 (midnight)
    let freezeWindowStartHour: Int
    
    /// Freeze window end hour in local time (exclusive). Default: 12 (noon)
    let freezeWindowEndHour: Int
    
    /// Minimum accumulated sleep duration (seconds) before a session can be declared ended.
    /// Based on data: shortest session was 6.3 hrs. Using 4 hrs as safe minimum.
    let minimumSleepSeconds: Double
    
    /// Seconds of no new segments before considering session stale (outside freeze).
    /// Within freeze window, staleness alone does not end a session.
    let stalenessThresholdSeconds: Double
    
    /// Seconds to look back for deep sleep absence. If no deep sleep in this window,
    /// it's a signal that the user is in the latter half of their sleep.
    let deepSleepAbsenceWindowSeconds: Double
    
    /// Default configuration based on real Apple Watch sleep data analysis.
    static let `default` = SleepSessionConfig(
        freezeWindowStartHour: 0,
        freezeWindowEndHour: 12,
        minimumSleepSeconds: 14400, // 4 hours
        stalenessThresholdSeconds: 3600,
        deepSleepAbsenceWindowSeconds: 5400
    )
}

// MARK: - Sleep Session State

/// Represents the current state of an ongoing sleep session being tracked.
struct SleepSessionState: Codable {
    /// ISO8601 date string when monitoring started for this session
    var sessionStartDate: String?
    
    /// ISO8601 date string of the latest segment's endDate
    var latestSegmentEndDate: String?
    
    /// Total accumulated sleep seconds (excluding inBed and awake)
    var totalSleepSeconds: Double
    
    /// Total accumulated awake seconds
    var totalAwakeSeconds: Double
    
    /// Number of segments received so far
    var segmentCount: Int
    
    /// Whether deep sleep has been seen in recent segments (last N minutes)
    var hasRecentDeepSleep: Bool
    
    /// ISO8601 date string of the last deep sleep segment's endDate
    var lastDeepSleepEndDate: String?
    
    /// ISO8601 date string of the latest inBed segment's endDate (tracks user's time in bed).
    /// Updated on every sample arrival — Apple Watch updates this live throughout the night.
    var latestInBedEndDate: String?
    
    /// Source bundle identifier of the latest inBed sample.
    /// Used to distinguish iPhone Sleep app (retroactive, reliable wake signal)
    /// from Apple Watch (continuous live update, NOT a wake signal).
    var latestInBedSourceBundle: String?
    
    /// Whether the session has been finalized (end detected)
    var isFinalized: Bool
    
    /// ISO8601 date string when the session was finalized
    var finalizedAt: String?
    
    /// UUIDs of all samples in this session (for deduplication)
    var sampleUUIDs: [String]
    
    static let empty = SleepSessionState(
        sessionStartDate: nil,
        latestSegmentEndDate: nil,
        totalSleepSeconds: 0,
        totalAwakeSeconds: 0,
        segmentCount: 0,
        hasRecentDeepSleep: false,
        lastDeepSleepEndDate: nil,
        latestInBedEndDate: nil,
        latestInBedSourceBundle: nil,
        isFinalized: false,
        finalizedAt: nil,
        sampleUUIDs: []
    )
}

// MARK: - Session Detection Result

/// Result of analyzing whether a sleep session has ended.
enum SleepSessionStatus {
    /// Session is still active — within freeze window and/or data still flowing.
    case active
    
    /// Session has ended — data analysis confirms sleep is over.
    /// Associated value is the reason for detection.
    case ended(reason: String)
    
    /// Freeze window expired — session auto-finalized at window end.
    case freezeExpired
}

// MARK: - SleepSessionDetector

/// Analyzes accumulated sleep segments to determine if a sleep session has ended.
/// Uses a freeze window (midnight to noon) during which sessions are never auto-ended.
///
/// Detection logic (must ALL be true to declare session ended during freeze):
/// 1. Current local time is within the freeze window (12 AM - 12 PM)
/// 2. Minimum 4 hours of accumulated sleep
/// 3. No deep sleep in the last 90 minutes of segments
/// 4. No new segments for >= 60 minutes (staleness)
///
/// After freeze window ends (12 PM), any accumulated session is auto-finalized.
@available(iOS 14.0, *)
class SleepSessionDetector {

    private let stateLock = NSLock()
    /// Process-local only — not written to `UserDefaults` (host app handles persistence via delegate if needed).
    private var memoryBackedSessionState: SleepSessionState?

    private let config: SleepSessionConfig
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    init(config: SleepSessionConfig = .default) {
        self.config = config
        UserDefaults.standard.removeObject(forKey: "com.humango.health.sleepSessionState")
    }
    
    // MARK: - Freeze Window Check
    
    /// Returns true if the given date falls within the freeze window (local time).
    func isInFreezeWindow(at date: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        return hour >= config.freezeWindowStartHour && hour < config.freezeWindowEndHour
    }
    
    /// Returns the next freeze window end date from the given date.
    func nextFreezeWindowEnd(from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = config.freezeWindowEndHour
        components.minute = 0
        components.second = 0
        
        if let endDate = calendar.date(from: components) {
            // If we're past the end hour today, use tomorrow's end
            if date >= endDate {
                return calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
            }
            return endDate
        }
        return date
    }
    
    // MARK: - Session Analysis
    
    /// Evaluates the current session state and determines if the sleep session has ended.
    ///
    /// Called each time the background observer fires or on a periodic check timer.
    ///
    /// - Parameters:
    ///   - state: The current accumulated session state
    ///   - currentTime: The time of evaluation (defaults to now)
    /// - Returns: The status of the sleep session
    func evaluateSession(state: SleepSessionState, currentTime: Date = Date()) -> SleepSessionStatus {
        // Already finalized — no-op
        guard !state.isFinalized else {
            return .ended(reason: "already_finalized")
        }
        
        // No data yet — still active
        guard state.segmentCount > 0, let latestEndStr = state.latestSegmentEndDate else {
            return .active
        }
        
        // Factor 0: inBed end from a retroactive source (iPhone Sleep app / third-party alarm app).
        // These sources write the inBed sample AFTER the user dismisses their alarm, so inBed.endDate
        // is a definitive wake-up time. We bypass the freeze window when this is confirmed.
        // Apple Watch is explicitly excluded — it updates inBed.endDate continuously throughout
        // the night (a rolling live value), so its endDate is NOT a reliable wake signal.
        if let inBedEndStr = state.latestInBedEndDate,
           let inBedEnd = isoFormatter.date(from: inBedEndStr),
           !isAppleWatchSource(state.latestInBedSourceBundle),
           state.totalSleepSeconds >= config.minimumSleepSeconds {
            let secondsSinceInBedEnd = currentTime.timeIntervalSince(inBedEnd)
            if secondsSinceInBedEnd >= config.stalenessThresholdSeconds {
                let source = state.latestInBedSourceBundle ?? "unknown"
                    print("🛏️ [SleepDetector] Factor 0: inBed end from retroactive source (\(source)) — confirmed wake \(secondsSinceInBedEnd)s ago")
                    return .ended(reason: "inBed_end_confirmed_wake, source=\(source), stale_\(secondsSinceInBedEnd)s")
            }
        }
        
        let isInFreeze = isInFreezeWindow(at: currentTime)
        
        // OUTSIDE freeze window (after 12 PM): auto-finalize any accumulated session
        if !isInFreeze && state.totalSleepSeconds > 0 {
            return .freezeExpired
        }
        
        // INSIDE freeze window: use multi-factor scoring
        return evaluateDuringFreeze(state: state, currentTime: currentTime, latestEndStr: latestEndStr)
    }
    
    /// Returns true if the source bundle belongs to Apple Watch.
    /// Apple Watch writes inBed as a continuous live segment — its endDate advances
    /// throughout the night and is NOT a reliable wake-up signal.
    private func isAppleWatchSource(_ bundle: String?) -> Bool {
        guard let bundle = bundle else { return false }
        // Apple Watch Health app bundle identifier
        return bundle == "com.apple.health.watch" || bundle.contains("watch")
    }
    
    /// Multi-factor evaluation during the freeze window.
    private func evaluateDuringFreeze(
        state: SleepSessionState,
        currentTime: Date,
        latestEndStr: String
    ) -> SleepSessionStatus {
        
        // Factor 1: Minimum sleep duration
        guard state.totalSleepSeconds >= config.minimumSleepSeconds else {
            print("🛏️ [SleepDetector] Still accumulating: \(state.totalSleepSeconds)s < \(config.minimumSleepSeconds)s minimum")
            return .active
        }
        
        // Factor 2: No deep sleep recently
        guard !state.hasRecentDeepSleep else {
            print("🛏️ [SleepDetector] Deep sleep still appearing — session still active")
            return .active
        }
        
        // Factor 3: Staleness — no new segments for threshold duration
        guard let latestEnd = isoFormatter.date(from: latestEndStr) else {
            return .active
        }
        
        let secondsSinceLastSegment = currentTime.timeIntervalSince(latestEnd)
        guard secondsSinceLastSegment >= config.stalenessThresholdSeconds else {
            print("🛏️ [SleepDetector] Recent data (\(secondsSinceLastSegment)s ago) — session still active")
            return .active
        }
        
        // All factors met
        let reason = "sleep>=\(state.totalSleepSeconds)s, " +
                     "no_deep_sleep_recently, " +
                 "stale_\(secondsSinceLastSegment)s"
        
        print("🛏️ [SleepDetector] Session ended: \(reason)")
        return .ended(reason: reason)
    }
    
    // MARK: - State Update from Samples
    
    /// Updates the session state with new sleep samples.
    ///
    /// - Parameters:
    ///   - state: Current session state (mutated in place)
    ///   - samples: Array of sample dictionaries from HealthKit
    /// - Returns: Updated session state
    func updateState(_ state: inout SleepSessionState, withSamples samples: [[String: Any]]) {
        for sample in samples {
            guard let uuid = sample["uuid"] as? String else { continue }
            
            // Deduplication: skip already-seen samples
            guard !state.sampleUUIDs.contains(uuid) else { continue }
            state.sampleUUIDs.append(uuid)
            
            let sleepStage = sample["sleepStage"] as? String ?? "unknown"
            let durationSeconds: Double = {
                if let value = sample["durationSeconds"] as? Double {
                    return value
                }
                if let value = sample["durationSeconds"] as? Int {
                    return Double(value)
                }
                if let value = sample["durationMinutes"] as? Double {
                    return value * 60.0
                }
                if let value = sample["durationMinutes"] as? Int {
                    return Double(value) * 60.0
                }
                return 0
            }()
            let endDateStr = sample["endDate"] as? String
            let startDateStr = sample["startDate"] as? String
            
            // Track earliest startDate as session start.
            // Apple Watch delivers inBed and detailed stage samples in arbitrary order across
            // observer fires. The inBed.startDate (bed time) is earlier than the first detailed
            // stage (first sleep stage), so we must keep the minimum, not just the first arrival.
            if let startStr = startDateStr {
                if let current = state.sessionStartDate,
                   let currentDate = isoFormatter.date(from: current),
                   let newDate = isoFormatter.date(from: startStr) {
                    if newDate < currentDate {
                        state.sessionStartDate = startStr
                    }
                } else {
                    state.sessionStartDate = startStr
                }
            }
            
            // Track latest segment end
            if let endStr = endDateStr {
                if let currentLatest = state.latestSegmentEndDate,
                   let currentDate = isoFormatter.date(from: currentLatest),
                   let newDate = isoFormatter.date(from: endStr) {
                    if newDate > currentDate {
                        state.latestSegmentEndDate = endStr
                    }
                } else {
                    state.latestSegmentEndDate = endStr
                }
            }
            
            // Accumulate totals
            state.segmentCount += 1
            
            switch sleepStage {
            case "awake":
                state.totalAwakeSeconds += durationSeconds
            case "inBed":
                // Track latest inBed endDate and its source on every sample arrival.
                // Apple Watch updates inBed continuously throughout the night (endDate advances live).
                // iPhone Sleep app writes inBed retroactively after the user dismisses their alarm.
                // We keep the latest endDate so evaluateSession() can use it as a Factor 0 wake signal.
                if let endStr = endDateStr {
                    let shouldUpdate: Bool
                    if let currentInBed = state.latestInBedEndDate,
                       let currentDate = isoFormatter.date(from: currentInBed),
                       let newDate = isoFormatter.date(from: endStr) {
                        shouldUpdate = newDate > currentDate
                    } else {
                        shouldUpdate = true
                    }
                    if shouldUpdate {
                        state.latestInBedEndDate = endStr
                        state.latestInBedSourceBundle = sample["sourceBundle"] as? String
                    }
                }
            default:
                state.totalSleepSeconds += durationSeconds
            }
            
            // Track deep sleep recency
            if sleepStage == "asleepDeep" {
                state.lastDeepSleepEndDate = endDateStr
            }
        }
        
        // Recalculate hasRecentDeepSleep based on the deep sleep absence window
        state.hasRecentDeepSleep = calculateRecentDeepSleep(state: state)
    }
    
    /// Determines if deep sleep appeared within the configured absence window
    /// from the latest segment end time.
    private func calculateRecentDeepSleep(state: SleepSessionState) -> Bool {
        guard let lastDeepStr = state.lastDeepSleepEndDate,
              let latestEndStr = state.latestSegmentEndDate,
              let lastDeep = isoFormatter.date(from: lastDeepStr),
              let latestEnd = isoFormatter.date(from: latestEndStr) else {
            return false
        }
        
        let secondsSinceDeep = latestEnd.timeIntervalSince(lastDeep)
        return secondsSinceDeep < config.deepSleepAbsenceWindowSeconds
    }
    
    // MARK: - State retention (memory only)

    /// Saves session state in memory for the lifetime of this detector instance.
    func saveState(_ state: SleepSessionState) {
        stateLock.lock()
        memoryBackedSessionState = state
        stateLock.unlock()
        print("🛏️ [SleepDetector] Saved session state: \(state.segmentCount) segments, \(state.totalSleepSeconds)s sleep")
    }

    func loadState() -> SleepSessionState {
        stateLock.lock()
        let state = memoryBackedSessionState
        stateLock.unlock()
        return state ?? .empty
    }

    func clearState() {
        stateLock.lock()
        memoryBackedSessionState = nil
        stateLock.unlock()
        print("🛏️ [SleepDetector] Cleared session state")
    }
    
    // MARK: - Finalize State
    
    /// Marks the session state as finalized.
    func finalizeState(_ state: inout SleepSessionState, reason: String) {
        state.isFinalized = true
        state.finalizedAt = isoFormatter.string(from: Date())
        saveState(state)
        print("🛏️ [SleepDetector] Session finalized: \(reason)")
    }
}
