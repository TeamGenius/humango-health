//
// WorkOutService.swift
// Updated: integrated RouteService registry + endDate 2-hour rule
// Uses native iOS lifecycle detection via AppLifecycleManager for automatic mode switching
//

import Foundation
import HealthKit
import WorkoutKit

@available(iOS 17.0, *)
final class WorkoutService: AppLifecycleObserver {
    // public-ish config
    static let liveWindowSeconds: TimeInterval = 2 * 60 * 60 // 2 hours

    let startDate: Date
    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private var anchor: HKQueryAnchor?
    private var updateTask: Task<Void, Never>?
    private var observer: HKObserverQuery?
    private var authorized = false

    // --- registry of active RouteService instances (only for recent + tracked workouts)
    private var routeServices: [String: RouteService] = [:]
    private let routeServiceQueue = DispatchQueue(label: "com.humango.WorkoutService.routeQueue", attributes: .concurrent)

    init(startDate: Date) {
        self.startDate = startDate
        
        // Register with AppLifecycleManager for automatic foreground/background switching
        AppLifecycleManager.shared.addObserver(self)
        debugPrint("[Humango] WorkoutService: initialized — startDate=\(startDate), lifecycle observer registered")
    }
    
    deinit {
        AppLifecycleManager.shared.removeObserver(self)
        debugPrint("[Humango] WorkoutService: deallocated")
    }
    
    // Call this ONCE after you create the service.
    // Chooses foreground (live stream) vs background (observer) based on current app state
    // so a cold background relaunch by HealthKit correctly registers the observer.
    func start() async {
        authorized = true
        // Prime the anchor to the current HealthKit position BEFORE opening the live
        // stream or installing the background observer. This prevents both paths from
        // replaying workouts that already exist in HealthKit — only workouts written
        // AFTER monitoring starts will be delivered to handleWorkouts.
        await primeAnchor()
        let mode = AppLifecycleManager.shared.isInForeground ? "foreground" : "background"
        SleepRemoteLogger.log(.info, step: "workoutService.start", message: "starting workout service", context: [
            "class": "WorkoutService",
            "method": "start",
            "mode": mode,
            "startDate": startDate.description,
        ], subsystem: "WorkoutService")
        if AppLifecycleManager.shared.isInForeground {
            debugPrint("[Humango] WorkoutService: start → foreground mode")
            startLiveUpdates()
        } else {
            debugPrint("[Humango] WorkoutService: start → background mode (cold background relaunch)")
            startBackgroundMonitoring()
        }
    }
    
    // MARK: - AppLifecycleObserver (Native iOS lifecycle)
    
    func appDidEnterForeground() {
        debugPrint("[Humango] WorkoutService: appDidEnterForeground — switching to foreground mode")
        SleepRemoteLogger.log(.info, step: "lifecycle", message: "appDidEnterForeground", context: ["class": "WorkoutService", "method": "appDidEnterForeground"], subsystem: "WorkoutService")
        enterForegroundMode()
    }
    
    func appDidEnterBackground() {
        debugPrint("[Humango] WorkoutService: appDidEnterBackground — switching to background mode")
        SleepRemoteLogger.log(.info, step: "lifecycle", message: "appDidEnterBackground", context: ["class": "WorkoutService", "method": "appDidEnterBackground"], subsystem: "WorkoutService")
        enterBackgroundMode()
    }

    // MARK: - Foreground / Background switches

    func enterBackgroundMode() {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: enterBackgroundMode skipped — not authorized")
            SleepRemoteLogger.log(.warn, step: "enterBackgroundMode", message: "skipped — not authorized", context: ["class": "WorkoutService", "method": "enterBackgroundMode"], subsystem: "WorkoutService")
            return
        }
        let activeRouteCount = routeServices.count
        debugPrint("[Humango] WorkoutService: enterBackgroundMode — stopping live updates, starting background observer (activeRouteServices=\(activeRouteCount))")
        SleepRemoteLogger.log(.info, step: "enterBackgroundMode", message: "entering background mode", context: [
            "class": "WorkoutService",
            "method": "enterBackgroundMode",
            "activeRouteServices": "\(activeRouteCount)",
        ], subsystem: "WorkoutService")
        stopLiveUpdates()
        startBackgroundMonitoring()
        debugPrint("[Humango] WorkoutService: entered BACKGROUND mode")

