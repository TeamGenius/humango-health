//
// WorkOutService.swift
// Updated: integrated RouteService registry + endDate 2-hour rule + WorkoutRecordStore touches
//

import Foundation
import HealthKit

@available(iOS 17.0, *)
final class WorkoutService {
    // public-ish config
    static let liveWindowSeconds: TimeInterval = 2 * 60 * 60 // 2 hours

    let startDate: Date
    let endDate: Date
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
    private var appIsActive = true

    // --- registry of active RouteService instances (only for recent + tracked workouts)
    private var routeServices: [String: RouteService] = [:]
    private let routeServiceQueue = DispatchQueue(label: "com.humango.WorkoutService.routeQueue", attributes: .concurrent)

    init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
        self.handleSpotImporting()
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
    func start() async {
        do {
            try await requestAuthorization()
            authorized = true
            debugPrint("Read Workouts: WorkoutService: start")
            await fetchWorkouts()          // initial delta fetch
             startLiveUpdates()   
        } catch {
            print("Read Workouts: HealthKit auth failed: \(error)")
        }
    }

    // MARK: - Foreground / Background switches

    // Call to switch into background mode: stop live streaming & enable background observer
    func enterBackgroundMode() {
        appIsActive = false
        // stop foreground live streaming
        stopLiveUpdates()
        // start background observer/wake-ups
        startBackgroundMonitoring()
        debugPrint("Read Workouts: WorkoutService -> entered BACKGROUND mode")

        // Propagate to retained route services
        routeServiceQueue.async(flags: .barrier) {
            for (_, rs) in self.routeServices {
                rs.enterBackgroundMode()
            }
        }
    }

    // Call to switch back into foreground mode: stop background monitoring & start live streaming
    func enterForegroundMode() {
        appIsActive = true
        // stop background observer/wake-ups
        stopBackgroundMonitoring()
        // start live streaming in foreground
        startLiveUpdates()
        debugPrint("Read Workouts: WorkoutService -> entered FOREGROUND mode")

        // Propagate to retained route services
        routeServiceQueue.async(flags: .barrier) {
            for (_, rs) in self.routeServices {
                rs.enterForegroundMode()
            }
        }

        // opportunistic cleanup
        pruneOldRouteServices()
    }

    // MARK: - Authorization & sample types

    private func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var hkSampleTypes = Set<HKSampleType>()
        hkSampleTypes.insert(HKObjectType.workoutType())
        hkSampleTypes.insert(HKSeriesType.workoutRoute())
        hkSampleTypes.insert(HKSampleType.categoryType(forIdentifier: .sleepAnalysis)!)
        let quantityIdentifiers = getQuantityTypeIdentifiers()
        for quantityIdentifier in quantityIdentifiers {
            if let q = HKSampleType.quantityType(forIdentifier: quantityIdentifier) {
                hkSampleTypes.insert(q)
            }
        }
        try await healthStore.requestAuthorization(
            toShare: [],
            read: hkSampleTypes
        )
    }

    func getQuantityTypeIdentifiers() -> [HKQuantityTypeIdentifier] {
        var quantityIdentifiers = [
            HKQuantityTypeIdentifier.heartRate,
            HKQuantityTypeIdentifier.stepCount,
            HKQuantityTypeIdentifier.distanceCycling,
            HKQuantityTypeIdentifier.swimmingStrokeCount,
            HKQuantityTypeIdentifier.distanceSwimming,
            HKQuantityTypeIdentifier.vo2Max,
            HKQuantityTypeIdentifier.distanceWalkingRunning,
            HKQuantityTypeIdentifier.activeEnergyBurned,
            HKQuantityTypeIdentifier.bodyMass,
            HKQuantityTypeIdentifier.height,
            HKQuantityTypeIdentifier.restingHeartRate,
            HKQuantityTypeIdentifier.heartRateVariabilitySDNN,
            HKQuantityTypeIdentifier.bodyMassIndex,
            HKQuantityTypeIdentifier.runningGroundContactTime,
            HKQuantityTypeIdentifier.runningPower,
            HKQuantityTypeIdentifier.runningSpeed,
            HKQuantityTypeIdentifier.runningStrideLength,
            HKQuantityTypeIdentifier.runningVerticalOscillation,
            HKQuantityTypeIdentifier.cyclingCadence,
            HKQuantityTypeIdentifier.cyclingPower,
        ]

        return quantityIdentifiers
    }

    // MARK: - Fetching workouts

    // Use this for one-shot fetches (e.g., on start or from observer)
    // Use this replacement for your fetchWorkouts()
    func fetchWorkouts(upToNow: Bool = false) async {
        debugPrint("Read Workouts: WorkoutService: fetchWorkouts (upToNow: \(upToNow))")
        guard authorized else { return }

        // If caller wants the latest data (background observer), use 'now' as end
        let effectiveEnd: Date? = upToNow ? Date() : endDate

        // Bounded window: startDate .. effectiveEnd
        let initialPredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: effectiveEnd,
            options: [.strictStartDate, .strictEndDate]
        )

        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(initialPredicate)],
            anchor: anchor,
            limit: 0
        )

        do {
            debugPrint("Read Workouts: WorkoutService: fetchWorkouts (upToNow: \(upToNow))")
            
            let result: HKAnchoredObjectQueryDescriptor<HKWorkout>.Result = try await desc.result(for: healthStore)
            debugPrint("Read Workouts: WorkoutService: anchored result — addedSamples.count = \(result.addedSamples.count)")
            anchor = result.newAnchor
            for w in result.addedSamples {
                debugPrint("Read Workouts: WorkoutService: workout activity type :\(w.workoutActivityType.name) ")
                if !excludeImporting.contains(w.workoutActivityType.name) {
                    handleWorkouts(workout: w)
                }
            }
        } catch {
            print("Read Workouts: WorkoutService: Fetch failed: \(error)")
        }
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
            // Check local record store presence
            let existsLocally = await WorkoutRecordStore.shared.hasRecord(deviceActivityId: deviceId)

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

                // Start the appropriate mode depending on app state
                if appIsActive {
                    // App in foreground — start live streaming
                    routeService.startLiveUpdates()
                    debugPrint("Read Workouts: WorkoutService:  started RouteService live updates for \(deviceId)")
                } else {
                    // App in background — enable background monitoring for route updates
                    routeService.startBackgroundMonitoring()
                    debugPrint("Read Workouts: WorkoutService: started RouteService background monitoring for \(deviceId)")
                }

                // touch last-seen timestamp in the store so we know this workout is being tracked
                await WorkoutRecordStore.shared.updateLastSeen(deviceActivityId: deviceId, date: Date())
            } else {
                // One-shot fetch & push. No live/background listeners retained.
                await routeService.fetchWorkoutRoute()
                // Record first seen so future logic can decide to retain if needed
                await WorkoutRecordStore.shared.recordFirstSeen(deviceActivityId: deviceId, date: Date())
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


