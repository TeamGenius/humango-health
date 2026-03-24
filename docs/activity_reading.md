# Read Workouts Subsystem - Requirements & Design

**Document Version:** 1.2  
**Date:** March 24, 2026  
**Plugin:** `humango_health`  
**Subsystem:** Workout Reading & Monitoring

> **Current API (0.0.12+):** Background workout delivery is **stream + `UserDefaults` pending queue** only. There is **no** Dart `getLocalWorkouts()` and **no** native HTTP POST for completed workouts. Use `WorkoutReadManager.configureBackgroundDelivery(const BackgroundDeliveryConfig())`, subscribe to `workoutStream`, call `readWorkouts` for catch-up, and drain pending JSON from **native** `BackgroundWorkouts.pending` in your Runner if you cannot keep a stream listener alive while suspended (see README and `READ_WORKOUTS_SUBSYSTEM.md`).

---

## Requirements

### Functional Requirements

#### 1. Permission Verification

- **MUST** verify user has READ permission for workout data before monitoring
- **MUST** use cached permission status from Permission Manager
- **MUST** return clear error if permission not granted
- Guide user to request permission if not available

#### 2. Reading APIs (Dart)

| Method / member | Description | Use Case |
|-----------------|-------------|----------|
| `readWorkouts(startDate, {endDate, options})` | One-shot fetch (respects `WorkoutRecordStore` dedup) | Initial sync, manual refresh |
| `fetchAllWorkouts(startDate, {endDate})` | One-shot unfiltered snapshot | Audit / full re-sync |
| `startMonitoring(startDate, {options})` | Continuous monitoring | Real-time tracking |
| `stopMonitoring()` | Stops observers / clears cached event stream | Teardown |
| `configureBackgroundDelivery(BackgroundDeliveryConfig())` | Arms stream + pending queue | After login (with `UserSessionManager`) |
| `workoutStream` | `Stream<String>` — each event is a workout JSON string | Live updates when a listener is attached |
| `markWorkoutsAsPushed(deviceActivityIds)` | Marks IDs as uploaded to **your** backend | After successful POST from your app |
| `setImportPreferences(running, cycling, swimming)` | Filters which activity types are imported | Before read/monitor |
| `getWorkoutStoreRecords()` | Debug: native store rows | Diagnostics |
| `enterForegroundMode` / `enterBackgroundMode` | Manual lifecycle override | Rare; iOS uses `AppLifecycleManager` by default |

Pending workouts while **no** stream listener exists are stored by native `WorkoutStreamDelivery` under `BackgroundWorkouts.pending`. There is **no** `getLocalWorkouts` on the MethodChannel — drain from Swift/Runner or avoid backlog by subscribing to `workoutStream` when the app runs.

#### 3. Dual-Mode Monitoring Strategy

**Foreground Mode (App Active):**
- Use `HKAnchoredObjectQueryDescriptor` with live streaming
- Push workouts immediately to Flutter via **Event Channel**
- Monitor both workout completion and route updates
- Real-time updates without delay

**Background Mode (App Suspended):**
- Use `HKObserverQuery` for system wake-ups
- Use `enableBackgroundDelivery()` for both workouts and routes
- Two-hour window for "recent" workouts that need route tracking
- Minimal battery impact

#### 4. Background delivery (stream / pending only)

`BackgroundDeliveryConfig` supports **`localStorage`** only (default). The native layer either delivers JSON on `workoutStream` (sink attached) or appends to the `UserDefaults` pending array. The plugin **never** POSTs workout JSON to your backend.

#### 5. Deduplication logic

**Read pipeline (`WorkoutRecordStore`):**
- SHA-256 hash + byte size of the serialized payload per `deviceActivityId`
- `shouldPush` / upsert pending before emitting to stream or pending queue
- `pushed == true` after your app calls **`markWorkoutsAsPushed`** (successful upload to **your** API). The plugin does **not** HTTP POST completed workouts.

**Scheduling (WorkoutKit) vs reading:** Seeing whether a completed HK workout corresponded to an Apple Watch **scheduled** plan is a separate product concern; the shipped `WorkoutData` model does not include `wasScheduled` fields.

#### 6. Workout data contents

Each workout includes:
- **Core metadata:** distance, duration, activity type, start/end times
- **Statistics:** all HKStatistics (avg/max/min heart rate, calories, etc.)
- **Quantity series:** heart rate, steps, distance, power, cadence (20+ types)
- **Route data:** GPS coordinates as `[CLLocation]` array
- **Events:** workout segments, laps, pauses
- **Metadata:** device source, iOS version, custom fields

#### 7. Selective import preferences

Dart: `setImportPreferences(running: bool, cycling: bool, swimming: bool)` — stored natively (`UserDefaults`) and applied during fetch/monitor.

