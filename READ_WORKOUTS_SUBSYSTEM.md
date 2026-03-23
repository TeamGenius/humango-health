# Read Workouts Subsystem - Requirements & Design

**Document Version:** 1.1  
**Date:** March 19, 2026  
**Plugin:** `humango_health`  
**Subsystem:** Workout Reading & Monitoring

**Implementation status:** Matches **`humango_health` 0.0.10+** — workout background delivery is `WorkoutStreamDelivery` (stream + `BackgroundWorkouts.pending` only). Sections labeled “Phase N” are historical rollout notes unless stated otherwise.

---

## Requirements

### Functional Requirements

#### 1. Permission Verification

- **MUST** verify user has READ permission for workout data before monitoring
- **MUST** use cached permission status from Permission Manager
- **MUST** return clear error if permission not granted
- Guide user to request permission if not available

#### 2. Reading Surfaces (one-shot, monitoring, stream, pending)

| Surface | Description | Use Case |
|---------|-------------|----------|
| `readWorkouts(startDate, { endDate })` | One-shot fetch; returns `List<String>` workout JSON | Initial sync, manual refresh |
| `startMonitoring(startDate, { options })` | Continuous monitoring (open-ended from `startDate`) | Real-time capture |
| `workoutStream` | `Stream<String>` of workout JSON when a listener is attached | Foreground / live upload path |
| `configureBackgroundDelivery` | Arms native delivery: stream if listening, else `UserDefaults` queue `BackgroundWorkouts.pending` | After login; idempotent |
| `markWorkoutsAsPushed(ids)` | Tells native which IDs you successfully uploaded | Dedup / exclude from future one-shot reads |
| `fetchAllWorkouts` / `getWorkoutStoreRecords` | Debug / audit helpers | See Dart `WorkoutReadManager` |

There is **no** `getLocalWorkouts()` on the MethodChannel — pending JSON lives natively until you add a bridge or read it from Runner code. Prefer keeping a `workoutStream` subscription while the app runs.

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

#### 4. Background delivery (stream + pending only)

`BackgroundDeliveryConfig` has a single mode, `localStorage`, meaning “deliver to Flutter stream or local pending queue” — **not** HTTP.

```dart
enum BackgroundDeliveryMode { localStorage }

class BackgroundDeliveryConfig {
  final BackgroundDeliveryMode mode;
  const BackgroundDeliveryConfig({this.mode = BackgroundDeliveryMode.localStorage});
}
```

**Native `WorkoutStreamDelivery`** (`ios/Classes/WorkoutReading/WorkoutStreamDelivery.swift`):

- **`arm()`** — sets `HumangoWorkoutStreamDeliveryArmed`, clears legacy `HumangoDelivery*` keys from removed API mode.
- **`deliverWorkout(_ jsonString, deviceId:)`** — if `FlutterEventSink` is set → send on `workoutStream`; else append JSON string to `BackgroundWorkouts.pending`.
- **`configureBackgroundDelivery` with legacy `mode: api`** → rejected on iOS (only `localStorage` is valid).

**Host app:** POST workout JSON to your backend from Dart (when running) or from Runner / `URLSession` when you drain pending natively. Retry/backoff is **app-owned**.

#### 5. Deduplication Logic

**Prevent duplicate pushes:**
- Hash workout payload (SHA256) + track size in bytes
- Store in `WorkoutRecordStore` (actor-based, UserDefaults-backed)
- Compare before pushing: skip if hash + size unchanged
- Works across app restarts (persisted)

**Match with pushed workouts:**
- When workout completes, check if it was previously pushed via PUSH subsystem
- Match using `workoutId` (UUID) and `hashValue`
- If match found: treat as scheduled completion (metadata); dedup still uses `WorkoutRecordStore`
- If no match or hash changed: emit completed workout JSON like any other completion

#### 6. Workout Data Contents

Each workout includes:
- **Core metadata:** distance, duration, activity type, start/end times
- **Statistics:** all HKStatistics (avg/max/min heart rate, calories, etc.)
- **Quantity series:** heart rate, steps, distance, power, cadence (20+ types)
- **Route data:** GPS coordinates as `[CLLocation]` array
- **Events:** workout segments, laps, pauses
- **Metadata:** device source, iOS version, custom fields

