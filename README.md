# Humango Health Plugin

A comprehensive Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform.

## Table of Contents

- [Features](#features)
- [Architecture Overview](#architecture-overview)
- [Requirements](#requirements)
- [Permission Handling](#permission-handling)
- [Workout Scheduling (Push)](#push-workouts-scheduling)
- [Workout Reading & Monitoring](#workout-reading--monitoring)
- [Background Delivery Manager](#background-delivery-manager-api-configuration)
- [Sleep Data Reading & Monitoring](#sleep-data-reading--monitoring)
- [Health Metrics Reading](#health-metrics-reading)
- [Native iOS Lifecycle Management](#native-ios-lifecycle-management)

## Features

| Feature | Description |
|---------|-------------|
| **Permission Handling** | Request, verify, and continuously monitor HealthKit permissions |
| **Workout Scheduling** | Push workouts to Apple Watch via WorkoutKit with two-layer deduplication |
| **Workout Reading** | Real-time workout monitoring with foreground/background modes |
| **Sleep Data** | Fetch and monitor sleep analysis with live streaming support |
| **Background Delivery** | Native iOS background processing with API or local storage delivery |
| **Native Lifecycle Management** | Centralized iOS app lifecycle detection for automatic mode switching |

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    Flutter Application Layer                     │
│  ├─ PermissionManager (permissions)                              │
│  ├─ WorkoutPushManager (scheduling)                              │
│  ├─ WorkoutReadManager (reading/monitoring)                      │
│  └─ SleepDataManager (sleep data)                                │
└──────────────────────────┬───────────────────────────────────────┘
                           │ Method Channels + Event Channels
┌──────────────────────────┴───────────────────────────────────────┐
│                    iOS Native Layer                              │
│  ├─ AppLifecycleManager (centralized lifecycle notifications)   │
│  ├─ PermissionManager (HealthKit authorization)                  │
│  ├─ WorkoutSchedulingService (WorkoutKit integration)            │
│  ├─ WorkoutService (HKAnchoredObjectQuery + HKObserverQuery)     │
│  ├─ SleepDataManager (sleep streaming + background monitoring)  │
│  └─ WorkoutRecordStore (deduplication + persistence)             │
└──────────────────────────┬───────────────────────────────────────┘
                           │
┌──────────────────────────┴───────────────────────────────────────┐
│                Apple HealthKit & WorkoutKit                      │
│  ├─ HKHealthStore (health data access)                           │
│  ├─ WorkoutScheduler (Apple Watch workout scheduling)            │
│  └─ HKObserverQuery (background delivery)                        │
└──────────────────────────────────────────────────────────────────┘
```

## Requirements

- **iOS 18.0** minimum deployment target
- **Physical device** required for testing (HealthKit not available in Simulator)
- **Apple Watch** required for WorkoutKit scheduling features

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

> **Note:** Both deduplication layers now correctly report skipped workouts in `WorkoutPushResponse`. When all workouts in a batch are skipped by iOS-level dedup, the skipped records (with `status: "skipped"`) are returned to the Dart layer so that `response.skipped` accurately reflects the count. Previously, iOS-level skips were only logged but not included in the response when the entire batch was deduplicated.

### Interpreting the Push Response

The `WorkoutPushResponse` provides accurate counts for all outcomes:

```dart
final response = await pushManager.pushRawWorkouts(workouts);

print('Total submitted: ${response.totalSubmitted}');
print('Successful: ${response.successful}');   // newly scheduled
print('Skipped: ${response.skipped}');         // deduplicated (Dart or iOS layer)
print('Failed: ${response.failed}');           // errors

// The sum always holds:
// response.successful + response.skipped + response.failed == response.totalSubmitted

// Determine overall outcome
if (response.successful > 0) {
  print('New workouts scheduled!');
} else if (response.skipped == response.totalSubmitted) {
  print('All workouts already scheduled — nothing changed');
}
```

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

---

## Native iOS Lifecycle Management

The plugin uses a centralized `AppLifecycleManager` on the iOS side to automatically detect foreground/background transitions. This is **more accurate** than Flutter's `WidgetsBindingObserver` because it uses native iOS notifications directly.

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                  AppLifecycleManager                        │
│  ├─ observes: UIApplication lifecycle notifications        │
│  ├─ isInForeground: Bool                                   │
│  └─ observers: NSHashTable<AppLifecycleObserver> (weak)    │
└───────────────────────┬─────────────────────────────────────┘
                        │ notifies
          ┌─────────────┴─────────────┐
          ▼                           ▼
┌───────────────────────┐   ┌───────────────────────┐
│   SleepDataManager    │   │    WorkoutService     │
│ (AppLifecycleObserver)│   │ (AppLifecycleObserver)│
└───────────────────────┘   └───────────────────────┘
```

### iOS Notifications Observed

| Notification | Action |
|--------------|--------|
| `UIApplication.didBecomeActiveNotification` | Switches to **foreground mode** (live streaming) |
| `UIApplication.didEnterBackgroundNotification` | Switches to **background mode** (observer queries) |

### Benefits

1. **Automatic Mode Switching**: Services automatically switch between live streaming and background observer modes
2. **No Flutter Code Needed**: No need to use `WidgetsBindingObserver` in Dart
3. **More Accurate**: Native iOS lifecycle detection is more reliable than Flutter callbacks
4. **Centralized Logic**: All services share the same lifecycle state

### Manual Override (Optional)

While lifecycle is handled automatically, you can still manually trigger mode switches if needed:

```dart
// Optional: Force foreground mode
await sleepManager.enterForeground();

// Optional: Force background mode
await sleepManager.enterBackground();
```

---

## Sleep Data Reading & Monitoring

The plugin provides comprehensive access to Apple HealthKit's sleep analysis data (`HKCategoryTypeIdentifier.sleepAnalysis`) with support for:

- **One-shot fetch**: Query sleep data for a configurable date range
- **Live streaming (Foreground)**: Real-time updates via EventChannel using `HKAnchoredObjectQueryDescriptor`
- **Background monitoring**: Detect changes via `HKObserverQuery` with UserDefaults storage

### Sleep Stages (iOS 16+)

| Value | Stage | Description |
|-------|-------|-------------|
| 0 | `inBed` | User is in bed but not necessarily asleep |
| 1 | `asleepUnspecified` | User is asleep (stage unknown) |
| 2 | `awake` | User woke up during sleep |
| 3 | `asleepCore` | Core/light sleep |
| 4 | `asleepDeep` | Deep sleep |
| 5 | `asleepREM` | REM sleep |

### Fetching Sleep Data

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void fetchSleepData() async {
  try {
    final response = await sleepManager.getSleepData();
    
    if (response.hasSleepData) {
      print('🛏️ Sleep Summary:');
      print('   Total sleep: ${response.totalSleepHours.toStringAsFixed(1)} hours');
      print('   Samples: ${response.sampleCount}');
      
      // Stage breakdown
      print('   Deep sleep: ${response.stageTotals.asleepDeepMinutes.toStringAsFixed(0)} min');
      print('   REM sleep: ${response.stageTotals.asleepREMMinutes.toStringAsFixed(0)} min');
      print('   Core sleep: ${response.stageTotals.asleepCoreMinutes.toStringAsFixed(0)} min');
      print('   Awake: ${response.stageTotals.awakeMinutes.toStringAsFixed(0)} min');
      
      // Individual samples with raw JSON
      for (final sample in response.samples) {
        print('   ${sample.sleepStage}: ${sample.durationMinutes.toStringAsFixed(0)} min');
        print('      Source: ${sample.sourceName}');
        print('      Device: ${sample.device?.name}');
        print('      Raw JSON: ${sample.rawJson}');
      }
      
      // Access full raw response
      print('Full response JSON: ${response.rawJson}');
    } else {
      print('No sleep data found for the last 24 hours');
    }
  } on SleepDataException catch (e) {
    print('Error: ${e.code} - ${e.message}');
  }
}
```

### Response Structure

The `SleepDataResponse` contains:

| Property | Type | Description |
|----------|------|-------------|
| `samples` | `List<SleepSample>` | Individual sleep samples |
| `sampleCount` | `int` | Number of samples |
| `totalSleepSeconds` | `double` | Total actual sleep time (excludes inBed/awake) |
| `totalSleepMinutes` | `double` | Total sleep in minutes |
| `totalSleepHours` | `double` | Total sleep in hours |
| `stageTotals` | `SleepStageTotals` | Time spent in each stage |
| `fetchedFrom` | `DateTime` | Query start time (24h ago) |
| `fetchedTo` | `DateTime` | Query end time (now) |
| `rawJson` | `Map<String, dynamic>` | Complete raw response from iOS |

### SleepSample Properties

Each `SleepSample` includes:

| Property | Type | Description |
|----------|------|-------------|
| `uuid` | `String` | HealthKit sample UUID |
| `startDate` | `DateTime` | Sleep segment start |
| `endDate` | `DateTime` | Sleep segment end |
| `value` | `int` | Raw sleep stage value (0-5) |
| `sleepStage` | `String` | Human-readable stage name |
| `durationSeconds` | `double` | Duration in seconds |
| `durationMinutes` | `double` | Duration in minutes |
| `sourceName` | `String?` | Recording app/device name |
| `sourceBundle` | `String?` | Recording app bundle ID |
| `device` | `SleepDevice?` | Device information |
| `metadata` | `Map?` | Additional HealthKit metadata |
| `rawJson` | `Map<String, dynamic>` | Complete raw sample JSON |

### Permission Requirements

Ensure sleep data read permission is granted before fetching:

```dart
final permissionManager = PermissionManager();

// Request sleep read permission
await permissionManager.request(
  [HealthDataType.sleepAnalysis],  // Read types
  []  // Write types (none needed for reading)
);

// Then fetch sleep data
final sleepManager = SleepDataManager();
final response = await sleepManager.getSleepData();
```

### Compatibility

- **iOS 14.0+**: Basic sleep data (inBed, asleepUnspecified, awake)
- **iOS 16.0+**: Detailed sleep stages (asleepCore, asleepDeep, asleepREM)

**Note:** On devices with iOS < 16, sleep samples will use `asleepUnspecified` instead of detailed stage classification.

### Live Sleep Monitoring (Foreground)

Start real-time monitoring for sleep data changes:

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void startSleepMonitoring() async {
  // 1. Start monitoring from 24 hours ago
  await sleepManager.startMonitoring(
    startDate: DateTime.now().subtract(const Duration(hours: 24)),
  );
  
  // 2. Listen to real-time updates
  sleepManager.sleepDataStream.listen((event) {
    if (event.type == SleepDataEventType.sleepSample) {
      print('📊 New sleep sample: ${event.sample?.sleepStage}');
      print('   Duration: ${event.sample?.durationMinutes} min');
    } else if (event.type == SleepDataEventType.sleepSampleDeleted) {
      print('🗑️ Sleep sample deleted: ${event.uuid}');
    }
  });
}

void stopSleepMonitoring() async {
  await sleepManager.stopMonitoring();
}
```

### Background Sleep Monitoring

When the app enters background, the plugin automatically switches to `HKObserverQuery` mode and stores new sleep data in `UserDefaults`. Retrieve it when the app opens:

```dart
void fetchBackgroundSleepData() async {
  // Retrieve sleep data stored while app was in background
  final response = await sleepManager.fetchStoredSleepData();
  
  if (response.hasSleepData) {
    print('Retrieved ${response.sampleCount} samples from background');
    
    for (final sample in response.samples) {
      print('Background sample: ${sample.sleepStage} - ${sample.durationMinutes} min');
    }
  }
  
  // Clear stored data after processing
  await sleepManager.clearStoredSleepData();
}
```

### Dual-Mode Architecture

| Mode | Trigger | Technology | Data Delivery |
|------|---------|------------|---------------|
| **Foreground** | App active | `HKAnchoredObjectQueryDescriptor` | EventChannel stream |
| **Background** | App suspended | `HKObserverQuery` + `enableBackgroundDelivery()` | UserDefaults storage |

**Automatic switching**: The `AppLifecycleManager` automatically switches between modes based on iOS app lifecycle notifications. No Flutter code needed.

### Channels

| Channel | Type | Purpose |
|---------|------|---------|
| `com.humango.health/sleep` | MethodChannel | Request/response operations |
| `com.humango.health/sleep/stream` | EventChannel | Real-time sleep sample streaming |

---

## Workout Reading & Monitoring

The plugin provides comprehensive workout reading with real-time monitoring and intelligent background processing.

### Reading Methods

| Method | Description | Use Case |
|--------|-------------|----------|
| `readWorkouts(startDate, endDate)` | One-shot fetch | Initial sync, manual refresh |
| `startMonitoring(startDate, endDate)` | Live monitoring | Real-time tracking |
| `getLocalWorkouts()` | Retrieve stored workouts | App startup, background data |

### Fetching Completed Workouts (One-Shot)

Use `readWorkouts()` to fetch historical/completed workouts from HealthKit:

```dart
import 'dart:convert';
import 'package:humango_health/humango_health.dart';

final workoutManager = WorkoutReadManager();

void fetchCompletedWorkouts() async {
  try {
    final now = DateTime.now();
    
    // Fetch past 7 days of completed workouts
    final List<String> rawJsons = await workoutManager.readWorkouts(
      now.subtract(const Duration(days: 7)),
      endDate: now, // Optional - defaults to current time
    );
    
    print('📦 Fetched ${rawJsons.length} completed workouts');
    
    for (final jsonString in rawJsons) {
      final workout = jsonDecode(jsonString);
      
      print('🏃 Workout:');
      print('   Activity: ${workout['activityType']}');
      print('   Duration: ${(workout['duration'] / 60).toStringAsFixed(1)} min');
      print('   Distance: ${((workout['distance'] ?? 0) / 1000).toStringAsFixed(2)} km');
      print('   Start: ${workout['startDate']}');
      print('   End: ${workout['endDate']}');
      
      // Statistics
      if (workout['statistics'] != null) {
        final stats = workout['statistics'];
        print('   Avg HR: ${stats['avgHeartRate']} bpm');
        print('   Max HR: ${stats['maxHeartRate']} bpm');
        print('   Calories: ${stats['totalCalories']} kcal');
      }
      
      // Route data (if available)
      if (workout['route'] != null) {
        final route = workout['route'] as List;
        print('   Route points: ${route.length}');
      }
    }
  } catch (e) {
    print('Error fetching workouts: $e');
  }
}
```

### Workout JSON Structure

Each workout is returned as a JSON string with the following structure:

```json
{
  "uuid": "ABC-123-DEF",
  "activityType": "running",
  "startDate": "2026-03-04T08:00:00.000Z",
  "endDate": "2026-03-04T08:45:00.000Z",
  "duration": 2700,
  "distance": 5500,
  "sourceBundle": "com.apple.health",
  "sourceName": "Apple Watch",
  "statistics": {
    "avgHeartRate": 145,
    "maxHeartRate": 172,
    "minHeartRate": 98,
    "totalCalories": 450,
    "activeCalories": 380
  },
  "route": [
    {"latitude": 37.7749, "longitude": -122.4194, "altitude": 10.5, "timestamp": "..."},
    ...
  ],
  "events": [
    {"type": "pause", "startDate": "...", "endDate": "..."},
    {"type": "lap", "startDate": "...", "endDate": "..."}
  ],
  "device": {
    "name": "Apple Watch Series 9",
    "model": "Watch6,1",
    "softwareVersion": "10.3"
  }
}
```

### Setting Import Preferences

Control which workout types are fetched/monitored:

```dart
void configureWorkoutTypes() async {
  await workoutManager.setImportPreferences(
    running: true,    // Import running workouts
    cycling: true,    // Import cycling workouts
    swimming: false,  // Skip swimming workouts
  );
  
  // Now fetch will only return running and cycling workouts
  final workouts = await workoutManager.readWorkouts(
    DateTime.now().subtract(const Duration(days: 30)),
  );
}
```

### Starting Workout Monitoring

```dart
import 'package:humango_health/humango_health.dart';

final workoutManager = WorkoutReadManager();

void startWorkoutMonitoring() async {
  // 1. Start monitoring from 7 days ago
  await workoutManager.startMonitoring(
    DateTime.now().subtract(const Duration(days: 7)),
  );
  
  // 2. Listen to real-time workout updates
  workoutManager.workoutStream.listen((workoutJson) {
    print('🏃 New workout received!');
    print('   JSON: $workoutJson');
    
    // Parse and process workout data
    final workout = jsonDecode(workoutJson);
    print('   Type: ${workout['activityType']}');
    print('   Duration: ${workout['duration']} seconds');
  });
}

void stopWorkoutMonitoring() async {
  await workoutManager.stopMonitoring();
}
```

### Workout Data Contents

Each workout includes comprehensive data:

| Category | Fields |
|----------|--------|
| **Core Metadata** | distance, duration, activityType, startDate, endDate, sourceBundle |
| **Statistics** | avgHeartRate, maxHeartRate, minHeartRate, totalCalories |
| **Quantity Series** | Heart rate, steps, distance, power, cadence (20+ types) |
| **Route Data** | GPS coordinates as `[CLLocation]` array |
| **Events** | Workout segments, laps, pauses |
| **Device Info** | Device name, model, iOS version |

### Dual-Mode Monitoring

| Mode | Technology | Data Delivery |
|------|------------|---------------|
| **Foreground** | `HKAnchoredObjectQueryDescriptor` | EventChannel stream |
| **Background** | `HKObserverQuery` + `enableBackgroundDelivery()` | API POST or localStorage |

### Deduplication

The plugin implements two-layer deduplication:

| Layer | Location | Strategy |
|-------|----------|----------|
| **Layer 1** | Dart | JSON size comparison (fast filter) |
| **Layer 2** | iOS | SHA256 hash + byte-level comparison |

---

## Health Metrics Reading

Read body-composition and vital-sign metrics from HealthKit with a single, generic manager.

### Supported Metrics

| Metric | HealthKit Identifier | Unit | iOS |
|--------|---------------------|------|-----|
| HRV (SDNN) | `heartRateVariabilitySDNN` | ms | 11.0+ |
| Resting Heart Rate | `restingHeartRate` | bpm | 11.0+ |
| Body Fat Percentage | `bodyFatPercentage` | % | 8.0+ |
| Weight (Body Mass) | `bodyMass` | kg | 8.0+ |
| Height | `height` | cm | 8.0+ |

### Quick Start

```dart
import 'package:humango_health/humango_health.dart';

final metrics = HealthMetricsManager();
```

### Fetching a Single Metric

```dart
// Fetch HRV samples from the last 30 days (default)
final hrvResponse = await metrics.getHRV();

print('Latest HRV: ${hrvResponse.latestValue} ${hrvResponse.unit}');
print('Average: ${hrvResponse.statistics.average}');
print('Samples: ${hrvResponse.sampleCount}');

for (final sample in hrvResponse.samples) {
  print('${sample.startDate}: ${sample.value} ${sample.unit}');
}
```

### Convenience Methods

Each metric has a dedicated convenience method that returns a `HealthMetricResponse`:

```dart
final hrv       = await metrics.getHRV();
final restingHR = await metrics.getRestingHeartRate();
final bodyFat   = await metrics.getBodyFatPercentage();
final weight    = await metrics.getWeight();
final height    = await metrics.getHeight();
```

All convenience methods accept optional `startDate`, `endDate`, and `limit` parameters:

```dart
final recentWeight = await metrics.getWeight(
  startDate: DateTime.now().subtract(const Duration(days: 7)),
  endDate: DateTime.now(),
  limit: 10,
);
```

### Fetching the Latest Value

Use `getLatestMetric` to fetch only the most recent sample for any metric type:

```dart
final latest = await metrics.getLatestMetric(HealthMetricType.bodyMass);
print('Current weight: ${latest.latestValue} ${latest.unit}');
```

### Fetching All Metrics at Once

`getAllMetrics` queries all 5 metric types in a single call and returns an `AllHealthMetricsResponse`:

```dart
final all = await metrics.getAllMetrics(
  startDate: DateTime.now().subtract(const Duration(days: 30)),
);

// Named convenience getters
print('HRV: ${all.hrv?.latestValue} ms');
print('Resting HR: ${all.restingHeartRate?.latestValue} bpm');
print('Body Fat: ${all.bodyFatPercentage?.latestValue} %');
print('Weight: ${all.weight?.latestValue} kg');
print('Height: ${all.height?.latestValue} cm');

// Check for per-metric errors
if (all.errors.isNotEmpty) {
  print('Errors: ${all.errors}');
}
```

### Response Structure

`HealthMetricResponse` contains:

| Field | Type | Description |
|-------|------|-------------|
| `metricType` | `String` | The metric key (e.g. `heartRateVariabilitySDNN`) |
| `unit` | `String` | Display unit (e.g. `ms`, `bpm`, `%`, `kg`, `cm`) |
| `samples` | `List<HealthMetricSample>` | Individual data points |
| `sampleCount` | `int` | Number of samples returned |
| `latestSample` | `HealthMetricSample?` | Most recent sample |
| `statistics` | `HealthMetricStatistics` | Aggregated avg / min / max / sum |
| `fetchedFrom` | `DateTime` | Query start date |
| `fetchedTo` | `DateTime` | Query end date |

Each `HealthMetricSample` includes:

| Field | Type | Description |
|-------|------|-------------|
| `uuid` | `String` | HealthKit sample UUID |
| `value` | `double` | Metric value |
| `unit` | `String` | Unit string |
| `startDate` / `endDate` | `DateTime` | Sample time range |
| `sourceName` | `String?` | Source app name |
| `sourceBundle` | `String?` | Source bundle identifier |
| `device` | `HealthMetricDevice?` | Device info (name, model, etc.) |
| `metadata` | `Map?` | HealthKit metadata dictionary |

### Error Handling

```dart
try {
  final response = await metrics.getHRV();
} on HealthMetricsException catch (e) {
  print('Code: ${e.code}');
  print('Message: ${e.message}');
  print('Details: ${e.details}');
}
```

### Permission Requirements

Health Metrics reading requires HealthKit read permissions for the corresponding quantity types. Ensure the following are included in your permission request:

- `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`
- `HKQuantityTypeIdentifier.restingHeartRate`
- `HKQuantityTypeIdentifier.bodyFatPercentage`
- `HKQuantityTypeIdentifier.bodyMass`
- `HKQuantityTypeIdentifier.height`

### Channel

| Channel | Type | Purpose |
|---------|------|--------|
| `com.humango.health/metrics` | MethodChannel | Health metrics queries |

---
## Channel Reference

All communication between Flutter and iOS uses these channels:

| Channel | Type | Purpose |
|---------|------|---------|
| `com.humango.health` | MethodChannel | Main health operations |
| `com.humango.health/permissions` | MethodChannel | Permission handling |
| `com.humango.health/permissions/stream` | EventChannel | Permission status changes |
| `com.humango.workouts/push` | MethodChannel | Workout scheduling |
| `com.humango.workouts/read` | MethodChannel | Workout reading |
| `com.humango.workouts/read/stream` | EventChannel | Real-time workout updates |
| `com.humango.health/sleep` | MethodChannel | Sleep data operations |
| `com.humango.health/sleep/stream` | EventChannel | Real-time sleep updates |
| `com.humango.health/metrics` | MethodChannel | Health metrics (HRV, HR, body comp) |

---

## Related Documentation

For detailed subsystem documentation, see:

- [PERMISSION_SUBSYSTEM.md](PERMISSION_SUBSYSTEM.md) - Permission handling architecture
- [PUSH_WORKOUTS_SUBSYSTEM.md](PUSH_WORKOUTS_SUBSYSTEM.md) - Workout scheduling implementation
- [READ_WORKOUTS_SUBSYSTEM.md](READ_WORKOUTS_SUBSYSTEM.md) - Workout reading architecture
- [SLEEP_DATA_SUBSYSTEM.md](SLEEP_DATA_SUBSYSTEM.md) - Sleep data implementation

---

## License

See [LICENSE](LICENSE) for details.