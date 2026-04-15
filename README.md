# Humango Health Plugin

A comprehensive Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform.

> **Version 0.0.39** — See [CHANGELOG](CHANGELOG.md) for what's new.

## Table of Contents

- [Features](#features)
- [Consumer app integration](#consumer-app-integration)
- [Documentation](#documentation)
- [Architecture Overview](#architecture-overview)
- [Requirements](#requirements)
- [User Session Management](#user-session-management)
- [Delegate Delivery](#delegate-delivery)
- [Permission Handling](#permission-handling)
- [Workout Scheduling (Push)](#push-workouts-scheduling)
  - [Swimming Workouts & Pool Size](#swimming-workouts--pool-size)
  - [Removing Scheduled Workouts](#removing-scheduled-workouts)
  - [Remove All Scheduled Workouts](#remove-all-scheduled-workouts)
- [Workout Reading & Monitoring](#workout-reading--monitoring)
- [Sleep Data Reading & Monitoring](#sleep-data-reading--monitoring)
- [Health Metrics Reading & Monitoring](#health-metrics-reading)
- [Native iOS Lifecycle Management](#native-ios-lifecycle-management)

## Features

| Feature | Description |
|---------|-------------|
| **User Session Management** | Login/logout gate for all background observers with automatic data cleanup on logout; per-subsystem `MonitoringConfig` flags persist which observers auto-restart across relaunches |
| **Permission Handling** | Request, verify, and continuously monitor HealthKit permissions |
| **Workout Scheduling** | Push workouts to Apple Watch via WorkoutKit with native deduplication |
| **Workout Reading** | Real-time workout monitoring with foreground/background modes; completed workouts delivered via `HumangoHealthDataDelegate.onWorkoutReady(workout:deviceId:)` |
| **Sleep Data** | One-shot fetch via `getSleepData` (uses `calculateSleepPayload` pipeline); raw sample query via `fetchSleepSamples(startDate,endDate)`; background monitoring (native iOS only — foreground Descriptor + background Observer) delivering finalized sessions via `HumangoHealthDataDelegate.onSleepSessionReady`; grouping-based `calculateSleepPayload` algorithm (gap ≤ 2 h, span ≥ 3 h); Apple-platform source priority (Watch/Health app over third-party, identified by bundle prefix `com.apple.health`); second-based precision for all durations; optimized 6 PM HealthKit query window |
| **Health Metrics (HRV, RHR, etc.)** | On-demand fetch via `HealthMetricsManager.fetchHealthMetric` (Flutter + native iOS); background monitoring via `HumangoHealthPlugin.shared.startMetricsMonitoring` (native iOS); delivery via `HumangoHealthDataDelegate.onHealthMetricReady` (re-fetched current-day, not delta) |
| **Delegate Delivery** | Workouts and finalized sleep sessions are pushed through **`HumangoHealthDataDelegate`** — no plugin-owned payload queues or HTTP |
| **Native Lifecycle Management** | Centralized iOS app lifecycle detection for automatic mode switching |

## Consumer app integration

The plugin **reads HealthKit on the device**. Completed workout and finalized sleep session JSON is pushed to your host app via the **`HumangoHealthDataDelegate`** protocol. Health metrics are **not** pushed; clients query them explicitly through `HealthMetricsManager`. The plugin performs no HTTP and maintains no persistent queues.

Implement `HumangoHealthDataDelegate` in your Runner (see [Delegate Delivery](#delegate-delivery)). After auth, the **host app** (native) must set `UserAuthStateManager.shared.isLoggedIn`, assign `HumangoHealthPlugin.delegate`, and call `HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()` (or start individual subsystems with `startActivityBackgroundMonitoring()`, `startSleepBackgroundMonitoring()`) — there is **no** `UserSessionManager.setUserLoggedIn` in the published Dart API. Each start call **arms a persisted flag** in `MonitoringConfig` so only those subsystems auto-restart on subsequent relaunches. The bundled app uses **`ExampleSessionChannel`** (`com.humango.example/session`) as a reference; copy that pattern in production. See **[example/](example/)** and [`example/README.md`](example/README.md).

## Documentation

Subsystem reference (under `docs/`):

| Document | Topic |
|----------|--------|
| [client_app_integration_guide.md](docs/client_app_integration_guide.md) | **Consolidated guide for host apps** (coordinator, checklist, example map) |
| [client_integration_contract.md](docs/client_integration_contract.md) | **Client ↔ library contract** (streams, polling, envelopes) |
| [activity_reading.md](docs/activity_reading.md) | Workout reading & monitoring |
| [sleep_data.md](docs/sleep_data.md) | Sleep fetch & monitoring |
| [permissions_management.md](docs/permissions_management.md) | HealthKit permissions |
| [health_data_reading.md](docs/health_data_reading.md) | General health data reading |
| [workout_scheduling.md](docs/workout_scheduling.md) | Push workouts to Apple Watch |
| [workout_scheduling_errors.md](docs/workout_scheduling_errors.md) | Scheduling errors |

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    Flutter Application Layer                     │
│  ├─ (Host Runner sets UserAuthStateManager + delegate)            │
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
│  ├─ SleepDataManager (foreground Descriptor + background Observer + inBed pipeline; delegate delivery) │
│  ├─ HealthMetricsManager (query-only reads for HRV, RHR, body composition)        │
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

The library uses a **native user session gate** (`UserAuthStateManager`) so HealthKit observers do not auto-start before login and so logout can tear everything down. The gate is a boolean persisted in `UserDefaults` and is **written from your iOS Runner** (or shared framework), not from a library Dart API.

### Why This Matters

The plugin persists login state across app launches so HealthKit observers can auto-restart when iOS relaunches the app. Without a session gate:

- A freshly installed app (no user yet) would attempt to start background observers on every launch.
- After logout, background observers could continue running with stale configuration.

Workout and sleep auto-start also require **`HumangoHealthPlugin.delegate`** to be set — if the delegate is `nil`, monitoring start methods are a no-op (see `HumangoHealthPlugin.swift`). You can start subsystems individually:

```swift
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()          // workouts + sleep (arms both flags)
HumangoHealthPlugin.shared?.startActivityBackgroundMonitoring()      // workouts only   (arms workoutsEnabled)
HumangoHealthPlugin.shared?.startSleepBackgroundMonitoring()         // sleep only       (arms sleepEnabled)
HumangoHealthPlugin.shared?.startMetricsMonitoring(for: [.restingHeartRate, .bodyMass])  // arms those metric keys
```

Each call both **arms the flag** and **starts the observer** in one step. On the next relaunch, `startAllBackgroundMonitoring()` consults the persisted flags and only auto-restarts what was previously armed.

---

### App-Launch Decision Flow

```
App Launch / Background Wake
        │
        ▼
HumangoHealthPlugin.register()
        │
        ▼
autoStartPersistedSubsystems()   ← reads flags only, never arms
        │
        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  UserAuthStateManager.isLoggedIn?                                       │
│                                                                         │
│  false ──→ Skip all auto-start (no observers started)                   │
│                                                                         │
│  true  ──→ check per-subsystem MonitoringConfig flags                   │
│              │                                                          │
│              ├─ workoutsEnabled == true && delegate set?                │
│              │     yes ──→ Auto-start WorkoutService (24 h lookback)    │
│              │     no  ──→ no-op                                        │
│              │                                                          │
│              ├─ sleepEnabled == true && delegate set?                   │
│              │     yes ──→ Auto-start SleepDataManager (12 h lookback)  │
│              │     no  ──→ no-op                                        │
│              │                                                          │
│              └─ enabledMetricKeys non-empty && delegate set?            │
│                    yes ──→ Auto-start HealthMetricMonitor per key       │
│                    no  ──→ no-op                                        │
└─────────────────────────────────────────────────────────────────────────┘

Flags are reset to false on every new login (isLoggedIn: false → true).
The host app must re-arm subsystems after each login.
```

### Case 1 — Logged In, Delegate Set

```
User installs app
  → Logs in → native sets UserAuthStateManager.shared.isLoggedIn = true
       (triggers MonitoringConfig.clearAll() — all flags reset to false)
  → AppDelegate sets HumangoHealthPlugin.delegate = ExampleHealthDataHandler()
  → startAllBackgroundMonitoring() arms workoutsEnabled + sleepEnabled
  → Kills app

Next launch:
  → isLoggedIn = true  ✅
  → Delegate set  ✅
  → autoStartPersistedSubsystems() reads flags → workouts + sleep auto-start
  → Workouts / sleep sessions delivered via delegate callbacks
```

### Case 2 — Logged In, No Delegate Set

```
User installs app
  → Logs in → native sets isLoggedIn = true
  → AppDelegate does NOT set HumangoHealthPlugin.delegate
  → Kills app

Next launch:
  → isLoggedIn = true  ✅
  → Delegate nil → auto-start skipped ✅
  → Done — no observers running until delegate is set
```

### Logout Cleanup — What Gets Cleared

Calling **`HumangoHealthPlugin.shared?.logout()`** (or setting `isLoggedIn = false` **without** using the plugin’s logout path — not recommended) affects cleanup as documented in native code. The plugin’s **`logout()`** clears all of the following:

| Data | What Is Cleared |
|------|-----------------|
| **Session gate** | `UserDefaults` `isLoggedIn` flag set to `false` |
| **Monitoring flags** | `MonitoringConfig.clearAll()` — `workoutsEnabled`, `sleepEnabled`, `enabledMetricKeys` all reset |
| **Sleep dedup state** | Clears `lastDeliveredSessionId` and `lastDeliveredWakeTime` so the next observer fire re-delivers if new data arrives |
| **Scheduled workouts** | All workouts in `ScheduledWorkoutStore` (Apple Watch scheduled workouts cache) |
| **Active monitors** | All running `HKObserverQuery` and `HKAnchoredObjectQueryDescriptor` tasks stopped |

> **Note:** There is no UserDefaults payload queue to clear — delivery is handled exclusively via `HumangoHealthDataDelegate`.

---

### Session API (host app)

Login and logout are **not** exposed as `UserSessionManager` Dart methods in the published package. Mirror the bundled **`ExampleSessionChannel` / `ExampleSessionManager`** pattern:

1. **iOS Runner:** Register a MethodChannel (example: `com.humango.example/session`).
2. **On login:** Set `UserAuthStateManager.shared.isLoggedIn = true`, optionally `userId`, assign `HumangoHealthPlugin.delegate`, then start monitoring — either `startAllBackgroundMonitoring()` or individual subsystems.
3. **On logout:** Call `HumangoHealthPlugin.shared?.logout()` (stops monitors, clears data, sets `isLoggedIn = false`).

From Flutter you invoke your channel (see `example/lib/example_session_manager.dart`).

### Optional: credentials in UserDefaults

If your native upload code needs `athleteId` / `accessToken`, the optional internal `UserSessionManager.saveCredentials` Dart helper targets `com.humango.health/session` — implement that channel in your Runner if you use it (the example app relies on the session channel above instead).

> **Important:** Set **`isLoggedIn`** and **`delegate`** before you expect workout or sleep delegate callbacks. Auto-start during `HumangoHealthPlugin.register()` runs only when both are satisfied.

---

## Delegate Delivery

The plugin delivers **workouts** and **finalized sleep sessions** through **`HumangoHealthDataDelegate`**. Health metrics are query-only. There are no plugin-owned UserDefaults queues for these payloads.

### Protocol

```swift
// humango_health plugin
public protocol HumangoHealthDataDelegate: AnyObject {
    func onWorkoutReady(workout: HuWorkout, deviceId: String) async
    func onSleepSessionReady(json: String, sessionId: String) async
}
```

Default implementations in `HumangoHealthDataDelegate.swift` are no-ops so you can override only what you need.

| Callback | When called | Payload |
|----------|------------|----------|
| `onWorkoutReady(workout:deviceId:)` | A completed workout is detected (foreground or background) | `HuWorkout` struct — call `workout.toDict()` for JSON |
| `onSleepSessionReady(json:sessionId:)` | A sleep session is ready (HealthKit observer fired, window fetched, payload computed) | Flat aggregated sleep payload JSON |

### Wiring in AppDelegate.swift

```swift
import UIKit
import Flutter
import humango_health

@main
class AppDelegate: FlutterAppDelegate {

    private let healthDataHandler = ExampleHealthDataHandler()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Wire the delegate BEFORE the plugin's register() runs background observers
        HumangoHealthPlugin.delegate = healthDataHandler

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
```

> **Timing matters:** Set `HumangoHealthPlugin.delegate` before calling `super.application(...)` so that auto-start observers (when `isLoggedIn == true`) already have a delegate in place on the first callback.

### Implementing the Delegate (`ExampleHealthDataHandler`)

Create a concrete handler in your iOS Runner. The example app ships `ExampleHealthDataHandler.swift` as a reference:

```swift
// example/ios/Runner/ExampleHealthDataHandler.swift
import Foundation
import humango_health

final class ExampleHealthDataHandler: HumangoHealthDataDelegate {

    private let athleteId = UUID().uuidString  // replace with your real athlete ID
    private let apiBase   = "https://your-api.example.com"

    // MARK: - HumangoHealthDataDelegate

    func onWorkoutReady(workout: HuWorkout, deviceId: String) async {
        print("[Delegate] \u{1F3C3} Workout ready \u2014 deviceId=\(deviceId), sport=\(workout.sport.name)")
        guard let dict = workout.toDict(),
              let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8) else { return }
      await post(path: "activities", json: json)
    }

    func onSleepSessionReady(json: String, sessionId: String) async {
        print("[Delegate] \u{1F634} Sleep session ready \u2014 sessionId=\(sessionId)")
      await post(path: "sleep", json: json)
    }

    // MARK: - Upload

    private func post(path: String, json: String) async {
        guard let url  = URL(string: "\(apiBase)/\(path)/\(athleteId)"),
              let body = json.data(using: .utf8) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Add Authorization header here if required

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Delegate] \u2705 POST /\(path)/\(athleteId) \u2192 HTTP \(status)")
        } catch {
            print("[Delegate] \u274C POST /\(path)/\(athleteId) failed: \(error)")
        }
    }
}
```

**Key points:**

- Delegate methods may run off the main thread \u2014 use `Task { ... }` or `DispatchQueue.main.async` if you need to update UI.
- `athleteId` should come from your auth context (user profile), not a random UUID in production.
- The plugin sets no retain cycle: `HumangoHealthPlugin.delegate` is a `weak` reference \u2014 keep a strong reference in your `AppDelegate` or a DI container.

### Sleep Session JSON Shape

The `json` parameter in `onSleepSessionReady` has the same flat aggregated shape as `calculateSleepPayload`. Duration fields are **seconds** (integers):

```json
{
  "SOURCE":           "Apple Watch",
  "SOURCE_BUNDLE":    "com.apple.health.\u2026",
  "TIMEZONE":         "America/New_York",
  "TOTAL_SLEEP":      25200,
  "SLEEP_LIGHT":      10800,
  "SLEEP_DEEP":        3600,
  "SLEEP_REM":         7200,
  "SLEEP_UNSPECIFIED": 3600,
  "SLEEP_AWAKE":        900,
  "SLEEP_IN_BED":          0,
  "BED_TIME":   "2026-03-17T22:30:00.000Z",
  "WAKE_TIME":  "2026-03-18T06:15:00.000Z",
  "START_DATE": "2026-03-17T18:00:00.000Z",
  "END_DATE":   "2026-03-18T06:30:00.000Z"
}
```

---

## Requirements

- **iOS 18.0** minimum deployment target
- **Physical device** recommended for HealthKit testing (simulator support is limited)
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

**Full set (default)** — requests all tracked types at once:

```dart
import 'package:humango_health/humango_health.dart';

final permissionManager = PermissionManager();

void requestPermissions() async {
  await permissionManager.requestAuthorization();
  // iOS will surface the permissions dialog to the user here.
  // Subscribe to permissionStream to react to the result.
}
```

**Selective request** — pass a `readTypes` list to request only the types your feature needs. On iOS, `HealthDataType.workout` automatically expands to all workout-ancillary types (see table below).

```dart
// Workout only (expands to all ancillary workout types on iOS)
await permissionManager.requestAuthorization(
  readTypes: [HealthDataType.workout],
);

// Sleep only
await permissionManager.requestAuthorization(
  readTypes: [HealthDataType.sleepAnalysis],
);

// Workout + health metrics
await permissionManager.requestAuthorization(
  readTypes: [
    HealthDataType.workout,
    HealthDataType.hrv,
    HealthDataType.restingHeartRate,
  ],
);
```

**Workout type expansion** — when `HealthDataType.workout` is included in `readTypes`, iOS automatically requests these ancillary types as part of the same permission sheet:

| Ancillary type | HealthKit identifier |
|---|---|
| Heart Rate | `HKQuantityTypeIdentifierHeartRate` |
| Step Count | `HKQuantityTypeIdentifierStepCount` |
| Distance Cycling | `HKQuantityTypeIdentifierDistanceCycling` |
| Swimming Stroke Count | `HKQuantityTypeIdentifierSwimmingStrokeCount` |
| Distance Swimming | `HKQuantityTypeIdentifierDistanceSwimming` |
| VO2 Max | `HKQuantityTypeIdentifierVO2Max` |
| Distance Walking/Running | `HKQuantityTypeIdentifierDistanceWalkingRunning` |
| Active Energy Burned | `HKQuantityTypeIdentifierActiveEnergyBurned` |
| Body Mass Index | `HKQuantityTypeIdentifierBodyMassIndex` |
| Running Ground Contact Time | `HKQuantityTypeIdentifierRunningGroundContactTime` |
| Running Power | `HKQuantityTypeIdentifierRunningPower` |
| Running Speed | `HKQuantityTypeIdentifierRunningSpeed` |
| Running Stride Length | `HKQuantityTypeIdentifierRunningStrideLength` |
| Running Vertical Oscillation | `HKQuantityTypeIdentifierRunningVerticalOscillation` |
| Cycling Cadence | `HKQuantityTypeIdentifierCyclingCadence` |
| Cycling Power | `HKQuantityTypeIdentifierCyclingPower` |
| Workout Route | `HKSeriesTypeWorkoutRoute` |

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
final restingHRStatus = result.statuses[HealthDataType.restingHeartRate];
if (restingHRStatus == PermissionStatus.authorized) {
  print('Resting heart rate: authorized with data present.');
} else if (restingHRStatus == PermissionStatus.noData) {
  print('Resting heart rate: authorized but no data recorded yet.');
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

Wire permissions the same way in your host app: one `PermissionManager`, `requestAuthorization()` where appropriate, and a single `permissionStream` subscription (see [Permission Handling](#permission-handling)).

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

Use `WorkoutPushEntry` to build each entry — `scheduleId` and `sport` are typed fields so they can never be misspelled or wrong-cased. `data` is the raw backend JSON blob (must contain `date` and `blocks`).

```dart
import 'package:humango_health/humango_health.dart';

final pushManager = WorkoutPushManager();

void scheduleWorkouts() async {

  // 1. Build typed entries — no raw strings for sport or schedule_id
  final List<WorkoutPushEntry> entries = [
    WorkoutPushEntry(
      scheduleId: '123456',
      sport: AppleSport.running,                  // ← typed, maps to 'RUNNING' on iOS
      data: {
        'date': DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String(),
        'blocks': [
          // ... (Humango specific Warmup/Interval/Cooldown definition)
        ],
      },
    ),
    WorkoutPushEntry(
      scheduleId: '123457',
      sport: AppleSport.poolSwimming,             // ← maps to 'POOL_SWIMMING' on iOS
      data: {
        'date': DateTime.now().add(const Duration(hours: 4)).toUtc().toIso8601String(),
        'pool_size': '25m',
        'blocks': [ /* ... */ ],
      },
    ),
  ];

  // 2. Dispatch — sport and schedule_id are stamped in automatically
  final response = await pushManager.pushRawWorkouts(entries);

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

#### `AppleSport` — all supported values

| `AppleSport` case | iOS raw value | HKWorkoutActivityType |
|---|---|---|
| `running` | `RUNNING` | `.running` |
| `cycling` | `CYCLING` | `.cycling` |
| `swimming` | `SWIMMING` | `.swimming` |
| `poolSwimming` | `POOL_SWIMMING` | `.swimming` (indoor) |
| `openWaterSwimming` | `OPEN_WATER_SWIMMING` | `.swimming` (outdoor) |
| `strength` | `STRENGTH` | `.traditionalStrengthTraining` |
| `hiking` | `HIKING` | `.hiking` |
| `walking` | `WALKING` | `.walking` |
| `yoga` | `YOGA` | `.yoga` |
| `paddling` | `PADDLING` | `.paddleSports` |
| `alpineSkiing` | `ALPINE_SKIING` | `.downhillSkiing` |
| `rowing` | `ROWING` | `.rowing` |
| `cardio` | `CARDIO` | `.mixedCardio` |
| `nordicSkiing` | `NORDIC_SKIING` | `.crossCountrySkiing` |
| `snowshoeing` | `SNOWSHOEING` | `.snowSports` |
| `hiit` | `HIIT` | `.highIntensityIntervalTraining` |
| `hyrox` | `HYROX` | `.highIntensityIntervalTraining` |
| `soccer` | `SOCCER` | `.soccer` |
| `tennis` | `TENNIS` | `.tennis` |
| `squash` | `SQUASH` | `.squash` |
| `pickleball` | `PICKLEBALL` | `.pickleball` |
| `badminton` | `BADMINTON` | `.badminton` |
| `baseball` | `BASEBALL` | `.baseball` |
| `hockey` | `HOCKEY` | `.hockey` |
| `volleyball` | `VOLLEYBALL` | `.volleyball` |
| `handball` | `HANDBALL` | `.handball` |
| `basketball` | `BASKETBALL` | `.basketball` |
| `multisport` | `MULTISPORT` | `.swimBikeRun` |
| `elliptical` | `ELLIPTICAL` | `.elliptical` |

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
    print("   Sport: ${workout.sport?.jsonValue ?? workout.activityType}"); // ← typed AppleSport
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
- `sport`: `AppleSport?` — typed enum, populated when the workout was pushed via `WorkoutPushEntry`; `null` if not matched in local store
- `activityType`: The raw activity type string from WorkoutKit (e.g. `"Running"`) — always present
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

---

## Sleep Data Reading & Monitoring

The plugin provides comprehensive access to Apple HealthKit's sleep analysis data (`HKCategoryTypeIdentifier.sleepAnalysis`) with support for:

- **One-shot fetch**: `getSleepData(startDate, endDate)` — queries HealthKit and returns a fully aggregated `SleepDataResponse`; uses `calculateSleepPayload` internally (Apple-source filter + session grouping)
- **Raw sample query**: `fetchSleepSamples(startDate, endDate)` — returns raw `HKCategorySample` records with no grouping or aggregation
- **Calculated payload**: `calculateSleepPayload(startDate, endDate)` — runs the full grouping algorithm and returns the flat backend payload map
- **Background monitoring** (native iOS only — no Flutter start/stop API): `HKAnchoredObjectQueryDescriptor` in foreground and `HKObserverQuery` in background; started via `HumangoHealthPlugin.shared.startSleepBackgroundMonitoring()` or `startAllBackgroundMonitoring()` from your iOS Runner
- **Grouping algorithm**: Samples are sorted, grouped by gap (≤ 2 h), short groups (span < 3 h) discarded, and remaining groups aggregated — filters out naps and fragmented readings
- **Source priority**: Apple-platform sources (bundle prefix `com.apple.health`) take priority over third-party. Covers Apple Watch (`com.apple.health.<device-UUID>`) and iPhone Health app. If no Apple samples exist, all samples are used.
- **Session-aware delivery**: When the HealthKit observer fires, the 6 PM window is fetched, `calculateSleepPayload` is run, and if valid the finalized JSON is passed to `HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:)` in your iOS Runner; a deduplication guard prevents re-delivery if the session is unchanged

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

`getSleepData` queries HealthKit and runs the full `calculateSleepPayload` pipeline
(Apple-source filter → session grouping → stage totals) before returning. The
`stageTotals` and `totalSleep*` values on the response reflect only qualifying sessions
(gap ≤ 2 h, span ≥ 3 h) from Apple-platform sources.

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void fetchSleepData() async {
  try {
    final response = await sleepManager.getSleepData();
    
    if (response.hasSleepData) {
      // Helper: format minutes as "Xh Ym"
      String fmtMin(double m) {
        final total = (m * 60).round();
        final h = total ~/ 3600; final min = (total % 3600) ~/ 60;
        if (h > 0 && min > 0) return '${h}h ${min}m';
        return h > 0 ? '${h}h' : '${min}m';
      }

      print('🛏️ Sleep Summary:');
      print('   Total sleep: ${fmtMin(response.totalSleepMinutes)}');
      print('   Samples: ${response.sampleCount}');
      
      // Stage breakdown
      print('   Deep sleep: ${fmtMin(response.stageTotals.asleepDeepMinutes)}');
      print('   REM sleep: ${fmtMin(response.stageTotals.asleepREMMinutes)}');
      print('   Core sleep: ${fmtMin(response.stageTotals.asleepCoreMinutes)}');
      print('   Awake: ${fmtMin(response.stageTotals.awakeMinutes)}');
      
      // Individual samples with raw JSON
      for (final sample in response.samples) {
        print('   ${sample.sleepStage}: ${fmtMin(sample.durationMinutes)}');
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

### Fetching Raw Sleep Samples (No Aggregation)

Use this API when you need raw sleep segments exactly as returned by HealthKit,
without source-priority filtering or grouped payload calculations.

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void fetchRawSleepSamples() async {
  try {
    final end = DateTime.now();
    final start = end.subtract(const Duration(hours: 24));

    final samples = await sleepManager.fetchSleepSamples(
      startDate: start,
      endDate: end,
    );

    print('Raw sample count: ${samples.length}');
    for (final s in samples) {
      print('${s.sleepStage}  ${s.startDate.toIso8601String()} -> ${s.endDate.toIso8601String()}');
    }
  } on SleepDataException catch (e) {
    print('Error: ${e.code} - ${e.message}');
  }
}
```

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

Ensure sleep analysis is included when you request HealthKit authorization (the plugin requests its full fixed type set—see [Tracked Health Types](#tracked-health-types)):

```dart
final permissionManager = PermissionManager();
await permissionManager.requestAuthorization();
// After the user has granted access, fetch sleep:
final sleepManager = SleepDataManager();
final response = await sleepManager.getSleepData();
```

### Compatibility

- **iOS 14.0+**: Basic sleep data (inBed, asleepUnspecified, awake)
- **iOS 16.0+**: Detailed sleep stages (asleepCore, asleepDeep, asleepREM)

**Note:** On devices with iOS < 16, sleep samples will use `asleepUnspecified` instead of detailed stage classification.

### Background Sleep Monitoring (Native iOS only)

Sleep monitoring is started exclusively from the native iOS side — there is no
Flutter start/stop API. Call one of these from your iOS Runner after the user
logs in and `HumangoHealthPlugin.delegate` is set:

```swift
// Start sleep monitoring only
HumangoHealthPlugin.shared?.startSleepBackgroundMonitoring()

// Or start all subsystems (workouts + sleep + metrics) at once
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()
```

The `AppLifecycleManager` automatically switches between:
- **Foreground**: `HKAnchoredObjectQueryDescriptor` for live streaming
- **Background**: `HKObserverQuery` + `enableBackgroundDelivery` for silent wake-ups

When the observer fires, `calculateSleepPayload` is run over the 6 PM window. If a
valid session is found, the finalized JSON is pushed to
`HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:)` in your iOS Runner.
A deduplication guard prevents re-delivery if the session has not changed.

### Dual-Mode Architecture (Native)

| Mode | Technology | Data Handling |
|------|-----------|---------------|
| **Foreground** | `HKAnchoredObjectQueryDescriptor` | Live sample streaming |
| **Background** | `HKObserverQuery` + `enableBackgroundDelivery()` | Silent wake-up → `calculateSleepPayload` → delegate |

Mode switching is automatic via `AppLifecycleManager` on iOS lifecycle notifications.
No Flutter code is needed to manage the mode — start/stop is native-only.

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
| `readWorkouts(startDate, endDate)` | One-shot fetch from HealthKit | Initial sync, manual refresh |
| `fetchAllWorkouts(startDate, endDate)` | Fetch all workout types (ignores import preferences) | Audit, re-sync, full snapshot |
| `startMonitoring(startDate, endDate)` | Live monitoring | Real-time tracking |

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

Start monitoring for new workouts. The native iOS side uses `HKAnchoredObjectQueryDescriptor` in the foreground and `HKObserverQuery` in the background. Completed workouts are delivered to your iOS Runner via `HumangoHealthDataDelegate.onWorkoutReady(workout:deviceId:)` — there is no Dart stream to subscribe to.

```dart
import 'package:humango_health/humango_health.dart';

final workoutManager = WorkoutReadManager();

void startWorkoutMonitoring() async {
  await workoutManager.startMonitoring(
    DateTime.now().subtract(const Duration(days: 7)),
  );
  // Workouts arrive via HumangoHealthDataDelegate.onWorkoutReady(workout:deviceId:) in AppDelegate.swift
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
| **Foreground** | `HKAnchoredObjectQueryDescriptor` | Completed workouts delivered via `HumangoHealthDataDelegate.onWorkoutReady(workout:deviceId:)` |
| **Background** | `HKObserverQuery` + `enableBackgroundDelivery()` | Same — delivered via `HumangoHealthDataDelegate.onWorkoutReady(workout:deviceId:)`. The plugin does **not** POST workouts. |

### Fetching All Workouts (No Preference Filter)

Use `fetchAllWorkouts` when you need every workout in the date range regardless of the import-preference filter:

```dart
final all = await workoutManager.fetchAllWorkouts(
  DateTime.now().subtract(const Duration(days: 30)),
  endDate: DateTime.now(),
);
print('Total workouts in range: ${all.length}');
```

---

### Native iOS Workout Read API

All workout fetch methods are `async throws` on `HumangoHealthPlugin.shared` — call them from any Swift `async` context without going through the Flutter method channel.

#### Prerequisites

```swift
import humango_health

guard let plugin = HumangoHealthPlugin.shared else { return }

let end   = Date()
let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
```

#### `readWorkouts` — with import preferences applied

```swift
// Fetches workouts respecting the user's running / cycling / swimming exclusions.
let workouts = try await plugin.readWorkouts(startDate: start, endDate: end)

for json in workouts {
    guard let data = json.data(using: .utf8),
          let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let sport    = obj["sport"]    as? String ?? ""
    let duration = obj["duration"] as? Double ?? 0
    let uuid     = obj["device_activity_id"] as? String ?? ""
    print("\(sport)  \(duration / 60, specifier: "%.1f") min  [\(uuid)]")
}
```

#### `fetchAllWorkouts` — no preference filter

```swift
// Returns every workout type in the range, bypassing import preferences.
let all = try await plugin.fetchAllWorkouts(startDate: start, endDate: end)
print("Total workouts: \(all.count)")
```

#### Completion handler wrappers (non-`async` call sites)

```swift
// readWorkouts
Task {
    guard let plugin = HumangoHealthPlugin.shared else { return }
    if let workouts = try? await plugin.readWorkouts(startDate: start, endDate: end) {
        DispatchQueue.main.async {
            // update UI with workouts
        }
    }
}
```

#### Response shape per workout (JSON string)

Each element is a compact JSON string. Decode it on the call site:

```swift
let data = json.data(using: .utf8)!
let obj  = try JSONSerialization.jsonObject(with: data) as! [String: Any]

// Top-level keys
// "device_activity_id" : String   — HealthKit UUID
// "sport"              : String   — e.g. "Running", "Cycling", "Swimming"
// "start_time"         : String   — ISO 8601 UTC
// "duration"           : Double   — seconds
// "distance"           : Double   — metres (0 if not available)
// "serial"             : String   — unique payload serial (UUID)
// "metadata"           : [String: Any]
//     "SOURCE_NAME"               : String
//     "IS_SCHEDULED_WORKOUT"      : Bool
//     "scheduledWorkoutId"        : String? (present when IS_SCHEDULED_WORKOUT = true)
// "series_data"        : [String: Any]
//     "samples"  : [[String: Any]]  — quantity series (HR, steps, energy, …)
//     "locations": [[String: Any]]  — GPS points (if route data available)
// "statistics"         : [[String: Any]]   — HealthKit statistics per type
// "events"             : [[String: Any]]   — laps, pauses, segments
```

---

## Health Metrics Reading

Read body-composition and vital-sign metrics from HealthKit. On-demand fetching is available from both Flutter (Dart) and native iOS. Continuous background monitoring is available from native iOS only — the delegate callback fires on each HealthKit notification.

### Supported Metrics

| Metric | `HealthMetricType` case | HealthKit Identifier | Unit |
|--------|------------------------|---------------------|------|
| HRV (SDNN) | `.heartRateVariabilitySDNN` | `heartRateVariabilitySDNN` | ms |
| Resting Heart Rate | `.restingHeartRate` | `restingHeartRate` | bpm |
| Body Fat Percentage | `.bodyFatPercentage` | `bodyFatPercentage` | % |
| Weight (Body Mass) | `.bodyMass` | `bodyMass` | kg |
| Height | `.height` | `height` | cm |

> **Note:** `HealthMetricType` is a typed enum used in both Dart and Swift. The Swift enum is the single source of truth for HealthKit identifier, unit, and unit label.

---

### Quick Start

```dart
import 'package:humango_health/humango_health.dart';

final metrics = HealthMetricsManager();
```

---

### 1. On-Demand Fetch (Flutter / Dart)

#### 1a. Fetch samples for a date range

`fetchHealthMetric` fetches all samples for a given metric type within a date range.
Both `startDate` and `endDate` default to the last 30 days when omitted.

```dart
// Fetch HRV samples for a specific date range
final hrvResponse = await metrics.fetchHealthMetric(
  HealthMetricType.heartRateVariabilitySDNN,
  startDate: DateTime.now().subtract(const Duration(days: 7)),
  endDate: DateTime.now(),
);

print('Latest HRV: ${hrvResponse.latestValue} ${hrvResponse.unit}');
print('Average:    ${hrvResponse.statistics.average}');
print('Min / Max:  ${hrvResponse.statistics.min} / ${hrvResponse.statistics.max}');
print('Samples:    ${hrvResponse.sampleCount}');

for (final sample in hrvResponse.samples) {
  print('${sample.startDate}: ${sample.value} ${sample.unit}  (${sample.sourceName})');
}

// Fetch all types in a loop
for (final type in HealthMetricType.values) {
  try {
    final r = await metrics.fetchHealthMetric(type,
        startDate: DateTime.now().subtract(const Duration(days: 30)));
    print('${type.displayName}: ${r.sampleCount} samples');
  } on HealthMetricsException catch (e) {
    print('${type.key} error: ${e.message}');
  }
}
```

#### 1b. Fetch the latest sample only

`fetchLatestMetric` returns the single most-recent HealthKit record — no date range
needed, no unnecessary data transfer.

```dart
// Latest weight
final weightResponse = await metrics.fetchLatestMetric(HealthMetricType.bodyMass);
if (weightResponse.hasData) {
  print('Current weight: ${weightResponse.latestValue} ${weightResponse.unit}');
  print('Recorded:       ${weightResponse.latestSample?.startDate}');
}

// Latest HRV
final hrv = await metrics.fetchLatestMetric(HealthMetricType.heartRateVariabilitySDNN);
print('Latest HRV: ${hrv.latestValue} ms');

// Latest resting heart rate
final rhr = await metrics.fetchLatestMetric(HealthMetricType.restingHeartRate);
print('Resting HR: ${rhr.latestValue} bpm');

// Any metric by type in a loop
for (final type in HealthMetricType.values) {
  try {
    final r = await metrics.fetchLatestMetric(type);
    if (r.hasData) {
      print('${type.displayName}: ${r.latestValue} ${r.unit}  '
            'at ${r.latestSample?.startDate}');
    } else {
      print('${type.displayName}: no data recorded yet');
    }
  } on HealthMetricsException catch (e) {
    print('${type.key} error: ${e.message}');
  }
}
```

---

### 2. Monitoring (Native iOS)

> **Monitoring is native-iOS-only.** The Dart `HealthMetricsManager` does not receive callbacks. Delivery goes through `HumangoHealthDataDelegate.onHealthMetricReady`.

#### 2a. Setup — Implement the delegate

Before starting any monitor, your host app must implement `HumangoHealthDataDelegate` and assign it to `HumangoHealthPlugin.delegate`. This is the same delegate used for workout and sleep delivery — you only do this once.

```swift
// AppDelegate.swift (or your coordinator)
import humango_health
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate, HumangoHealthDataDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        HumangoHealthPlugin.delegate = self   // ← assign delegate
        return true
    }

    // Called whenever a monitored metric receives new HealthKit data.
    func onHealthMetricReady(payload: [String: Any], metricType: String) async {
        guard let stats = payload["statistics"] as? [String: Double] else { return }
        print("[\(metricType)] avg=\(stats["average"] ?? 0) sampleCount=\(payload["sampleCount"] ?? 0)")
        // forward to your analytics/API layer, update local state, etc.
    }
}
```

> The `onHealthMetricReady` method has a default no-op implementation in the protocol extension, so you only need to add it when you want to act on the data.

#### 2b. Starting and stopping monitors

Call `startMetricsMonitoring(for:)` after your user is authenticated and the delegate is assigned. A typical place is your post-login coordinator:

```swift
import humango_health

final class HealthCoordinator {

    func onUserLoggedIn() {
        guard let plugin = HumangoHealthPlugin.shared else { return }

        // Monitor HRV and resting heart rate
        plugin.startMetricsMonitoring(for: [.heartRateVariabilitySDNN, .restingHeartRate])

        // Or monitor every supported metric type at once
        plugin.startMetricsMonitoring(for: HealthMetricType.allCases)
    }

    func onUserLoggedOut() {
        // Stops all monitors and clears the registry.
        // Also called automatically by HumangoHealthPlugin.clearAllDataOnLogout().
        HumangoHealthPlugin.shared?.stopMetricsMonitoring(for: HealthMetricType.allCases)
    }

    func pauseHRVMonitoring() {
        HumangoHealthPlugin.shared?.stopMetricsMonitoring(for: [.heartRateVariabilitySDNN])
    }
}
```

#### 2c. Delegate Callback — Payload Keys

Every monitor fires `onHealthMetricReady` whenever HealthKit delivers a change notification:

```swift
func onHealthMetricReady(payload: [String: Any], metricType: String) async {
    // ── Identification ──────────────────────────────────────────────────
    // metricType   : String          — "heartRateVariabilitySDNN", "restingHeartRate", …
    // unit         : String          — "ms", "bpm", "%", "kg", "cm"
    // sampleCount  : Int             — number of samples in window
    //
    // ── Latest sample ───────────────────────────────────────────────────
    // latestSample : [String: Any]?  — most recent sample dict (or nil if none)
    //     .uuid        : String
    //     .value       : Double      — raw, no rounding
    //     .unit        : String
    //     .startDate   : String      — ISO 8601 UTC with fractional seconds
    //     .endDate     : String
    //     .sourceName  : String
    //     .sourceBundle: String
    //     .device      : [String: Any]?
    //     .metadata    : [String: Any]?
    //
    // ── Aggregates ──────────────────────────────────────────────────────
    // statistics   : [String: Double] — average, min, max, sum (raw Double)
    //
    // ── Window ──────────────────────────────────────────────────────────
    // fetchedFrom  : String          — midnight local time, as UTC ISO 8601
    // fetchedTo    : String          — now, as UTC ISO 8601
    //
    // ── Samples ─────────────────────────────────────────────────────────
    // samples      : [[String: Any]] — all samples in window (same shape as latestSample)

    let type   = HealthMetricType(rawValue: metricType)
    let stats  = payload["statistics"] as? [String: Double] ?? [:]
    let latest = payload["latestSample"] as? [String: Any]

    switch type {
    case .heartRateVariabilitySDNN:
        print("HRV today: avg \(stats["average"] ?? 0) ms  latest \(latest?["value"] ?? "–") ms")
    case .restingHeartRate:
        print("Resting HR today: avg \(stats["average"] ?? 0) bpm")
    default:
        print("[\(metricType)] \(payload["sampleCount"] ?? 0) samples")
    }
}
```

> **Important:** `onHealthMetricReady` delivers **re-fetched current-day samples** (midnight → now on the device clock). It is **not** a delta of new samples. Each HealthKit notification triggers a full re-query of today's window.

#### 2d. Monitoring Behavior

| App State | Mechanism | Notes |
|-----------|-----------|-------|
| Foreground | `HKAnchoredObjectQueryDescriptor` live stream | Real-time, low-latency |
| Background | `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` | System-scheduled wake-up |

- When the app transitions **background → foreground**, monitoring automatically switches to live-stream mode (same `AppLifecycleManager` pattern as workout and sleep monitors).
- `completion()` is called by `HKObserverQuery` only **after** the full `await fetchAndDeliverCurrentDay()` chain — never via `defer`.
- Requires **iOS 17+** (`@available(iOS 17.0, *)`).

#### 2e. Starting / Stopping from Dart (Verification / Debug)

> The Dart API for monitoring control is intended for **testing/verification only** — use native iOS (§2b) in production. No Dart callback fires; delivery always goes to the native delegate.

```dart
final metrics = HealthMetricsManager();

// Start a monitor
await metrics.startMetricMonitoring(HealthMetricType.heartRateVariabilitySDNN);

// Stop a specific monitor
await metrics.stopMetricMonitoring(HealthMetricType.heartRateVariabilitySDNN);

// Stop all active monitors
await metrics.stopAllMetricMonitoring();
```

---

### 3. Native iOS Fetch API

All fetch methods are `async throws` and return `[String: Any]` — the same dictionary shape described in §4 (Response Shape). Call them from any `async` context in your host app.

#### 3a. Prerequisites

```swift
import humango_health

// Ensure the plugin is initialised (it is, after FlutterEngine registers it).
guard let plugin = HumangoHealthPlugin.shared else { return }

let now   = Date()
let end   = now
let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
```

#### 3b. Generic fetch (any metric type)

```swift
// All samples for a type in a date range
let hrvData = try await plugin.fetchHealthMetric(
    .heartRateVariabilitySDNN,
    startDate: start,
    endDate: end
)

// Most recent sample only
let latestWeight = try await plugin.fetchLatestHealthMetric(.bodyMass)

// Every supported type at once — returns [String: [String: Any]]
let allMetrics = try await plugin.fetchAllHealthMetrics(startDate: start, endDate: end)
if let hrv = allMetrics["heartRateVariabilitySDNN"] {
    let stats = hrv["statistics"] as? [String: Double] ?? [:]
    print("30-day HRV avg: \(stats["average"] ?? 0) ms")
}
```

#### 3c. Per-type convenience wrappers

Each supported metric has a dedicated pair of methods — one for a date range and one for the latest sample:

```swift
// HRV (ms)
let hrv       = try await plugin.fetchHRV(startDate: start, endDate: end)
let latestHRV = try await plugin.fetchLatestHRV()

// Resting Heart Rate (bpm)
let rhr       = try await plugin.fetchRestingHeartRate(startDate: start, endDate: end)
let latestRHR = try await plugin.fetchLatestRestingHeartRate()

// Body Fat Percentage (% stored as 0–1 fraction by HealthKit)
let bodyFat       = try await plugin.fetchBodyFatPercentage(startDate: start, endDate: end)
let latestBodyFat = try await plugin.fetchLatestBodyFatPercentage()

// Weight / Body Mass (kg)
let weight       = try await plugin.fetchWeight(startDate: start, endDate: end)
let latestWeight = try await plugin.fetchLatestWeight()

// Height (cm)
let height       = try await plugin.fetchHeight(startDate: start, endDate: end)
let latestHeight = try await plugin.fetchLatestHeight()
```

#### 3d. Reading the response

```swift
// Inspect any fetch result the same way
func printMetric(_ data: [String: Any]) {
    let type       = data["metricType"] as? String ?? ""
    let unit       = data["unit"] as? String ?? ""
    let count      = data["sampleCount"] as? Int ?? 0
    let stats      = data["statistics"] as? [String: Double] ?? [:]
    let latest     = data["latestSample"] as? [String: Any]
    let latestVal  = latest?["value"] as? Double

    print("\(type): \(count) samples — avg \(stats["average"] ?? 0) \(unit)"
          + (latestVal != nil ? "  latest \(latestVal!) \(unit)" : ""))
}

let hrv = try await plugin.fetchHRV(startDate: start, endDate: end)
printMetric(hrv)  // "heartRateVariabilitySDNN: 14 samples — avg 42.785341 ms  latest 44.12 ms"
```

#### 3e. Completion handler API (non-`async` call sites)

If your host app code is not inside an `async` function, use the completion-handler overloads on
`HealthMetricsManager.shared`. Results are always delivered on the **main queue**.

```swift
import humango_health

let end   = Date()
let start = Calendar.current.date(byAdding: .day, value: -30, to: end)!

// ── Single metric, date range ────────────────────────────────────────────────
HealthMetricsManager.shared.fetchMetric(
    .heartRateVariabilitySDNN,
    startDate: start,
    endDate: end
) { result in
    switch result {
    case .success(let payload):
        let stats  = payload["statistics"]  as? [String: Double] ?? [:]
        let latest = payload["latestSample"] as? [String: Any]
        let count  = payload["sampleCount"] as? Int ?? 0
        print("HRV: \(count) samples, avg \(stats["average"] ?? 0) ms, "
              + "latest \(latest?["value"] ?? "–") ms")
    case .failure(let error):
        print("Error: \(error)")
    }
}

// ── Single metric, string key ────────────────────────────────────────────────
// Use this when the metric type comes from a variable/config string.
HealthMetricsManager.shared.fetchMetric(
    key: "restingHeartRate",   // one of: heartRateVariabilitySDNN, restingHeartRate,
                               //         bodyFatPercentage, bodyMass, height
    startDate: start,
    endDate: end
) { result in
    if case .success(let payload) = result {
        print("RHR latest: \(payload["latestSample"] ?? "no data")")
    }
}

// ── Latest sample only ───────────────────────────────────────────────────────
HealthMetricsManager.shared.fetchLatestMetric(.bodyMass) { result in
    switch result {
    case .success(let payload):
        let latest = payload["latestSample"] as? [String: Any]
        let value  = latest?["value"] as? Double ?? 0
        let unit   = payload["unit"] as? String ?? ""
        print("Current weight: \(value) \(unit)")
    case .failure(let error):
        print("Error: \(error)")
    }
}

// ── All metrics at once ──────────────────────────────────────────────────────
HealthMetricsManager.shared.fetchAllMetrics(startDate: start, endDate: end) { payload in
    let metrics = payload["metrics"] as? [String: Any] ?? [:]
    let errors  = payload["errors"]  as? [String: String] ?? [:]

    for (key, data) in metrics {
        let stats = (data as? [String: Any])?["statistics"] as? [String: Double] ?? [:]
        print("\(key): avg \(stats["average"] ?? 0)")
    }
    for (key, message) in errors {
        print("\(key) failed: \(message)")
    }
}
```

---

### 4. Response Shape

Both Flutter and native iOS metric queries return dictionaries with this structure:

```json
{
  "metricType":  "heartRateVariabilitySDNN",
  "unit":        "ms",
  "sampleCount": 14,
  "latestSample": {
    "uuid":         "A1B2C3D4-...",
    "value":        42.785341,
    "unit":         "ms",
    "startDate":    "2026-03-27T02:14:00.000Z",
    "endDate":      "2026-03-27T02:14:00.000Z",
    "sourceName":   "Apple Watch",
    "sourceBundle": "com.apple.health",
    "device": { "name": "Apple Watch", "model": "Watch" },
    "metadata":     {}
  },
  "statistics": {
    "average": 42.785341,
    "min": 38.521847,
    "max": 49.201563,
    "sum": 597.994774
  },
  "fetchedFrom": "2026-02-26T06:30:00.000Z",
  "fetchedTo":   "2026-03-27T06:30:00.000Z",
  "samples": [ "..." ]
}
```

> All numeric values are **raw `Double` with full HealthKit precision** — no rounding is applied at any layer (native or Dart).

---

### 5. Error Handling

```dart
try {
  final response = await metrics.fetchHealthMetric(
    HealthMetricType.heartRateVariabilitySDNN,
  );
} on HealthMetricsException catch (e) {
  switch (e.code) {
    case 'UNKNOWN_METRIC':
      print('Bad metric key: ${e.message}');
    case 'FETCH_ERROR':
      print('HealthKit error: ${e.message}');
    default:
      print('${e.code}: ${e.message}');
  }
}
```

---

### 6. Permission Requirements

Ensure the following types are requested via `PermissionManager.requestAuthorization()`:

| Type | `HealthDataType` |
|------|-----------------|
| `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | `hrv` |
| `HKQuantityTypeIdentifierRestingHeartRate` | `restingHeartRate` |
| `HKQuantityTypeIdentifierBodyFatPercentage` | `bodyFatPercentage` |
| `HKQuantityTypeIdentifierBodyMass` | `bodyMass` |
| `HKQuantityTypeIdentifierHeight` | `height` |

All are included in the plugin's fixed permission set — a single `requestAuthorization()` call covers them all.

---

### 7. Channel

| Channel | Type | Purpose |
|---------|------|---------|
| `com.humango.health/metrics` | MethodChannel | `fetchHealthMetric`, `startMetricMonitoring`, `stopMetricMonitoring`, `stopAllMetricMonitoring` |

---
## Channel Reference

All communication between Flutter and iOS uses these channels:

| Channel | Type | Purpose |
|---------|------|---------|
| `healthkit/method` | MethodChannel | Permission handling (`requestAuthorization`, `verifyAuthorization`) |
| `healthkit/event` | EventChannel | Permission status stream (`permissionStream`) |
| `com.humango.workouts/workoutplan` | MethodChannel | Workout scheduling (push/remove) |
| `com.humango.workouts/read` | MethodChannel | Workout reading (one-shot + monitoring control) |
| `com.humango.health/sleep` | MethodChannel | Sleep data operations |
| `com.humango.health/session` | MethodChannel | Optional: `saveCredentials` if implemented in your Runner (not registered by the plugin itself) |
| `com.humango.health/metrics` | MethodChannel | Health metrics (query-only reads) |

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