#### 7. Selective Import Preferences

Users opt-in/out of specific workout types:
- `importRunning` → Running workouts
- `importCycling` → Cycling workouts  
- `importSwimming` → Swimming workouts

Stored in UserDefaults, respected during fetch/monitoring.

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
│  ├─ readWorkouts(startDate, { endDate }) → List<String>   │
│  ├─ startMonitoring(startDate, { options })              │
│  ├─ stopMonitoring()                                     │
│  ├─ configureBackgroundDelivery(BackgroundDeliveryConfig) │
│  ├─ markWorkoutsAsPushed / fetchAllWorkouts / store debug │
│  └─ Stream<String> workoutStream (JSON)                    │
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
│  │   ├─ Background: route observer + delivery            │
│  │   ├─ Quantity series fetching (20+ types)             │
│  │   └─ Final JSON → WorkoutStreamDelivery (stream/pending) │
│  │                                                        │
│  ┌─ WorkoutRecordStore (actor-based storage)             │
│  │   ├─ SHA256 hashing for change detection              │
│  │   ├─ UserDefaults persistence                         │
│  │   ├─ Deduplication logic                              │
│  │   └─ Push status tracking                             │
│  │                                                        │
│  ├─ WorkoutStreamDelivery (stream vs UserDefaults pending) │
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

## Data Models

### 1. Workout payload (Dart)

The plugin’s MethodChannel / `workoutStream` surface uses **JSON strings** (`List<String>`, `Stream<String>`). The shape below is a **reference model** you can mirror or generate with `json_serializable` — it is not required by the package API.

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

### 2. BackgroundDeliveryConfig (Dart) — `lib/src/models/background_delivery_config.dart`

```dart
enum BackgroundDeliveryMode {
  localStorage,
}

class BackgroundDeliveryConfig {
  final BackgroundDeliveryMode mode;

  const BackgroundDeliveryConfig({
    this.mode = BackgroundDeliveryMode.localStorage,
  });

  Map<String, dynamic> toJson() => {'mode': mode.name};
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
    var pushed: Bool                  // true after host calls markWorkoutsAsPushed (upload acknowledged)
    var firstSeenISO: String?         // ISO8601 timestamp
    var lastUpdatedISO: String        // ISO8601 timestamp
}
```

---

## Implementation Strategy

### Phase 1: Dart API Design

**Objective:** Create Flutter-side workout reading API

**Tasks:**
1. `WorkoutReadManager` (`lib/src/managers/workout_read_manager.dart`) — core surface:
   ```dart
   class WorkoutReadManager {
     Future<List<String>> readWorkouts(DateTime startDate, {DateTime? endDate, WorkoutReadOptions? options});
     Future<void> startMonitoring(DateTime startDate, {WorkoutReadOptions? options});
     Future<void> stopMonitoring();
     Future<void> configureBackgroundDelivery(BackgroundDeliveryConfig config);
     Stream<String> get workoutStream; // JSON strings
     Future<void> enterForegroundMode();
     Future<void> enterBackgroundMode();
     Future<int> markWorkoutsAsPushed(List<String> deviceActivityIds);
     Future<List<String>> fetchAllWorkouts(DateTime startDate, {DateTime? endDate});
     Future<List<WorkoutStoreRecord>> getWorkoutStoreRecords();
     // … setImportPreferences, etc.
   }
   ```

2. Create all Dart model classes listed above
3. Add JSON serialization/deserialization
4. Set up `MethodChannel` for commands
5. Set up `EventChannel` for workout stream

**Files:**
- `lib/src/managers/workout_read_manager.dart`
- `lib/src/models/workout_data.dart`
- `lib/src/models/background_delivery_config.dart`
- `lib/src/models/workout_read_options.dart`
- `lib/src/models/quantity_series.dart`
- `lib/src/models/route_location.dart`

### Phase 2: iOS WorkoutService Integration

**Objective:** Adapt existing WorkoutService for Flutter integration

