# Read Workouts Subsystem - Requirements & Design

**Document Version:** 1.0  
**Date:** February 24, 2026  
**Plugin:** humango_workouts  
**Subsystem:** Workout Reading & Monitoring

---

## Requirements

### Functional Requirements

#### 1. Permission Verification

- **MUST** verify user has READ permission for workout data before monitoring
- **MUST** use cached permission status from Permission Manager
- **MUST** return clear error if permission not granted
- Guide user to request permission if not available

#### 2. Three Reading Methods with DateRange

Provide three distinct methods for reading completed workouts:

| Method | Description | Use Case |
|--------|-------------|----------|
| `readWorkouts(startDate, endDate)` | One-shot fetch of historical workouts | Initial sync, manual refresh |
| `startMonitoring(startDate, endDate)` | Continuous monitoring for new/updated workouts | Real-time tracking |
| `getLocalWorkouts()` | Retrieve workouts stored locally from background | App startup, offline access |

All methods accept **DateRange** with `startDate` and `endDate` parameters.

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

#### 4. User Opt-In Delivery System

Users configure how background workouts are delivered:

```dart
enum BackgroundDeliveryMode {
  api,          // Push to API endpoint
  localStorage, // Store in UserDefaults
}
```

**API Option:**
- User provides: `apiURL`, `headers` (including auth token)
- Native iOS makes direct HTTP POST to API
- Retries on failure with exponential backoff
- Marks as pushed in `WorkoutRecordStore`

**Local Storage Option:**
- Store workout JSON in UserDefaults
- Retrieve on app open via `getLocalWorkouts()`
- Return to Flutter and clear from storage
- Useful for offline scenarios or custom processing

#### 5. Deduplication Logic

**Prevent duplicate pushes:**
- Hash workout payload (SHA256) + track size in bytes
- Store in `WorkoutRecordStore` (actor-based, UserDefaults-backed)
- Compare before pushing: skip if hash + size unchanged
- Works across app restarts (persisted)

**Match with pushed workouts:**
- When workout completes, check if it was previously pushed via PUSH subsystem
- Match using `workoutId` (UUID) and `hashValue`
- If match found: skip API push (already scheduled)
- If no match or hash changed: push as completed workout

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
│  ├─ readWorkouts(startDate, endDate)                     │
│  ├─ startMonitoring(startDate, endDate)                  │
│  ├─ stopMonitoring()                                     │
│  ├─ getLocalWorkouts()                                   │
│  ├─ configureBackgroundDelivery(mode, apiURL, headers)   │
│  └─ Stream<WorkoutData> workoutStream                    │
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
│  │   └─ API push with deduplication                      │
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

## Data Models

### 1. WorkoutData (Dart)

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
  final BackgroundDeliveryMode mode;
  final String? apiURL;             // Required if mode includes API
  final Map<String, String>? headers; // Auth token, custom headers
  
  BackgroundDeliveryConfig({
    required this.mode,
    this.apiURL,
    this.headers,
  });
  
  Map<String, dynamic> toJson();
  factory BackgroundDeliveryConfig.fromJson(Map<String, dynamic> json);
}

