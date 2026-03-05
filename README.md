# Humango Health Plugin

A Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform. 

Currently, this plugin specifically supports the **Permission Handling Subsystem**.

## Requirements
- **iOS 18.0** minimum deployment target
- This plugin requires physical devices for testing HealthKit permission popups and reading/writing Health data.

### iOS Setup (Info.plist)
Any application using this plugin must declare the following keys in their `ios/Runner/Info.plist` file. Apple requires clear explanations for why your app needs to read and write Health data. Without these, your app will crash upon requesting permissions.

```xml
<key>NSHealthShareUsageDescription</key>
<string>We need access to read your health data to track your training metrics.</string>
<key>NSHealthUpdateUsageDescription</key>
<string>We need access to write your health data to save workouts and activities.</string>
```

---

## Permission Handling

iOS HealthKit requires specific capability definitions and uses a nuanced permissions model.
Permissions on iOS are split strictly between **Read** and **Write** (`Share`). 

### Apple's Strict Privacy Rules (Must Read)
When building systems dependent on HealthKit, you must understand two core iOS behaviors:

1. **The "One-Time Prompt" Rule**: iOS will only *ever* show the HealthKit permission popup **once** per device for a specific set of data types. If the user taps "Don't Allow," you **cannot** trigger the sheet again via code. Calling `request()` again simply returns success silently without showing the prompt.
2. **The "Blind Read" Rule**: Apple protects user privacy by making it impossible to check if a user explicitly denied `Read` access. A denied read permission simply appears as `notDetermined` or behaves as if there is no data. You can only deterministically check the status of `Write` (share) access.

**Handling Denials:** Because you cannot show the prompt twice, if you determine (via the write status) that a user is missing permissions, your app must show a custom Flutter UI explaining why access is needed, and provide a button to deep-link the user into the `iOS Settings -> Health -> Data Access & Devices` to toggle the switches manually.

### Supported Data Types
The `HealthDataType` enum maps Dart instances to correct `HKQuantityTypeIdentifier` strings natively.
Supported values currently include:
- `HealthDataType.workout`
- `HealthDataType.heartRate`
- `HealthDataType.hrv`
- `HealthDataType.restingHeartRate`
- `HealthDataType.steps`
- `HealthDataType.activeCalories`
- `HealthDataType.sleepAnalysis`
... and more.

### 1. Verification
You can manually check the current iOS authorization status.

```dart
import 'package:humango_health/humango_health.dart';

final permissionManager = PermissionManager();

void checkPermissions() async {
  final response = await permissionManager.verify(
    [HealthDataType.heartRate, HealthDataType.steps], // Read types 
    [HealthDataType.workout] // Write types
  );

  final writeStatus = response.writeStatuses[HealthDataType.workout];
  if (writeStatus == PermissionStatus.authorized) {
    print("Allowed to write workouts!");
  }
}
```

### 2. Requesting
Apple requires all permissions to be requested simultaneously on a unified permissions sheet. This is a fire-and-forget request returning `Future<void>`, as iOS displays the modal independently.

```dart
void requestPermissions() async {
  // Pass identical lists to verify()
  await permissionManager.request(
    [HealthDataType.heartRate, HealthDataType.steps],
    [HealthDataType.workout]
  );
  
  // Natively, iOS will surface the permissions dialog to the user here.
}
```

### 3. Listening (Continuous Monitoring)
Because users can leave your App, toggle permissions natively in the iOS Settings, and return, you should rely on the `listen()` stream. This ties natively into `UIApplication.didBecomeActiveNotification` ensuring your Dart logic automatically reacts when users background/foreground the app.

```dart
StreamSubscription? _sub;

void startListening() {
  _sub = permissionManager.listen(
    [HealthDataType.heartRate, HealthDataType.steps],
    [HealthDataType.workout]
  ).listen((PermissionResponse response) {
      // Rebuild UI, handle logic here according to returned status.
      print(response.readStatuses);
  });
}

void dispose() {
  _sub?.cancel();
}
```

See the `example/` app directory for a complete working demonstration on requesting, verifying, and streaming Permission actions. 

---

## Push Workouts (Scheduling)

The plugin incorporates native support for scheduling workouts against Apple's `WorkoutKit`. It bypasses intermediate Dart models and directly ingests custom JSON representations designed by your backend, translating them natively into iOS `WorkoutPlan` models. 

### Requesting Authorization