**Tasks:**
1. **Existing code** (`WorkoutService.swift`) already handles:
   - ✅ Date range initialization
   - ✅ Authorization
   - ✅ Foreground: `HKAnchoredObjectQueryDescriptor` with live streaming
   - ✅ Background: `HKObserverQuery` + background delivery
   - ✅ RouteService registry for recent workouts (2-hour window)
   - ✅ Mode switching (enterBackgroundMode/enterForegroundMode)
   - ✅ Selective import (running/cycling/swimming)

2. **Implemented:** `WorkoutServiceChannel` wires MethodChannel + EventChannel, attaches `FlutterEventSink` to `WorkoutStreamDelivery`, handles `configureBackgroundDelivery` (arm + reject `api`), `markWorkoutsAsPushed`, `fetchAllWorkouts`, `getWorkoutStoreRecords`, etc.

3. **Method channel sketch (representative):**
   ```swift
   class WorkoutServiceChannel: NSObject, FlutterStreamHandler {
       func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
           switch call.method {
           case "readWorkouts": handleReadWorkouts(call, result)
           case "startWorkoutMonitoring": …
           case "stopWorkoutMonitoring": …
           case "configureBackgroundDelivery": … // arms WorkoutStreamDelivery; unknown mode → error
           case "markWorkoutsAsPushed": …
           case "enterForeground", "enterBackground": …
           default: result(FlutterMethodNotImplemented)
           }
       }
   }
   ```

4. Completed workouts flow through dedupe / `WorkoutRecordStore`, then **`WorkoutStreamDelivery.shared.deliverWorkout(jsonString, deviceId:)`** (not HTTP).

**Files:**
- `ios/Classes/WorkoutServiceChannel.swift` (new)
- `ios/Classes/WorkoutService.swift` (modify)

### Phase 3: iOS RouteService Integration

**Objective:** Adapt existing RouteService for Flutter event streaming

**Tasks:**
1. **Existing code** (`RouteService.swift`) already handles:
   - ✅ Route fetching with `HKAnchoredObjectQueryDescriptor`
   - ✅ Live streaming in foreground
   - ✅ Background monitoring with `HKObserverQuery`
   - ✅ Quantity series fetching (20+ types)
   - ✅ Mode switching
   - ✅ Dedup via `WorkoutRecordStore` before calling `WorkoutStreamDelivery`

2. **Delivery:** Completed `HuWorkout` is serialized to JSON, deduped via `WorkoutRecordStore`, then handed to **`WorkoutStreamDelivery`** (stream if sink attached, else `BackgroundWorkouts.pending`). No native HTTP.

3. **`RouteService` completion path (conceptual):**
   ```swift
   func pushWorkout(finalWorkout: HuWorkout) async {
       let deviceId = finalWorkout.deviceActivityId
       // … match scheduled push hash in UserDefaults if present …
       guard let dict = finalWorkout.toDict(),
             let data = try? JSONSerialization.data(withJSONObject: [dict]) else { return }
       let shouldPush = await WorkoutRecordStore.shared.shouldPush(deviceActivityId: deviceId, payload: data)
       guard shouldPush else { return }
       await WorkoutRecordStore.shared.upsertRecordPending(deviceActivityId: deviceId, payload: data)
       guard let jsonString = String(data: data, encoding: .utf8) else { return }
       await WorkoutStreamDelivery.shared.deliverWorkout(jsonString, deviceId: deviceId)
   }
   ```

**Files:**
- `ios/Classes/RouteService.swift` (modify)

### Phase 4: Workout stream / pending delivery (implemented)

**Objective:** Deliver completed workout JSON to Flutter or queue it — **no** plugin HTTP.

**Implementation:** `ios/Classes/WorkoutReading/WorkoutStreamDelivery.swift`

- **`arm()`** — persists `HumangoWorkoutStreamDeliveryArmed`, clears legacy `HumangoDeliveryMode` / `HumangoDeliveryURL` / `HumangoDeliveryHeaders`.
- **`attachEventSink(_:)`** — called from `WorkoutServiceChannel` when Dart listens to `workoutStream`.
- **`deliverWorkout(_ jsonString, deviceId:)`** — main.async to sink if present; else `storePending` → `BackgroundWorkouts.pending`.
- **`clearConfiguration()`** — logout: disarm, clear legacy keys, nil sink.

