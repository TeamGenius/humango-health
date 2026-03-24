//
//  SleepBackgroundDeliveryManager.swift
//  humango_health
//
//  Persists finalized sleep session JSON to UserDefaults for the host app to retrieve.
//  No HTTP — upload from Dart or Runner native (same policy as workout delivery).
//

import Foundation

// MARK: - UserDefaults Keys

private struct SleepDeliveryKeys {
    static let armed             = "HumangoSleepDeliveryArmed"
    static let pendingLocalSleep = "com.humango.health.sleepPendingLocal"
    /// Legacy from removed API mode
    static let legacyMode    = "com.humango.health.sleepDeliveryMode"
    static let legacyApiURL  = "com.humango.health.sleepDeliveryURL"
    static let legacyHeaders = "com.humango.health.sleepDeliveryHeaders"
}

// MARK: - SleepBackgroundDeliveryManager

@available(iOS 14.0, *)
final class SleepBackgroundDeliveryManager {
    static let shared = SleepBackgroundDeliveryManager()

    /// Log label for delivery path (only local storage).
    static let deliveryModeLogLabel = "localStorage"

    private init() {}

    private var isArmed: Bool {
        get { UserDefaults.standard.bool(forKey: SleepDeliveryKeys.armed) }
        set { UserDefaults.standard.set(newValue, forKey: SleepDeliveryKeys.armed) }
    }

    var isArmedForAutoStart: Bool {
        isArmed
    }

    /// Clears legacy API keys and sets armed (idempotent).
    func arm() {
        clearLegacyApiKeys()
        if !isArmed {
            isArmed = true
            debugPrint("🛏️ [SleepDelivery] armed for local session delivery")
        } else {
            debugPrint("🛏️ [SleepDelivery] configure — already armed, legacy keys cleared")
        }
        UserDefaults.standard.synchronize()
    }

    func clearConfiguration() {
        isArmed = false
        clearLegacyApiKeys()
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.pendingLocalSleep)
        UserDefaults.standard.synchronize()
        debugPrint("🔐 [SleepDelivery] cleared configuration on logout")
    }

    private func clearLegacyApiKeys() {
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.legacyMode)
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.legacyApiURL)
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.legacyHeaders)
    }

    func deliverSleepSession(_ sleepDataJSON: String, sessionId: String) async {
        debugPrint("🛏️ [SleepDelivery] storing session sessionId=\(sessionId) size=\(sleepDataJSON.count)")
        storeLocally(sleepDataJSON)
    }

    private func storeLocally(_ sleepJSON: String) {
        var existing = UserDefaults.standard.stringArray(forKey: SleepDeliveryKeys.pendingLocalSleep) ?? []
        existing.append(sleepJSON)
        UserDefaults.standard.set(existing, forKey: SleepDeliveryKeys.pendingLocalSleep)
        // synchronize() ensures the write is flushed to disk before the process
        // is killed by iOS after HKObserverQuery's completion() handler returns.
        UserDefaults.standard.synchronize()
        debugPrint("💾 [SleepDelivery] pending sessions=\(existing.count)")
    }

    func retrieveLocalSleepSessions() -> [String] {
        let sessions = UserDefaults.standard.stringArray(forKey: SleepDeliveryKeys.pendingLocalSleep) ?? []
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.pendingLocalSleep)
        UserDefaults.standard.synchronize()
        if !sessions.isEmpty {
            debugPrint("🛏️ [SleepDelivery] retrieved \(sessions.count) pending session(s)")
        }
        return sessions
    }
}
