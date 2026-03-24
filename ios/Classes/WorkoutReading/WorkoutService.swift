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
    private let cycling = "Cycling"
    private let running = "Running"
    private let swimminng = "Swimming"
    private let strength = "Strength"
    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private var anchor: HKQueryAnchor?
    private var updateTask: Task<Void, Never>?
    private var observer: HKObserverQuery?
    private var authorized = false
    private var importRunning = false
    private var importCycling = false
    private var importSwimming = false
    private var excludeImporting : [String] = []

    // --- registry of active RouteService instances (only for recent + tracked workouts)
    private var routeServices: [String: RouteService] = [:]
    private let routeServiceQueue = DispatchQueue(label: "com.humango.WorkoutService.routeQueue", attributes: .concurrent)

    init(startDate: Date) {
        self.startDate = startDate
        self.handleSpotImporting()
        
        // Register with AppLifecycleManager for automatic foreground/background switching
        AppLifecycleManager.shared.addObserver(self)
        debugPrint("Read Workouts: WorkoutService initialized with native lifecycle observer")
    }
    
    deinit {
        AppLifecycleManager.shared.removeObserver(self)
    }
    
    func handleSpotImporting(){
        importRunning =  UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportRunning)
        importCycling =  UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportCycling)
        importSwimming =  UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportSwimming)

        
        if !importRunning {
            excludeImporting.append(running)
        }
        if !importCycling {
            excludeImporting.append(cycling)
        }
        if !importSwimming {
            excludeImporting.append(swimminng)
        }
       
    }

    // Call this ONCE after you create the service
    // Note: Authorization is handled by PermissionManager before creating this service
    // startLiveUpdates() uses an open-ended anchored query (startDate → nil) so the first
    // stream delivery already includes all historical workouts — no separate fetch needed.
    func start() async {
        authorized = true
        debugPrint("Read Workouts: WorkoutService: start")
        startLiveUpdates()
    }
    
    // MARK: - AppLifecycleObserver (Native iOS lifecycle)
    
    func appDidEnterForeground() {
        enterForegroundMode()
    }
    
    func appDidEnterBackground() {
        enterBackgroundMode()
    }

    // MARK: - Foreground / Background switches

    // Call to switch into background mode: stop live streaming & enable background observer
    func enterBackgroundMode() {
        guard authorized else { return }
        
        // stop foreground live streaming
        stopLiveUpdates()
        // start background observer/wake-ups
        startBackgroundMonitoring()
        debugPrint("Read Workouts: WorkoutService -> entered BACKGROUND mode via native lifecycle")

        // Propagate to retained route services
        routeServiceQueue.async(flags: .barrier) {
            for (_, rs) in self.routeServices {
                rs.enterBackgroundMode()
            }
        }
    }

    // Call to switch back into foreground mode: stop background monitoring & start live streaming
    func enterForegroundMode() {
        guard authorized else { return }
        
        // stop background observer/wake-ups
        stopBackgroundMonitoring()
        // start live streaming in foreground
        startLiveUpdates()
        debugPrint("Read Workouts: WorkoutService -> entered FOREGROUND mode via native lifecycle")

        // Propagate to retained route services
        routeServiceQueue.async(flags: .barrier) {
            for (_, rs) in self.routeServices {
                rs.enterForegroundMode()
            }
        }

        // opportunistic cleanup
        pruneOldRouteServices()
    }

   
    // Live stream while app is open
    func startLiveUpdates() {
        guard authorized else { return }

        // OPEN-ENDED: start at startDate, no endDate so future workouts match
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
            do {
                for try await update in stream {
                    self.anchor = update.newAnchor

                    for w in update.addedSamples {
                        debugPrint("Read Workouts: WorkoutService: Live Workout")
                        debugPrint("Read Workouts: WorkoutService: workout activity type :\(w.workoutActivityType.name)")
                        print("Workout UUID: \(w.uuid)")
                        
                        // Check workoutPlan asynchronously without blocking the stream
                        // Task {
                        //     do {
                        //         let plan = try await w.workoutPlan
                        //         if let plan = plan {
                        //             print("✅ WorkoutPlan found - ID: \(plan.id)")
                        //         } else {
                        //             print("ℹ️ No WorkoutPlan attached (manual workout)")
                        //         }
                        //     } catch {
                        //         print("⚠️ Error accessing workoutPlan: \(error)")
                        //     }
                        // }
                        
                        dump(w)
                        self.handleWorkouts(workout: w)
                    }
                }
            } catch {
                print("Read Workouts: WorkoutService: Live updates error: \(error)")
            }
        }
    }

    func stopLiveUpdates() { updateTask?.cancel(); updateTask = nil }

    // MARK: - Initial fetch (anchored query snapshot)
    
    private func fetchWorkouts(upToNow: Bool = false) async {
        guard authorized else { return }
        
        // For initial fetch or background wake-ups
        let endDate = upToNow ? Date() : Date().addingTimeInterval(-WorkoutService.liveWindowSeconds)
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
            
            debugPrint("Read Workouts: WorkoutService: fetchWorkouts found \(result.addedSamples.count) workouts")
            
            for workout in result.addedSamples {
                handleWorkouts(workout: workout)
            }
        } catch {
            print("Read Workouts: WorkoutService: fetchWorkouts error: \(error)")
        }
    }
    

    // MARK: - Background observer/wake-ups

    func startBackgroundMonitoring() {
        guard authorized else {
               debugPrint("Read Workouts: WorkoutService: startBackgroundMonitoring: not authorized — skipping")
               return
           }

        // 1) Enable background delivery for workouts and workout routes (async)
            Task {
                do {
                    try await healthStore.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
                    debugPrint("Read Workouts: WorkoutService: enabled background delivery for workoutType (immediate)")
                } catch {
                    debugPrint("Read Workouts: WorkoutService: enableBackgroundDelivery(workoutType) failed: \(error)")
                }
            }

        // Use a broad predicate (or nil) so you don’t miss changes
        observer = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            // ALWAYS re-arm observer — use defer to ensure completion() is called once.
            defer { completion() }

            if let error = error {
                debugPrint("Read Workouts: WorkoutService: workout observer error: \(error)")
                return
            }

            // Keep observer work minimal — schedule async Task to do the real work.
            Task {
                debugPrint("Read Workouts: WorkoutService: workout observer fired (background) — fetching workouts (one-shot)")
                 // use upToNow: true so predicate end = now (includes newly finished workouts)
                 await self.fetchWorkouts(upToNow: true)
                    
                 self.pruneOldRouteServices()
            }
        }

        if let q = observer {
            healthStore.execute(q)
            debugPrint("Read Workouts: WorkoutService: installed workout observer")
        }
    }

    func stopBackgroundMonitoring() {
        if let q = observer {
                healthStore.stop(q)
            observer = nil
                debugPrint("Read Workouts: WorkoutService: removed workout observer")
            }
      
        // Disable background delivery per-type (completion-based API)
        healthStore.disableBackgroundDelivery(for: .workoutType()) { ok, err in
                if let err {
                    debugPrint("Read Workouts: WorkoutService: disableBackgroundDelivery(workoutType) error: \(err)")
                } else {
                    debugPrint("Read Workouts: WorkoutService: disableBackgroundDelivery(workoutType) ok: \(ok)")
                }
            }
    }

    // MARK: - Decide per-workout behavior (one-shot vs retained live)

    func handleWorkouts(workout: HKWorkout) {
        // Defensive: ignore incomplete workouts that don't have a valid completion time.
        if workout.endDate <= workout.startDate {
            debugPrint("Read Workouts: skipping incomplete workout: \(workout.uuid.uuidString) start:\(workout.startDate) end:\(workout.endDate)")
            return
        }

        debugPrint("Read Workouts: workout activity type :\(workout.workoutActivityType.name)")
        // Use workout.endDate (completed time) for recency logic
        let deviceId = workout.uuid.uuidString
        let now = Date()
        let ageSinceEnd = now.timeIntervalSince(workout.endDate)
        let twoHours = WorkoutService.liveWindowSeconds


        // Run async work in a single Task (keeps this method fast and non-blocking)
        Task {
            // Create a RouteService for this workout (we'll either retain it or use it for one-shot)
            let routeService = RouteService(workout: workout)

            if ageSinceEnd <= twoHours  {
                // Recent completion AND already tracked locally -> retain and start listening.
                // Add to registry (thread-safe)
                routeServiceQueue.async(flags: .barrier) {
                    self.routeServices[deviceId] = routeService
                }

                // Fetch snapshot first (so we have any already-available routes)
                await routeService.fetchWorkoutRoute()

                // Start the appropriate mode depending on app state (from native lifecycle manager)
                if AppLifecycleManager.shared.isInForeground {
                    // App in foreground — start live streaming
                    routeService.startLiveUpdates()
                    debugPrint("Read Workouts: WorkoutService:  started RouteService live updates for \(deviceId)")
                } else {
                    // App in background — enable background monitoring for route updates
                    routeService.startBackgroundMonitoring()
                    debugPrint("Read Workouts: WorkoutService: started RouteService background monitoring for \(deviceId)")
                }
            } else {
                // One-shot fetch & push. No live/background listeners retained.
                await routeService.fetchWorkoutRoute()
                debugPrint("Read Workouts: one-shot RouteService fetch complete for \(deviceId)")
            }
        }
    }


    // --- cleanup helpers for the route service registry

    /// Remove route services whose workout endDate is older than 2 hours + optional grace
    func pruneOldRouteServices(graceMinutes: Int = 5) {
        let cutoff = Date().addingTimeInterval(-(WorkoutService.liveWindowSeconds + Double(graceMinutes * 60)))
        routeServiceQueue.async(flags: .barrier) {
            let keysToRemove = self.routeServices.compactMap { (key, rs) -> String? in
                return rs.workoutEndDate < cutoff ? key : nil
            }
            for k in keysToRemove {
                self.routeServices[k]?.invalidate()
                self.routeServices.removeValue(forKey: k)
            }
        }
    }

    func removeRouteService(forWorkoutUUID uuidString: String) {
        routeServiceQueue.async(flags: .barrier) {
            self.routeServices[uuidString]?.invalidate()
            self.routeServices.removeValue(forKey: uuidString)
        }
    }

}