---

## Technical Design

### Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                Flutter Application Layer                 │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│          Workout Read Manager (Dart)                     │
│  ├─ readWorkouts / fetchAllWorkouts                      │
│  ├─ startMonitoring / stopMonitoring                     │
│  ├─ configureBackgroundDelivery                         │
│  ├─ markWorkoutsAsPushed / setImportPreferences           │
│  └─ workoutStream → Stream<String> (JSON)              │
└─────────────────────┬────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          │                       │
    MethodChannel           EventChannel
  "com.humango.workouts/read"  "com.humango.workouts/read/stream"
          │                       │
          └───────────┬───────────┘
┌─────────────────────┴────────────────────────────────────┐
│           iOS Native - Workout Monitoring                │
│  ┌─ WorkoutService (main orchestrator)                   │
│  │   ├─ Foreground: HKAnchoredObjectQueryDescriptor      │
│  │   ├─ Background: HKObserverQuery + background delivery│
│  │   ├─ RouteService registry (2-hour window)            │
│  │   └─ Mode switching (foreground/background)           │
│  │                                                        │
│  ┌─ RouteService (per-workout route tracking)            │
│  │   ├─ Foreground: live route streaming                 │
│  │   ├─ Background: route observer                       │
│  │   ├─ Quantity series fetching (20+ types)             │
│  │   └─ Completes payload → WorkoutStreamDelivery        │
│  ┌─ WorkoutStreamDelivery                                │
│  │   └─ EventSink or UserDefaults pending (no HTTP)      │
│  │                                                        │
│  ┌─ WorkoutRecordStore (actor-based storage)             │
│  │   ├─ SHA256 hashing for change detection              │
│  │   ├─ UserDefaults persistence                         │
│  │   ├─ Deduplication logic                              │
│  │   └─ Push status tracking                             │
│  │                                                        │
│  └─ WorkoutFetcher (one-shot queries)                    │
│      ├─ Date range bounded fetches                       │
│      ├─ Selective import filtering                       │
│      └─ JSON serialization                               │
└──────────────────────────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│                HealthKit Framework (iOS)                 │
│  ├─ HKAnchoredObjectQueryDescriptor (foreground)         │
│  ├─ HKObserverQuery (background)                         │
│  ├─ HKWorkout, HKWorkoutRoute                            │
│  ├─ HKQuantitySample (heart rate, steps, etc.)           │
│  └─ enableBackgroundDelivery() / disableBackgroundDelivery() │
└──────────────────────────────────────────────────────────┘
```

---

## Data models

The MethodChannel and `workoutStream` carry **`List<String>` / `String` JSON** payloads. Parsing into the optional Dart model is done in your app, e.g. `WorkoutData.fromJson(jsonDecode(s))` when shapes match.

### 1. WorkoutData (Dart — optional parser)

```dart
class WorkoutData {
  final String workoutId;           // UUID from HealthKit
  final String activityType;        // Running, Cycling, Swimming, etc.
  final DateTime startTime;
  final DateTime endTime;
  final double duration;            // seconds
  final double? distance;           // meters
  final double? activeCalories;     // kcal
  final WorkoutStatistics statistics;
  final List<QuantitySeries> quantitySeries;
  final List<RouteLocation> route;
  final List<WorkoutEvent> events;
  final Map<String, dynamic> metadata;
  
  WorkoutData({...});
  
  factory WorkoutData.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}

class WorkoutStatistics {
  final double? avgHeartRate;
  final double? maxHeartRate;
  final double? avgPower;
  final double? avgCadence;
  // ... more stats
}

class QuantitySeries {
  final String type;                // heartRate, steps, power, etc.
  final List<QuantityPoint> points;
}

class QuantityPoint {
  final DateTime timestamp;
  final double value;
  final String unit;
}

class RouteLocation {
  final double latitude;
  final double longitude;
  final double altitude;
  final double? speed;
  final double? course;
  final DateTime timestamp;
}

class WorkoutEvent {
  final String type;                // lap, pause, resume, segment
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;
}
```

### 2. BackgroundDeliveryConfig (Dart)

```dart
class BackgroundDeliveryConfig {
  final BackgroundDeliveryMode mode; // localStorage only

  const BackgroundDeliveryConfig({this.mode = BackgroundDeliveryMode.localStorage});

  Map<String, dynamic> toJson();
  factory BackgroundDeliveryConfig.fromJson(Map<String, dynamic> json);
}

enum BackgroundDeliveryMode {
  localStorage,
}
```

### 3. WorkoutReadOptions (Dart)

```dart
class WorkoutReadOptions {
  final DateTime startDate;
  final DateTime endDate;
  final bool includeRunning;
  final bool includeCycling;
  final bool includeSwimming;
  final bool includeOther;          // All other activity types
  
