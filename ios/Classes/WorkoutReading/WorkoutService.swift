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
        // NOTE: Do NOT call AppLifecycleManager.removeObserver(self) here.
        // removeObserver dispatches an async(flags: .barrier) block that strongly captures
        // the observer argument, extending its lifetime past deinit and causing a
        // "deallocated with non-zero retain count" dangling-reference warning.
        // invalidate() removes the observer explicitly before the strong ref is released;
        // NSHashTable.weakObjects() clears any remaining stale entry on dealloc.
        debugPrint("[Humango] WorkoutService: deallocated")
    }
    
    // Call this ONCE after you create the service.
    // Chooses foreground (live stream) vs background (observer) based on current app state
    // so a cold background relaunch by HealthKit correctly registers the observer.
    func start() async {
        authorized = true

        if AppLifecycleManager.shared.isInForeground {
            // Foreground: no timing pressure. Prime the anchor first so the live stream
            // only surfaces workouts written after monitoring starts, then enable delivery.
            await primeAnchor()
            await enableBackgroundDelivery()
            debugPrint("VINAY :  [Humango] WorkoutService: start → foreground mode")
            startLiveUpdates()
        } else {
            // Cold background relaunch: the HKObserverQuery may already be registered
            // by prepareBackgroundObserver() called synchronously before this Task.
            // Only install it here if it hasn't been set up yet.
            if observer == nil {
                startBackgroundMonitoring()
            }
            debugPrint("VINAY : [Humango] WorkoutService: start → background mode (cold background relaunch)")
            await primeAnchor()
            await enableBackgroundDelivery()
        }
    }

    /// Registers the HKObserverQuery synchronously — call this immediately after creating
    /// the service when the app is in the background so HealthKit can fire the handler
    /// even if iOS suspends the app before the async `start()` Task runs.
    func prepareBackgroundObserver() {
        authorized = true
        startBackgroundMonitoring()
        debugPrint("[Humango] WorkoutService: prepareBackgroundObserver — observer registered synchronously")
    }

    /// Enables background delivery for workout type once per session. Idempotent —
    /// calling it again when already enabled is a no-op from HealthKit's perspective.
    private func enableBackgroundDelivery() async {
        do {
            try await healthStore.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
            debugPrint("[Humango] WorkoutService: enableBackgroundDelivery(workoutType) — success (immediate)")
        } catch {
            debugPrint("[Humango] WorkoutService: enableBackgroundDelivery(workoutType) — failed: \(error)")
        }
    }
    
    // MARK: - AppLifecycleObserver (Native iOS lifecycle)
    
    func appDidEnterForeground() {
        debugPrint("VINAY:[Humango] WorkoutService: appDidEnterForeground — switching to foreground mode")
        enterForegroundMode()
    }
    
    func appDidEnterBackground() {
        debugPrint("VINAY: [Humango] WorkoutService: appDidEnterBackground — switching to background mode")
        enterBackgroundMode()
    }

    // MARK: - Foreground / Background switches

    func enterBackgroundMode() {
        guard authorized else {
            debugPrint("VINAY: [Humango] WorkoutService: enterBackgroundMode skipped — not authorized")
            return
        }
        let activeRouteCount = routeServices.count
        debugPrint("VINAY: [Humango] WorkoutService: enterBackgroundMode — stopping live updates, starting background observer (activeRouteServices=\(activeRouteCount))")
        stopLiveUpdates()
        startBackgroundMonitoring()
        // Re-register background delivery on every foreground→background transition.
        // enableBackgroundDelivery is idempotent; re-calling it refreshes the HealthKit
        // wake-up registration so iOS wakes the app when new workouts arrive.
        Task { [weak self] in
            guard let self else { return }
            await self.enableBackgroundDelivery()
        }
        debugPrint("VINAY: [Humango] WorkoutService: entered BACKGROUND mode")

        routeServiceQueue.async(flags: .barrier) {
            for (id, rs) in self.routeServices {
                debugPrint("VINAY: [Humango] WorkoutService: propagating background mode → RouteService(\(id))")
                rs.enterBackgroundMode()
            }
        }
    }

    func enterForegroundMode() {
        guard authorized else {
            debugPrint("VINAY: [Humango] WorkoutService: enterForegroundMode skipped — not authorized")
            return
        }
        let activeRouteCount = routeServices.count
        debugPrint("VINAY: [Humango] WorkoutService: enterForegroundMode — stopping background observer, starting live updates (activeRouteServices=\(activeRouteCount))")
        stopBackgroundMonitoring()
        startLiveUpdates()
        debugPrint("VINAY: [Humango] WorkoutService: entered FOREGROUND mode")

        routeServiceQueue.async(flags: .barrier) {
            for (id, rs) in self.routeServices {
                debugPrint("VINAY: [Humango] WorkoutService: propagating foreground mode → RouteService(\(id))")
                rs.enterForegroundMode()
            }
        }

        pruneOldRouteServices()
    }

    // MARK: - Live Updates (Foreground)

    func startLiveUpdates() {
        guard authorized else {
            debugPrint("VINAY: [Humango] WorkoutService: startLiveUpdates skipped — not authorized")
            return
        }
        debugPrint("VINAY: [Humango] WorkoutService: startLiveUpdates — opening HKAnchoredObjectQueryoror stream from \(startDate)")

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
            do {
                for try await update in stream {
                    self.anchor = update.newAnchor
                    let count = update.addedSamples.count
                    debugPrint("[Humango] WorkoutService: live stream update — \(count) new workout(s)")
                    for w in update.addedSamples {
                        debugPrint("[Humango] WorkoutService: live workout received — uuid=\(w.uuid.uuidString) type=\(w.workoutActivityType.name) start=\(w.startDate) end=\(w.endDate)")
                        // Fire-and-forget in foreground — keeps the stream loop unblocked.
                        Task { await self.handleWorkouts(workout: w) }
                    }
                }
                debugPrint("[Humango] WorkoutService: live update stream ended normally")
            } catch {
                debugPrint("[Humango] WorkoutService: live update stream error — \(error)")
            }
        }
    }

    func stopLiveUpdates() {
        guard updateTask != nil else { return }
        debugPrint("[Humango] WorkoutService: stopLiveUpdates — cancelling live stream task")
        updateTask?.cancel()
        updateTask = nil
    }

    // MARK: - Initial / Background Fetch (anchored query snapshot)

    private func fetchWorkouts(upToNow: Bool = false) async {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: fetchWorkouts skipped — not authorized")
            return
        }
        let endDate = upToNow ? Date() : Date().addingTimeInterval(-WorkoutService.liveWindowSeconds)
        debugPrint("[Humango] WorkoutService: fetchWorkouts — querying \(startDate) → \(endDate) (upToNow=\(upToNow))")

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
            await withTaskGroup(of: Void.self) { group in
                for workout in result.addedSamples {
                    debugPrint("[Humango] WorkoutService: fetchWorkouts — handling uuid=\(workout.uuid.uuidString) type=\(workout.workoutActivityType.name)")
                    group.addTask { await self.handleWorkouts(workout: workout) }
                }
            }
        } catch {
            debugPrint("[Humango] WorkoutService: fetchWorkouts error — \(error)")
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
        } catch {
            // Leave anchor nil; worst case the first update replays known workouts
            // which WorkoutDedup in the delegate will handle.
            debugPrint("[Humango] WorkoutService: primeAnchor failed (\(error)) — proceeding with nil anchor")
        }
    }

    // MARK: - Background Monitoring (HKObserverQuery)

    func startBackgroundMonitoring() {
        guard authorized else {
            debugPrint("[Humango] WorkoutService: startBackgroundMonitoring skipped — not authorized")
            return
        }
        // Stop any existing observer before registering a new one to prevent leaking
        // orphaned HKObserverQuery instances on repeated calls.
        if let existing = observer {
            healthStore.stop(existing)
            observer = nil
            debugPrint("[Humango] WorkoutService: startBackgroundMonitoring — stopped stale observer before re-registering")
        }
        debugPrint("[Humango] WorkoutService: startBackgroundMonitoring — installing background observer")

        observer = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            // NOTE: Do NOT use `defer { completion() }` here.
            // completion() must be called AFTER the full async fetch → route → delegate
            // pipeline finishes so iOS does not suspend the app mid-delivery.

            let fireTime = Date()
            if let error = error {
                debugPrint("[Humango] WorkoutService: background observer error at \(fireTime) — \(error)")
                completion()
                return
            }

            debugPrint("[Humango] WorkoutService: background observer fired at \(fireTime) — starting fetch pipeline")
            Task {
                await self.fetchWorkouts(upToNow: true)
                self.pruneOldRouteServices()
                debugPrint("[Humango] WorkoutService: background observer pipeline complete — signalling completion()")
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
        }
    }

    /// Tear down this service cleanly.
    /// Sets `authorized = false` so all lifecycle guards (enterForegroundMode /
    /// enterBackgroundMode) become no-ops immediately, stops both monitoring paths,
    /// and removes the lifecycle observer. Call this BEFORE releasing the strong
    /// reference to the service (e.g. `workoutService = nil`) so that removeObserver's
    /// async barrier fires while the object is still valid.
    func invalidate() {
        authorized = false
        stopLiveUpdates()
        stopBackgroundMonitoring()
        AppLifecycleManager.shared.removeObserver(self)
        debugPrint("[Humango] WorkoutService: invalidated")
    }

    // MARK: - Decide per-workout behavior (one-shot vs retained live)

    func handleWorkouts(workout: HKWorkout) async {
        if workout.endDate <= workout.startDate {
            debugPrint("[Humango] WorkoutService: handleWorkouts — skipping incomplete workout uuid=\(workout.uuid.uuidString) start=\(workout.startDate) end=\(workout.endDate)")
            return
        }

        let deviceId = workout.uuid.uuidString
        let ageSinceEnd = Date().timeIntervalSince(workout.endDate)
        let ageMinutes = Int(ageSinceEnd / 60)
        let isRecent = ageSinceEnd <= WorkoutService.liveWindowSeconds
        debugPrint("[Humango] WorkoutService: handleWorkouts — uuid=\(deviceId) type=\(workout.workoutActivityType.name) ageMinutes=\(ageMinutes) isRecent=\(isRecent)")

        let routeService = RouteService(workout: workout)

        if isRecent {
            debugPrint("[Humango] WorkoutService: handleWorkouts — recent workout, retaining RouteService for uuid=\(deviceId)")
            routeServiceQueue.sync(flags: .barrier) {
                self.routeServices[deviceId] = routeService
            }

            debugPrint("[Humango] WorkoutService: handleWorkouts — fetching initial route snapshot for uuid=\(deviceId)")
            await routeService.fetchWorkoutRoute()

            if AppLifecycleManager.shared.isInForeground {
                routeService.startLiveUpdates()
                debugPrint("[Humango] WorkoutService: handleWorkouts — RouteService live updates started for uuid=\(deviceId)")
            } else {
                await routeService.startBackgroundMonitoring()
                debugPrint("[Humango] WorkoutService: handleWorkouts — RouteService background monitoring started for uuid=\(deviceId)")
            }
        } else {
            debugPrint("[Humango] WorkoutService: handleWorkouts — old workout (ageMinutes=\(ageMinutes)), one-shot fetch for uuid=\(deviceId)")
            await routeService.fetchWorkoutRoute()
            debugPrint("[Humango] WorkoutService: handleWorkouts — one-shot fetch complete for uuid=\(deviceId)")
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


