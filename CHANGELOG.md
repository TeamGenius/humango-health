## 0.0.6 — 2026-03-18

### New Features

#### Health Metrics — HRV data background fetching
HRV (Heart Rate Variability) can now be observed automatically in foreground, background, and when the app is suspended. iOS wakes the app briefly when new HRV data is written to HealthKit via `enableBackgroundDelivery`.

**Dart API (`HealthMetricsManager`):**
- `startHRVMonitoring()` — Start observing HealthKit for new HRV data; persists across app launches.
- `stopHRVMonitoring()` — Stop HRV observation and background delivery.
- `hrvUpdates` — Stream of HRV updates (emits while app is in foreground and monitoring is active).
- `getPendingHRVUpdates()` — Returns HRV updates collected while the app was in background or suspended; clears the pending list after retrieval.
- `isHRVMonitoringActive()` — Whether HRV monitoring is currently enabled.

**iOS:** `HRVObserverManager` (HKObserverQuery + background delivery) and `HRVStreamHandler` (EventChannel for foreground updates). HRV monitoring auto-starts on app launch when it was previously started (no login gate).

**Changed in:** `ios/Classes/HealthMetrics/HRVObserverManager.swift` (new), `ios/Classes/HealthMetrics/HRVStreamHandler.swift` (new), `ios/Classes/HumangoHealthPlugin.swift`, `lib/src/managers/health_metrics_manager.dart`, `example/lib/health_metrics_screen.dart`

---

## 0.0.5 — 2026-03-15

### New Features

#### Workout Reading — `markWorkoutsAsPushed`
Flutter apps can now explicitly acknowledge that a batch of workouts has been successfully uploaded to the backend. Calling this method marks each `deviceActivityId` as `pushed = true` in the native `WorkoutRecordStore`, so they are excluded from future `readWorkouts` calls. Without this call, workouts remain in `pending` state and would be returned again on the next fetch.

```dart
final count = await workoutManager.markWorkoutsAsPushed(deviceActivityIds);
```

**Changed in:** `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `lib/src/managers/workout_read_manager.dart`

---

#### Workout Reading — `fetchAllWorkouts`
A new unfiltered fetch method that returns every workout in the given date range directly from HealthKit, **bypassing `WorkoutRecordStore` deduplication entirely**. Use this for audit, re-sync, or any scenario where you need a complete snapshot regardless of push history.

```dart
final all = await workoutManager.fetchAllWorkouts(startDate, endDate: endDate);
```

**Changed in:** `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `lib/src/managers/workout_read_manager.dart`

---

#### Workout Reading — `getWorkoutStoreRecords`
Exposes the full contents of the native `WorkoutRecordStore` to Flutter as a typed `List<WorkoutStoreRecord>`. Useful for debugging and testing — shows the pushed/pending state of every workout ID the library has ever seen.

```dart
final records = await workoutManager.getWorkoutStoreRecords();
for (final r in records) {
  print('${r.deviceActivityId} — pushed: ${r.pushed}, size: ${r.dataSize}B');
}
```

**New model:** `lib/src/models/workout_store_record.dart` (`WorkoutStoreRecord`)

**Changed in:** `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `lib/src/managers/workout_read_manager.dart`, `lib/humango_health.dart`

---

#### Workout Scheduling — `sport` field validation
The native JSON decoder previously crashed with an opaque `"The data couldn't be read because it is missing."` platform exception when the top-level `sport` field was absent from the workout JSON. The per-workout validation step now catches this before decoding and returns a clear, actionable error:

```
status: "validation_error"
reason: "Missing required field: 'sport'. Must be one of: RUNNING, CYCLING, SWIMMING, STRENGTH"
```

The rest of the batch continues to be processed normally.

**Changed in:** `ios/Classes/WorkoutScheduling/WorkoutPlanManager.swift`

---

#### Workout Builder — `RECOVERY` block type support
Top-level blocks of type `"RECOVERY"` are now correctly handled as `.recovery` interval steps, matching the existing Flutter mapping. Previously they fell into the `default` case and were silently skipped with a warning log.

Both `buildIntervalBlocks` and `intervalStepPurpose` now mirror the full Flutter mapping:

| Block type | Purpose |
|---|---|
| `REST`, `RECOVERY`, `WARMUP`, `COOLDOWN` | `.recovery` |
| `INTERVAL` (or any other) | `.work` |

**Changed in:** `ios/Classes/WorkoutScheduling/WorkoutPlanBuilder.swift`

---

#### Debug Logging — `WorkoutRecordStore` snapshot
A `printAllRecords(context:)` method has been added to `WorkoutRecordStore`. It is called automatically after every `markWorkoutsAsPushed` call and after every `RouteService` background push, printing a full summary table to the console for easy testing:

```
📋 WorkoutRecordStore [after markWorkoutsAsPushed]: ── ALL RECORDS (3 total) ──
   ✅ pushed  | id: A1B2C3D4-... | size: 48302B | updated: 2026-03-15T10:22:01Z
   ⏳ pending | id: X9Y0Z1W2-... | size: 52100B | updated: 2026-03-15T10:21:58Z