  WorkoutReadOptions({
    required this.startDate,
    required this.endDate,
    this.includeRunning = true,
    this.includeCycling = true,
    this.includeSwimming = true,
    this.includeOther = true,
  });
}
```

### 4. HuWorkout (Swift - from your existing code)

```swift
struct HuWorkout {
    let distance: HKQuantity?
    let duration: TimeInterval
    let sport: HKWorkoutActivityType
    let start_time: Date
    let routeData: HuRouteData
    let deviceActivityId: String      // UUID
    let statistics: [HKStatisticsOptions: HKStatistics]
    let events: [HKWorkoutEvent]?
    let workoutActivities: [HKWorkoutActivity]?
    let metadata: [String: Any]
    
    func toDict() -> [String: Any]?
    func toJson() -> Data?
}

struct HuRouteData {
    let samples: [[HKQuantitySample]]  // 20+ quantity types
    let locations: [CLLocation]        // GPS route
}
```

### 5. WorkoutRecord (Swift - from WorkoutRecordStore)

```swift
struct WorkoutRecord: Codable {
    var deviceActivityId: String      // workout UUID
    var dataHash: String              // SHA256 hex
    var dataSize: Int                 // bytes
    var pushed: Bool                  // true after markWorkoutsAsPushed / backend ack
    var firstSeenISO: String?         // ISO8601 timestamp
    var lastUpdatedISO: String        // ISO8601 timestamp
}
```

---

## Implementation reference (0.0.12)

Older drafts of this document (Phases 1–8) described `BackgroundDeliveryManager`, native HTTP POST, `getLocalWorkouts`, and `HumangoWorkoutsPlugin`. **Those are removed / superseded.** The following matches the repo today.

### Dart (`lib/src/`)

| Symbol | Role |
|--------|------|
| `WorkoutReadManager` | `readWorkouts`, `fetchAllWorkouts`, `startMonitoring`, `stopMonitoring`, `configureBackgroundDelivery`, `markWorkoutsAsPushed`, `setImportPreferences`, `getWorkoutStoreRecords`, lifecycle overrides |
| `workoutStream` | `Stream<String>` — workout JSON strings |
| `BackgroundDeliveryConfig` | `localStorage` only |
| `WorkoutReadOptions` | Optional filters for reads |
| `WorkoutData`, `QuantitySeries`, etc. | Optional parsing of JSON maps |

**Channels:** `com.humango.workouts/read` (method), `com.humango.workouts/read/stream` (events). **Registration:** `ios/Classes/HumangoHealthPlugin.swift`.

### iOS (`ios/Classes/WorkoutReading/`)

| File | Role |
|------|------|
| `WorkoutServiceChannel.swift` | Method + stream handler; routes `configureBackgroundDelivery` to `WorkoutStreamDelivery.arm()` |
| `WorkoutStreamDelivery.swift` | Delivers JSON to Flutter when `EventSink` attached; else appends to `UserDefaults` key `BackgroundWorkouts.pending`. **No URLSession to your API.** |
| `WorkoutService.swift` | Anchored + observer queries, lifecycle via `AppLifecycleManager` |
| `RouteService.swift` | Routes, quantity samples, final workout assembly |
| `WorkoutRecordStore.swift` | Dedup + `pushed` flag (set when Dart calls `markWorkoutsAsPushed`) |

### Pending queue

`WorkoutStreamDelivery.retrieveLocalWorkouts()` exists **in Swift** for internal use / testing. There is **no** Dart MethodChannel to pull pending JSON — host Runner code may read `BackgroundWorkouts.pending`, or keep `workoutStream` subscribed while the app is foregrounded.

### Optional: Flutter lifecycle overrides

`enterForegroundMode` / `enterBackgroundMode` on `WorkoutReadManager` are optional. **Native** `AppLifecycleManager` already switches workout monitoring modes; see [README.md](../README.md#native-ios-lifecycle-management).

---

### Phase 9 (optional product design — not in shipped API)

**Objective:** Link completed workouts with scheduled workouts from the WorkoutKit **push** subsystem.

The current `WorkoutData` model and JSON pipeline **do not** expose `wasScheduled` / `scheduledHash`. Treat this section as a **future** design note if you need adherence analytics.

**Tasks:**
1. When workout completes, check UserDefaults for matching hash:
   ```swift
   func handleWorkoutCompletion(workout: HKWorkout) async {
       let workoutId = workout.uuid.uuidString
       
       // Check if this was a pushed/scheduled workout
       if let pushedHash = UserDefaults.standard.string(forKey: workoutId) {
           debugPrint("✅ Workout \(workoutId) matches pushed workout")
           debugPrint("   Scheduled hash: \(pushedHash)")
           
           // Add to workout metadata
           var metadata = workout.metadata ?? [:]
           metadata["wasScheduled"] = true
           metadata["scheduledHash"] = pushedHash
           
           // Continue with normal processing...
       } else {
           debugPrint("📝 Workout \(workoutId) was NOT scheduled (spontaneous workout)")
       }
   }
   ```

2. In Dart, expose this information:
   ```dart
   class WorkoutData {
     // ... existing fields
     final bool wasScheduled;        // Was this a scheduled workout?
     final String? scheduledHash;    // Hash from push subsystem
     
     bool matchesScheduledWorkout(String pushHash) {
       return wasScheduled && scheduledHash == pushHash;
     }
   }
   ```

3. Add analytics/reporting:
   ```dart
   class WorkoutAnalytics {
     static void trackWorkoutCompletion(WorkoutData workout) {
       if (workout.wasScheduled) {
         print('User completed scheduled workout: ${workout.workoutId}');
         // Send to analytics: user adherence tracking
       } else {
         print('User completed spontaneous workout: ${workout.workoutId}');
         // Send to analytics: extra activity tracking
       }
     }
   }
   ```

**Files:**
- `ios/Classes/RouteService.swift` (add matching logic)
- `lib/src/models/workout_data.dart` (add scheduled fields)
- `lib/src/utils/workout_analytics.dart` (new)

### Phase 10: Testing Infrastructure

**Objective:** Comprehensive testing for read workflow

**Unit Tests (Dart):**
1. Mock method channel responses
2. Test date range validation
3. Test JSON deserialization
4. Test stream subscription/cancellation
5. Test background delivery config
6. Test deduplication logic

**Integration Tests (iOS):**
1. Test WorkoutService foreground/background switching
2. Test RouteService live streaming
3. Test WorkoutRecordStore deduplication
4. Test `WorkoutStreamDelivery` (stream vs pending queue)
5. Test app lifecycle transitions
6. Test matching with pushed workouts
7. Test on iOS 18+ device with actual workouts

**Files:**
- `test/managers/workout_read_manager_test.dart`
- `test/models/workout_data_test.dart`
- `ios/Tests/WorkoutServiceTests.swift`
- `ios/Tests/RouteServiceTests.swift`
- `ios/Tests/WorkoutRecordStoreTests.swift`

### Phase 11: Host app integration

**Objective:** Demonstrate workout reading in your Flutter host app.

The bundled [`example/`](../example/) project demonstrates workout reading; see [example/README.md](../example/README.md), [README.md](../README.md), and [docs/client_app_integration_guide.md](client_app_integration_guide.md).

### Phase 12: Documentation

**Objective:** Comprehensive usage documentation

**Tasks:**
1. Update main README with read workflow
2. Document all three reading methods
3. Explain foreground vs background behavior
4. Document background delivery configuration
5. Show deduplication examples
6. Document matching with pushed workouts
7. Add troubleshooting section

**Files:**
- `README.md` (update)
- `docs/API_REFERENCE.md` (update)
- `docs/WORKOUT_MONITORING.md` (new)

---

## Detailed Workflows

### Workflow 1: One-Shot Historical Fetch

**User Action:** Fetch workouts from last 30 days

```dart
// Dart
final manager = WorkoutReadManager();
final workouts = await manager.readWorkouts(
  DateTime.now().subtract(Duration(days: 30)),
  DateTime.now(),
);