enum BackgroundDeliveryMode {
  api,
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
    var pushed: Bool                  // API push status
    var firstSeenISO: String?         // ISO8601 timestamp
    var lastUpdatedISO: String        // ISO8601 timestamp
}
```

---

## Implementation Strategy

### Phase 1: Dart API Design

**Objective:** Create Flutter-side workout reading API

**Tasks:**
1. Create `WorkoutReadManager` class with three main methods:
   ```dart
   class WorkoutReadManager {
     // One-shot historical fetch
     Future<List<WorkoutData>> readWorkouts(
       DateTime startDate,
       DateTime endDate,
       {WorkoutReadOptions? options}
     );
     
     // Start continuous monitoring
     Future<void> startMonitoring(
       DateTime startDate,
       DateTime endDate,
       {WorkoutReadOptions? options}
     );
     
     // Stop monitoring
     Future<void> stopMonitoring();
     
     // Get locally stored workouts (from background)
     Future<List<WorkoutData>> getLocalWorkouts();
     
     // Configure background delivery
     Future<void> configureBackgroundDelivery(
       BackgroundDeliveryConfig config
     );
     
     // Stream for real-time workout updates
     Stream<WorkoutData> get workoutStream;
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

2. **Enhancements needed:**
   - Add Flutter event channel sink for pushing workouts
   - Add method to retrieve locally stored workouts
   - Add configuration for background delivery mode (API/local)
   - Add foreground/background mode callbacks from Flutter

3. **Integrate with FlutterMethodChannel:**
   ```swift
   class WorkoutServiceChannel: NSObject, FlutterStreamHandler {
       private var workoutService: WorkoutService?
       private var eventSink: FlutterEventSink?
       
       func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
           switch call.method {
           case "readWorkouts":
               handleReadWorkouts(call, result)
           case "startMonitoring":
               handleStartMonitoring(call, result)
           case "stopMonitoring":
               handleStopMonitoring(result)
           case "getLocalWorkouts":
               handleGetLocalWorkouts(result)
           case "configureBackgroundDelivery":
               handleConfigureBackground(call, result)
           case "enterForeground":
               workoutService?.enterForegroundMode()
               result(nil)
           case "enterBackground":
               workoutService?.enterBackgroundMode()
               result(nil)
           default:
               result(FlutterMethodNotImplemented)
           }
       }
   }
   ```

4. Modify `WorkoutService.handleWorkouts()` to:
   - Send workout JSON to event channel if foreground
   - Use background delivery config if background
   - Call `pushToEventChannel()` or `handleBackgroundDelivery()`

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
   - ✅ API push with deduplication via `WorkoutRecordStore`

2. **Enhancements needed:**
   - Add event channel sink reference (passed from WorkoutService)
   - Push completed workouts to event channel in foreground
   - Respect background delivery config
   - Match with pushed workout hash values

3. Modify `RouteService.pushWorkout()` to:
   ```swift
   func pushWorkout(finalWorkout: HuWorkout) async {
       let deviceId = finalWorkout.deviceActivityId
       
       // Check if this matches a pushed workout from PUSH subsystem
       if let pushedHash = UserDefaults.standard.string(forKey: deviceId) {
           // This was a scheduled workout - verify completion
           debugPrint("Workout \(deviceId) matches pushed workout hash: \(pushedHash)")
       }
       
       // Standard deduplication
       guard let dict = finalWorkout.toDict() else { return }
       let data = try JSONSerialization.data(withJSONObject: [dict])
       let shouldPush = await WorkoutRecordStore.shared.shouldPush(
           deviceActivityId: deviceId,
           payload: data
       )
       
       if !shouldPush {
           debugPrint("Skipping - already pushed")
           return
       }
       
       await WorkoutRecordStore.shared.upsertRecordPending(
           deviceActivityId: deviceId,
           payload: data
       )
       
       // Route to appropriate delivery method
       if appIsActive, let eventLink = eventSink {
           // Foreground: push to event channel
           pushToEventChannel(workout: finalWorkout, eventSink: eventLink)
       } else {
           // Background: use configured delivery mode
           await handleBackgroundDelivery(workout: finalWorkout)
       }
   }
   ```

**Files:**
- `ios/Classes/RouteService.swift` (modify)

### Phase 4: Background Delivery System

**Objective:** Implement user-configurable background delivery

**Tasks:**
1. Create `BackgroundDeliveryManager.swift`:
   ```swift
   actor BackgroundDeliveryManager {
       static let shared = BackgroundDeliveryManager()
       
       private var mode: BackgroundDeliveryMode = .localStorage
       private var apiURL: URL?
       private var headers: [String: String] = [:]
       
       func configure(mode: BackgroundDeliveryMode, 
                      apiURL: URL?, 
                      headers: [String: String]) {
           self.mode = mode
           self.apiURL = apiURL
           self.headers = headers
           saveConfig()
       }
       
       func deliverWorkout(_ workout: HuWorkout) async {
           switch mode {
           case .api:
               await pushToAPI(workout)
           case .localStorage:
               await storeLocally(workout)
           }
       }
       
       private func pushToAPI(_ workout: HuWorkout) async {
           guard let url = apiURL else { return }
           guard let data = workout.toJson() else { return }
           
           var request = URLRequest(url: url)
           request.httpMethod = "POST"
           request.httpBody = data
           
           for (key, value) in headers {
               request.setValue(value, forHTTPHeaderField: key)
           }
           
           do {
               let (_, response) = try await URLSession.shared.data(for: request)
               if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                   await WorkoutRecordStore.shared.markPushed(
                       deviceActivityId: workout.deviceActivityId
                   )
               }
           } catch {
               debugPrint("API push failed: \(error)")
           }
       }
       
       private func storeLocally(_ workout: HuWorkout) async {
           guard let json = workout.toJson(),
                 let jsonString = String(data: json, encoding: .utf8) else {
               return
           }
           
           // Append to array in UserDefaults
           let key = "BackgroundWorkouts.pending"
           var existing = UserDefaults.standard.stringArray(forKey: key) ?? []
           existing.append(jsonString)
           UserDefaults.standard.set(existing, forKey: key)
           UserDefaults.standard.synchronize()
       }
       
       func retrieveLocalWorkouts() async -> [String] {
           let key = "BackgroundWorkouts.pending"
           let workouts = UserDefaults.standard.stringArray(forKey: key) ?? []
           // Clear after retrieval
           UserDefaults.standard.removeObject(forKey: key)
           UserDefaults.standard.synchronize()
           return workouts
       }
   }
   
   enum BackgroundDeliveryMode: String, Codable {
       case api, localStorage
   }
   ```

2. Integrate with RouteService:
   ```swift
   func handleBackgroundDelivery(workout: HuWorkout) async {
       await BackgroundDeliveryManager.shared.deliverWorkout(workout)
   }
   ```

3. Add configuration method in WorkoutServiceChannel:
   ```swift
   func handleConfigureBackground(_ call: FlutterMethodCall, 
                                   _ result: FlutterResult) {
       guard let args = call.arguments as? [String: Any],
             let modeStr = args["mode"] as? String,
             let mode = BackgroundDeliveryMode(rawValue: modeStr) else {
           result(FlutterError(code: "INVALID_ARGS", ...))
           return
       }
       
       let apiURL = (args["apiURL"] as? String).flatMap(URL.init)
       let headers = args["headers"] as? [String: String] ?? [:]
       
       Task {
           await BackgroundDeliveryManager.shared.configure(
               mode: mode,
               apiURL: apiURL,
               headers: headers
           )
           result(nil)
       }
   }
   ```

**Files:**
- `ios/Classes/BackgroundDeliveryManager.swift` (new)

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
1. Register channels in `HumangoWorkoutsPlugin.swift`:
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
- `ios/Classes/HumangoWorkoutsPlugin.swift` (modify)
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
         // App returning to foreground
         workoutManager.enterForegroundMode();
         // Retrieve any workouts captured in background
         _fetchLocalWorkouts();
       }
     }
     
     Future<void> _fetchLocalWorkouts() async {
       final localWorkouts = await workoutManager.getLocalWorkouts();
       if (localWorkouts.isNotEmpty) {
         print('Retrieved ${localWorkouts.length} workouts from background');
         // Process workouts...
       }
     }
   }
   ```

2. Add lifecycle methods to WorkoutReadManager:
   ```dart
   Future<void> enterForegroundMode() async {
     await _methodChannel.invokeMethod('enterForeground');
   }
   
   Future<void> enterBackgroundMode() async {
     await _methodChannel.invokeMethod('enterBackground');
   }
   ```

**Files:**
- `lib/src/managers/workout_read_manager.dart` (add lifecycle methods)
- `example/lib/main.dart` (demonstrate lifecycle handling)

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
4. Test background delivery (API + localStorage)
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
// Configure background delivery BEFORE backgrounding
await manager.configureBackgroundDelivery(
  BackgroundDeliveryConfig(
    mode: BackgroundDeliveryMode.api,
    apiURL: 'https://api.example.com/workouts',
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
  ),
);
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
9. `BackgroundDeliveryManager.deliverWorkout()`:
   - If API mode: POST to configured URL
   - If localStorage mode: Store in UserDefaults
10. App returns to background

**On App Resume:**
```dart
// App returns to foreground
await manager.enterForegroundMode();

