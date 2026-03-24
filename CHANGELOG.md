## 0.0.12 — 2026-03-23

### Improvements

#### Sleep — New grouping-based `calculateSleepPayload` algorithm

The background delivery pipeline now uses a grouping algorithm instead of calling `buildAggregatedPayload` directly.

**Algorithm (`calculateSleepPayload(from:)` — `SleepDataManager.swift`):**
1. **Sort** all fetched samples by `startDate`.
2. **Group** consecutive samples where the gap between consecutive sample end→start is ≤ 2 hours. Groups whose total span (from first `startDate` to true max `endDate`) is < 3 hours are discarded as non-sleep noise.
3. **Aggregate** all valid-group samples into the final payload via `buildAggregatedPayload`.

The method is exposed on the Dart side as `SleepDataManager.calculateSleepPayload({DateTime? startDate, DateTime? endDate})`.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`, `lib/src/managers/sleep_data_manager.dart`, `ios/Classes/HumangoHealthPlugin.swift`

### Bug Fixes

#### Sleep — Overlap predicate for HealthKit queries

Previous `HKQueryAnchor`-predicate options used `.strictStartDate` and `.strictEndDate` respectively, which caused samples that *cross* the query-window boundary to be excluded. Both `fetchSleepData` and `fetchSleepSamples` now use `options: []` so overlapping sessions are correctly returned.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`

#### Sleep — Span end-anchor used `group.last.endDate` instead of true max

Samples are sorted by `startDate`, so `group.last` has the latest start but not necessarily the latest end. The span filter and `queryEnd` computation now use `group.max(by: { $0.endDate < $1.endDate })!.endDate`.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`

#### Sleep — Date parsing replaced with `DateUtils.parseDate(from:)`

All five inline `ISO8601DateFormatter().date(from:)` calls in `SleepDataManager.swift` have been replaced with `DateUtils.parseDate(from:)`. This fixes a silent 24-hour fallback that occurred when Flutter passed a local `DateTime.toIso8601String()` string without a timezone suffix (which the bare `ISO8601DateFormatter` cannot parse).

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`

#### Sleep — Duration fields use ceiling rounding

`buildAggregatedPayload` previously truncated fractional seconds using `Int(value)`. All duration fields now use `Int(value.rounded(.up))` so partial seconds are rounded up rather than floor-truncated.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`

### Example App

- Sleep duration values throughout the sleep screen are now displayed as `Xh Ym` (e.g. `6h 27m`) instead of `6.3 hours` / `83 min`.
- Added a **Calculate Payload** test card (teal) that calls `calculateSleepPayload` for a selected date range and shows the grouped result.

**Changed in:** `example/lib/sleep_data_screen.dart`

---

## 0.0.11 — 2026-03-19

### Breaking Changes

#### Sleep — no native HTTP for session payloads; `SleepBackgroundDeliveryMode.api` removed

- **iOS:** `SleepBackgroundDeliveryManager` only stores finalized session JSON in `UserDefaults` (`com.humango.health.sleepPendingLocal`). Legacy keys `com.humango.health.sleepDeliveryMode` / `sleepDeliveryURL` / `sleepDeliveryHeaders` are cleared when delivery is armed. Arming uses `HumangoSleepDeliveryArmed`.
- **Dart:** `SleepBackgroundDeliveryConfig` has only `localStorage` (default). `apiURL` and `headers` are removed. Calling `configureSleepBackgroundDelivery` with `mode: api` fails on iOS with `PlatformException` (e.g. `INVALID_MODE`).
- **Migration:** Call `getLocalSleepSessions()` and POST to your API from Dart or Runner native (same pattern as workout pending JSON).

**Changed in:** `lib/src/models/sleep_background_delivery_config.dart`, `ios/Classes/SleepData/SleepBackgroundDeliveryManager.swift`, `ios/Classes/SleepData/SleepDataManager.swift`, README, subsystem docs.

---

## 0.0.10 — 2026-03-19

### Breaking Changes

#### Workouts — no native HTTP; `BackgroundDeliveryManager` removed

- **Removed** `ios/Classes/WorkoutReading/BackgroundDeliveryManager.swift`. **Added** `WorkoutStreamDelivery.swift`: sends completed workout JSON to Flutter’s `workoutStream` when a listener exists, otherwise appends to `UserDefaults` (`BackgroundWorkouts.pending`). The plugin **never** POSTs workout data to your API.
- **Dart:** `BackgroundDeliveryMode.api` removed. `BackgroundDeliveryConfig` no longer has `apiURL` or `headers`. Calling `configureBackgroundDelivery` from Dart with `mode: api` (legacy JSON) fails on iOS with `PlatformException` (e.g. `INVALID_ARGS`).
- **Auto-start:** Workout monitoring resumes when `HumangoWorkoutStreamDeliveryArmed` is set (after successful `configureBackgroundDelivery`), not when a workout API URL was stored.

**Migration:** Use `workoutStream` and/or consume pending JSON from your app and POST to your backend (Dart or Runner native). Sleep session API mode was removed in **0.0.11** — use local queue + app-side upload. *(Supersedes older changelog text that referred to workout `BackgroundDeliveryMode.api`.)*

**Changed in:** `lib/src/models/background_delivery_config.dart`, `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `ios/Classes/WorkoutReading/RouteService.swift`, README.

