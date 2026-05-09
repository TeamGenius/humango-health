# Humango Health Plugin

A comprehensive Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform.

> **Version 1.0.18** — See [CHANGELOG](CHANGELOG.md) for what's new.

## Table of Contents

- [Features](#features)
- [Consumer app integration](#consumer-app-integration)
- [Documentation](#documentation)
- [Architecture Overview](#architecture-overview)
- [Requirements](#requirements)
- [Monitoring Lifecycle](#monitoring-lifecycle)
- [Delegate Delivery](#delegate-delivery)
- [Permission Handling](#permission-handling)
- [Workout Scheduling (Push)](#push-workouts-scheduling)
  - [Supported Sports](#supported-sports-workout-push)
  - [Swimming Workouts & Pool Size](#swimming-workouts--pool-size)
  - [Removing Scheduled Workouts](#removing-scheduled-workouts)
  - [Remove All Scheduled Workouts](#remove-all-scheduled-workouts)
- [Workout Reading & Monitoring](#workout-reading--monitoring)
- [Sleep Data Reading & Monitoring](#sleep-data-reading--monitoring)
- [Health Metrics Reading & Monitoring](#health-metrics-reading)
- [Biological Sex](#biological-sex)
- [Native iOS Lifecycle Management](#native-ios-lifecycle-management)

## Features

| Feature | Description |
|---------|-------------|
| **Stateless Monitoring Lifecycle** | No auth gate, no persisted flags — client calls `startAllBackgroundMonitoring()` on every app open after setting the delegate; library does nothing until explicitly started |
| **Permission Handling** | Request, verify, and continuously monitor HealthKit permissions |
| **Workout Scheduling** | Push workouts to Apple Watch via WorkoutKit with native deduplication |
| **Workout Reading** | Real-time workout monitoring with foreground/background modes; completed workouts delivered via `HumangoHealthDataDelegate.onWorkoutReady(workout:deviceId:)`; **multisport support** — Triathlon and other multi-activity workouts produce a `sessions` array with per-sub-activity breakdown (sport, duration, distance, events, statistics, series data) |
| **Sleep Data** | On-demand fetch via `getSleepData` (Flutter) or `HumangoHealthPlugin.shared?.fetchSleep(startDate:endDate:)` → `HuSleepSession` (native iOS); raw sample query via `fetchSleepSamples(startDate,endDate)`; background monitoring (native iOS only — foreground Descriptor + background Observer) delivering finalized sessions via `HumangoHealthDataDelegate.onSleepSessionReady(_ session: HuSleepSession)`; `HuSleepSession.toJson()` serialises with legacy backend key names; grouping-based `calculateSleepPayload` algorithm (gap ≤ 2 h, span ≥ 3 h); Apple-platform source priority (Watch/Health app over third-party, identified by bundle prefix `com.apple.health`); **normalised source name** — Apple-platform samples report `sourceName`/`SOURCE` as `"Apple"` instead of device-specific names; second-based precision for all durations; optimized 6 PM HealthKit query window |
| **Health Metrics (HRV, RHR, etc.)** | On-demand fetch via `HealthMetricsManager.fetchHealthMetric` (Flutter + native iOS); background monitoring via `HumangoHealthPlugin.shared.startMetricsMonitoring` (native iOS); delivery via `HumangoHealthDataDelegate.onHealthMetricReady` (re-fetched current-day, not delta); HRV and resting HR filtered to Apple-platform sources only (`com.apple.health` prefix) with user-entered samples (`HKMetadataKeyWasUserEntered`) excluded; **normalised source name** — Apple-platform samples report `sourceName` as `"Apple"` instead of device-specific names (e.g. "Varun's Apple Watch") |
| **Biological Sex** | On-demand read of the user's biological sex from HealthKit via `HealthMetricsManager.fetchBiologicalSex()` (Flutter) or `handleFetchBiologicalSex` (native iOS); returns `"female"`, `"male"`, `"other"`, or `"notSet"`; requires `HealthDataType.biologicalSex` to be included in `requestAuthorization` |
| **Delegate Delivery** | Workouts and finalized sleep sessions are pushed through **`HumangoHealthDataDelegate`** — no plugin-owned payload queues or HTTP |
| **Native Lifecycle Management** | Centralized iOS app lifecycle detection for automatic mode switching |

## Consumer app integration

The plugin **reads HealthKit on the device**. Completed workout and finalized sleep session JSON is pushed to your host app via the **`HumangoHealthDataDelegate`** protocol. Health metrics are **not** pushed; clients query them explicitly through `HealthMetricsManager`. The plugin performs no HTTP and maintains no persistent queues.

Implement `HumangoHealthDataDelegate` in your Runner (see [Delegate Delivery](#delegate-delivery)). On **every app open** when the user is logged in, the host app must assign `HumangoHealthPlugin.delegate` and call `HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()` (plus `startMetricsMonitoring(for:)` for health metrics). The library is fully stateless — there is no auth gate, no persisted flags, and no auto-restart on relaunch. The bundled app uses **`ExampleSessionChannel`** (`com.humango.example/session`) as a reference; copy that pattern in production. See **[example/](example/)** and [`example/README.md`](example/README.md).

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
│  ├─ (Host Runner sets delegate + calls startAllBackgroundMonitoring on every open)│
│  ├─ PermissionManager (permissions)                              │
│  ├─ WorkoutPushManager (scheduling)                              │
│  ├─ WorkoutReadManager (reading/monitoring)                      │
│  └─ SleepDataManager (sleep data)                                │
└──────────────────────────┬───────────────────────────────────────┘
                           │ Method Channels + Event Channels
┌──────────────────────────┴───────────────────────────────────────┐
│                    iOS Native Layer                              │
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

## Monitoring Lifecycle

The library is **fully stateless** — no auth gate, no persisted flags, no auto-restart on relaunch. The client app owns the monitoring lifecycle.

### Contract

On every app open when the user is logged in:

```swift
// 1. Set delegate before any start call
HumangoHealthPlugin.delegate = yourHealthDataHandler

// 2. Start workout + sleep monitoring
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()

// 3. Start health metrics (opt-in per type)
HumangoHealthPlugin.shared?.startMetricsMonitoring(for: [.restingHeartRate, .bodyMass])
```

If `delegate` is `nil` when a start method is called, it is a no-op.

### App-Launch Flow

```
App Launch (foreground or HealthKit background wake)
        │
        ▼
application(_:didFinishLaunchingWithOptions:)   ← REQUIRED first step
        │
        ├─ isLoggedIn == false  ──→  skip
        │
        └─ isLoggedIn == true   ──→  HumangoHealthPlugin.delegate = handler
                                      SleepDataManager.shared.startMonitoring()
                                      WorkoutServiceChannel.shared.startMonitoring()
                                      HealthMetricsManager.shared.startMonitoring(.restingHeartRate)
                                      HealthMetricsManager.shared.startMonitoring(.bodyFatPercentage)
        │
        ▼
HumangoHealthPlugin.register()  (Flutter engine ready)
        │
        └─ All start calls above are idempotent — safe to call again from Flutter session channel
```

> **Why `didFinishLaunchingWithOptions`?** Apple requires `HKObserverQuery` instances to be
> registered here so HealthKit can fire them immediately on a cold background relaunch —
> before the Flutter engine initialises. `HumangoHealthPlugin.shared` is `nil` at this point,
> so the singletons (`SleepDataManager.shared`, `WorkoutServiceChannel.shared`,
> `HealthMetricsManager.shared`) must be called directly.

### Kill + Reopen

After a kill + reopen, all in-process objects are gone. HealthKit background delivery registration **survives** the kill (system-level), but there is no `HKObserverQuery` handler in the new process until the client calls `startAllBackgroundMonitoring()` again. Failing to do so leaves delivery enabled but unhandled — iOS may eventually disable it for the app.

### Logout Cleanup

Call `HumangoHealthPlugin.shared?.logout()` on logout. It:
- Stops all active `HKObserverQuery` and live-stream tasks
- Clears sleep dedup state (`lastDeliveredSessionId`, `lastDeliveredWakeTime`)
- Clears `ScheduledWorkoutStore` (Apple Watch scheduled workouts cache)

Do **not** set a delegate or call start methods after logout until the user logs back in.

---

## Delegate Delivery

---

## Supported Sports (Workout Push)

The plugin supports scheduling the following sports to Apple Watch via WorkoutKit. The `sport` field in push payloads must be one of these values (SCREAMING_SNAKE_CASE):

| Sport Key | JSON Value | HKWorkoutActivityType | Notes |
|-----------|-----------|----------------------|-------|
| `running` | `RUNNING` | `.running` | |
| `cycling` | `CYCLING` | `.cycling` | |
| `swimming` | `SWIMMING` | `.swimming` | `SingleGoalWorkout`; swimming location derived from `indoor_outdoor` (INDOOR → pool, else → openWater) |
| `poolSwimming` | `POOL_SWIMMING` | `.swimming` | `SingleGoalWorkout`; swimming location forced to `.pool` — Apple Watch shows **"Pool Swim"** |
| `openWaterSwimming` | `OPEN_WATER_SWIMMING` | `.swimming` | `SingleGoalWorkout`; swimming location forced to `.openWater` — Apple Watch shows **"Open Water Swim"** |
| `strength` | `STRENGTH` | `.traditionalStrengthTraining` | |
| `hiking` | `HIKING` | `.hiking` | |
| `walking` | `WALKING` | `.walking` | |
| `rowing` | `ROWING` | `.rowing` | |
| `elliptical` | `ELLIPTICAL` | `.elliptical` | |

> **Note:** Unsupported sport values in the push JSON will cause a decoding error. For workout **reading**, all HealthKit activity types are supported — the restriction above applies only to push/scheduling.

---

## Biological Sex

Read the user's biological sex characteristic from HealthKit.

### Permission

Include `HealthDataType.biologicalSex` in your authorization request:

```dart
await permissionManager.requestAuthorization(
  types: [HealthDataType.biologicalSex],
);
```

### Flutter usage

```dart
final metrics = HealthMetricsManager();
final sex = await metrics.fetchBiologicalSex();
// Returns: "female" | "male" | "other" | "notSet"
print('Biological sex: $sex');
```

### Return values

| Value | Meaning |
|-------|---------|
| `"female"` | User has set biological sex to Female in Health app |
| `"male"` | User has set biological sex to Male in Health app |
| `"other"` | User has set biological sex to Other |
| `"notSet"` | User has not set a biological sex value |

> **Note:** `HKBiologicalSex` is a HealthKit *characteristic* — it is not a time-series sample, so there are no date ranges, no samples array, and no monitoring/observer support. A single synchronous read is sufficient.