// Retrieve locally stored workouts
final localWorkouts = await manager.getLocalWorkouts();
print('Retrieved ${localWorkouts.length} workouts from background');

// Process and display workouts...
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

## Background Delivery Configuration

### User-Facing Configuration

```dart
// Example: Configure API delivery
await workoutManager.configureBackgroundDelivery(
  BackgroundDeliveryConfig(
    mode: BackgroundDeliveryMode.api,
    apiURL: 'https://api.example.com/workouts',
    headers: {
      'Authorization': 'Bearer eyJhbGc...',
      'X-User-ID': 'user_123',
      'Content-Type': 'application/json',
    },
  ),
);

// Example: Configure local storage
await workoutManager.configureBackgroundDelivery(
  BackgroundDeliveryConfig(
    mode: BackgroundDeliveryMode.localStorage,
  ),
);


```

### iOS Background Delivery Implementation

**API Delivery:**
```swift
private func pushToAPI(_ workout: HuWorkout) async {
    guard let url = apiURL else { return }
    guard let data = workout.toJson() else { return }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.timeoutInterval = 30
    
    // Add configured headers
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    
    do {
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse {
            debugPrint("API push status: \(http.statusCode)")
            
            if http.statusCode == 200 || http.statusCode == 201 {
                // Success - mark as pushed
                await WorkoutRecordStore.shared.markPushed(
                    deviceActivityId: workout.deviceActivityId
                )
            } else {
                // Server error - leave pushed=false for retry
                debugPrint("API error: \(http.statusCode)")
            }
        }
    } catch {
        debugPrint("Network error: \(error.localizedDescription)")
        // Leave pushed=false for retry on next fetch
    }
}
```