---

## 0.0.9 — 2026-03-19

### Improvements

- **Idempotent background delivery configure (iOS):** workout `BackgroundDeliveryManager.configure` (removed in 0.0.10) and `SleepBackgroundDeliveryManager.configure` (sleep) return early when unchanged — safe to call again after login or when rebuilding config.

### Documentation

- **[README.md](README.md)** — consumer integration (guide + contract links, docs index).
- **[docs/client_integration_contract.md](docs/client_integration_contract.md)** & **[docs/client_app_integration_guide.md](docs/client_app_integration_guide.md)** — contract + host-app guide (cross-linked).
- **Example app** — [`HealthSyncCoordinator`](example/lib/health_sync_coordinator.dart) pattern (`Selector`, shared managers, HRV subscription fix).

---

## 0.0.8 — 2026-03-19

### Breaking Changes

#### Sleep — Dart session methods removed

`configureSleepSession()`, `getSleepSessionStatus()`, and `resetSleepSession()` have been removed from the Dart `SleepDataManager` API. These were already non-functional stubs that returned `FlutterMethodNotImplemented` since the native `SleepSessionDetector` was removed in 0.0.7. They are now gone from both the Dart layer and the plugin method channel routing.

**Removed from `SleepDataManager` (Dart):**
- `configureSleepSession({freezeWindowStartHour, freezeWindowEndHour, minimumSleepMinutes, stalenessThresholdMinutes, deepSleepAbsenceWindowMinutes})`
- `getSleepSessionStatus()`
- `resetSleepSession()`

**Removed from `HumangoHealthPlugin.swift` routing:**
- `"configureSleepSession"`, `"getSleepSessionStatus"`, `"resetSleepSession"` removed from the sleep method allowlist

**Migration:** Remove any remaining calls to these methods. Sleep session detection is now fully automatic via the inBed-check pipeline introduced in 0.0.7.

**Changed in:** `lib/src/managers/sleep_data_manager.dart`, `ios/Classes/HumangoHealthPlugin.swift`

---

### Bug Fixes

#### User Session — `autoStartIfConfigured()` not called on runtime login

When `setUserLoggedIn(true)` was called at runtime (i.e. after `HumangoHealthPlugin.register()` had already run), background monitoring never resumed even if API delivery was previously configured in `UserDefaults`. This was because `autoStartIfConfigured()` was only called once during `register()` — if `isLoggedIn` was `false` at that point, the auto-start was skipped and never retried.

**Fix:** `handleSetUserLoginState` now calls `autoStartIfConfigured()` on both `WorkoutServiceChannel` and `SleepDataManager` when `loggedIn = true`. Both methods are idempotent and guard against double-starting.

**Practical impact:** After calling `setUserLoggedIn(true)` at runtime (e.g. after a fresh install where the user logs in for the first time), background monitoring resumes automatically if API delivery was already configured — no extra Flutter call needed.

**Changed in:** `ios/Classes/HumangoHealthPlugin.swift`

---

## 0.0.7 — 2026-03-18

### Breaking Changes

#### Sleep — Background pipeline rewritten; session detector removed

The `SleepSessionDetector` and its multi-factor freeze-window scoring approach have been removed and replaced with a simpler **inBed-check pipeline** that more reliably handles the Apple Watch's limited sleep-stage writing behaviour.

**Removed from iOS (`SleepDataManager.swift`):**
- `SleepSessionDetector` — entire class removed
- `SleepSessionConfig` struct
- `SleepSessionState` enum
- `freezeCheckTimer` instance variable
- `fetchAccumulateAndEvaluate()`, `evaluateAndNotifySessionStatus()`, `notifyFlutterSessionEnded()`

**Removed from method channel (`com.humango.health/sleep`):**
- `configureSleepSession` — no replacement; detection is now automatic
- `getSleepSessionStatus` — removed
- `resetSleepSession` — removed