Before pushing workouts, you should request authorization for WorkoutKit. This displays Apple's native permission dialog for workout scheduling (requires iOS 17.0+).

```dart
import 'package:humango_health/humango_health.dart';

final pushManager = WorkoutPushManager();

void requestWorkoutPushPermission() async {
  final result = await pushManager.requestAuthorizationForWorkoutPush();
  
  if (result.isAuthorized) {
    print("✅ Workout push authorized!");
  } else {
    switch (result.status) {
      case WorkoutPushAuthorizationStatus.denied:
        print("❌ User denied workout push access");
        // Guide user to Settings -> Health -> Data Access
        break;
      case WorkoutPushAuthorizationStatus.notDetermined:
        print("⏳ Authorization not yet determined");
        break;
      case WorkoutPushAuthorizationStatus.error:
        print("⚠️ Error: ${result.errorMessage}");
        break;
      default:
        print("Unknown status");
    }
  }
}
```

**Note:** WorkoutKit authorization is separate from HealthKit permissions. Even if the user has granted HealthKit permissions, they must also authorize WorkoutKit for scheduling workouts to Apple Watch.

### Performing the Push

A robust `WorkoutPushManager` coordinates the dispatch. The system strictly enforces the Apple requirement that all scheduled workouts must take place within the next **7 days**. 

### Required Fields (Strict Validation)

Every workout JSON object **must** contain the following fields. If ANY workout in a batch is missing required fields, the **entire batch will be rejected**.

| Field | Type | Description |
|-------|------|-------------|
| `schedule_id` | `String` or `int` | **Required.** Unique identifier for the workout. Used for deduplication and tracking. |
| `date` | `String` (ISO8601) | **Required.** Scheduled date/time in ISO8601 format. Must be in the future and within 7 days. |
| `blocks` | `Array` (non-empty) | **Required.** Array of interval blocks defining the workout structure. Cannot be empty. |

**Validation Behavior:**
- Validation happens at **both** Dart and iOS layers
- If ANY workout fails validation, ALL workouts in the batch fail
- Failed workouts return with `status: WorkoutPushStatus.validationError`
- The `errorMessage` contains details about which fields are missing
- The `currentJson` contains the original JSON that failed validation

```dart
// Example: What happens when validation fails
final invalidWorkouts = [
  {
    "schedule_id": 123,
    "date": "2026-03-06T10:00:00Z",
    "blocks": [/* valid blocks */]
  },
  {
    // Missing schedule_id - will cause ENTIRE batch to fail!
    "date": "2026-03-06T12:00:00Z",
    "blocks": [/* valid blocks */]
  }
];

final response = await pushManager.pushRawWorkouts(invalidWorkouts);

// response.failed == 2 (entire batch failed)
for (final result in response.results) {
  if (result.status == WorkoutPushStatus.validationError) {
    print("❌ Validation failed: ${result.errorMessage}");
    print("   Failed JSON: ${result.currentJson}");
  }
}
```

### Pushing Workouts

The deduplication engine natively compares the exact JSON byte-size, alongside extracting your custom `schedule_id` key, to ensure workouts aren't duplicated if users click sync multiple times.

```dart
import 'package:humango_health/humango_health.dart';

final pushManager = WorkoutPushManager();

void scheduleWorkouts() async {

  // 1. Ingest raw backend JSON (List of Maps)
  // All required fields: schedule_id, date, blocks
  final List<Map<String, dynamic>> rawBackendJson = [
    {
      "schedule_id": 123456,
      "date": DateTime.now().add(const Duration(hours: 2)).toIso8601String(),
      "sport": "RUNNING",
      "blocks": [
        // ... (Humango specific Warmup/Interval/Cooldown definition)
      ]
    }
  ];

  // 2. Dispatch the raw maps natively
  final response = await pushManager.pushRawWorkouts(rawBackendJson);

  // 3. Process the results
  for (final result in response.results) {
    if (result.status == WorkoutPushStatus.success) {
      print("✅ Successfully Pushed: ${result.workoutId}");
    } else if (result.status == WorkoutPushStatus.skipped) {
      print("⏭️ Skipped (Already cached natively): ${result.workoutId}");
    } else if (result.status == WorkoutPushStatus.validationError) {
      print("❌ Validation Error: ${result.errorMessage}");
    } else {
      print("❌ Failed: ${result.errorMessage}");
    }
  }
}
```

### Retrieving Scheduled Workouts