**Configure from Flutter:** `configureBackgroundDelivery` with `{ "mode": "localStorage" }` arms delivery. Any other `mode` → `PlatformException` (e.g. `INVALID_ARGS`).

**Files:**
- `ios/Classes/WorkoutReading/WorkoutStreamDelivery.swift`
- `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift` (configure + stream handler)

### Phase 5: WorkoutRecordStore Enhancements

**Objective:** Your existing `WorkoutRecordStore.swift` is excellent! Minor enhancements only.

**Tasks:**
1. **Existing code** already provides:
   - ✅ Actor-based thread safety
   - ✅ SHA256 hashing
   - ✅ UserDefaults persistence
   - ✅ Deduplication via hash + size comparison
   - ✅ Push status tracking
   - ✅ Cleanup for old records

2. **Optional enhancements:**
   - Add method to match with pushed workout hashes:
     ```swift
     func matchesPushedWorkout(deviceActivityId: String) async -> String? {
         // Check if this workout was pushed via PUSH subsystem
         return UserDefaults.standard.string(forKey: deviceActivityId)
     }
     ```
   
   - Add batch operations for efficiency:
     ```swift
     func shouldPushBatch(workouts: [(id: String, payload: Data)]) async -> [Bool] {
         return workouts.map { shouldPush(deviceActivityId: $0.id, payload: $0.payload) }
     }
     ```

**Files:**
- `ios/Classes/WorkoutRecordStore.swift` (minor modifications)

### Phase 6: WorkoutFetcher Integration

**Objective:** Your existing `WorkoutFetcher.swift` handles one-shot fetches perfectly

**Tasks:**
1. **Existing code** already provides:
   - ✅ Date range bounded fetches
   - ✅ Selective import (running/cycling/swimming)
   - ✅ Deduplication via WorkoutRecordStore
   - ✅ Returns JSON strings

2. **Integrate with method channel:**
   ```swift
   func handleReadWorkouts(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
       guard let args = call.arguments as? [String: Any],
             let startISO = args["startDate"] as? String,
             let endISO = args["endDate"] as? String,
             let startDate = ISO8601DateFormatter().date(from: startISO),
             let endDate = ISO8601DateFormatter().date(from: endISO) else {
           result(FlutterError(code: "INVALID_ARGS", ...))
           return
       }
       
       Task {
           do {
               let workoutsJson = try await WorkoutFetcher.shared.fetchWorkouts(
                   startDate: startDate,
                   effectiveEnd: endDate
               )
               result(workoutsJson)
           } catch {
               result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
           }
       }
   }
   ```

**Files:**
- `ios/Classes/WorkoutServiceChannel.swift` (use existing WorkoutFetcher)

### Phase 7: Method Channel & Event Channel Setup

**Objective:** Wire up Flutter ↔ iOS communication

**Tasks:**
1. Register channels in `HumangoHealthPlugin.swift` (workout read delegate is `WorkoutServiceChannel`):
   ```swift
   public static func register(with registrar: FlutterPluginRegistrar) {
       // Method channel for commands
       let methodChannel = FlutterMethodChannel(
           name: "com.humango.workouts/read",
           binaryMessenger: registrar.messenger()
       )
       
       // Event channel for workout stream
       let eventChannel = FlutterEventChannel(
           name: "com.humango.workouts/read/stream",
           binaryMessenger: registrar.messenger()
       )
       
       let instance = WorkoutServiceChannel()
       registrar.addMethodCallDelegate(instance, channel: methodChannel)
       eventChannel.setStreamHandler(instance)
   }
   ```

2. Implement `FlutterStreamHandler` in WorkoutServiceChannel:
   ```swift
   func onListen(withArguments arguments: Any?, 
                 eventSink events: @escaping FlutterEventSink) -> FlutterError? {
       self.eventSink = events
       return nil
   }
   
   func onCancel(withArguments arguments: Any?) -> FlutterError? {
       self.eventSink = nil
       return nil
   }
   ```