```

**Changed in:** `ios/Classes/WorkoutReading/WorkoutRecordStore.swift`, `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `ios/Classes/WorkoutReading/RouteService.swift`

---

### Bug Fixes

#### Permission Manager — removed noisy debug prints
Removed two debug `print` statements that were polluting the console during normal operation:
- `[PermissionManager] 🗑️ Clearing stale permission snapshot (fresh authorization)` from `PermissionManager.swift`
- `Event listen : { ... }` from `permission_manager.dart`

**Changed in:** `ios/Classes/PermissionManager.swift`, `lib/src/managers/permission_manager.dart`

---

## 0.0.4 — 2026-03-14

### Improvements

#### Workout Scheduling — Broadened Date String Support
The Swift `JSONDecoder` used inside `WorkoutPlanManager.scheduleWorkouts` previously relied on the `.iso8601` date decoding strategy, which requires a timezone designator (`Z` or `±HH:MM`). Dates passed without a timezone suffix (e.g. `2026-03-13T00:30:00`) caused a decoding failure.

The decoder now uses a custom strategy that delegates to `DateUtils.parseDate`, supporting all previously accepted formats plus bare local-time strings:

| Format | Example |
|---|---|
| ISO-8601 with `Z` | `2026-03-13T00:30:00Z` |
| ISO-8601 with offset | `2026-03-13T06:00:00+05:30` |
| ISO-8601 with fractional seconds + `Z` | `2026-03-13T00:30:00.000Z` |
| Milliseconds, no timezone | `2026-03-13T00:30:00.123` |
| Microseconds, no timezone | `2026-03-13T00:30:00.123456` |
| Plain seconds, no timezone *(new)* | `2026-03-13T00:30:00` |

Bare timestamps (no timezone) are interpreted as UTC by `DateUtils`.

**Changed in:** `ios/Classes/WorkoutScheduling/WorkoutPlanManager.swift`

---

#### Tests — `DateUtils.parseDate` Unit Tests Added
18 XCTest cases added to `RunnerTests.swift` covering all supported date string formats, invalid / edge-case inputs, and round-trip consistency checks.

**Changed in:** `example/ios/RunnerTests/RunnerTests.swift`

---

#### Example App — Date Format Test Scenario
A new **"Date Format Tests"** section has been added to the Push Workouts screen. Tapping the button schedules 4 identical workouts for tomorrow, each with a different `date` string format, allowing end-to-end verification that every accepted format flows through the full Dart → Swift → WorkoutKit pipeline without error.

**Changed in:** `example/lib/workout_push_screen.dart`

---

## 0.0.3 — 2026-03-13

### Breaking Changes

#### Workout Reading — `getLocalWorkouts()` removed
`getLocalWorkouts()` has been removed from both the Dart API and native iOS layer. Background workout delivery via `localStorage` mode was redundant — when background monitoring is enabled, all workouts are POSTed directly to the configured API endpoint. There is no offline/local retrieval path needed.

**Removed from Dart (`WorkoutReadManager`):**
- `getLocalWorkouts()` method

**Removed from iOS (`WorkoutServiceChannel.swift`):**
- `case "getLocalWorkouts"` from the method channel switch
- `handleGetLocalWorkouts(_ result:)` private method

