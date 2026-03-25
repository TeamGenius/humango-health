# Read Workouts Subsystem — Requirements & Design

**Document version:** 2.0  
**Date:** March 25, 2026  
**Plugin:** `humango_health` (aligned with **0.0.17+**)

## Summary

Workout reading uses **`com.humango.workouts/read`** (MethodChannel only). There is **no** `workoutStream`, **no** `configureBackgroundDelivery`, **no** UserDefaults pending queue for workouts, and **no** native `WorkoutRecordStore` — upload deduplication is **host-app owned**.

Completed workouts (after route/quantity assembly in **`RouteService`**) are delivered to the host iOS app through **`HumangoHealthDataDelegate.onWorkoutReady(json:deviceId:)`**. Wire the delegate in your Runner (see [README.md](../README.md#delegate-delivery)).

Foreground vs background HealthKit mode switching is driven by **`AppLifecycleManager`** (native). Do **not** call removed Dart lifecycle methods on `WorkoutReadManager`.

---

## Functional requirements

### Permission

- Host app should ensure HealthKit read access for workouts (and related types) via **`PermissionManager`** before expecting data.
- Method-channel calls that read health data require **`UserAuthStateManager.shared.isLoggedIn == true`** (set from **native** after login — see [README — User session](../README.md#user-session-management)).

### Dart API (`WorkoutReadManager`)

| Method | Description |
|--------|-------------|
| `readWorkouts(startDate, { endDate, options })` | One-shot fetch; returns `List<String>` JSON (respects import preferences). |
| `fetchAllWorkouts(startDate, { endDate })` | One-shot snapshot; **ignores** import preferences. |
| `startMonitoring(startDate, { options })` | Starts continuous monitoring; new completions flow to the **delegate**, not Dart. |
| `stopMonitoring()` | Stops native monitoring. |
| `setImportPreferences(running, cycling, swimming)` | Persists filters in `UserDefaults`; applied on fetch/monitor. |

### Native delivery (monitoring)

When monitoring is active:

- **Foreground:** `WorkoutService` uses **`HKAnchoredObjectQueryDescriptor`** (live workout stream from HealthKit).
- **Background:** **`HKObserverQuery`** + **`enableBackgroundDelivery`** for `workoutType`; on fire, a one-shot anchored fetch runs with an end time of **now** so newly finished workouts are included.
- **Route follow-up:** Workouts whose end time is within **`WorkoutService.liveWindowSeconds`** (2 hours) keep a **`RouteService`** in a registry for live/background route updates; older completions use a one-shot route fetch only.

Completed payloads are emitted via **`HumangoHealthPlugin.delegate?.onWorkoutReady(json:deviceId:)`** (see `RouteService`).

### Import preferences

Dart `setImportPreferences` maps to `UserDefaults` keys (`isImportRunning`, `isImportCycling`, `isImportSwimming`). Types use HealthKit activity **names** (`Running`, `Cycling`, `Swimming`) for exclusion lists.

---

## Architecture

```
Flutter                          iOS
────────                         ───
WorkoutReadManager ──Method───► WorkoutServiceChannel
  readWorkouts                     ├─ batched anchored fetch + processWorkout
  fetchAllWorkouts                 ├─ start/stop → WorkoutService
  startMonitoring                  └─ setImportPreferences → UserDefaults
  stopMonitoring
  setImportPreferences

(no EventChannel for workouts)

                                 WorkoutService (AppLifecycleObserver)
                                   ├─ foreground: anchored live stream
                                   ├─ background: HKObserverQuery
                                   └─ handleWorkouts → RouteService registry

                                 RouteService (per workout)
                                   └─ on completion → HumangoHealthDataDelegate.onWorkoutReady
```

**Channels:** `com.humango.workouts/read` (methods only). **Routing:** `HumangoHealthPlugin.swift`.

**Key Swift files (under `ios/Classes/WorkoutReading/`):** `WorkoutServiceChannel.swift`, `WorkoutService.swift`, `RouteService.swift`.

---

## JSON shape

Method channel and delegate pass **`String` JSON** per workout. Optional Dart parsing: `WorkoutData` / `QuantitySeries` in `lib/src/models/` if the JSON matches your build.

---

## Workflows

### One-shot history (Dart)

```dart
final manager = WorkoutReadManager();
final jsonStrings = await manager.readWorkouts(
  DateTime.now().subtract(const Duration(days: 7)),
  endDate: DateTime.now(),
);
```

### Monitoring + upload (native delegate)

1. After login, set **`UserAuthStateManager.shared.isLoggedIn`**, assign **`HumangoHealthPlugin.delegate`**, call **`HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()`** (pattern in `example/ios/Runner/ExampleSessionChannel.swift`).
2. From Dart: `await workoutReadManager.startMonitoring(...)`.
3. Implement **`onWorkoutReady`** in the delegate to POST JSON to your API; track `deviceId` to dedupe on the server or locally in the host app.

### Logout

**`HumangoHealthPlugin.shared?.logout()`** stops monitors and clears plugin-owned state (see README). Do not expect pending workout JSON in UserDefaults from the plugin.

---

## Platform notes

- **Deployment:** Example app targets **iOS 18**; workout stack uses APIs such as **`HKAnchoredObjectQueryDescriptor`** (see Apple docs for OS version requirements).
- **Simulator:** HealthKit workout data is limited; use a physical device for realistic tests.

---

## Related docs

- [README.md](../README.md) — delegate wiring, session gate, workout section  
- [client_app_integration_guide.md](client_app_integration_guide.md) — host app coordinator pattern  
- [READ_WORKOUTS_SUBSYSTEM.md](../READ_WORKOUTS_SUBSYSTEM.md) — subsystem mirror (keep in sync)  
- [CHANGELOG.md](../CHANGELOG.md) — 0.0.14–0.0.17 breaking removals  