print('Fetched ${workouts.length} workouts');
```

**iOS Flow:**
1. Method channel receives `readWorkouts` call
2. `WorkoutFetcher.shared.fetchWorkouts()` called
3. Uses `HKAnchoredObjectQueryDescriptor` with date range
4. For each workout:
   - Check `WorkoutRecordStore` for deduplication
   - Build `HuWorkout` with routes + quantity series
   - Convert to JSON string
5. Return array of JSON strings to Flutter
6. Dart deserializes to `List<WorkoutData>`

### Workflow 2: Continuous Monitoring (Foreground)

**User Action:** Monitor for new workouts while app is active

```dart
// Dart
final manager = WorkoutReadManager();

// Start monitoring
await manager.startMonitoring(
  DateTime.now().subtract(Duration(hours: 2)),
  DateTime.now().add(Duration(days: 7)),
);

// Listen to stream
manager.workoutStream.listen((workout) {
  print('New workout: ${workout.activityType}');
  // Update UI in real-time
});
```

**iOS Flow:**
1. Method channel receives `startMonitoring` call
2. Create `WorkoutService` with date range
3. Call `workoutService.start()`:
   - Request authorization
   - `fetchWorkouts()` (initial delta)
   - `startLiveUpdates()` (open-ended streaming)
4. When new workout detected:
   - Create/retrieve `RouteService`
   - `routeService.fetchWorkoutRoute()` (snapshot)
   - `routeService.startLiveUpdates()` (live streaming)
5. As routes arrive:
   - Build complete `HuWorkout`
   - Check `WorkoutRecordStore` (dedupe)
   - Push to event channel → Flutter stream
6. Flutter receives workout in real-time

### Workflow 3: Background Monitoring

**User Action:** App goes to background, workouts continue to be captured

```dart
// Arm stream / pending delivery (no plugin HTTP)
await manager.configureBackgroundDelivery(const BackgroundDeliveryConfig());
```

**iOS Flow:**
1. App lifecycle state changes to background
2. Flutter calls `enterBackgroundMode()`
3. `WorkoutService.enterBackgroundMode()`:
   - Stop live updates
   - Enable background delivery for workouts + routes
   - Start `HKObserverQuery`
4. User completes a workout (HealthKit records it)
5. System wakes app via background delivery
6. `HKObserverQuery` fires
7. `WorkoutService.fetchWorkouts(upToNow: true)` called
8. Workout processed:
   - Create `RouteService` (background mode)
   - Fetch routes (one-shot)
   - Build `HuWorkout`
9. `WorkoutStreamDelivery` delivers JSON to Flutter’s `workoutStream` if a listener exists; otherwise appends to `UserDefaults` (`BackgroundWorkouts.pending`) for your Runner/native or a future bridge to consume.

**On App Resume:**
```dart
await manager.enterForegroundMode();
// Prefer a `workoutStream` subscription for live delivery; use `readWorkouts` for catch-up if needed.
```

### Workflow 4: Matching with Pushed Workouts

**Scenario:** User pushes a scheduled workout, then completes it

**Push Phase:**
```dart
// User schedules a workout
final workout = WorkoutPlan(
  id: 'workout_abc123',
  scheduledDate: DateTime.now().add(Duration(days: 1)),
  workout: CustomWorkout(...),
);