**Removed from iOS (`HumangoHealthPlugin.swift`):**
- `"getLocalWorkouts"` from the workout read channel routing list

**Migration:** If you were calling `getLocalWorkouts()` on app startup, switch to `BackgroundDeliveryMode.api`. Workouts will be pushed directly to your API endpoint by the native iOS layer — both in foreground and background — with no additional Flutter call required.

---

### Improvements

#### Workout Route Debounce Reduced (3 min → 1 min)
The `RouteService` debounce window — the time iOS waits after the last GPS route update before finalising and pushing the workout — has been reduced from **3 minutes** to **1 minute**. This means completed workouts are delivered to the API approximately 2 minutes faster after the final route point arrives.

**Changed in:** `ios/Classes/WorkoutReading/RouteService.swift` — `routeUpdateWaitSeconds`

---

## 0.0.2 — 2026-03-13

### Breaking Changes

#### Sleep — EventChannel (live streaming) removed
The `com.humango.health/sleep/stream` EventChannel and all Dart event classes have been removed. Sleep data is no longer streamed sample-by-sample to Flutter. The new architecture accumulates samples into an on-device session and delivers the **complete finalized session** as a single payload.

**Removed from Dart (`SleepDataManager`):**
- `sleepDataStream` getter (EventChannel broadcast stream)
- `SleepDataEvent` abstract class and all subclasses: `SleepSampleEvent`, `SleepSampleDeletedEvent`, `SleepSessionEndedEvent`, `SleepSessionDeliveredEvent`, `SleepDataUnknownEvent`

**Removed from iOS (`SleepDataManager.swift`):**
- `FlutterStreamHandler` conformance, `eventSink`, `onListen`, `onCancel`
- `isAPIMode` branch inside `startLiveUpdates()` — both delivery modes now follow the same accumulation path

**Removed from iOS (`SleepBackgroundDeliveryManager.swift`):**
- `attachEventSink(_:)`, `shouldStreamToEventChannel`, `eventSink` property, `import Flutter`

**Example app (`sleep_data_screen.dart`):**
- Removed `StreamSubscription`, `_liveEvents` list, `_buildLiveEventsSection()`, `_buildEventTile()`, and stream subscription logic from `_startMonitoring` / `_stopMonitoring`

---

### New Features

#### User Session Management
A **login/logout gate** prevents background HealthKit observers from auto-starting before the user has authenticated, and cleanly wipes all stored data on logout.

**New Dart class:**
- `UserSessionManager` — exposes `setUserLoggedIn(bool)` static method

**New iOS class:**
- `UserAuthStateManager` — singleton persisting `isLoggedIn` in `UserDefaults`; gates `autoStartIfConfigured()` in both `WorkoutServiceChannel` and `SleepDataManager`

**New iOS method channel:** `com.humango.health/session`
- `setUserLoginState({ loggedIn: bool })` — sets login state; on `false`, calls `clearAllDataOnLogout()` which stops all monitors and clears all UserDefaults data

**What is cleared on logout:**
| Data | Cleared by |
|------|-----------|
| Workout background delivery config | `BackgroundDeliveryManager.clearConfiguration()` |
| Sleep background delivery config + local sessions | `SleepBackgroundDeliveryManager.clearConfiguration()` |
| Sleep session state (in-progress accumulation) | `SleepSessionDetector` reset |
| Scheduled workouts cache | `ScheduledWorkoutStore` clear |
| Workout dedup record store | `WorkoutRecordStore` clear |
| All active HKObserverQuery / HKAnchoredObjectQuery tasks | Stopped immediately |

---

### Improvements

#### Sleep monitoring — unified foreground/background accumulation
Both `api` and `localStorage` delivery modes now follow the identical foreground accumulation path inside `startLiveUpdates()`. The only difference is the final delivery target when the session ends (HTTP POST vs. `UserDefaults`).

#### Documentation
- `README.md` — fully updated Sleep Data section: removed EventChannel references, added session management section, updated architecture diagram, updated Dual-Mode table, updated Channel Reference table
- `SLEEP_DATA_SUBSYSTEM.md` — removed Event Channel events table, updated architecture diagram, replaced "Live Streaming" code sample, updated delivery mode descriptions

---

## 0.0.1

* Initial release.
