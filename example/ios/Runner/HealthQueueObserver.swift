//
//  HealthQueueObserver.swift
//  Runner (example app)
//
//  KVO-based watcher for both the sleep payload and workout pending queues
//  written by the humango_health plugin into UserDefaults.
//
//  In the production app (humango_workouts) this role is played by
//  HealthKitBackgroundQueueObserver + NativeHealthBackendService (which does the
//  actual HTTP POSTs). In the example app there is no backend service, so this
//  observer just:
//    • Logs every queue growth with counts.
//    • Posts a local notification so the event is visible even when the app is
//      in the background.
//    • Sleep payloads are already surfaced to Flutter via the plugin's own
//      EventChannel ("com.humango.health/sleep_payload_updates") so the Dart
//      layer can drain and display them. No duplicate drain is done here.
//
//  Lifecycle hooks in AppDelegate call start() and onEnterBackground() /
//  onEnterForeground() so the observer mirrors the behaviour expected in a
//  real host app.
//

import Foundation
import UIKit
import UserNotifications
import humango_health

final class HealthQueueObserver: NSObject {
    static let shared = HealthQueueObserver()

    // Keys must stay aligned with the plugin's delivery managers.
    private let sleepKey    = "com.humango.health.sleepPendingLocal"
    private let workoutKey  = "BackgroundWorkouts.pending"
    private let hrvKey      = "com.humango.health.hrvPendingUpdates"

    private var lastSleepCount   = 0
    private var lastWorkoutCount = 0
    private var lastHrvCount     = 0

    // KVO observation tokens (one per key)
    private var sleepObservation:   NSObject?
    private var workoutObservation: NSObject?
    private var isObserving = false

    private override init() {}

    // MARK: - Lifecycle