await pushManager.pushWorkouts([workout]);
// iOS stores hash: UserDefaults["workout_abc123"] = "1234567890"
```

**Completion Phase:**
```dart
// User completes the workout
// iOS HealthKit assigns UUID: "workout_abc123"
```

**Matching Logic (iOS):**
```swift
func handleWorkoutCompletion(workout: HKWorkout) async {
    let workoutId = workout.uuid.uuidString
    
    // Check if this matches a pushed workout
    if let pushedHash = UserDefaults.standard.string(forKey: workoutId) {
        debugPrint("✅ MATCH: Workout was scheduled!")
        debugPrint("   WorkoutId: \(workoutId)")
        debugPrint("   Scheduled Hash: \(pushedHash)")
        
        // Add to metadata
        var metadata = workout.metadata ?? [:]
        metadata["wasScheduled"] = true
        metadata["scheduledHash"] = pushedHash
        
        // Build HuWorkout with this metadata
        let huWorkout = buildHuWorkout(workout, metadata: metadata)
        
        // Push to Flutter (if foreground) or deliver via background mode
        await deliverWorkout(huWorkout)
        
        // Remove from UserDefaults (workout completed)
        UserDefaults.standard.removeObject(forKey: workoutId)
    } else {
        debugPrint("📝 Spontaneous workout (not scheduled)")
    }
}
```

**Flutter Side:**
```dart
manager.workoutStream.listen((workout) {
  if (workout.wasScheduled) {
    print('✅ User completed scheduled workout!');
    print('   Adherence: 100%');
    // Update training plan progress
  } else {
    print('📝 Extra workout (bonus activity)');
    // Track as additional training volume
  }
});
```

---

## Deduplication Logic (Detailed)

### SHA256 Hash + Size Comparison

**Your existing `WorkoutRecordStore` implementation is excellent:**

```swift
// From WorkoutRecordStore.swift
func shouldPush(deviceActivityId: String, payload: Data) async -> Bool {
    let hash = sha256Hex(payload)
    let size = payload.count
    
    if let rec = recordsById[deviceActivityId] {
        if rec.pushed == false { return true }  // Previous push failed
        if rec.dataSize != size { return true }  // Route data added
        return false  // Already pushed, no changes
    } else {
        return true  // New workout
    }
}
```

### Example Scenarios

**Scenario 1: New Workout**
```
Workout UUID: workout_001
Record exists: NO
Result: PUSH ✓
```

**Scenario 2: Already Pushed (No Changes)**
```
Workout UUID: workout_001
Existing: hash="abc123", size=4096, pushed=true
New:      hash="abc123", size=4096
Result: SKIP (already pushed)
```

**Scenario 3: Route Data Added**
```
Workout UUID: workout_001
Existing: hash="abc123", size=4096, pushed=true
New:      hash="def456", size=8192 (route added)
Result: PUSH ✓ (size changed)
```

**Scenario 4: Failed Previous Push**
```
Workout UUID: workout_001
Existing: hash="abc123", size=4096, pushed=false
New:      hash="abc123", size=4096
Result: PUSH ✓ (retry failed push)
```

### 2-Hour Window for Route Tracking

**Your existing logic in `WorkoutService.handleWorkouts()`:**

```swift
let ageSinceEnd = now.timeIntervalSince(workout.endDate)
let twoHours = WorkoutService.liveWindowSeconds  // 2 * 60 * 60