**New background pipeline (every `HKObserverQuery` trigger):**

```
HKObserverQuery fires
  │
  ├─ guard: user must be logged in
  │
  └─ STEP 1: isUserCurrentlyInBed? (FIRST — before any HealthKit fetch)
       YES → STEP 2–3: compute 6PM window, fetch samples
              STEP 4: store in local cache
              → start 15-min re-check timer
                   Timer fires → isUserCurrentlyInBed?
                     YES → wait for next HKObserver trigger
                     NO  → fetch → buildAggregatedPayload → deliver
       NO  → STEP 2–3: compute 6PM window, fetch samples
              STEP 4: buildAggregatedPayload → deliver immediately
```

**New query window:** `6:00 PM previous day → now` (matches humango-mobile's `SleepStatisticsManager`). Replaces the previous sliding 12-hour window.

**New flat payload format — 14 keys, all durations in minutes:**

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

`TOTAL_SLEEP = SLEEP_LIGHT + SLEEP_DEEP + SLEEP_REM`. Source winner = source with highest `TOTAL_SLEEP` when multiple sources are present.

**Migration:** Remove any calls to `configureSleepSession()`, `getSleepSessionStatus()`, or `resetSleepSession()` — these no longer exist on the method channel.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift` (full rewrite)

---

### New Features

#### Sleep — Remote logging (`SleepRemoteLogger`)

A new **fire-and-forget remote logger** sends a structured JSON event to the Humango logging endpoint at every step of the background sleep pipeline, enabling server-side inspection of background observer activity that is invisible in the Xcode console in production.

- **Endpoint:** `https://humango-api-629346406456.us-central1.run.app/log`
- **Auto-appended fields on every call:** `platform`, `subsystem`, `dateTime`, `userId`, `appVersion`, `buildNumber`
- **Log levels:** `debug`, `info`, `warn`, `error`
- All network errors are non-fatal and never disrupt the sleep pipeline

Every branch of the pipeline emits both a local `debugPrint` and a remote log:

| Step | Level |
|------|-------|
| Observer error | `error` |
| Not logged in (auth guard) | `warn` |
| Observer fired | `info` |
| STEP 1: inBed check result | `info` |
| STEP 2: 6PM window computed | `info` |
| STEP 3: fetch error / empty / success | `error` / `warn` / `info` |
| STEP 4-YES: cached + timer started | `info` |
| Timer fired + re-check result | `info` |
| Timer: still in bed → wait | `info` |
| Timer: woke up → deliver | `info` |
| Payload built (all 14 keys) | `info` |
| Serialization failure | `error` |
| Delivering payload | `info` |
| Pipeline complete (with timing) | `info` |

**New file:** `ios/Classes/SleepData/SleepRemoteLogger.swift`

---

#### User Session — `userId` support

`setUserLoggedIn` now accepts an optional `userId` that is persisted to `UserDefaults` alongside the login flag. `SleepRemoteLogger` automatically attaches this value to every remote log event as `context["userId"]`.

**Dart API change (`UserSessionManager`):**

```dart
// Before
await UserSessionManager.setUserLoggedIn(true);

// After — userId optional; supply on login for tagged remote logs
await UserSessionManager.setUserLoggedIn(true, userId: 'user-abc123');
```

**Persistence:**
- `UserDefaults` key `com.humango.health.userId` — set on login, cleared automatically on logout

**Changed in:** `ios/Classes/UserAuthStateManager.swift`, `ios/Classes/HumangoHealthPlugin.swift`, `lib/src/managers/user_session_manager.dart`

---

#### Example app — Background Delivery Test Setup card

A new test card has been added at the top of the **Sleep Data** screen in the example app, enabling one-tap end-to-end testing of the background delivery pipeline:

| Button | Action |
|--------|--------|
| **Set Logged In** | `UserSessionManager.setUserLoggedIn(true, userId: ...)` with a configurable test user ID |
| **Set Logged Out** | `UserSessionManager.setUserLoggedIn(false)` |
| **Re-apply delivery arm** | `configureSleepBackgroundDelivery` with local-only config (idempotent) |

**Changed in:** `example/lib/sleep_data_screen.dart`

---

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

**Migration:** If you were calling `getLocalWorkouts()` on app startup, use `workoutStream` and/or consume native `BackgroundWorkouts.pending` (see 0.0.10+) and POST from your app — the plugin does not HTTP workouts.

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
| Workout background delivery config | `WorkoutStreamDelivery.clearConfiguration()` |
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