After pushing workouts, you can retrieve the list of currently scheduled workouts from Apple Watch:

```dart
import 'package:humango_health/humango_health.dart';

final pushManager = WorkoutPushManager();

void fetchScheduledWorkouts() async {
  final scheduledWorkouts = await pushManager.getScheduledWorkouts();
  
  for (final workout in scheduledWorkouts) {
    print("📅 Scheduled: ${workout.name ?? 'Unnamed'}");
    print("   Activity: ${workout.activityType}");
    print("   Date: ${workout.scheduledDate}");
    print("   Workout ID: ${workout.workoutId}");
  }
  
  print("Total scheduled: ${scheduledWorkouts.length}");
}
```

The `ScheduledWorkoutInfo` model provides:
- `id`: The WorkoutKit UUID
- `workoutId`: Your original `schedule_id` (if matched with local records)
- `scheduledDate`: When the workout is scheduled
- `name`: The workout name
- `activityType`: The activity type (Running, Cycling, etc.)
- `workoutJson`: The full JSON payload that was scheduled (for comparison)
- `jsonSizeBytes`: Size of the JSON payload in bytes

**Note:** This retrieves workouts directly from `WorkoutScheduler.shared.scheduledWorkouts` on iOS 17.0+.

### Two-Layer Deduplication System

The plugin implements a sophisticated two-layer deduplication system to prevent duplicate workout scheduling:

| Layer | Location | Strategy | Purpose |
|-------|----------|----------|---------|
| **Layer 1** | Dart (`WorkoutPushManager`) | JSON size comparison | Fast filter - avoids unnecessary native calls if size unchanged |
| **Layer 2** | iOS (`ScheduledWorkoutStore`) | Byte-level JSON comparison | Accurate filter - catches edge cases where size matches but content differs |

**How it works:**

1. **Dart Layer**: Before sending to iOS, checks if a workout with the same `schedule_id` exists locally with identical `jsonSizeBytes`. If sizes match, the workout is skipped immediately.