if ageSinceEnd <= twoHours {
    // Recent workout - retain RouteService and monitor live
    let routeService = RouteService(store: store, workout: workout)
    routeServices[deviceId] = routeService
    await routeService.fetchWorkoutRoute()
    
    if appIsActive {
        routeService.startLiveUpdates()
    } else {
        routeService.startBackgroundMonitoring()
    }
} else {
    // Old workout - one-shot fetch, no live monitoring
    let routeService = RouteService(store: store, workout: workout)
    await routeService.fetchWorkoutRoute()
    // Don't retain - will be deallocated
}
```

**Rationale:**
- Workouts completed within 2 hours may still be receiving route updates
- Apple Watch syncs route data progressively (not always immediate)
- After 2 hours, route data is typically complete → one-shot fetch is sufficient
- Reduces memory usage and battery impact (don't retain unnecessary services)

---

## Background delivery configuration

Workout background delivery is **stream + pending JSON only**. Call:

```dart
await workoutManager.configureBackgroundDelivery(const BackgroundDeliveryConfig());
```

Native `WorkoutStreamDelivery` sends completed workout JSON on `workoutStream` when the Dart side is listening; otherwise it appends to `UserDefaults` under `BackgroundWorkouts.pending`. The plugin does **not** POST workouts to your API — upload from your app (Dart when foreground, or Runner native for suspended uploads).

Legacy `mode: api` is rejected on iOS (only `localStorage` is valid).

---

## Selective Import Preferences

### Configuration

```dart
// Configure which workout types to import
final options = WorkoutReadOptions(
  startDate: DateTime.now().subtract(Duration(days: 7)),
  endDate: DateTime.now(),
  includeRunning: true,
  includeCycling: true,
  includeSwimming: false,  // Exclude swimming
  includeOther: true,
);

final workouts = await manager.readWorkouts(
  options.startDate,
  options.endDate,
  options: options,
);
```

### iOS Implementation (Already in your code)

```swift
// From WorkoutService.swift
private var importRunning = false
private var importCycling = false
private var importSwimming = false
private var excludeImporting: [String] = []

func handleSpotImporting() {
    importRunning = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportRunning)
    importCycling = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportCycling)
    importSwimming = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportSwimming)
    
    if !importRunning { excludeImporting.append("Running") }
    if !importCycling { excludeImporting.append("Cycling") }
    if !importSwimming { excludeImporting.append("Swimming") }
}

