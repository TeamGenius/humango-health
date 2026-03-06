# Humango Health Plugin

A comprehensive Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform.

## Table of Contents

- [Features](#features)
- [Architecture Overview](#architecture-overview)
- [Requirements](#requirements)
- [Permission Handling](#permission-handling)
- [Workout Scheduling (Push)](#push-workouts-scheduling)
- [Workout Reading & Monitoring](#workout-reading--monitoring)
- [Background Delivery Manager (Workouts + Sleep)](#background-delivery-manager-api-configuration)
- [Sleep Data Reading & Monitoring](#sleep-data-reading--monitoring)
- [Health Metrics Reading](#health-metrics-reading)
- [Native iOS Lifecycle Management](#native-ios-lifecycle-management)

## Features

| Feature | Description |
|---------|-------------|
| **Permission Handling** | Request, verify, and continuously monitor HealthKit permissions |
| **Workout Scheduling** | Push workouts to Apple Watch via WorkoutKit with native deduplication |
| **Workout Reading** | Real-time workout monitoring with foreground/background modes |
| **Sleep Data** | Fetch and monitor sleep analysis with live streaming support |
| **Background Delivery** | Native iOS background processing with API or local storage delivery (workouts + sleep) |
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

### Device Support Check

Before attempting to schedule workouts, the plugin verifies `WorkoutScheduler.isSupported` at the native level. If the device does not support scheduled workouts (e.g. iPhone without a paired Apple Watch), every workout in the batch is returned with `status: "device_not_supported"` and a descriptive reason — no crash, no silent failure.

### Performing the Push

A robust `WorkoutPushManager` coordinates the dispatch. The system strictly enforces the Apple requirement that all scheduled workouts must take place within the next **7 days**.

### Required Fields (Per-Workout Validation)

Every workout JSON object **must** contain the following fields. Validation is applied **per-workout** — invalid workouts are recorded with `validationError` status while the remaining valid workouts continue to be scheduled.

| Field | Type | Description |
|-------|------|-------------|
| `schedule_id` | `String` or `int` | **Required.** Unique identifier for the workout. Used for deduplication and tracking. |
| `date` | `String` (ISO8601) | **Required.** Scheduled date/time in ISO8601 format. Must be in the future and within 7 days. |
| `blocks` | `Array` (non-empty) | **Required.** Array of interval blocks defining the workout structure. Cannot be empty. |

**Validation Behavior:**
- Validation happens at **both** Dart and iOS layers, **per-workout**
- Invalid workouts are recorded with `status: WorkoutPushStatus.validationError`; valid workouts continue
- The `errorMessage` contains details about which fields are missing
- The `currentJson` contains the original JSON that failed validation

```dart
// Example: Per-workout validation — valid workouts still get scheduled
final mixedWorkouts = [
  {
    "schedule_id": 123,
    "date": "2026-03-06T10:00:00Z",
    "blocks": [/* valid blocks */]
  },
  {
    // Missing schedule_id — only THIS workout fails
    "date": "2026-03-06T12:00:00Z",
    "blocks": [/* valid blocks */]
  }
];

final response = await pushManager.pushRawWorkouts(mixedWorkouts);

// response.successful == 1 (first workout scheduled)
// response.failed == 1 (second workout failed validation)
for (final result in response.results) {
  if (result.status == WorkoutPushStatus.validationError) {
    print("❌ Validation failed: ${result.errorMessage}");
    print("   Failed JSON: ${result.currentJson}");
  } else if (result.status == WorkoutPushStatus.success) {
    print("✅ Scheduled: ${result.workoutId}");
  }
}
```

### Pushing Workouts

The native deduplication engine compares sorted-key JSON bytes, alongside extracting your custom `schedule_id` key, to ensure workouts aren't duplicated if users click sync multiple times.

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
      print("   WorkoutPlan ID: ${result.workoutPlanId}");
    } else if (result.status == WorkoutPushStatus.skipped) {
      print("⏭️ Skipped (Already cached natively): ${result.workoutId}");
    } else if (result.status == WorkoutPushStatus.validationError) {
      print("❌ Validation Error: ${result.errorMessage}");
    } else if (result.status == WorkoutPushStatus.failed) {
      print("❌ Failed: ${result.errorMessage}");
    }
  }
}
```

### Rescheduling Behavior

When a workout with the same `schedule_id` is pushed again with **different** content (changed date or JSON), the plugin automatically:

1. Finds the existing scheduled workout on Apple Watch by its stored `WorkoutPlan.id`
2. Removes the old workout via `WorkoutScheduler.shared.remove(plan, at: date)`
3. Schedules the new version
4. Updates the local dedup record

This ensures users always see the latest version on Apple Watch without manual removal.

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

### Removing Scheduled Workouts

Remove one or more scheduled workouts from Apple Watch and local storage by their `workoutPlanId` (the UUID assigned by WorkoutKit when the workout was originally scheduled):

```dart
final pushManager = WorkoutPushManager();

void removeWorkouts(List<String> planIds) async {
  final results = await pushManager.removeScheduledWorkouts(planIds);
  
  for (final result in results) {
    switch (result.status) {
      case WorkoutRemovalStatus.success:
        print("✅ Removed: ${result.workoutPlanId}");
        break;
      case WorkoutRemovalStatus.partial:
        // Not found on Apple Watch but cleaned from local storage
        print("⚠️ Partial: ${result.message}");
        break;
      case WorkoutRemovalStatus.fail:
        print("❌ Not found: ${result.workoutPlanId}");
        break;
    }
  }
}
```

The `WorkoutRemovalResult` model provides:
- `workoutPlanId`: The requested WorkoutPlan UUID
- `workoutId`: Your original `schedule_id` (if matched in local storage)
- `status`: `success` | `partial` | `fail`
- `message`: Human-readable description of the outcome

### Native Deduplication

All deduplication is handled at the **native iOS layer** via `ScheduledWorkoutStore`. There is no Dart-side storage — the single source of truth is the native `UserDefaults`-backed store.

**How it works:**

1. iOS serializes the incoming JSON with `.sortedKeys` for consistent byte ordering
2. Compares the exact bytes against stored records keyed by `schedule_id`
3. If sizes differ → push (content changed)
4. If sizes match → compare actual bytes. If identical → skip; if different → push

| Scenario | Action | Status |
|----------|--------|--------|
| New workout (no existing record) | **Schedule** | `scheduled` |
| Same `schedule_id`, identical JSON bytes | **Skip** | `skipped` (reason: `unchanged`) |
| Same `schedule_id`, different JSON bytes | **Reschedule** (remove old + schedule new) | `scheduled` |
| Same `schedule_id`, different JSON size | **Reschedule** (remove old + schedule new) | `scheduled` |

### Interpreting the Push Response

The `WorkoutPushResponse` provides accurate counts for all outcomes:

```dart
final response = await pushManager.pushRawWorkouts(workouts);

print('Total submitted: ${response.totalSubmitted}');
print('Successful: ${response.successful}');   // newly scheduled
print('Skipped: ${response.skipped}');         // deduplicated by native
print('Failed: ${response.failed}');           // errors (validation + device not supported)

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
    
  } else if (result.status == WorkoutPushStatus.failed) {
    print("❌ Failed: ${result.errorMessage}");
  }
}
```

### Skip Reasons

The `skipReason` field indicates why the native deduplication layer skipped the workout:

| Reason | Description |
|--------|-------------|
| `unchanged` | JSON byte content is identical — nothing to update |
| `size_changed` | (Would NOT skip — triggers reschedule) |
| `content_changed` | (Would NOT skip — triggers reschedule) |
| `date_outside_window` | Scheduled date is in the past or beyond 7 days |

### Possible Statuses

| Status | Source | Description |
|--------|--------|-------------|
| `success` / `scheduled` | Native | Successfully scheduled on Apple Watch |
| `skipped` | Native | Identical workout already scheduled (dedup) |
| `validationError` | Dart or Native | Missing/invalid required fields |
| `failed` | Dart or Native | General failure (network, builder, etc.) |
| `device_not_supported` | Native | `WorkoutScheduler.isSupported` returned `false` |

### Clearing the Deduplication Cache

To force a full re-sync on the next push, clear the native deduplication cache:

```dart
final cleared = await pushManager.clearDeduplicationCache();
// Returns true if native cache was successfully cleared
```

### Tracking with WorkoutPlan.id

Each scheduled workout receives a stable UUID from Apple's `WorkoutPlan.id`. This ID:
- Persists across app restarts
- Allows matching scheduled workouts with your records
- Is available in both `WorkoutPushResult.workoutPlanId` and `ScheduledWorkoutInfo.workoutPlanId`
- Can be used with `removeScheduledWorkouts()` to remove specific workouts

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

// Or remove specific workouts by their WorkoutPlan IDs
final results = await pushManager.removeScheduledWorkouts(
  ['plan-uuid-1', 'plan-uuid-2'],
);
```

---

## Background Delivery Manager (API Configuration)

Both the **Workout** and **Sleep** subsystems support configurable background delivery — either pushing data directly to your backend API via native HTTP POST, or storing locally for retrieval on next app open.

### Unified Architecture

Both subsystems share the same foreground/background query strategy regardless of delivery mode:

| App State | Query Technology | Always Runs |
|-----------|-----------------|-------------|
| **Foreground** | `HKAnchoredObjectQueryDescriptor` | Yes — both modes |
| **Background** | `HKObserverQuery` + `enableBackgroundDelivery()` | Yes — both modes |

The **delivery mode** only controls how data is routed after it's received:

| Delivery Mode | Foreground Behavior | Background Behavior |
|---------------|--------------------|--------------------|  
| **API** | Data accumulated → native HTTP POST on completion | Data accumulated → native HTTP POST on completion |
| **localStorage** | Push to Flutter EventChannel in real-time | Store in UserDefaults for later retrieval |

### Configuration Persistence

All delivery configuration (`mode`, `apiURL`, `headers`) is persisted to `UserDefaults` and survives app restarts. This is critical because HealthKit background observers can fire when iOS relaunches your app.

| Subsystem | UserDefaults Keys |
|-----------|------------------|
| **Workouts** | `HumangoDeliveryMode`, `HumangoDeliveryURL`, `HumangoDeliveryHeaders` |
| **Sleep** | `com.humango.health.sleepDeliveryMode`, `com.humango.health.sleepDeliveryURL`, `com.humango.health.sleepDeliveryHeaders` |

### Auto-Start Monitoring

Once API delivery is configured, monitoring **auto-starts on every subsequent app launch** — no Flutter `startMonitoring()` call is needed.

**How it works:**

```
App Launch / Background Wake
        │
        ▼
HumangoHealthPlugin.register()
        │
        ▼
Check UserDefaults:
  ┌─ Workout API URL configured? ──→ Yes → Auto-start WorkoutService (24h lookback)
  └─ Sleep API URL configured?   ──→ Yes → Auto-start SleepDataManager (12h lookback)
                                  ──→ No  → No-op (wait for Flutter to configure)
```

**First launch:** No monitoring starts — UserDefaults is empty. Flutter must call `configureBackgroundDelivery()` and/or `configureSleepBackgroundDelivery()` with API details. This also **immediately starts monitoring** after configuration.

**Subsequent launches:** The persisted API config is detected at plugin registration time → monitoring starts automatically in the correct mode (foreground `HKAnchoredObjectQueryDescriptor` or background `HKObserverQuery` based on current app state).

**Default lookback windows:**

| Subsystem | Auto-Start Lookback | Rationale |
|-----------|-------------------|-----------|
| **Workouts** | 24 hours | Covers any workout data missed during downtime |
| **Sleep** | 12 hours | Aligns with the freeze window (12 AM – 12 PM) |

**Stopping auto-start:** To disable auto-start (e.g., on user logout), switch back to localStorage mode:

```dart
// This clears the API config from UserDefaults, stopping auto-start on next launch
await workoutManager.configureBackgroundDelivery(
  BackgroundDeliveryConfig(mode: BackgroundDeliveryMode.localStorage),
);
await sleepManager.configureSleepBackgroundDelivery(
  SleepBackgroundDeliveryConfig(mode: SleepBackgroundDeliveryMode.localStorage),
);
```

---

### Workout API Configuration

#### Delivery Modes

| Mode | Description |
|------|-------------|
| `BackgroundDeliveryMode.api` | Native iOS directly POSTs workout JSON to your configured API endpoint. |
| `BackgroundDeliveryMode.localStorage` | Stores workout JSON in `UserDefaults`. Retrieve on next app open via `getLocalWorkouts()`. |

#### How It Works

**API mode:**
- Workouts are **always** pushed directly to your API endpoint via native HTTP POST — whether the app is in the foreground or background. Flutter's event stream is bypassed entirely.

**localStorage mode (default):**
- **Foreground:** Workouts are pushed to Flutter's `workoutStream` via EventChannel in real-time.
- **Background:** HealthKit wakes the app via `HKObserverQuery`. Workouts are stored in `UserDefaults`. Call `getLocalWorkouts()` to retrieve them.

#### Configuring Workout API Mode

```dart
import 'package:humango_health/humango_health.dart';

final workoutManager = WorkoutReadManager();

void configureWorkoutAPIDelivery() async {
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
- The `apiURL` and `headers` are persisted to `UserDefaults`, surviving app restarts.
- **All** detected workouts (foreground and background) are pushed via native HTTP POST.
- On HTTP 2xx, the workout is marked as pushed in `WorkoutRecordStore` to prevent duplicates.
- On failure, the error is logged natively.

#### Configuring Workout Local Storage Mode

```dart
void configureWorkoutLocalDelivery() async {
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
    print('Retrieved pending workout: $workoutJson');
  }
  // Local storage is automatically cleared after retrieval
}
```

#### Recommended Workout Setup

Call `configureBackgroundDelivery` early in your app lifecycle (e.g., after login). **Monitoring starts automatically** — no need to call `startMonitoring()` in API mode:

```dart
void initWorkoutMonitoring() async {
  // Configure API delivery — monitoring starts automatically.
  // On subsequent app launches, monitoring auto-starts from UserDefaults config.
  await workoutManager.configureBackgroundDelivery(
    BackgroundDeliveryConfig(
      mode: BackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/workouts/ingest',
      headers: {'Authorization': 'Bearer $authToken'},
    ),
  );
  
  // That's it! No startMonitoring() call needed in API mode.
  // The native iOS layer auto-starts with a 24h lookback window.
}
```

---

### Sleep API Configuration

#### Delivery Modes

| Mode | Description |
|------|-------------|
| `SleepBackgroundDeliveryMode.api` | Finalized sleep sessions are POSTed directly to your configured API endpoint. |
| `SleepBackgroundDeliveryMode.localStorage` | Default — foreground pushes to EventChannel, background stores in UserDefaults. |

#### How It Works

Sleep delivery differs from workouts because sleep data is **accumulated over the entire night** and delivered as a **single finalized session** (not individual samples).

**API mode:**
- **Foreground:** `HKAnchoredObjectQueryDescriptor` receives live samples → accumulated into session state (NOT pushed to EventChannel)
- **Background:** `HKObserverQuery` fires → samples fetched and accumulated into session state
- **In both cases:** When the session detector determines sleep has ended (multi-factor scoring), the complete session is POSTed to your API
- Falls back to local storage on API failure (non-2xx or network error)
- The `sleepDataStream` still emits `sleepSessionEnded` events for awareness

**localStorage mode (default):**
- **Foreground:** Individual sleep samples pushed to Flutter's `sleepDataStream` via EventChannel
- **Background:** Data stored in UserDefaults for later retrieval
- Finalized sessions stored locally; retrieve via `getLocalSleepSessions()`

#### Sleep Session Detection

Before configuring delivery, you can optionally configure the **session detection algorithm** (freeze-window approach). The detector uses multi-factor scoring to determine when a sleep session has ended:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `freezeWindowStartHour` | 0 (midnight) | Local hour when freeze window opens |
| `freezeWindowEndHour` | 12 (noon) | Local hour when freeze window closes |
| `minimumSleepMinutes` | 240 (4 hrs) | Minimum sleep time before session can end |
| `stalenessThresholdMinutes` | 60 | Minutes of no new data → stale |
| `deepSleepAbsenceWindowMinutes` | 90 | No deep sleep in this window = late sleep |

**Session ends when ALL conditions are met (during freeze window):**
1. Minimum 4 hours of accumulated sleep
2. No deep sleep in the last 90 minutes
3. No new segments for ≥ 60 minutes (staleness)
4. Current time is within the freeze window (12 AM – 12 PM)

**After freeze window ends (12 PM):** session is auto-finalized.

```dart
void configureSleepDetection() async {
  await sleepManager.configureSleepSession(
    freezeWindowStartHour: 0,
    freezeWindowEndHour: 12,
    minimumSleepMinutes: 240,
    stalenessThresholdMinutes: 60,
    deepSleepAbsenceWindowMinutes: 90,
  );
}
```

#### Configuring Sleep API Mode

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void configureSleepAPIDelivery() async {
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/sleep-sessions',
      headers: {
        'Authorization': 'Bearer <your-auth-token>',
        'X-Device-Id': '<device-identifier>',
      },
    ),
  );
}
```

**What happens natively:**
- Configuration persists to `UserDefaults`, surviving app restarts.
- Foreground uses `HKAnchoredObjectQueryDescriptor`, background uses `HKObserverQuery` — **same query strategy as localStorage mode**.
- In API mode, samples are accumulated into session state instead of being pushed to Flutter's EventChannel.
- When the sleep session ends (multi-factor scoring or freeze window expiry), the **complete session** is POSTed to your API.
- On HTTP 2xx: success logged.
- On failure: session data falls back to local storage.

#### Sleep API Request Payload

When a sleep session is finalized, the following JSON is POSTed:

```json
{
  "samples": [ ... ],
  "sampleCount": 19,
  "totalSleepSeconds": 28260.0,
  "totalSleepMinutes": 471.0,
  "totalSleepHours": 7.85,
  "stageTotals": {
    "asleepCore": { "seconds": 16800.0, "minutes": 280.0 },
    "asleepDeep": { "seconds": 3600.0, "minutes": 60.0 },
    "asleepREM": { "seconds": 7860.0, "minutes": 131.0 },
    "awake": { "seconds": 900.0, "minutes": 15.0 },
    "inBed": { "seconds": 0.0, "minutes": 0.0 },
    "asleepUnspecified": { "seconds": 0.0, "minutes": 0.0 }
  },
  "fetchedFrom": "2026-03-04T22:00:00.000Z",
  "fetchedTo": "2026-03-05T06:00:00.000Z",
  "reason": "sleep>=471m, no_deep_sleep_recently, stale_65m",
  "segmentCount": 19,
  "isFinalized": true,
  "finalizedAt": "2026-03-05T06:05:00.000Z",
  "sessionStartDate": "2026-03-04T22:00:00.000Z",
  "latestSegmentEndDate": "2026-03-05T05:00:00.000Z"
}
```

#### Configuring Sleep Local Storage Mode

```dart
void configureSleepLocalDelivery() async {
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.localStorage,
    ),
  );
}
```

Retrieve stored sessions on app startup:

```dart
void fetchPendingSleepSessions() async {
  final sessions = await sleepManager.getLocalSleepSessions();
  
  for (final sessionJson in sessions) {
    print('Retrieved sleep session: ${sessionJson.substring(0, 100)}...');
  }
  // Local storage is cleared after retrieval
}
```

#### Recommended Sleep Setup

```dart
void initSleepMonitoring() async {
  // 1. Configure session detection parameters (optional — defaults are sensible)
  await sleepManager.configureSleepSession(
    freezeWindowStartHour: 0,
    freezeWindowEndHour: 12,
    minimumSleepMinutes: 240,
  );

  // 2. Configure API delivery mode — monitoring starts automatically.
  // On subsequent app launches, monitoring auto-starts from UserDefaults config
  // with a 12h lookback window.
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/sleep-sessions',
      headers: {'Authorization': 'Bearer $authToken'},
    ),
  );

  // That's it! No startMonitoring() call needed in API mode.
  // Optionally listen for session-ended events:
  sleepManager.sleepDataStream.listen((event) {
    if (event.type == SleepDataEventType.sleepSessionEnded) {
      print('Sleep session ended!');
      sleepManager.resetSleepSession();
    }
  });
}
```

---

### Combined Setup (Both Workouts + Sleep)

For apps that need both workout and sleep API delivery, configure them together after login:

```dart
import 'package:humango_health/humango_health.dart';

final workoutManager = WorkoutReadManager();
final sleepManager = SleepDataManager();

void initAllHealthMonitoring(String authToken) async {
  // ── Workout API delivery (auto-starts monitoring) ──
  await workoutManager.configureBackgroundDelivery(
    BackgroundDeliveryConfig(
      mode: BackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/workouts/ingest',
      headers: {
        'Authorization': 'Bearer $authToken',
        'Content-Type': 'application/json',
      },
    ),
  );

  // ── Sleep API delivery (auto-starts monitoring) ──
  await sleepManager.configureSleepSession();
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/sleep-sessions',
      headers: {
        'Authorization': 'Bearer $authToken',
        'Content-Type': 'application/json',
      },
    ),
  );

  // No startMonitoring() calls needed! Both auto-start in API mode.
  // On subsequent app launches, monitoring resumes automatically from UserDefaults.

  // ── Optional: Listen for events ──
  sleepManager.sleepDataStream.listen((event) {
    if (event.type == SleepDataEventType.sleepSessionEnded) {
      sleepManager.resetSleepSession();
    }
  });
}
```

> **Note:** Both subsystems auto-switch between `HKAnchoredObjectQueryDescriptor` (foreground) and `HKObserverQuery` (background) via the native `AppLifecycleManager`. No Flutter lifecycle code is needed. Monitoring auto-starts on app launch when API delivery is configured.

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

The workout reading subsystem implements native deduplication:

| Location | Strategy |
|----------|----------|
| iOS (`WorkoutRecordStore`) | SHA256 hash + byte-level comparison |

Workout scheduling deduplication is handled entirely at the native iOS layer via `ScheduledWorkoutStore` (sorted-key JSON byte comparison). There is no Dart-side storage for scheduling.

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
| `com.humango.workouts/workoutplan` | MethodChannel | Workout scheduling (push/remove) |
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