2. **iOS Layer**: If passed through Dart, iOS serializes the JSON with `.sortedKeys` for consistent ordering, then compares the exact bytes against stored records using `WorkoutPlan.id` (Apple's stable UUID).

### JSON Response Details

Every push operation returns detailed information about each workout's fate:

```dart
final response = await pushManager.pushRawWorkouts(rawBackendJson);

for (final result in response.results) {
  print("Workout: ${result.workoutId}");
  print("Status: ${result.status}"); // success, skipped, failed, validationError
  
  if (result.status == WorkoutPushStatus.success) {
    // Successfully scheduled to Apple Watch
    print("✅ Scheduled!");
    print("   WorkoutPlan ID: ${result.workoutPlanId}");
    print("   JSON: ${result.currentJson}");
    
  } else if (result.status == WorkoutPushStatus.skipped) {
    // Deduplication prevented scheduling
    print("⏭️ Skipped: ${result.skipReason}");
    
    // Compare JSONs to see exact differences
    print("   Current JSON (attempted): ${result.currentJson}");
    print("   Existing JSON (stored): ${result.existingJson}");
    print("   Current size: ${result.currentJsonSizeBytes} bytes");
    print("   Existing size: ${result.existingJsonSizeBytes} bytes");
    
    // Use this to show user what changed (or didn't change)
    _showDifferenceDialog(result.currentJson, result.existingJson);
    
  } else if (result.status == WorkoutPushStatus.failed) {
    print("❌ Failed: ${result.errorMessage}");
  }
}
```

### Skip Reasons

The `skipReason` field indicates which deduplication layer caught the workout:

| Reason | Layer | Description |
|--------|-------|-------------|
| `dart_dedup_unchanged` | Dart | JSON size matched existing record - skipped before iOS call |
| `ios_dedup_unchanged` | iOS | Byte-level comparison matched - workout already scheduled |
| `ios_unchanged` | iOS | General iOS deduplication (fallback reason) |

### Tracking with WorkoutPlan.id

Each scheduled workout receives a stable UUID from Apple's `WorkoutPlan.id`. This ID:
- Persists across app restarts
- Allows matching scheduled workouts with your records
- Is available in both `WorkoutPushResult.workoutPlanId` and `ScheduledWorkoutInfo.workoutPlanId`

```dart
// After pushing
for (final result in response.results) {
  if (result.status == WorkoutPushStatus.success) {
    // Store this ID to track the workout
    final appleId = result.workoutPlanId;
    await saveWorkoutMapping(result.workoutId, appleId);
  }
}

// Later, when retrieving scheduled workouts
final scheduled = await pushManager.getScheduledWorkouts();
for (final workout in scheduled) {
  final originalId = await findOriginalId(workout.workoutPlanId);
  print("Apple workout ${workout.id} maps to your workout $originalId");
}
```

---

## Background Delivery Manager (API Configuration)

When monitoring workouts, the plugin needs a strategy for delivering workout data discovered while the app is in the **background** (suspended by iOS). The `BackgroundDeliveryManager` handles this natively on the iOS side.

### Delivery Modes

| Mode | Description |
|------|-------------|
| `BackgroundDeliveryMode.api` | Native iOS directly POSTs workout JSON to your configured API endpoint — no Flutter involvement needed. |
| `BackgroundDeliveryMode.localStorage` | Stores workout JSON in `UserDefaults`. Retrieve on next app open via `getLocalWorkouts()`. |

### How It Works

**If API mode is configured:**
- Workouts are **always** pushed directly to your API endpoint via native HTTP POST — whether the app is in the foreground or background. Flutter's event stream is bypassed entirely.

**If not configured (default `localStorage` mode):**
- **Foreground (Flutter listening):** Workouts are pushed directly to Flutter's `workoutStream` via the `EventChannel` in real-time.
- **Background (app suspended):** HealthKit wakes the app via `HKObserverQuery`. Workouts are stored in `UserDefaults`. When the user opens the app, call `getLocalWorkouts()` to retrieve them and push to your Flutter code.

### Configuring API Mode

To push workouts directly to your backend from the background:

```dart
import 'package:humango_health/humango_health.dart';

final workoutManager = WorkoutReadManager();

void configureAPIDelivery() async {
  await workoutManager.configureBackgroundDelivery(
    BackgroundDeliveryConfig(
      mode: BackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/workouts/ingest',
      headers: {
        'Authorization': 'Bearer <your-auth-token>',
        'X-Device-Id': '<device-identifier>',
        'Content-Type': 'application/json',
      },
    ),
  );
}
```

**What happens natively:**
- The `apiURL` and `headers` are persisted to `UserDefaults`, so they survive app restarts.
- **All** detected workouts (foreground and background) are pushed via native HTTP POST — Flutter's event stream is not used.
- On a successful response (HTTP 2xx), the workout is marked as pushed in the `WorkoutRecordStore` to prevent duplicates.
- On failure, the error is logged natively.

### Configuring Local Storage Mode

If you prefer to retrieve workouts yourself when the app opens:

```dart
void configureLocalDelivery() async {
  await workoutManager.configureBackgroundDelivery(
    BackgroundDeliveryConfig(mode: BackgroundDeliveryMode.localStorage),
  );
}
```

Then retrieve pending workouts on app startup:

```dart
void fetchPendingWorkouts() async {
  final List<String> pending = await workoutManager.getLocalWorkouts();
  
  for (final workoutJson in pending) {
    // Parse and process each workout
    print('Retrieved pending workout: $workoutJson');
  }
  // Local storage is automatically cleared after retrieval
}
```

### Configuration Persistence

All delivery configuration (`mode`, `apiURL`, `headers`) is persisted to `UserDefaults` under the keys:
- `HumangoDeliveryMode`
- `HumangoDeliveryURL`
- `HumangoDeliveryHeaders`

This means the configuration survives app restarts — critical because HealthKit background observers can fire when iOS relaunches your app in the background.

### Recommended Setup

Call `configureBackgroundDelivery` early in your app lifecycle (e.g., after login when you have a valid auth token), and before calling `startMonitoring()`:

```dart
void initWorkoutMonitoring() async {
  // 1. Configure how background workouts should be delivered
  await workoutManager.configureBackgroundDelivery(
    BackgroundDeliveryConfig(
      mode: BackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/workouts/ingest',
      headers: {
        'Authorization': 'Bearer $authToken',
      },
    ),
  );

  // 2. Start monitoring from 1 hour ago onwards
  await workoutManager.startMonitoring(
    DateTime.now().subtract(const Duration(hours: 1)),
  );

  // 3. Listen to the live stream for foreground workouts
  workoutManager.workoutStream.listen((workoutJson) {
    print('Live workout received: $workoutJson');
  });
}
```