// In fetch loop
for w in result.addedSamples {
    if !excludeImporting.contains(w.workoutActivityType.name) {
        handleWorkouts(workout: w)
    }
}
```

### Dart → iOS Bridge

```dart
Future<void> setImportPreferences({
  required bool running,
  required bool cycling,
  required bool swimming,
}) async {
  await _methodChannel.invokeMethod('setImportPreferences', {
    'running': running,
    'cycling': cycling,
    'swimming': swimming,
  });
}
```

```swift
func handleSetImportPreferences(_ call: FlutterMethodCall, _ result: FlutterResult) {
    guard let args = call.arguments as? [String: Bool] else {
        result(FlutterError(...))
        return
    }
    
    let running = args["running"] ?? true
    let cycling = args["cycling"] ?? true
    let swimming = args["swimming"] ?? true
    
    UserDefaults.standard.set(running, forKey: UserDefaultsKeys.isImportRunning)
    UserDefaults.standard.set(cycling, forKey: UserDefaultsKeys.isImportCycling)
    UserDefaults.standard.set(swimming, forKey: UserDefaultsKeys.isImportSwimming)
    UserDefaults.standard.synchronize()
    
    result(nil)
}
```

---

## Error Handling

### Dart-side errors

`WorkoutReadManager` surfaces failures as **`PlatformException`** from the method channel unless the call completes successfully. There are no exported Dart exception types (e.g. `MonitoringAlreadyActiveException`) in the package today — use `try/catch` on `PlatformException` and inspect `code` / `message`. JSON parsing errors arise in **your** code when decoding stream / `readWorkouts` strings.

### iOS-Side Errors

| Error | When | Handling |
|-------|------|----------|
| `authorizationFailed` | HealthKit permission denied | Return error to Flutter |
| `queryFailed` | HKQuery error | Log error, return empty array |
| `backgroundDeliveryFailed` | Background delivery setup failed | Fall back to foreground only |
| *(removed)* | Native workout HTTP upload | Use app-side POST from stream/pending JSON |

---

## Performance Considerations

### Memory Management

**RouteService Registry Pruning:**
- Your code already has `pruneOldRouteServices()` ✓
- Called on foreground mode entry
- Removes services for workouts older than 2 hours + grace
- Calls `invalidate()` to clean up observers

**WorkoutRecordStore Cleanup:**
- Your code has `cleanupOlderThan(days: 15)` ✓
- Call periodically (e.g., on app launch)
- Removes records older than 15 days

Native `WorkoutRecordStore` may expose cleanup (e.g. `cleanupOlderThan`) from Swift if you extend the channel; there is no Dart singleton named `WorkoutRecordStore.shared`.

### Battery Impact

**Foreground:**
- Live streaming uses active queries (moderate battery usage)
- Acceptable since app is in use

**Background:**
- `HKObserverQuery` uses minimal battery (system-optimized)
- Background delivery wakes app briefly (efficient)
- Route data sync may increase battery slightly (necessary for accuracy)

**Optimization:**
- 2-hour window limits retained services
- One-shot fetches for old workouts (no live monitoring)
- Background delivery only when needed

### Network Optimization

**Deduplication:**
- SHA256 hash prevents re-uploading unchanged workout data
- Size check catches route additions without full comparison
- Saves bandwidth and API costs

**Batching (host app):**
- When uploading to your backend, batch multiple workout JSON payloads in one request if your API supports it. The plugin does not perform that HTTP.

---

## Security & Privacy

### Info.plist Requirements

```xml
<key>NSHealthShareUsageDescription</key>
<string>We need to read your workout data to track your training progress and provide personalized insights.</string>

<key>NSMotionUsageDescription</key>
<string>We use motion data to enhance workout tracking accuracy.</string>
```

### Data Protection

**Workout Data Sensitivity:**
- Contains GPS coordinates (location privacy)
- Contains health metrics (medical privacy)
- Must handle per HealthKit and GDPR guidelines

**API transmission (your app):**
- Workout JSON leaves the device when **your** Flutter or native code POSTs it. The read plugin does not call your API.
- Use HTTPS, auth headers, and retention policies appropriate to health data.

**Local Storage:**
- UserDefaults is NOT encrypted by default
- Consider using Keychain for sensitive config
- WorkoutRecordStore stores only hashes (not full workout data)

### User control

- Users can stop monitoring / logout (`UserSessionManager`) to tear down observers
- Users can exclude workout types via `setImportPreferences`
- Your app chooses where workout JSON is uploaded (no plugin-configured workout URL)

---

## Testing Strategy

### Unit Tests (Dart)

```dart
group('WorkoutReadManager', () {
  test('readWorkouts returns JSON strings in date range', () async {
    final manager = WorkoutReadManager();
    final workouts = await manager.readWorkouts(
      DateTime(2026, 1, 1),
      endDate: DateTime(2026, 2, 1),
    );
    expect(workouts, isA<List<String>>());
  });

  test('startMonitoring accepts start date only', () async {
    final manager = WorkoutReadManager();
    await manager.startMonitoring(DateTime(2026, 1, 1));
    await manager.stopMonitoring();
  });
});
```

### Integration Tests (iOS)

```swift
func testWorkoutServiceForegroundMode() async throws {
    let service = WorkoutService(
        startDate: Date().addingTimeInterval(-3600),
        endDate: Date()
    )
    
    await service.start()
    service.enterForegroundMode()
    
    // Verify live updates started
    XCTAssertNotNil(service.updateTask)
}

func testRouteServiceDeduplication() async throws {
    let workout = createTestWorkout()
    let routeService = RouteService(store: store, workout: workout)
    
    await routeService.fetchWorkoutRoute()
    let firstPush = await WorkoutRecordStore.shared.shouldPush(
        deviceActivityId: workout.uuid.uuidString,
        payload: testData
    )
    XCTAssertTrue(firstPush)
    
    await WorkoutRecordStore.shared.markPushed(
        deviceActivityId: workout.uuid.uuidString
    )
    
    let secondPush = await WorkoutRecordStore.shared.shouldPush(
        deviceActivityId: workout.uuid.uuidString,
        payload: testData
    )
    XCTAssertFalse(secondPush)
}
```

---

## Usage Examples

### Example 1: Read Last 7 Days of Workouts

```dart
final manager = WorkoutReadManager();

final workouts = await manager.readWorkouts(
  DateTime.now().subtract(Duration(days: 7)),
  DateTime.now(),
);