3. Push workouts to event channel:
   ```swift
   func pushToEventChannel(workout: HuWorkout, eventSink: FlutterEventSink) {
       guard let jsonData = workout.toJson(),
             let jsonString = String(data: jsonData, encoding: .utf8) else {
           return
       }
       eventSink(jsonString)
   }
   ```

**Files:**
- `ios/Classes/HumangoHealthPlugin.swift`
- `ios/Classes/WorkoutServiceChannel.swift` (modify)

### Phase 8: App Lifecycle Integration

**Objective:** Handle foreground/background transitions

**Tasks:**
1. In Flutter app, listen to app lifecycle:
   ```dart
   class WorkoutMonitoringApp extends StatefulWidget {
     @override
     _WorkoutMonitoringAppState createState() => _WorkoutMonitoringAppState();
   }
   
   class _WorkoutMonitoringAppState extends State<WorkoutMonitoringApp> 
       with WidgetsBindingObserver {
     
     final workoutManager = WorkoutReadManager();
     
     @override
     void initState() {
       super.initState();
       WidgetsBinding.instance.addObserver(this);
     }
     
     @override
     void dispose() {
       WidgetsBinding.instance.removeObserver(this);
       super.dispose();
     }
     
     @override
     void didChangeAppLifecycleState(AppLifecycleState state) {
       if (state == AppLifecycleState.paused) {
         // App going to background
         workoutManager.enterBackgroundMode();
       } else if (state == AppLifecycleState.resumed) {
         workoutManager.enterForegroundMode();
       }
     }
   }
   ```

Keep a **single long-lived** `workoutStream` subscription (see `WorkoutReadManager`’s cached broadcast stream) so completed workouts are received when the Dart engine runs; pending `UserDefaults` JSON is used when there is no listener — drain via Runner native or a future MethodChannel if you add one.

2. Lifecycle helpers (already implemented on `WorkoutReadManager`):
   ```dart
   Future<void> enterForegroundMode() async {
     await _methodChannel.invokeMethod('enterForeground');
   }
   
   Future<void> enterBackgroundMode() async {
     await _methodChannel.invokeMethod('enterBackground');
   }
   ```

**Files:**
- `lib/src/managers/workout_read_manager.dart` (lifecycle + stream + configure)
- `example/lib/` (see coordinator / workout tabs for lifecycle handling)

### Phase 9: Matching with Pushed Workouts

**Objective:** Link completed workouts with scheduled workouts from PUSH subsystem

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
4. Test `WorkoutStreamDelivery` (stream attached vs pending queue)
5. Test app lifecycle transitions
6. Test matching with pushed workouts
7. Test on iOS 18+ device with actual workouts

**Files:**
- `test/managers/workout_read_manager_test.dart`
- `test/models/workout_data_test.dart`
- `ios/Tests/WorkoutServiceTests.swift`
- `ios/Tests/RouteServiceTests.swift`
- `ios/Tests/WorkoutRecordStoreTests.swift`

### Phase 11: Example Implementation

**Objective:** Demonstrate complete workout reading workflow

**Tasks:**
1. Create example screen showing:
   - Permission request
   - Date range selector
   - "Read Workouts" button (one-shot)
   - "Start Monitoring" button (continuous)
   - "Stop Monitoring" button
   - Real-time workout list (from stream)
   - Local workouts display (from background)
   - Background delivery configuration
   - Scheduled vs spontaneous workout indicator

2. Show foreground/background behavior:
   - Display workouts arriving in real-time
   - Simulate app backgrounding
   - Show local workouts on app resume

**Files:**
- `example/lib/read_workout_screen.dart`
- `example/lib/widgets/workout_list_item.dart`
- `example/lib/widgets/delivery_config_dialog.dart`

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
  DateTime.now().subtract(const Duration(days: 30)),
  endDate: DateTime.now(),
);

