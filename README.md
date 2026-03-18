# Humango Health Plugin

A comprehensive Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform.

> **Version 0.0.8** — See [CHANGELOG](CHANGELOG.md) for what's new.

## Table of Contents

- [Features](#features)
- [Architecture Overview](#architecture-overview)
- [Requirements](#requirements)
- [User Session Management](#user-session-management)
- [Permission Handling](#permission-handling)
- [Workout Scheduling (Push)](#push-workouts-scheduling)
  - [Swimming Workouts & Pool Size](#swimming-workouts--pool-size)
  - [Removing Scheduled Workouts](#removing-scheduled-workouts)
  - [Remove All Scheduled Workouts](#remove-all-scheduled-workouts)
- [Workout Reading & Monitoring](#workout-reading--monitoring)
- [Background Delivery Manager (Workouts + Sleep)](#background-delivery-manager-api-configuration)
- [Sleep Data Reading & Monitoring](#sleep-data-reading--monitoring)
- [Health Metrics Reading](#health-metrics-reading)
- [Native iOS Lifecycle Management](#native-ios-lifecycle-management)

## Features

| Feature | Description |
|---------|-------------|
| **User Session Management** | Login/logout gate for all background observers with automatic data cleanup on logout |
| **Permission Handling** | Request, verify, and continuously monitor HealthKit permissions |
| **Workout Scheduling** | Push workouts to Apple Watch via WorkoutKit with native deduplication |
| **Workout Reading** | Real-time workout monitoring with foreground/background modes |
| **Sleep Data** | Fetch and monitor sleep analysis with foreground (Descriptor) + background (Observer) monitoring; inBed-check pipeline with 15-min re-check timer; flat aggregated payload delivered via API or local storage |
| **Health Metrics (HRV)** | One-shot fetch plus automatic HRV updates in foreground, background, and when app is suspended (stream + pending retrieval) |
| **Background Delivery** | Native iOS background processing with API or local storage delivery (workouts + sleep) |
| **Native Lifecycle Management** | Centralized iOS app lifecycle detection for automatic mode switching |

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    Flutter Application Layer                     │
│  ├─ UserSessionManager (login/logout gate)                       │
│  ├─ PermissionManager (permissions)                              │
│  ├─ WorkoutPushManager (scheduling)                              │
│  ├─ WorkoutReadManager (reading/monitoring)                      │
│  └─ SleepDataManager (sleep data)                                │
└──────────────────────────┬───────────────────────────────────────┘
                           │ Method Channels + Event Channels
┌──────────────────────────┴───────────────────────────────────────┐
│                    iOS Native Layer                              │
│  ├─ UserAuthStateManager (login gate + logout cleanup)           │
│  ├─ AppLifecycleManager (centralized lifecycle notifications)    │
│  ├─ PermissionManager (HealthKit authorization)                  │
│  ├─ WorkoutSchedulingService (WorkoutKit integration)            │
│  ├─ WorkoutService (HKAnchoredObjectQuery + HKObserverQuery)     │
│  ├─ SleepDataManager (foreground Descriptor + background Observer + inBed pipeline) │
│  ├─ SleepRemoteLogger (fire-and-forget remote logging for background pipeline)      │
│  ├─ HRVObserverManager (HRV background delivery + foreground stream)               │
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

## User Session Management

The library uses a **user session gate** to prevent background health observers from auto-starting before the user has logged in, and to cleanly wipe all stored data on logout.

### Why This Matters

The plugin persists background delivery configuration (API URL, headers, mode) across app launches so that HealthKit observers can auto-restart even when iOS relaunches the app in the background. Without a session gate:

- A freshly installed app (no user yet) would attempt to start background observers on every launch.
- After logout, background observers would continue running and posting data to the previous user's API endpoint.

The `UserSessionManager` solves both problems with a single boolean persisted in `UserDefaults`.

---

### App-Launch Decision Flow

```
App Launch / Background Wake
        │
        ▼
HumangoHealthPlugin.register()
        │
        ▼
┌─────────────────────────────────────────────────────┐
│  UserAuthStateManager.isLoggedIn?                   │
│                                                     │
│  false ──→ Skip all auto-start                      │
│            (no observers started)                   │
│                                                     │
│  true  ──→ Check API configuration                  │
│              │                                      │
│              ├─ Workout API configured? ──→ Auto-start WorkoutService (24h lookback)
│              │                          ──→ Not configured → no-op
│              │                                      │
│              └─ Sleep API configured?   ──→ Auto-start SleepDataManager (12h lookback)
│                                         ──→ Not configured → no-op
└─────────────────────────────────────────────────────┘
```

### Case 1 — Logged In, No Background Configuration

```
User installs app
  → Logs in → setUserLoggedIn(true)
  → Sleep/workout background API NOT configured
  → Kills app

Next launch:
  → isLoggedIn = true  ✅
  → isAPIConfigured = false  → auto-start skipped ✅
  → Done — no observers running
```

### Case 2 — Logged In, Background Configuration Present

```
User installs app
  → Logs in → setUserLoggedIn(true)
  → Configures sleep/workout API → monitoring starts immediately
  → Kills app

Next launch:
  → isLoggedIn = true  ✅
  → isAPIConfigured = true  → auto-start begins ✅
  → Sleep and workout observers resume automatically
```

### Logout Cleanup — What Gets Cleared

Calling `setUserLoggedIn(false)` immediately and synchronously clears all of the following:

| Data | What Is Cleared |
|------|-----------------|
| **Workout background config** | API URL, headers, delivery mode (`BackgroundDeliveryManager`) |
| **Sleep background config** | API URL, headers, delivery mode, pending local sleep data (`SleepBackgroundDeliveryManager`) |
| **Stored sleep data** | Sleep samples stored in `UserDefaults` during background monitoring |
| **Sleep in-bed timer** | Cancels any pending 15-min re-check timer (`SleepDataManager.inBedCheckTimer`) |
| **Scheduled workouts** | All workouts in `ScheduledWorkoutStore` (Apple Watch scheduled workouts cache) |
| **Workout record store** | All push-dedup tracking records in `WorkoutRecordStore` |
| **Active monitors** | All running `HKObserverQuery` and `HKAnchoredObjectQueryDescriptor` tasks stopped |

> **Note:** `UserDefaultskeys.isLoggedIn` is set to `false` immediately so that if the app is relaunched before the user logs in again, no auto-start occurs.

---

### API Reference

```dart
import 'package:humango_health/humango_health.dart';

// After a successful login — optionally supply userId for tagged remote log events
await UserSessionManager.setUserLoggedIn(true, userId: 'user-abc123');

// After logout
await UserSessionManager.setUserLoggedIn(false);
```

### Recommended Integration

```dart
import 'package:humango_health/humango_health.dart';

class AuthService {
  /// Call after a successful login (token received, user identity confirmed).
  Future<void> onLoginSuccess() async {
    // 1. Mark the user as logged in — unblocks background observer auto-start.
    //    Supply userId so background loggers can tag remote log events with this user.
    await UserSessionManager.setUserLoggedIn(true, userId: userId);

    // 2. Configure background delivery (starts monitoring immediately)
    await WorkoutReadManager().configureBackgroundDelivery(
      BackgroundDeliveryConfig(
        mode: BackgroundDeliveryMode.api,
        apiURL: 'https://api.example.com/v1/workouts/ingest',
        headers: {'Authorization': 'Bearer $authToken'},
      ),
    );

    await SleepDataManager().configureSleepBackgroundDelivery(
      SleepBackgroundDeliveryConfig(
        mode: SleepBackgroundDeliveryMode.api,
        apiURL: 'https://api.example.com/v1/sleep-sessions',
        headers: {'Authorization': 'Bearer $authToken'},
      ),
    );
  }

  /// Call after the user logs out (token invalidated / session ended).
  Future<void> onLogout() async {
    // Single call — stops all background observers, clears all stored data
    // and API configuration. On next app launch, nothing auto-starts.
    await UserSessionManager.setUserLoggedIn(false);
  }
}
```

> **Important:** Always call `setUserLoggedIn(true)` **before** calling `configureBackgroundDelivery()` or `configureSleepBackgroundDelivery()`. The login flag must be set first so that if the app is killed and relaunched immediately, the auto-start logic finds both `isLoggedIn=true` and the API config in place.

---

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

### Apple's Strict Privacy Rules (Must Read)
When building systems dependent on HealthKit, you must understand two core iOS behaviors:

1. **The "One-Time Prompt" Rule**: iOS will only *ever* show the HealthKit permission popup **once** per device. If the user taps "Don't Allow," you **cannot** trigger the sheet again via code. Calling `requestAuthorization()` again returns success silently without showing the prompt.
2. **The "Blind Read" Rule**: Apple protects user privacy by making it impossible to check if a user explicitly denied `Read` access. A denied read permission simply behaves as if there is no data. You can only infer denial by checking whether data queries return empty results.

**Handling Denials:** Because you cannot show the prompt twice, if you determine that a user is missing permissions, your app must show a custom Flutter UI explaining why access is needed, and provide a button to deep-link the user into **iOS Settings → Health → Data Access & Devices** to toggle the switches manually.

### Tracked Health Types

The plugin tracks a **fixed, hardcoded** set of HealthKit types — types are not user-configurable. The following `HealthDataType` values are reported in every `HealthKitAuthorizationResult`:

| `HealthDataType` | HealthKit type |
|-----------------|----------------|
| `workout` | `HKWorkoutType` |
| `heartRate` | `HKQuantityTypeIdentifierHeartRate` |
| `hrv` | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` |
| `restingHeartRate` | `HKQuantityTypeIdentifierRestingHeartRate` |
| `steps` | `HKQuantityTypeIdentifierStepCount` |
| `activeCalories` | `HKQuantityTypeIdentifierActiveEnergyBurned` |
| `distance` | `HKQuantityTypeIdentifierDistanceWalkingRunning` |
| `sleepAnalysis` | `HKCategoryTypeIdentifierSleepAnalysis` |
| `bodyMass` | `HKQuantityTypeIdentifierBodyMass` |
| `height` | `HKQuantityTypeIdentifierHeight` |
| `bodyFatPercentage` | `HKQuantityTypeIdentifierBodyFatPercentage` |

### Permission Status Values

`PermissionStatus` values returned per data type:

| Status | Meaning |
|--------|---------|
| `unknown` | Permission has never been requested — user hasn't seen the HealthKit prompt yet |
| `authorized` | Permission granted and data confirmed present in HealthKit |
| `noData` | Permission was granted, but no data of this type exists in HealthKit yet |
| `denied` | Permission was denied or was previously granted then revoked in Settings |

> `noData` is **not** the same as denied — the user likely granted access but simply has no recorded data of that type. Use `PermissionStatus.denied` as your gate, not `noData`.

### 1. Requesting Authorization

Call this once on first launch. It shows Apple's native HealthKit permission sheet (fire-and-forget — iOS displays the modal independently). Subsequent calls are silently ignored by iOS if the prompt has already been shown.

```dart
import 'package:humango_health/humango_health.dart';

final permissionManager = PermissionManager();

void requestPermissions() async {
  await permissionManager.requestAuthorization();
  // iOS will surface the permissions dialog to the user here.
  // Subscribe to permissionStream to react to the result.
}
```

### 2. Verification

Manually check the current iOS authorization status at any point:

```dart
final result = await permissionManager.verifyAuthorization();

if (result.isLikelyFullyGranted) {
  print('All permissions granted (or no data yet).');
} else if (result.hasAnyDenied) {
  print('One or more permissions denied — prompt user to go to Settings.');
}

// Inspect individual types
final heartRateStatus = result.statuses[HealthDataType.heartRate];
if (heartRateStatus == PermissionStatus.authorized) {
  print('Heart rate: authorized with data present.');
} else if (heartRateStatus == PermissionStatus.noData) {
  print('Heart rate: authorized but no data recorded yet.');
}
```

`HealthKitAuthorizationResult` helper getters:

| Getter | Returns `true` when… |
|--------|----------------------|
| `isAuthorized` | Overall authorization succeeded (sheet was accepted) |
| `isLikelyFullyGranted` | All tracked types are `authorized` or `noData` |
| `hasAnyDenied` | At least one type has `denied` status |
| `hasAnyNoData` | At least one type has `noData` status |
| `hasAnyUnknown` | At least one type has `unknown` status (prompt not yet shown) |

### 3. Listening (Continuous Monitoring)

Because users can leave your app, toggle permissions in iOS Settings, and return, subscribe to `permissionStream`. It is backed by `UIApplication.didBecomeActiveNotification` so your Dart logic automatically reacts every time the app comes to the foreground.

```dart
import 'dart:async';
import 'package:humango_health/humango_health.dart';

StreamSubscription? _sub;

void startListening() {
  _sub = permissionManager.permissionStream.listen(
    (HealthKitAuthorizationResult result) {
      if (result.hasAnyDenied) {
        // Show UI guiding user to iOS Settings → Health
      } else if (result.isLikelyFullyGranted) {
        // All good — proceed with data access
      }

      // Inspect per-type status
      result.statuses.forEach((type, status) {
        print('$type → ${status.name}');
      });
    },
  );
}

void dispose() {
  _sub?.cancel();
}
```

See the `example/` app directory for a complete working demonstration.

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

The native deduplication engine compares the SHA-256 hash of the sorted-key JSON alongside the scheduled date, keyed by `schedule_id`, to ensure workouts aren't duplicated if users click sync multiple times.

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
      print("   WorkoutPlan ID : ${result.workoutPlanId}");
      print("   Pushed JSON    : ${result.currentJson}");   // full workout JSON that was scheduled
    } else if (result.status == WorkoutPushStatus.skipped) {
      print("⏭️ Skipped (Already cached natively): ${result.workoutId}");
      print("   Skip reason    : ${result.skipReason}");
      print("   Incoming JSON  : ${result.currentJson}");   // always present
      print("   Stored JSON    : ${result.existingJson}");  // only when reason == 'unchanged'
      print("   Incoming hash  : ${result.currentJsonHash}");
      print("   Stored hash    : ${result.existingJsonHash}");
    } else if (result.status == WorkoutPushStatus.validationError) {
      print("❌ Validation Error: ${result.errorMessage}");
      print("   Failed JSON    : ${result.currentJson}");   // the workout that failed validation
    } else if (result.status == WorkoutPushStatus.failed) {
      print("❌ Failed: ${result.errorMessage}");
      print("   Failed JSON    : ${result.currentJson}");   // the workout that could not be scheduled
    }
  }
}
```

### Swimming Workouts & Pool Size

Swimming workouts are routed to `SingleGoalWorkout` (WorkoutKit's pool swim type). You must tell the plugin the pool lane length so it sets the correct unit on Apple Watch.

Include `"pool_size"` as a **top-level key** alongside `schedule_id`, `date`, and `blocks`.

#### Pool Size Rules

| `pool_size` value | Unit sent to Apple Watch |
|-------------------|--------------------------|
| `null` / key absent | **Meters** (default) |
| `"25m"`, `"50m"` (contains `"m"`) | **Meters** |
| `"25y"`, `"50y"` (no `"m"`) | **Yards** |

#### Sample JSON — 25 m Pool Swim

```dart
final List<Map<String, dynamic>> swimmingWorkout = [
  {
    "schedule_id": 98765,
    "date": DateTime.now().add(const Duration(hours: 3)).toIso8601String(),
    "sport": "SWIMMING",
    "distance": 1500.0,   // total distance in metres
    "duration": 3600,     // total duration in seconds
    "pool_size": "25m",   // ← 25-metre pool (omit or set "50m" for a 50 m pool)
    "summary": {
      "name": "Morning Pool Swim",
      "sport": "SWIMMING",
      "indoor_outdoor": "INDOOR",
      "measurement_unit": "meter"
    },
    "blocks": [
      {
        "type": "WARMUP",
        "distance": 200.0,
        "duration": 300,
        "measurement_unit": "meter"
      },
      {
        "type": "INTERVAL",
        "distance": 1000.0,
        "duration": 2400,
        "measurement_unit": "meter",
        "zone_unit": "HR",
        "target_range": {"low": 130, "high": 160}
      },
      {
        "type": "COOLDOWN",
        "distance": 300.0,
        "duration": 600,
        "measurement_unit": "meter"
      }
    ]
  }
];

final response = await pushManager.pushRawWorkouts(swimmingWorkout);
```

#### Sample JSON — 25 yd Pool Swim (yards)

```dart
{
  "schedule_id": 98766,
  "date": "2026-03-12T09:00:00.000Z",
  "sport": "SWIMMING",
  "distance": 1650.0,
  "duration": 3600,
  "pool_size": "25y",   // ← yards pool
  "summary": {
    "name": "Yards Pool Swim",
    "sport": "SWIMMING",
    "indoor_outdoor": "INDOOR",
    "measurement_unit": "yard"
  },
  "blocks": [
    {
      "type": "WARMUP",
      "distance": 200.0,
      "duration": 360,
      "measurement_unit": "yard"
    },
    {
      "type": "INTERVAL",
      "distance": 1200.0,
      "duration": 2520,
      "measurement_unit": "yard",
      "zone_unit": "HR",
      "target_range": {"low": 130, "high": 165}
    },
    {
      "type": "COOLDOWN",
      "distance": 250.0,
      "duration": 420,
      "measurement_unit": "yard"
    }
  ]
}
```

> **Note:** If `pool_size` is absent or `null`, the plugin defaults to **meters**. The `pool_size` key takes precedence over `summary.measurement_unit` — so always set `pool_size` explicitly for swimming workouts.

---

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
- `jsonHash`: SHA-256 hex hash of the stored JSON payload

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

### Remove All Scheduled Workouts

To do a **full reset** — remove every scheduled workout from Apple Watch **and** clear the entire local `ScheduledWorkoutStore` in a single native call — use `removeAllScheduledWorkouts()`.

This is preferred over the manual get → remove → clear sequence when you want a clean slate:

```dart
final pushManager = WorkoutPushManager();

void removeAll() async {
  final response = await pushManager.removeAllScheduledWorkouts();

  final removedFromWatch  = response['removedFromWatch']  as int;    // workouts removed from Apple Watch
  final localCleared      = response['localRecordsCleared'] as int;  // local store records cleared
  final storeCleared      = response['storeCleared']      as bool;   // always true on success

  print('Removed $removedFromWatch workout(s) from Apple Watch');
  print('Cleared $localCleared local record(s)');

  // Optional: check for errors
  if (response.containsKey('error')) {
    print('Error: ${response["error"]}');
  }
}
```

**Response fields:**

| Field | Type | Description |
|-------|------|-------------|
| `removedFromWatch` | `int` | Number of workouts removed from Apple Watch via `WorkoutScheduler` |
| `storeCleared` | `bool` | `true` if the local `ScheduledWorkoutStore` was cleared |
| `localRecordsCleared` | `int` | Number of local deduplication records that were cleared |
| `error` | `String?` | Only present if the call failed; describes the error |

> **Note:** A workout on Apple Watch that has no matching local record (e.g. scheduled from another device or a previous app install) is still removed from Apple Watch and counted in `removedFromWatch`. Requires iOS 17.0+.

### Native Deduplication

All deduplication is handled entirely at the **native iOS layer** via `ScheduledWorkoutStore`. There is **no Dart-side deduplication logic**. The single source of truth is a `UserDefaults`-backed store keyed by `schedule_id`.

---

#### Deduplication Flow (Step by Step)

When `pushRawWorkouts()` is called, for each workout in the batch the native layer runs through the following pipeline:

```
Incoming workout JSON
        │
        ▼
┌─────────────────────────────────────┐
│ 1. Dart-side field validation       │
│    • schedule_id present?           │
│    • date present + valid ISO8601?  │
│    • blocks present + non-empty?    │
└──────────────┬──────────────────────┘
               │ FAIL → status: validationError
               │         errorMessage: "Missing required field: ..."
               │         currentJson: <the invalid workout>
               │
               │ PASS ↓
               ▼
┌─────────────────────────────────────┐
│ 2. Device support check (native)    │
│    WorkoutScheduler.isSupported     │
└──────────────┬──────────────────────┘
               │ NOT SUPPORTED → status: device_not_supported
               │                 errorMessage: reason string
               │
               │ SUPPORTED ↓
               ▼
┌─────────────────────────────────────┐
│ 3. Date window check (native)       │
│    Must be: now < date ≤ now+7days  │
└──────────────┬──────────────────────┘
               │ OUTSIDE WINDOW → status: skipped
               │                  skipReason: "date_outside_window"
               │
               │ INSIDE WINDOW ↓
               ▼
┌─────────────────────────────────────┐
│ 4. Look up existing record          │
│    ScheduledWorkoutStore[schedule_id]│
└──────────────┬──────────────────────┘
               │ NOT FOUND → schedule as NEW → status: success
               │                               workoutPlanId: <Apple UUID>
               │
               │ FOUND ↓
               ▼
┌─────────────────────────────────────────────────────┐
│ 5. Stage 1 — Scheduled date comparison              │
│    existing.scheduledDate vs incoming date          │
│    (compared at second precision)                   │
└──────────────┬──────────────────────────────────────┘
               │ DIFFERENT → reschedule (remove old + schedule new)
               │             status: success
               │             (internal reason: "date_changed")
               │
               │ SAME ↓
               ▼
┌─────────────────────────────────────────────────────┐
│ 6. Stage 2 — SHA-256 hash comparison                │
│    Serialize incoming JSON with .sortedKeys         │
│    → SHA256(bytes) vs existing.jsonHash             │
└──────────────┬──────────────────────────────────────┘
               │ DIFFERENT → reschedule (remove old + schedule new)
               │             status: success
               │             (internal reason: "content_changed")
               │
               │ IDENTICAL ↓
               ▼
        status: skipped
        skipReason: "unchanged"
        currentJsonHash / existingJsonHash returned for inspection
```

---

#### What is Returned for Each Outcome

Every `pushRawWorkouts()` call returns a `WorkoutPushResponse` containing two things:
- **Summary counts** (`successful`, `skipped`, `failed`, `totalSubmitted`)
- **Per-workout `results`** — a `List<WorkoutPushResult>` with full detail for each workout

##### `WorkoutPushResult` — field availability per status

| Field | `success` | `skipped`<br>`(unchanged)` | `skipped`<br>`(date_outside_window)` | `validationError` | `failed` |
|-------|:---------:|:--------------------------:|:------------------------------------:|:-----------------:|:--------:|
| `scheduleId` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `workoutId` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `status` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `currentJson` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `workoutPlanId` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `skipReason` | ❌ | ✅ `"unchanged"` | ✅ `"date_outside_window"` | ❌ | ❌ |
| `existingJson` | ❌ | ✅ | ❌ | ❌ | ❌ |
| `currentJsonHash` | ❌ | ✅ | ❌ | ❌ | ❌ |
| `existingJsonHash` | ❌ | ✅ | ❌ | ❌ | ❌ |
| `errorMessage` | ❌ | ❌ | ❌ | ✅ | ✅ |

---

#### Status Reference

| Status | Source | Counter | What happened |
|--------|--------|---------|---------------|
| `success` | Native | `successful++` | Workout successfully scheduled on Apple Watch. `workoutPlanId` is populated. |
| `skipped` | Native | `skipped++` | Deduplication determined nothing changed. `skipReason` and hash fields are populated. |
| `validationError` | Dart (pre-send) | `failed++` | Required field missing or invalid. `errorMessage` and `currentJson` are populated. Remaining valid workouts still proceed. |
| `failed` | Native | `failed++` | WorkoutKit scheduling error. `errorMessage` describes the cause. |
| `device_not_supported` | Native | `failed++` | Device does not support WorkoutKit (`WorkoutScheduler.isSupported == false`). |

> **Guaranteed invariant:**
> `response.successful + response.skipped + response.failed == response.totalSubmitted`

---

#### Skip Reason Reference

`skipReason` is only populated when `status == WorkoutPushStatus.skipped`.

| `skipReason` | Meaning |
|--------------|---------|
| `unchanged` | Both the scheduled date and the SHA-256 hash are identical to what is stored — nothing to do |
| `date_outside_window` | The workout's scheduled date is in the past or more than 7 days from now |

> **Note:** `date_changed` and `content_changed` are internal native reasons that trigger a **reschedule** (not a skip) — you will receive `status: success` for those workouts.

---

#### Handling All Outcomes in Code

```dart
final response = await WorkoutPushManager().pushRawWorkouts(workouts);

// Summary
print('Submitted : ${response.totalSubmitted}');
print('Scheduled : ${response.successful}');
print('Skipped   : ${response.skipped}');
print('Failed    : ${response.failed}');

for (final result in response.results) {
  switch (result.status) {

    case WorkoutPushStatus.success:
      // ✅ Workout is now on Apple Watch
      print('✅ Scheduled  schedule_id=${result.scheduleId}');
      print('   Apple plan ID : ${result.workoutPlanId}');
      break;

    case WorkoutPushStatus.skipped:
      // ⏭️ Already up-to-date — native dedup decided nothing changed
      print('⏭️ Skipped  schedule_id=${result.scheduleId}');
      print('   Reason         : ${result.skipReason}');
      // Optional: inspect hashes to confirm
      print('   Stored hash    : ${result.existingJsonHash}');
      print('   Incoming hash  : ${result.currentJsonHash}');
      break;

    case WorkoutPushStatus.validationError:
      // ❌ Missing or invalid field — caught before reaching iOS
      print('❌ Validation error  schedule_id=${result.scheduleId}');
      print('   Error   : ${result.errorMessage}');
      print('   Bad JSON: ${result.currentJson}');
      break;

    case WorkoutPushStatus.failed:
      // ❌ WorkoutKit / native scheduling error
      print('❌ Failed  schedule_id=${result.scheduleId}');
      print('   Error: ${result.errorMessage}');
      break;

    case WorkoutPushStatus.device_not_supported:
      // ⚠️ Device has no Apple Watch or does not support WorkoutKit
      print('⚠️ Not supported  schedule_id=${result.scheduleId}');
      print('   Reason: ${result.errorMessage}');
      break;
  }
}
```

### Computing a Workout JSON Hash

You can ask the native iOS layer to compute the same SHA-256 hash it uses internally for deduplication. This is useful for pre-flight comparisons, diagnostics, or building your own sync logic without duplicating the hashing algorithm in Dart.

```dart
final pushManager = WorkoutPushManager();

final workoutJson = {
  'schedule_id': '8de52c5d-0d04-4db7-8045-208c01cac282',
  'workout_id': 232550,
  'date': '2026-03-15T08:00:00Z',
  'blocks': [ /* ... */ ],
};

final hash = await pushManager.computeWorkoutJsonHash(workoutJson);
// Returns a 64-character lowercase SHA-256 hex string, e.g.:
// "a3f1c2d4e5b6..." — identical to WorkoutPushRecord.jsonHash for the same payload

if (hash != null) {
  print('Hash: $hash');
}
```

**Notes:**
- The hash is computed by native iOS using `CryptoKit.SHA256` on the UTF-8 JSON bytes serialized with sorted keys (`.sortedKeys` option), matching exactly what is stored in `WorkoutPushRecord.jsonHash` after scheduling.
- Returns `null` if JSON serialization fails (e.g. non-serializable values).
- Requires iOS (the method channel is iOS-only).

### Clearing the Deduplication Cache

To force a full re-sync on the next push, clear the native deduplication cache without touching Apple Watch:

```dart
final cleared = await pushManager.clearDeduplicationCache();
// Returns true if native cache was successfully cleared
// Note: does NOT remove workouts from Apple Watch — use removeAllScheduledWorkouts() for a full reset
```

> **Tip:** If you also want to remove the workouts from Apple Watch at the same time, use [`removeAllScheduledWorkouts()`](#remove-all-scheduled-workouts) instead — it clears the local store **and** removes all workouts from Apple Watch in one call.

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

**Stopping auto-start on logout:** Use `UserSessionManager.setUserLoggedIn(false)` — this is the single correct call for logout. It stops all active monitors, clears all API configuration from `UserDefaults`, and wipes all stored data. See [User Session Management](#user-session-management) for the full logout cleanup table.

```dart
// ✅ Correct: single logout call handles everything
await UserSessionManager.setUserLoggedIn(false);
```

---

### Workout API Configuration

#### Delivery Modes

| Mode | Description |
|------|-------------|
| `BackgroundDeliveryMode.api` | Native iOS directly POSTs workout JSON to your configured API endpoint. |
| `BackgroundDeliveryMode.localStorage` | Workouts are pushed to Flutter's `workoutStream` via EventChannel in real-time (foreground). In background, native iOS POSTs to API — `localStorage` mode is no longer supported for background delivery. |

#### How It Works

**API mode:**
- Workouts are **always** pushed directly to your API endpoint via native HTTP POST — whether the app is in the foreground or background. Flutter's event stream is bypassed entirely.

**localStorage mode (default):**
- **Foreground:** Workouts are pushed to Flutter's `workoutStream` via EventChannel in real-time.
- **Background:** Not applicable for background delivery. When background monitoring is required, use `BackgroundDeliveryMode.api` — the native iOS layer will POST workouts directly to your API endpoint.

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

> **Note:** `localStorage` mode delivers workouts via the Flutter `workoutStream` EventChannel while the app is in the foreground. For background delivery (when the app is suspended), configure `BackgroundDeliveryMode.api` instead — the native iOS layer will POST directly to your API without requiring the app to be active.

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
| `SleepBackgroundDeliveryMode.localStorage` | Finalized sleep sessions are stored in UserDefaults; retrieve via `getLocalSleepSessions()`. |

#### How It Works

Sleep delivery differs from workouts because sleep data is **accumulated over the entire night** and delivered as a **single finalized session** (not individual samples).

**API mode:**
- **Foreground:** `HKAnchoredObjectQueryDescriptor` detects new samples → accumulated in background cache
- **Background:** `HKObserverQuery` fires → **inBed check runs first**; if user is in bed, data is cached and a 15-min re-check timer starts; once the user has woken, the aggregated flat payload is built and POSTed

**localStorage mode:**
- **Foreground:** `HKAnchoredObjectQueryDescriptor` accumulates samples into local cache
- **Background:** `HKObserverQuery` fires → same inBed-check pipeline → on wakeup, payload is stored in `UserDefaults`; retrieve via `getLocalSleepSessions()`

#### Background Pipeline (new inBed-check flow)

Every `HKObserverQuery` trigger follows this exact flow:

```
HKObserverQuery fires
  │
  ├─ guard: user must be logged in (UserAuthStateManager.isLoggedIn)
  │
  └─ STEP 1: isUserCurrentlyInBed?  ← checked FIRST, before any HealthKit fetch
       │
       YES ─→ STEP 2: compute 6PM window (6:00 PM previous day → now)
              STEP 3: fetch HealthKit samples
              STEP 4: store in local cache
              → start 15-min re-check timer
                   Timer fires → isUserCurrentlyInBed?
                     YES → wait for next HKObserver trigger (still sleeping)
                     NO  → fetch → buildAggregatedPayload → deliver
       │
       NO  ─→ STEP 2: compute 6PM window
              STEP 3: fetch HealthKit samples
              STEP 4: buildAggregatedPayload → deliver immediately
```

**Query window:** `6:00 PM previous day → now` — matches humango-mobile's `SleepStatisticsManager`.

**Source selection:** when multiple sources contributed data, the source with the highest `TOTAL_SLEEP` (Core + Deep + REM minutes) wins.

**Remote logging:** `SleepRemoteLogger` POSTs a structured JSON event to the Humango logging endpoint at every step of the pipeline (both local `debugPrint` and remote log). The `userId` from `UserAuthStateManager` is attached to every event automatically.

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
- Foreground uses `HKAnchoredObjectQueryDescriptor`, background uses `HKObserverQuery`.
- On every HKObserver trigger, the inBed-check pipeline runs (see above). When the user has woken, `buildAggregatedPayload()` produces a flat 14-key payload which is POSTed to your API.
- On HTTP 2xx: success logged remotely via `SleepRemoteLogger`.
- On failure: session data falls back to local storage.

#### Sleep API Request Payload

When the pipeline determines the user has woken, the following **flat** JSON is POSTed. All duration values are in **minutes**:

```json
{
  "SOURCE":            "Vinay's Apple Watch",
  "SOURCE_BUNDLE":     "com.apple.health.XXXXXXXXXXXXXXXX",
  "TIMEZONE":          "Asia/Kolkata",
  "TOTAL_SLEEP":       420.0,
  "SLEEP_IN_BED":      0.0,
  "SLEEP_LIGHT":       180.0,
  "SLEEP_DEEP":        60.0,
  "SLEEP_REM":         120.0,
  "SLEEP_UNSPECIFIED": 60.0,
  "SLEEP_AWAKE":       15.0,
  "BED_TIME":          "2026-03-17T22:30:00.000Z",
  "WAKE_TIME":         "2026-03-18T06:15:00.000Z",
  "START_DATE":        "2026-03-17T18:00:00.000Z",
  "END_DATE":          "2026-03-18T06:30:00.000Z"
}
```

`TOTAL_SLEEP = SLEEP_LIGHT + SLEEP_DEEP + SLEEP_REM` (excludes inBed, awake, and unspecified). `SLEEP_IN_BED` will be `0.0` for Apple Watch users — the Watch does not write `inBed` samples.

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
  // Configure API delivery mode — monitoring starts automatically.
  // Session detection is now automatic (inBed-check pipeline) — no
  // configureSleepSession() call is needed.
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/sleep-sessions',
      headers: {'Authorization': 'Bearer $authToken'},
    ),
  );

  // No startMonitoring() call needed in API mode.
  // Monitoring starts automatically on configureSleepBackgroundDelivery.
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
  // No configureSleepSession() needed — detection is automatic (inBed-check pipeline).
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
| `UIApplication.didBecomeActiveNotification` | Switches to **foreground mode** (`HKAnchoredObjectQueryDescriptor`) |
| `UIApplication.didEnterBackgroundNotification` | Switches to **background mode** (observer queries) |

### Benefits

1. **Automatic Mode Switching**: Services automatically switch between foreground (`HKAnchoredObjectQueryDescriptor`) and background (`HKObserverQuery`) modes
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
- **Foreground monitoring**: `HKAnchoredObjectQueryDescriptor` accumulates samples into session state while the app is active
- **Background monitoring**: `HKObserverQuery` detects changes and accumulates samples into session state when the app is suspended
- **Session-aware delivery**: When the session detector determines sleep has ended (multi-factor scoring or freeze-window expiry), the complete session is delivered — either POSTed to your API or stored locally

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

### Foreground Sleep Monitoring

Start monitoring for sleep data changes in the foreground. The native iOS side uses `HKAnchoredObjectQueryDescriptor` to accumulate samples into session state:

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void startSleepMonitoring() async {
  await sleepManager.startMonitoring(
    startDate: DateTime.now().subtract(const Duration(hours: 24)),
  );
  // Samples accumulate on-device; finalized session is delivered
  // via API or stored locally when the session ends.
}

void stopSleepMonitoring() async {
  await sleepManager.stopMonitoring();
}
```

### Background Sleep Monitoring

When the app enters the background, the native `AppLifecycleManager` automatically switches to `HKObserverQuery` mode. New sleep samples are accumulated into the same on-device session state as foreground samples. When the session ends, the finalized session is delivered via your configured delivery mode (API POST or local storage).

To retrieve locally stored finalized sessions when the app next opens:

```dart
void fetchPendingSleepSessions() async {
  // Retrieve finalized sessions stored while app was in background (localStorage mode)
  final sessions = await sleepManager.getLocalSleepSessions();
  
  for (final sessionJson in sessions) {
    print('Retrieved session: ${sessionJson.substring(0, 100)}...');
  }
  // Local storage is cleared after retrieval
}
```

> In API mode, finalized sessions are POSTed directly to your endpoint — no retrieval step needed.

### Dual-Mode Architecture

| Mode | Trigger | Technology | Data Handling |
|------|---------|------------|---------------|
| **Foreground** | App active | `HKAnchoredObjectQueryDescriptor` | Accumulates samples into on-device session state |
| **Background** | App suspended | `HKObserverQuery` + `enableBackgroundDelivery()` | Accumulates samples into the same session state |

In **both** modes, once the session detector determines sleep has ended, the finalized session is delivered:
- **API mode** → HTTP POST to your endpoint
- **localStorage mode** → stored in `UserDefaults`; retrieve with `getLocalSleepSessions()`

**Automatic switching**: The `AppLifecycleManager` switches between modes on iOS lifecycle notifications. No Flutter code needed.

### Channel

| Channel | Type | Purpose |
|---------|------|---------|
| `com.humango.health/sleep` | MethodChannel | All sleep data operations |

---

## Workout Reading & Monitoring

The plugin provides comprehensive workout reading with real-time monitoring and intelligent background processing.

### Reading Methods

| Method | Description | Use Case |
|--------|-------------|----------|
| `readWorkouts(startDate, endDate)` | One-shot fetch with dedup filtering | Initial sync, manual refresh |
| `fetchAllWorkouts(startDate, endDate)` | Unfiltered fetch — bypasses `WorkoutRecordStore` | Audit, re-sync, full snapshot |
| `startMonitoring(startDate, endDate)` | Live monitoring | Real-time tracking |
| `markWorkoutsAsPushed(ids)` | Acknowledge successful backend upload | After uploading workouts to your API |
| `getWorkoutStoreRecords()` | Inspect the native dedup store | Debugging, testing |

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
| **Foreground** | `HKAnchoredObjectQueryDescriptor` | EventChannel stream (workout updates) |
| **Background** | `HKObserverQuery` + `enableBackgroundDelivery()` | API POST or localStorage |

### Deduplication

The workout reading subsystem implements native deduplication:

| Location | Strategy |
|----------|----------|
| iOS (`WorkoutRecordStore`) | SHA256 hash + byte-level comparison |

Workout scheduling deduplication is handled entirely at the native iOS layer via `ScheduledWorkoutStore` (sorted-key JSON byte comparison). There is no Dart-side storage for scheduling.

### Acknowledging Pushed Workouts

After `readWorkouts()` returns workouts to Flutter and your app successfully uploads them to your backend, call `markWorkoutsAsPushed` to mark them as pushed in the native `WorkoutRecordStore`. Without this, they remain in `pending` state and will be returned again on the next `readWorkouts` call.

```dart
// After successfully uploading to your backend:
final ids = rawJsons
    .map((j) => jsonDecode(j)['deviceActivityId'] as String)
    .toList();

final count = await workoutManager.markWorkoutsAsPushed(ids);
print('Marked $count workout(s) as pushed');
```

### Fetching All Workouts (No Dedup Filter)

Use `fetchAllWorkouts` when you need a complete unfiltered snapshot — every workout in the date range is returned regardless of push history:

```dart
final all = await workoutManager.fetchAllWorkouts(
  DateTime.now().subtract(const Duration(days: 30)),
  endDate: DateTime.now(),
);
print('Total workouts in range: ${all.length}');
```

### Inspecting the Dedup Store

Use `getWorkoutStoreRecords` to inspect every record the native layer has tracked — useful for debugging and verifying push state:

```dart
final records = await workoutManager.getWorkoutStoreRecords();
for (final r in records) {
  print('${r.deviceActivityId}');
  print('  pushed      : ${r.pushed}');
  print('  size        : ${r.dataSize} bytes');
  print('  lastUpdated : ${r.lastUpdated}');
  print('  firstSeen   : ${r.firstSeen}');
}
```

`WorkoutStoreRecord` fields:

| Field | Type | Description |
|-------|------|-------------|
| `deviceActivityId` | `String` | HealthKit UUID (`HKWorkout.uuid`) |
| `dataHash` | `String` | SHA-256 hex of the last serialized payload |
| `dataSize` | `int` | Byte size of the last serialized payload |
| `pushed` | `bool` | `true` after `markWorkoutsAsPushed`; `false` while pending |
| `firstSeen` | `DateTime?` | When this workout ID was first recorded |
| `lastUpdated` | `DateTime` | Timestamp of the most recent record update |

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

### HRV automatic updates (background / suspended)

HRV can be observed automatically so new data is delivered when HealthKit is updated — in foreground via a stream, and in background or when the app is suspended via pending updates.

- **Foreground:** While the app is active and monitoring is started, new HRV samples are emitted on the `hrvUpdates` stream.
- **Background / suspended:** iOS wakes the app briefly when new HRV is saved. The native layer collects updates; call `getPendingHRVUpdates()` after the app returns to foreground to retrieve and clear them.

Call `startHRVMonitoring()` once (e.g. after user logs in or when entering the health metrics flow). Monitoring persists across app launches and auto-starts on next launch. Use `stopHRVMonitoring()` to disable.

```dart
final metrics = HealthMetricsManager();

// Start observing (foreground + background + suspended)
await metrics.startHRVMonitoring();

// Foreground: listen to live updates
metrics.hrvUpdates.listen((update) {
  print('New HRV: ${update['samples']}');
});

// When resuming from background: get updates collected while away
final pending = await metrics.getPendingHRVUpdates();
for (final update in pending) {
  print('Pending HRV: ${update['samples']}');
}

// Optional: check state, stop when done
final active = await metrics.isHRVMonitoringActive();
await metrics.stopHRVMonitoring();
```

| Method / getter | Description |
|-----------------|-------------|
| `startHRVMonitoring()` | Start observing HealthKit for new HRV data; enables background delivery |
| `stopHRVMonitoring()` | Stop observation and background delivery |
| `hrvUpdates` | Stream of HRV updates (foreground only) |
| `getPendingHRVUpdates()` | Returns and clears updates collected in background/suspended |
| `isHRVMonitoringActive()` | Whether monitoring is currently enabled |

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
| `com.humango.health/metrics/hrv_updates` | EventChannel | HRV automatic updates (foreground stream) |

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
| `com.humango.health/session` | MethodChannel | User login/logout state (`setUserLoginState`) |
| `com.humango.health/metrics` | MethodChannel | Health metrics (HRV, HR, body comp) |
| `com.humango.health/metrics/hrv_updates` | EventChannel | HRV automatic updates (foreground stream) |

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