for (var workout in workouts) {
  print('${workout.activityType}: ${workout.distance}m in ${workout.duration}s');
}
```

### Example 2: Monitor Workouts in Real-Time

```dart
final manager = WorkoutReadManager();

// Start monitoring
await manager.startMonitoring(
  DateTime.now(),
  DateTime.now().add(Duration(days: 30)),
);

// Listen to stream
final subscription = manager.workoutStream.listen(
  (workout) {
    print('New workout completed!');
    print('Type: ${workout.activityType}');
    print('Duration: ${workout.duration} seconds');
    print('Distance: ${workout.distance} meters');
    
    // Update UI
    setState(() {
      _workouts.add(workout);
    });
  },
  onError: (error) {
    print('Error: $error');
  },
);

// Later: stop monitoring
await manager.stopMonitoring();
await subscription.cancel();
```

### Example 3: Arm background delivery (stream / pending)

```dart
await manager.configureBackgroundDelivery(const BackgroundDeliveryConfig());
```

### Example 4: Subscribe to completed workouts

```dart
import 'dart:async';

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final manager = WorkoutReadManager();
  StreamSubscription<String>? _workoutSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _workoutSub = manager.workoutStream.listen((json) {
      // POST json to your API or update local state
    });
  }

  @override
  void dispose() {
    _workoutSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      manager.enterBackgroundMode();
    } else if (state == AppLifecycleState.resumed) {
      manager.enterForegroundMode();
    }
  }
}
```

### Example 5: Match Scheduled Workouts

```dart
manager.workoutStream.listen((workout) {
  if (workout.wasScheduled) {
    print('✅ Scheduled workout completed!');
    print('   Workout ID: ${workout.workoutId}');
    print('   Scheduled Hash: ${workout.scheduledHash}');
    
    // Update training plan
    await trainingPlan.markWorkoutComplete(workout.workoutId);
    
    // Track adherence
    analytics.trackAdherence(userId, completed: true);
  } else {
    print('📝 Spontaneous workout logged');
    
    // Track as bonus activity
    analytics.trackBonusActivity(userId, workout);
  }
});
```

---

## Limitations & Gotchas

1. **iOS 18+ Required:** `HKAnchoredObjectQueryDescriptor` requires iOS 18+
2. **Background Delivery Limits:** System may throttle if too many wake-ups
3. **Route Sync Delay:** GPS routes may take minutes/hours to fully sync from Apple Watch
4. **2-Hour Window Assumption:** Assumes route data completes within 2 hours (may vary)
5. **UserDefaults Size:** Large pending workout JSON in `BackgroundWorkouts.pending` can grow; drain or cap in your app / Runner code.
6. **Upload retries:** Your app owns HTTP — implement retry/backoff where needed.
7. **Suspended Dart:** When no stream listener is attached, workouts queue natively until your app or Runner consumes them.

---

## Future Enhancements

1. **Dart API for pending queue:** Optional method channel to read `BackgroundWorkouts.pending` without Runner code
2. **Batch uploads:** App-side batching when posting queued JSON
3. **Local SQLite Storage:** Replace UserDefaults for large workout volumes
4. **Incremental Route Updates:** Stream route data as it arrives (don't wait for completion)
5. **Workout Editing:** Support for updating/deleting workouts
6. **Workout Sharing:** Export workouts to GPX/TCX formats
7. **Analytics Dashboard:** Aggregate statistics across workouts

---

## References

### Apple Documentation
- [HKAnchoredObjectQueryDescriptor](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquerydescriptor)
- [HKObserverQuery](https://developer.apple.com/documentation/healthkit/hkobserverquery)
- [HKWorkout](https://developer.apple.com/documentation/healthkit/hkworkout)
- [HKWorkoutRoute](https://developer.apple.com/documentation/healthkit/hkworkoutroute)
- [Background Delivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/1614175-enablebackgrounddelivery)

### Flutter Documentation
- [Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
- [Event Channels](https://docs.flutter.dev/development/platform-integration/platform-channels#event-channels)
- [App Lifecycle](https://docs.flutter.dev/get-started/fundamentals/app-lifecycle)

---

## Next Steps

1. ✅ Review and approve this design
2. Begin Phase 1: Dart API design and models
3. Begin Phase 2: iOS WorkoutService integration with Flutter
4. Set up method and event channels
5. Test foreground/background mode switching
6. Implement background delivery configuration
7. Test deduplication and matching logic
8. ✅ Bundled reference app: [`example/`](../example/) — see [example/README.md](../example/README.md); extend as new flows land

**Your existing Swift code is excellent and production-ready!** The main work is integrating it with Flutter's platform channels and adding the background delivery configuration layer.