        routeServiceQueue.async(flags: .barrier) {
            for (id, rs) in self.routeServices {
                debugPrint("[Humango] WorkoutService: propagating background mode → RouteService(\(id))")
                rs.enterBackgroundMode()
            }
        }
    }

    func enterForegroundMode() {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: enterForegroundMode skipped — not authorized")
            SleepRemoteLogger.log(.warn, step: "enterForegroundMode", message: "skipped — not authorized", context: ["class": "WorkoutService", "method": "enterForegroundMode"], subsystem: "WorkoutService")
            return
        }
        let activeRouteCount = routeServices.count
        debugPrint("[Humango] WorkoutService: enterForegroundMode — stopping background observer, starting live updates (activeRouteServices=\(activeRouteCount))")
        SleepRemoteLogger.log(.info, step: "enterForegroundMode", message: "entering foreground mode", context: [
            "class": "WorkoutService",
            "method": "enterForegroundMode",
            "activeRouteServices": "\(activeRouteCount)",
        ], subsystem: "WorkoutService")
        stopBackgroundMonitoring()
        startLiveUpdates()
        debugPrint("[Humango] WorkoutService: entered FOREGROUND mode")

        routeServiceQueue.async(flags: .barrier) {
            for (id, rs) in self.routeServices {
                debugPrint("[Humango] WorkoutService: propagating foreground mode → RouteService(\(id))")
                rs.enterForegroundMode()
            }
        }

        pruneOldRouteServices()
    }

    // MARK: - Live Updates (Foreground)

    func startLiveUpdates() {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: startLiveUpdates skipped — not authorized")
            SleepRemoteLogger.log(.warn, step: "liveUpdates.start", message: "startLiveUpdates skipped — not authorized", context: ["class": "WorkoutService", "method": "startLiveUpdates"], subsystem: "WorkoutService")
            return
        }
        debugPrint("[Humango] WorkoutService: startLiveUpdates — opening HKAnchoredObjectQueryoror stream from \(startDate)")
        SleepRemoteLogger.log(.info, step: "liveUpdates.start", message: "opening live workout stream", context: [
            "class": "WorkoutService",
            "method": "startLiveUpdates",
            "startDate": startDate.description,
        ], subsystem: "WorkoutService")

        let livePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: nil,
            options: [.strictStartDate]
        )

        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(livePredicate)],
            anchor: anchor
        )
        let stream = desc.results(for: healthStore)

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self = self else { return }
            debugPrint("[Humango] WorkoutService: live update stream started")
            SleepRemoteLogger.log(.info, step: "liveUpdates.streaming", message: "live workout stream started", context: ["class": "WorkoutService", "method": "startLiveUpdates"], subsystem: "WorkoutService")
            do {
                for try await update in stream {
                    self.anchor = update.newAnchor
                    let count = update.addedSamples.count
                    debugPrint("[Humango] WorkoutService: live stream update — \(count) new workout(s)")
                    SleepRemoteLogger.log(.info, step: "liveUpdates.update", message: "live stream update received", context: [
                        "class": "WorkoutService",
                        "method": "startLiveUpdates",
                        "count": "\(count)",
                    ], subsystem: "WorkoutService")
                    for w in update.addedSamples {
                        debugPrint("[Humango] WorkoutService: live workout received — uuid=\(w.uuid.uuidString) type=\(w.workoutActivityType.name) start=\(w.startDate) end=\(w.endDate)")
                        SleepRemoteLogger.log(.info, step: "liveUpdates.workout", message: "live workout received", context: [
                            "class": "WorkoutService",
                            "method": "startLiveUpdates",
                            "uuid": w.uuid.uuidString,
                            "type": w.workoutActivityType.name,
                            "start": w.startDate.description,
                            "end": w.endDate.description,
                        ], subsystem: "WorkoutService")
                        self.handleWorkouts(workout: w)
                    }
                }
                debugPrint("[Humango] WorkoutService: live update stream ended normally")
                SleepRemoteLogger.log(.info, step: "liveUpdates.ended", message: "live workout stream ended normally", context: ["class": "WorkoutService", "method": "startLiveUpdates"], subsystem: "WorkoutService")
            } catch {
                debugPrint("[Humango] WorkoutService: live update stream error — \(error)")
                SleepRemoteLogger.log(.error, step: "liveUpdates.error", message: "live workout stream error", context: [
                    "class": "WorkoutService",
                    "method": "startLiveUpdates",
                    "error": "\(error)",
                ], subsystem: "WorkoutService")
            }
        }
    }

    func stopLiveUpdates() {
        guard updateTask != nil else { return }
        debugPrint("[Humango] WorkoutService: stopLiveUpdates — cancelling live stream task")
        SleepRemoteLogger.log(.info, step: "liveUpdates.stop", message: "stopping live workout stream", context: ["class": "WorkoutService", "method": "stopLiveUpdates"], subsystem: "WorkoutService")
        updateTask?.cancel()
        updateTask = nil
    }

    // MARK: - Initial / Background Fetch (anchored query snapshot)

    private func fetchWorkouts(upToNow: Bool = false) async {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: fetchWorkouts skipped — not authorized")
            SleepRemoteLogger.log(.warn, step: "fetchWorkouts.skip", message: "fetchWorkouts skipped — not authorized", context: ["class": "WorkoutService", "method": "fetchWorkouts"], subsystem: "WorkoutService")
            return
        }
        let endDate = upToNow ? Date() : Date().addingTimeInterval(-WorkoutService.liveWindowSeconds)
        debugPrint("[Humango] WorkoutService: fetchWorkouts — querying \(startDate) → \(endDate) (upToNow=\(upToNow))")
        SleepRemoteLogger.log(.info, step: "fetchWorkouts.start", message: "snapshot fetch started", context: [
            "class": "WorkoutService",
            "method": "fetchWorkouts",
            "startDate": startDate.description,
            "endDate": endDate.description,
            "upToNow": upToNow,
        ], subsystem: "WorkoutService")

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: [.strictStartDate]
        )
        
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(predicate)],
            anchor: anchor
        )
        
        do {
            let result = try await desc.result(for: healthStore)
            self.anchor = result.newAnchor
            debugPrint("[Humango] WorkoutService: fetchWorkouts — found \(result.addedSamples.count) workout(s)")
            SleepRemoteLogger.log(.info, step: "fetchWorkouts.result", message: "snapshot fetch returned workouts", context: [
                "class": "WorkoutService",
                "method": "fetchWorkouts",
                "count": "\(result.addedSamples.count)",
            ], subsystem: "WorkoutService")
            for workout in result.addedSamples {
                debugPrint("[Humango] WorkoutService: fetchWorkouts — handling uuid=\(workout.uuid.uuidString) type=\(workout.workoutActivityType.name)")
                SleepRemoteLogger.log(.info, step: "fetchWorkouts.handle", message: "handling fetched workout", context: [
                    "class": "WorkoutService",
                    "method": "fetchWorkouts",
                    "uuid": workout.uuid.uuidString,
                    "type": workout.workoutActivityType.name,
                ], subsystem: "WorkoutService")
                handleWorkouts(workout: workout)
            }
        } catch {
            debugPrint("[Humango] WorkoutService: fetchWorkouts error — \(error)")
            SleepRemoteLogger.log(.error, step: "fetchWorkouts.error", message: "snapshot fetch failed", context: [
                "class": "WorkoutService",
                "method": "fetchWorkouts",
                "error": "\(error)",
            ], subsystem: "WorkoutService")
        }
    }
    

    // MARK: - Anchor Priming

    /// Advances `self.anchor` to the current HealthKit position without processing
    /// or delivering any samples. Called once at the start of `start()` so that
    /// both foreground live-stream updates and background observer fetches only
    /// surface workouts written AFTER monitoring began — not historical replays.
    ///
    /// Failure is non-fatal: if the HealthKit query fails, `anchor` stays nil and
    /// monitoring falls back to the old full-replay behaviour. WorkoutDedup in the
    /// delegate will deduplicate any re-delivered workouts in that edge case.
    private func primeAnchor() async {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: Date(),
            options: [.strictStartDate]
        )
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(predicate)],
            anchor: nil   // always nil — priming from scratch at monitoring start
        )
        do {
            let result = try await desc.result(for: healthStore)
            self.anchor = result.newAnchor
            let skipped = result.addedSamples.count
            debugPrint("[Humango] WorkoutService: primeAnchor — anchor set, skipped \(skipped) existing workout(s)")
            SleepRemoteLogger.log(.info, step: "primeAnchor", message: "anchor primed — skipping existing workouts", context: [
                "class":        "WorkoutService",
                "method":       "primeAnchor",
                "skippedCount": "\(skipped)",
                "startDate":    startDate.description,
            ], subsystem: "WorkoutService")
        } catch {
            // Leave anchor nil; worst case the first update replays known workouts
            // which WorkoutDedup in the delegate will handle.
            debugPrint("[Humango] WorkoutService: primeAnchor failed (\(error)) — proceeding with nil anchor")
            SleepRemoteLogger.log(.warn, step: "primeAnchor", message: "anchor priming failed — may replay existing workouts", context: [
                "class":  "WorkoutService",
                "method": "primeAnchor",
                "error":  "\(error)",
            ], subsystem: "WorkoutService")
        }
    }

    // MARK: - Background Monitoring (HKObserverQuery)

    func startBackgroundMonitoring() {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: startBackgroundMonitoring skipped — not authorized")
            return
        }
        debugPrint("[Humango] WorkoutService: startBackgroundMonitoring — enabling background delivery + installing observer")
        SleepRemoteLogger.log(.info, step: "startBackgroundMonitoring", message: "registering background delivery + observer", context: ["class": "WorkoutService", "method": "startBackgroundMonitoring"], subsystem: "WorkoutService")

        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
                debugPrint("[Humango] WorkoutService: enableBackgroundDelivery(workoutType) — success (immediate)")
                SleepRemoteLogger.log(.info, step: "startBackgroundMonitoring", message: "background delivery enabled", context: ["class": "WorkoutService", "method": "startBackgroundMonitoring"], subsystem: "WorkoutService")
            } catch {
                debugPrint("[Humango] WorkoutService: enableBackgroundDelivery(workoutType) — failed: \(error)")
                SleepRemoteLogger.log(.error, step: "startBackgroundMonitoring", message: "enableBackgroundDelivery failed", context: ["class": "WorkoutService", "method": "startBackgroundMonitoring", "error": "\(error)"], subsystem: "WorkoutService")
            }
        }

        observer = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            // NOTE: Do NOT use `defer { completion() }` here.
            // completion() must be called AFTER the full async fetch → route → delegate
            // pipeline finishes so iOS does not suspend the app mid-delivery.

            let fireTime = Date()
            if let error = error {
                debugPrint("[Humango] WorkoutService: background observer error at \(fireTime) — \(error)")
                SleepRemoteLogger.log(.error, step: "observer", message: "observer error", context: ["class": "WorkoutService", "method": "startBackgroundMonitoring", "error": "\(error)"], subsystem: "WorkoutService")
                completion()
                return
            }

            debugPrint("[Humango] WorkoutService: background observer fired at \(fireTime) — starting fetch pipeline")
            SleepRemoteLogger.log(.info, step: "observer_fired", message: "background observer fired — starting fetch", context: [
                "class": "WorkoutService",
                "method": "startBackgroundMonitoring",
                "fireTime": ISO8601DateFormatter().string(from: fireTime),
            ], subsystem: "WorkoutService")
            Task {
                await self.fetchWorkouts(upToNow: true)
                self.pruneOldRouteServices()
                debugPrint("[Humango] WorkoutService: background observer pipeline complete — signalling completion()")
                SleepRemoteLogger.log(.info, step: "observer_fired", message: "pipeline complete — signalling completion", context: ["class": "WorkoutService", "method": "startBackgroundMonitoring"], subsystem: "WorkoutService")
                // Signal HealthKit AFTER all async work completes so iOS keeps the
                // app alive for the full fetch → route → delegate pipeline.
                completion()
            }
        }

        if let q = observer {
            healthStore.execute(q)
            debugPrint("[Humango] WorkoutService: background observer installed and executing")
        }
    }

    func stopBackgroundMonitoring() {
        if let q = observer {
            healthStore.stop(q)
            observer = nil
            debugPrint("[Humango] WorkoutService: stopBackgroundMonitoring — observer removed")
            SleepRemoteLogger.log(.info, step: "bgMonitoring.stop", message: "background observer removed", context: ["class": "WorkoutService", "method": "stopBackgroundMonitoring"], subsystem: "WorkoutService")
        }
        healthStore.disableBackgroundDelivery(for: .workoutType()) { ok, err in
            if let err {
                debugPrint("[Humango] WorkoutService: disableBackgroundDelivery(workoutType) error — \(err)")
                SleepRemoteLogger.log(.error, step: "bgMonitoring.disableDelivery", message: "disableBackgroundDelivery error", context: ["class": "WorkoutService", "method": "stopBackgroundMonitoring", "error": "\(err)"], subsystem: "WorkoutService")
            } else {
                debugPrint("[Humango] WorkoutService: disableBackgroundDelivery(workoutType) — ok=\(ok)")
                SleepRemoteLogger.log(.info, step: "bgMonitoring.disableDelivery", message: "background delivery disabled", context: ["class": "WorkoutService", "method": "stopBackgroundMonitoring"], subsystem: "WorkoutService")
            }
        }
    }

    // MARK: - Decide per-workout behavior (one-shot vs retained live)

    func handleWorkouts(workout: HKWorkout) {
        if workout.endDate <= workout.startDate {
            debugPrint("[Humango] WorkoutService: handleWorkouts — skipping incomplete workout uuid=\(workout.uuid.uuidString) start=\(workout.startDate) end=\(workout.endDate)")
            SleepRemoteLogger.log(.warn, step: "handleWorkouts.skip", message: "skipping incomplete workout", context: [
                "class": "WorkoutService",
                "method": "handleWorkouts",
                "uuid": workout.uuid.uuidString,
                "reason": "endDate <= startDate",
            ], subsystem: "WorkoutService")
            return
        }

        let deviceId = workout.uuid.uuidString
        let ageSinceEnd = Date().timeIntervalSince(workout.endDate)
        let ageMinutes = Int(ageSinceEnd / 60)
        let isRecent = ageSinceEnd <= WorkoutService.liveWindowSeconds
        debugPrint("[Humango] WorkoutService: handleWorkouts — uuid=\(deviceId) type=\(workout.workoutActivityType.name) ageMinutes=\(ageMinutes) isRecent=\(isRecent)")
        SleepRemoteLogger.log(.info, step: "handleWorkouts.classify", message: "workout classified", context: [
            "class": "WorkoutService",
            "method": "handleWorkouts",
            "uuid": deviceId,
            "type": workout.workoutActivityType.name,
            "ageMinutes": "\(ageMinutes)",
            "isRecent": "\(isRecent)",
        ], subsystem: "WorkoutService")

        Task {
            let routeService = RouteService(workout: workout)

            if isRecent {
                debugPrint("[Humango] WorkoutService: handleWorkouts — recent workout, retaining RouteService for uuid=\(deviceId)")
                routeServiceQueue.async(flags: .barrier) {
                    self.routeServices[deviceId] = routeService
                }

                debugPrint("[Humango] WorkoutService: handleWorkouts — fetching initial route snapshot for uuid=\(deviceId)")
                SleepRemoteLogger.log(.info, step: "handleWorkouts.snapshot", message: "fetching initial route snapshot for recent workout", context: [
                    "class": "WorkoutService",
                    "method": "handleWorkouts",
                    "uuid": deviceId,
                ], subsystem: "WorkoutService")
                await routeService.fetchWorkoutRoute()

                if AppLifecycleManager.shared.isInForeground {
                    routeService.startLiveUpdates()
                    debugPrint("[Humango] WorkoutService: handleWorkouts — RouteService live updates started for uuid=\(deviceId)")
                    SleepRemoteLogger.log(.info, step: "handleWorkouts.routeMode", message: "RouteService started in live mode", context: [
                        "class": "WorkoutService",
                        "method": "handleWorkouts",
                        "uuid": deviceId,
                        "mode": "live",
                    ], subsystem: "WorkoutService")
                } else {
                    routeService.startBackgroundMonitoring()
                    debugPrint("[Humango] WorkoutService: handleWorkouts — RouteService background monitoring started for uuid=\(deviceId)")
                    SleepRemoteLogger.log(.info, step: "handleWorkouts.routeMode", message: "RouteService started in background mode", context: [
                        "class": "WorkoutService",
                        "method": "handleWorkouts",
                        "uuid": deviceId,
                        "mode": "background",
                    ], subsystem: "WorkoutService")
                }
            } else {
                debugPrint("[Humango] WorkoutService: handleWorkouts — old workout (ageMinutes=\(ageMinutes)), one-shot fetch for uuid=\(deviceId)")
                SleepRemoteLogger.log(.info, step: "handleWorkouts.oneShot", message: "one-shot route fetch for old workout", context: [
                    "class": "WorkoutService",
                    "method": "handleWorkouts",
                    "uuid": deviceId,
                    "ageMinutes": "\(ageMinutes)",
                ], subsystem: "WorkoutService")
                await routeService.fetchWorkoutRoute()
                debugPrint("[Humango] WorkoutService: handleWorkouts — one-shot fetch complete for uuid=\(deviceId)")
                SleepRemoteLogger.log(.info, step: "handleWorkouts.oneShotComplete", message: "one-shot route fetch complete", context: [
                    "class": "WorkoutService",
                    "method": "handleWorkouts",
                    "uuid": deviceId,
                ], subsystem: "WorkoutService")
            }
        }
    }


    // MARK: - RouteService Registry Cleanup

    /// Remove route services whose workout endDate is older than 2 hours + optional grace
    func pruneOldRouteServices(graceMinutes: Int = 5) {
        let cutoff = Date().addingTimeInterval(-(WorkoutService.liveWindowSeconds + Double(graceMinutes * 60)))
        routeServiceQueue.async(flags: .barrier) {
            let keysToRemove = self.routeServices.compactMap { (key, rs) -> String? in
                return rs.workoutEndDate < cutoff ? key : nil
            }
            if !keysToRemove.isEmpty {
                debugPrint("[Humango] WorkoutService: pruneOldRouteServices — removing \(keysToRemove.count) stale RouteService(s): \(keysToRemove)")
            }
            for k in keysToRemove {
                self.routeServices[k]?.invalidate()
                self.routeServices.removeValue(forKey: k)
            }
        }
    }

    func removeRouteService(forWorkoutUUID uuidString: String) {
        debugPrint("[Humango] WorkoutService: removeRouteService — uuid=\(uuidString)")
        routeServiceQueue.async(flags: .barrier) {
            self.routeServices[uuidString]?.invalidate()
            self.routeServices.removeValue(forKey: uuidString)
        }
    }

}