    /// Call once from AppDelegate.didFinishLaunchingWithOptions.
    /// Wires up the login-state notification so Flutter's `setUserLoggedIn`
    /// drives start/stop automatically. Also auto-starts if the user was already
    /// logged in (cold launch after background HK delivery).
    func setup() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLoginStateChanged(_:)),
            name: .humangoUserLoginStateChanged,
            object: nil
        )
        requestNotificationPermission()
        // Cold-launch: if user was already logged in, start immediately.
        if UserAuthStateManager.shared.isLoggedIn {
            start()
        } else {
            print("[Example][HealthQueue] setup — user not logged in, monitoring deferred")
        }
    }

    /// Starts KVO queue observation and logs the current baseline.
    /// Called automatically by `setup()` on login. Safe to call multiple times.
    func start() {
        syncBaseline()
        addKVOObservers()
        print("[Example][HealthQueue] started — sleep=\(lastSleepCount) workouts=\(lastWorkoutCount) hrv=\(lastHrvCount)")
    }

    /// Stops KVO observation. Called automatically on logout.
    func stop() {
        removeKVOObservers()
        print("[Example][HealthQueue] stopped (user logged out)")
    }

    @objc private func handleLoginStateChanged(_ notification: Notification) {
        let loggedIn = notification.userInfo?["loggedIn"] as? Bool ?? false
        if loggedIn {
            start()
        } else {
            stop()
        }
    }

    /// Call from AppDelegate.applicationDidEnterBackground.
    /// Logs the current queue snapshot so you can verify data was stored.
    func onEnterBackground() {
        let d = UserDefaults.standard
        let sc = d.stringArray(forKey: sleepKey)?.count   ?? 0
        let wc = d.stringArray(forKey: workoutKey)?.count ?? 0
        let hc = Self.hrvCount(d)
        print("[Example][HealthQueue] ── app entered background ──")
        print("[Example][HealthQueue]  sleep pending   : \(sc)")
        print("[Example][HealthQueue]  workout pending : \(wc)")
        print("[Example][HealthQueue]  hrv pending     : \(hc)")
    }

    /// Call from AppDelegate.applicationWillEnterForeground.
    /// Retries any failed uploads from the background pass before Flutter resumes.
    func onEnterForeground() {
        let d = UserDefaults.standard
        let sc = d.stringArray(forKey: sleepKey)?.count   ?? 0
        let wc = d.stringArray(forKey: workoutKey)?.count ?? 0
        let hc = Self.hrvCount(d)
        print("[Example][HealthQueue] \u{2500}\u{2500} app entering foreground \u{2500}\u{2500}")
        print("[Example][HealthQueue]  sleep pending   : \(sc) (will upload natively then Flutter drains)")
        print("[Example][HealthQueue]  workout pending : \(wc)")
        print("[Example][HealthQueue]  hrv pending     : \(hc)")
        // Retry any sessions that the background upload missed (e.g. no athleteId yet).
        if sc > 0 {
            Task { await uploadSleepWithBackgroundTask() }
        }
        // Re-sync so next background pass uses new baseline.
        syncBaseline()
    }

    // MARK: - KVO setup / teardown

    private func addKVOObservers() {
        guard !isObserving else { return }
        UserDefaults.standard.addObserver(self, forKeyPath: sleepKey,   options: [.new], context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: workoutKey, options: [.new], context: nil)
        isObserving = true
    }

    private func removeKVOObservers() {
        guard isObserving else { return }
        UserDefaults.standard.removeObserver(self, forKeyPath: sleepKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: workoutKey)
        isObserving = false
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        let d = UserDefaults.standard
        switch keyPath {
        case sleepKey:
            let newCount = d.stringArray(forKey: sleepKey)?.count ?? 0
            if newCount > lastSleepCount {
                print("[Example][HealthQueue] 🛏  sleep queue grew: \(lastSleepCount) → \(newCount)")
                // Upload natively under a background task so the POST can complete
                // before iOS suspends the process. If athleteId is not yet set in
                // UserDefaults the upload is skipped and retried on next resume.
                Task {
                    await uploadSleepWithBackgroundTask()
                }
                lastSleepCount = newCount
            } else {
                // Queue was consumed (upload succeeded) — update baseline.
                lastSleepCount = newCount
            }

        case workoutKey:
            let newCount = d.stringArray(forKey: workoutKey)?.count ?? 0
            if newCount > lastWorkoutCount {
                print("[Example][HealthQueue] 🏃  workout queue grew: \(lastWorkoutCount) → \(newCount)")
                sendWithBackgroundTask(
                    title: "Workout payload stored",
                    body: "\(newCount) pending workout(s). Open the app to view."
                )
                lastWorkoutCount = newCount
            } else {
                lastWorkoutCount = newCount
            }

        default:
            break
        }
    }

    deinit { removeKVOObservers() }

    // MARK: - Sleep upload (wraps SleepUploadService in a UIBackgroundTask)

    private func uploadSleepWithBackgroundTask() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                let app = UIApplication.shared
                var taskId = UIBackgroundTaskIdentifier.invalid
                taskId = app.beginBackgroundTask(withName: "com.example.sleepUpload") {
                    app.endBackgroundTask(taskId)
                    taskId = .invalid
                    cont.resume()
                }
                Task {
                    await SleepUploadService.shared.uploadPending()
                    await MainActor.run {
                        // Notify user only when there is something to report
                        let remaining = UserDefaults.standard.stringArray(forKey: self.sleepKey)?.count ?? 0
                        if remaining == 0 {
                            self.sendLocalNotification(
                                title: "Sleep data uploaded",
                                body: "Background sleep session sent to Humango."
                            )
                        } else {
                            self.sendLocalNotification(
                                title: "Sleep payload stored",
                                body: "\(remaining) session(s) pending — will retry when credentials are set."
                            )
                        }
                        app.endBackgroundTask(taskId)
                        taskId = .invalid
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Helpers

    private func syncBaseline() {
        let d = UserDefaults.standard
        lastSleepCount   = d.stringArray(forKey: sleepKey)?.count   ?? 0
        lastWorkoutCount = d.stringArray(forKey: workoutKey)?.count ?? 0
        lastHrvCount     = Self.hrvCount(d)
    }

    private static func hrvCount(_ d: UserDefaults) -> Int {
        guard let data = d.data(forKey: "com.humango.health.hrvPendingUpdates"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }
        return arr.count
    }

    // MARK: - Local notifications (example-app visibility only)

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Dispatches a local notification wrapped in a UIBackgroundTask so iOS
    /// gives the process the full ~30-second background window.
    /// Without this, the process can be suspended the moment the HKObserverQuery
    /// completion() handler returns, before UNUserNotificationCenter has a chance
    /// to schedule the notification.
    private func sendWithBackgroundTask(title: String, body: String) {
        DispatchQueue.main.async {
            let app = UIApplication.shared
            var taskId = UIBackgroundTaskIdentifier.invalid
            taskId = app.beginBackgroundTask(withName: "com.example.healthQueue.notify") {
                // Expiration handler — end the task if we run out of time.
                app.endBackgroundTask(taskId)
                taskId = .invalid
            }
            self.sendLocalNotification(title: title, body: body)
            app.endBackgroundTask(taskId)
            taskId = .invalid
        }
    }

    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