print('Fetched ${workouts.length} workout JSON string(s)');
```

**iOS Flow:**
1. Method channel receives `readWorkouts` call
2. `WorkoutFetcher.shared.fetchWorkouts()` (or equivalent path) runs for the range
3. Uses `HKAnchoredObjectQueryDescriptor` with date range
4. For each workout:
   - Check `WorkoutRecordStore` for deduplication
   - Build `HuWorkout` with routes + quantity series
   - Convert to JSON string
5. Return `List<String>` JSON to Flutter
6. Host app parses JSON as needed (`jsonDecode` / models)

### Workflow 2: Continuous Monitoring (Foreground)

**User Action:** Monitor for new workouts while app is active

```dart
// Dart
final manager = WorkoutReadManager();

// Start monitoring (open-ended from startDate)
await manager.startMonitoring(
  DateTime.now().subtract(const Duration(hours: 2)),
);

// Listen to stream (each event is a JSON string)
manager.workoutStream.listen((json) {
  print('New workout JSON: ${json.substring(0, json.length.clamp(0, 80))}…');
});
```

**iOS Flow:**
1. Method channel receives `startWorkoutMonitoring` (Dart `startMonitoring`)
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
  endDate: options.endDate,
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

### Dart-Side Errors

| Error | When | User Action |
|-------|------|-------------|
| `PermissionDeniedException` | No read permission | Request workout permission |
| `InvalidDateRangeException` | Start date after end date | Fix date range |
| `MonitoringAlreadyActiveException` | startMonitoring() called twice | Stop existing monitoring first |
| `PlatformException` | Native iOS error | Check logs, retry |
| `DeserializationException` | Invalid JSON from iOS | Report bug |

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

```dart
// In app initialization
await WorkoutRecordStore.shared.cleanupOlderThan(days: 15);
```

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

**Batching (app-side):**
- Batch multiple workout JSON payloads in one HTTPS request from your upload layer
- Reduces HTTP overhead when draining pending data

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

**Upload to your backend (app responsibility):**
- Use HTTPS, auth headers, and retention policies appropriate to health data
- Consider end-to-end encryption for sensitive payloads

**Local Storage:**
- UserDefaults is NOT encrypted by default
- Consider using Keychain for sensitive config
- WorkoutRecordStore stores only hashes (not full workout data)

### User Control

- Users can stop monitoring / log out (clears armed flag and legacy keys)
- Users can exclude specific workout types via import preferences
- Host app chooses upload targets and when to call `markWorkoutsAsPushed`
- Clear separation between scheduled and spontaneous workouts (metadata)

---

## Testing Strategy

### Unit Tests (Dart)

```dart
group('WorkoutReadManager', () {
  test('readWorkouts returns workouts in date range', () async {
    // Mock method channel
    final manager = WorkoutReadManager();
    final workouts = await manager.readWorkouts(
      DateTime(2026, 1, 1),
      endDate: DateTime(2026, 2, 1),
    );
    expect(workouts, isNotEmpty);
  });
  
  test('configureBackgroundDelivery forwards localStorage JSON', () async {
    final manager = WorkoutReadManager();
    await manager.configureBackgroundDelivery(const BackgroundDeliveryConfig());
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

import 'dart:convert';

final workouts = await manager.readWorkouts(
  DateTime.now().subtract(const Duration(days: 7)),
  endDate: DateTime.now(),
);

for (final json in workouts) {
  final map = jsonDecode(json) as Map<String, dynamic>;
  print('Workout keys: ${map.keys.take(5).join(", ")}…');
}
```

### Example 2: Monitor Workouts in Real-Time

```dart
final manager = WorkoutReadManager();

// Start monitoring
await manager.startMonitoring(DateTime.now());

// Listen to stream (JSON strings — decode in your app)
final subscription = manager.workoutStream.listen(
  (json) {
    print('New workout JSON received (${json.length} chars)');
    // final map = jsonDecode(json) as Map<String, dynamic>;
    // Update UI from parsed model
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

### Example 5: Match scheduled workouts (parse JSON)

```dart
import 'dart:convert';

manager.workoutStream.listen((json) async {
  final map = jsonDecode(json) as Map<String, dynamic>;
  final id = map['deviceActivityId'] as String?;
  final wasScheduled = map['wasScheduled'] == true;
  final scheduledHash = map['scheduledHash'] as String?;
  if (wasScheduled) {
    print('✅ Scheduled workout completed: $id (hash: $scheduledHash)');
    // await trainingPlan.markWorkoutComplete(id);
  } else {
    print('📝 Spontaneous workout: $id');
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
8. Create comprehensive example app

**Your existing Swift code is excellent and production-ready!** The main work is integrating it with Flutter's platform channels and adding the background delivery configuration layer.

---

## `markWorkoutsAsPushed` — Flutter → Native Acknowledgement

### Purpose

After `readWorkouts()` returns workout JSON to Flutter and the Flutter app successfully sends those workouts to its backend, the app **must** call `markWorkoutsAsPushed` to inform the native layer. This permanently marks each workout as pushed in `WorkoutRecordStore` so it is excluded from all future `readWorkouts` calls.

Without this call, the same workouts will be returned again on the next `readWorkouts` invocation (they remain in `⏳ pending` state).

### Dart API

```dart
/// Call after successfully uploading workouts to your backend.
/// [deviceActivityIds] — the `deviceActivityId` field from each workout JSON.
/// Returns the number of IDs marked.
Future<int> markWorkoutsAsPushed(List<String> deviceActivityIds)
```

### Usage

```dart
// 1. Fetch workouts
final jsonStrings = await workoutManager.readWorkouts(startDate, endDate: endDate);

// 2. Parse and upload to your backend
final uploaded = <String>[];
for (final json in jsonStrings) {
  final workout = jsonDecode(json);
  final success = await myBackend.upload(workout);
  if (success) {
    uploaded.add(workout['deviceActivityId'] as String);
  }
}

// 3. Acknowledge back to native so they are excluded next time
if (uploaded.isNotEmpty) {
  final count = await workoutManager.markWorkoutsAsPushed(uploaded);
  debugPrint('Marked $count workout(s) as pushed');
}
```

### What Happens Internally

| Step | Description |
|------|-------------|
| Flutter calls `markWorkoutsAsPushed([id1, id2, ...])` | Sends array to native via MethodChannel |
| Native iterates each ID | Calls `WorkoutRecordStore.shared.markPushed(deviceActivityId:)` |
| Store sets `pushed = true` | Persisted to UserDefaults immediately |
| Next `readWorkouts` call | `shouldPush()` returns `false` → workout skipped |
| Returns `{ markedCount: N, deviceActivityIds: [...] }` | Flutter receives count of marked IDs |

### Debug Logging

After every `markWorkoutsAsPushed` call (and after every background push from `RouteService`), the full `WorkoutRecordStore` is printed to the console for easy testing:

```
📋 WorkoutRecordStore [after markWorkoutsAsPushed]: ── ALL RECORDS (3 total) ──
   ✅ pushed  | id: A1B2C3D4-... | size: 48302B | updated: 2026-03-15T10:22:01Z
   ✅ pushed  | id: E5F6G7H8-... | size: 31200B | updated: 2026-03-14T08:10:45Z
   ⏳ pending | id: X9Y0Z1W2-... | size: 52100B | updated: 2026-03-15T10:21:58Z
📋 WorkoutRecordStore [after markWorkoutsAsPushed]: ────────────────────────────
```

The same snapshot is also printed after `RouteService` hands JSON to `WorkoutStreamDelivery` (stream or pending queue):

```
📋 WorkoutRecordStore [after RouteService delivery]: ── ALL RECORDS (2 total) ──
   ⏳ pending | id: A1B2C3D4-... | size: 48302B | updated: 2026-03-15T09:05:12Z
   ⏳ pending | id: E5F6G7H8-... | size: 31200B | updated: 2026-03-15T09:04:55Z
📋 WorkoutRecordStore [after RouteService delivery]: ───────────────────────────
```

> **Note:** Records stay `⏳ pending` until the **host app** successfully uploads and calls `markWorkoutsAsPushed`. Native code does not POST to your API, so it never sets `✅ pushed` on its own.
