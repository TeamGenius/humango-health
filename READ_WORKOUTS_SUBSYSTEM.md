# Read Workouts Subsystem — Requirements & Design

**Document version:** 2.0  
**Date:** March 25, 2026  
**Plugin:** `humango_health` (**0.0.17+**)

## Implementation status

Matches the current repository: **MethodChannel-only** workout reads, **delegate-based** completion delivery, **no** `WorkoutStreamDelivery`, **no** `WorkoutRecordStore`, **no** Dart `workoutStream` / `configureBackgroundDelivery` / `markWorkoutsAsPushed`.

---

## Dart API (`lib/src/managers/workout_read_manager.dart`)

| Method | Purpose |
|--------|---------|
| `readWorkouts(startDate, { endDate, options })` | One-shot; `List<String>` JSON; honors import preferences |
| `fetchAllWorkouts(startDate, { endDate })` | One-shot; unfiltered |
| `startMonitoring(startDate, { options })` | Starts `WorkoutService`; completions → **delegate** |
| `stopMonitoring()` | Stops monitoring |
| `setImportPreferences(...)` | Running / cycling / swimming toggles |

Exported from `package:humango_health/humango_health.dart`.

---

## Native iOS

| Component | Role |
|-----------|------|
| `WorkoutServiceChannel` | Method channel handler; login-gated |
| `WorkoutService` | Anchored live stream (foreground) + observer + background delivery (background); **AppLifecycleObserver** |
| `RouteService` | Routes + quantities; calls **`HumangoHealthDataDelegate.onWorkoutReady`** when a payload is ready |
| `HumangoHealthPlugin` | Registers channel; **`startAllBackgroundMonitoring()`** / **`logout()`** |

**Channel:** `com.humango.workouts/read` (methods only).

---

## Delivery contract

- **One-shot reads:** JSON returned to Dart on the method channel.
- **Monitoring:** JSON delivered on **`HumangoHealthDataDelegate.onWorkoutReady(json:deviceId:)`** in the host Runner.
- **Dedup / “already uploaded”:** Implement in the **host app** (server idempotency, local cache, etc.). The plugin does not persist push state for workouts.

---

## Lifecycle

Foreground vs background switching is **only** via **`AppLifecycleManager`** (native). Removed Dart APIs: `enterForegroundMode` / `enterBackgroundMode` on `WorkoutReadManager` (see CHANGELOG 0.0.17).

---

## Related documentation

- [docs/activity_reading.md](docs/activity_reading.md) — detailed behavior and diagrams  
- [README.md](README.md) — integration and delegate setup  
- [CHANGELOG.md](CHANGELOG.md) — migration notes for removed APIs  
