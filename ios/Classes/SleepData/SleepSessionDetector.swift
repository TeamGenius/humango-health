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
    
    /// Minimum accumulated sleep duration (minutes) before a session can be declared ended.
    /// Based on data: shortest session was 6.3 hrs. Using 4 hrs as safe minimum.
    let minimumSleepMinutes: Double
    
    /// Minutes of no new segments before considering session stale (outside freeze).
    /// Within freeze window, staleness alone does not end a session.
    let stalenessThresholdMinutes: Double
    
    /// Minutes to look back for deep sleep absence. If no deep sleep in this window,
    /// it's a signal that the user is in the latter half of their sleep.
    let deepSleepAbsenceWindowMinutes: Double
    
    /// Default configuration based on real Apple Watch sleep data analysis.
    static let `default` = SleepSessionConfig(
        freezeWindowStartHour: 0,
        freezeWindowEndHour: 12,
        minimumSleepMinutes: 240, // 4 hours
        stalenessThresholdMinutes: 60,
        deepSleepAbsenceWindowMinutes: 90
    )
}

// MARK: - Sleep Session State

/// Represents the current state of an ongoing sleep session being tracked.
struct SleepSessionState: Codable {
    /// ISO8601 date string when monitoring started for this session
    var sessionStartDate: String?
    
    /// ISO8601 date string of the latest segment's endDate
    var latestSegmentEndDate: String?
    
    /// Total accumulated sleep minutes (excluding inBed and awake)
    var totalSleepMinutes: Double
    
    /// Total accumulated awake minutes
    var totalAwakeMinutes: Double
    
    /// Number of segments received so far
    var segmentCount: Int
    
    /// Whether deep sleep has been seen in recent segments (last N minutes)
    var hasRecentDeepSleep: Bool
    
    /// ISO8601 date string of the last deep sleep segment's endDate
    var lastDeepSleepEndDate: String?
    
    /// Whether the session has been finalized (end detected)
    var isFinalized: Bool
    
    /// ISO8601 date string when the session was finalized
    var finalizedAt: String?
    
    /// UUIDs of all samples in this session (for deduplication)
    var sampleUUIDs: [String]
    
    static let empty = SleepSessionState(
        sessionStartDate: nil,
        latestSegmentEndDate: nil,
        totalSleepMinutes: 0,
        totalAwakeMinutes: 0,
        segmentCount: 0,
        hasRecentDeepSleep: false,
        lastDeepSleepEndDate: nil,
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
    
    private let config: SleepSessionConfig
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    init(config: SleepSessionConfig = .default) {
        self.config = config
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
        
        let isInFreeze = isInFreezeWindow(at: currentTime)
        
        // OUTSIDE freeze window (after 12 PM): auto-finalize any accumulated session
        if !isInFreeze && state.totalSleepMinutes > 0 {
            return .freezeExpired
        }
        
        // INSIDE freeze window: use multi-factor scoring
        return evaluateDuringFreeze(state: state, currentTime: currentTime, latestEndStr: latestEndStr)
    }
    
    /// Multi-factor evaluation during the freeze window.
    private func evaluateDuringFreeze(
        state: SleepSessionState,
        currentTime: Date,
        latestEndStr: String
    ) -> SleepSessionStatus {
        
        // Factor 1: Minimum sleep duration
        guard state.totalSleepMinutes >= config.minimumSleepMinutes else {
            print("🛏️ [SleepDetector] Still accumulating: \(String(format: "%.0f", state.totalSleepMinutes))m < \(String(format: "%.0f", config.minimumSleepMinutes))m minimum")
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
        
        let minutesSinceLastSegment = currentTime.timeIntervalSince(latestEnd) / 60.0
        guard minutesSinceLastSegment >= config.stalenessThresholdMinutes else {
            print("🛏️ [SleepDetector] Recent data (\(String(format: "%.0f", minutesSinceLastSegment))m ago) — session still active")
            return .active
        }
        
        // All factors met
        let reason = "sleep>=\(String(format: "%.0f", state.totalSleepMinutes))m, " +
                     "no_deep_sleep_recently, " +
                     "stale_\(String(format: "%.0f", minutesSinceLastSegment))m"
        
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
            let durationMinutes = sample["durationMinutes"] as? Double ?? 0
            let endDateStr = sample["endDate"] as? String
            let startDateStr = sample["startDate"] as? String
            
            // Set session start from first segment
            if state.sessionStartDate == nil {
                state.sessionStartDate = startDateStr
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
                state.totalAwakeMinutes += durationMinutes
            case "inBed":
                break // Don't count inBed
            default:
                state.totalSleepMinutes += durationMinutes
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
        
        let minutesSinceDeep = latestEnd.timeIntervalSince(lastDeep) / 60.0
        return minutesSinceDeep < config.deepSleepAbsenceWindowMinutes
    }
    
    // MARK: - Persistence
    
    private static let stateKey = "com.humango.health.sleepSessionState"
    
    /// Saves session state to UserDefaults for persistence across background wakes.
    func saveState(_ state: SleepSessionState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
            print("🛏️ [SleepDetector] Saved session state: \(state.segmentCount) segments, \(String(format: "%.0f", state.totalSleepMinutes))m sleep")
        }
    }
    
    /// Loads session state from UserDefaults.
    func loadState() -> SleepSessionState {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(SleepSessionState.self, from: data) else {
            return .empty
        }
        return state
    }
    
    /// Clears persisted session state (call after session is processed).
    func clearState() {
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
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