**Local Storage:**
```swift
private func storeLocally(_ workout: HuWorkout) async {
    guard let json = workout.toJson(),
          let jsonString = String(data: json, encoding: .utf8) else {
        return
    }
    
    let key = "BackgroundWorkouts.pending"
    var existing = UserDefaults.standard.stringArray(forKey: key) ?? []
    existing.append(jsonString)
    
    // Limit to 100 workouts to prevent storage bloat
    if existing.count > 100 {
        existing = Array(existing.suffix(100))
    }
    
    UserDefaults.standard.set(existing, forKey: key)
    UserDefaults.standard.synchronize()
    
    debugPrint("Stored workout locally: \(workout.deviceActivityId)")
}

func retrieveLocalWorkouts() async -> [String] {
    let key = "BackgroundWorkouts.pending"
    let workouts = UserDefaults.standard.stringArray(forKey: key) ?? []
    
    // Clear after retrieval
    UserDefaults.standard.removeObject(forKey: key)
    UserDefaults.standard.synchronize()
    
    debugPrint("Retrieved \(workouts.count) local workouts")
    return workouts
}
```

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
| `apiPushFailed` | Network/server error | Leave pushed=false, retry later |

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

**Batching (Future Enhancement):**
- Consider batching multiple workouts in single API call
- Reduces HTTP overhead
- Implement in `BackgroundDeliveryManager`

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

**API Transmission:**
- Always use HTTPS for API endpoints
- Include authentication token in headers
- Consider end-to-end encryption for sensitive data

**Local Storage:**
- UserDefaults is NOT encrypted by default
- Consider using Keychain for sensitive config
- WorkoutRecordStore stores only hashes (not full workout data)

### User Control

- Users can disable background delivery
- Users can exclude specific workout types
- Users control API endpoint (can use localhost for testing)
- Clear separation between scheduled and spontaneous workouts

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
      DateTime(2026, 2, 1),
    );
    expect(workouts, isNotEmpty);
  });
  
  test('startMonitoring throws if already monitoring', () async {
    final manager = WorkoutReadManager();
    await manager.startMonitoring(DateTime.now(), DateTime.now());
    
    expect(
      () => manager.startMonitoring(DateTime.now(), DateTime.now()),
      throwsA(isA<MonitoringAlreadyActiveException>()),
    );
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

### Example 3: Configure Background API Push

```dart
// Configure API delivery
await manager.configureBackgroundDelivery(
  BackgroundDeliveryConfig(
    mode: BackgroundDeliveryMode.api,
    apiURL: 'https://api.myapp.com/workouts',
    headers: {
      'Authorization': 'Bearer ${userToken}',
      'Content-Type': 'application/json',
    },
  ),
);

print('Background delivery configured - workouts will push to API');
```

### Example 4: Retrieve Background Workouts on App Launch

```dart
class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final manager = WorkoutReadManager();
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkForBackgroundWorkouts();
  }
  
  Future<void> _checkForBackgroundWorkouts() async {
    final localWorkouts = await manager.getLocalWorkouts();
    
    if (localWorkouts.isNotEmpty) {
      print('Found ${localWorkouts.length} workouts from background');
      
      // Process and display
      for (var workout in localWorkouts) {
        _processWorkout(workout);
      }
      
      // Show notification
      _showNotification('${localWorkouts.length} workouts synced');
    }
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      manager.enterBackgroundMode();
    } else if (state == AppLifecycleState.resumed) {
      manager.enterForegroundMode();
      _checkForBackgroundWorkouts();
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
5. **UserDefaults Size:** Storing large workout JSON may hit UserDefaults limits (use local storage mode sparingly)
6. **API Retry Logic:** Current implementation doesn't retry failed API pushes (left to app logic)
7. **Network Dependency:** Background API push requires network connectivity

---

## Future Enhancements

1. **Exponential Backoff for API Retries:** Implement in `BackgroundDeliveryManager`
2. **Batch API Uploads:** Send multiple workouts in single request
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
