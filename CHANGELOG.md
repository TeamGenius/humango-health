## 0.0.21 — 2026-03-27

### Breaking Changes

#### Health Metrics — `HealthMetricType` Swift enum introduced as single source of truth

A new `HealthMetricType.swift` enum (public, `CaseIterable`) is now the **single source of truth** for all quantity-metric configuration on the iOS side, mirroring the Dart `HealthMetricType` enum exactly (same `rawValue` / channel key).

Each case carries:
- `identifier: HKQuantityTypeIdentifier`
- `unit: HKUnit` / `unitLabel: String`
- `displayName: String`
- `observerLookbackDays: Int` / `observerSampleLimit: Int`
- `quantityType: HKQuantityType?` (computed)

The private `MetricDescriptor` struct and `metricDescriptors` dictionary in `HealthMetricsManager.swift` have been removed. The private `ObservableQuantityMetric` struct and `observedQuantityMetrics` array in `HRVObserverManager.swift` have been removed. Both files now iterate `HealthMetricType.allCases` directly.

**Changed in:** `ios/Classes/HealthMetrics/HealthMetricType.swift` *(new)*, `ios/Classes/HealthMetrics/HealthMetricsManager.swift`, `ios/Classes/HealthMetrics/HRVObserverManager.swift`

---

#### Health Metrics — `onHealthMetricSamplesReady` delegate parameter changed from `String` to `HealthMetricType`

The `HumangoHealthDataDelegate.onHealthMetricSamplesReady` signature has changed:

```swift
// Before
func onHealthMetricSamplesReady(json: String, metricType: String, fetchedAt: String) async

// After
func onHealthMetricSamplesReady(json: String, metricType: HealthMetricType, fetchedAt: String) async
```

The host app now receives a typed `HealthMetricType` enum value instead of a raw string, enabling direct `switch` dispatch without string parsing. The `metricType.key` property returns the original string value if needed.

**Migration:** Update your `HumangoHealthDataDelegate` implementation to accept `metricType: HealthMetricType` instead of `metricType: String`. Use `metricType.key` to recover the string if your upload contract requires it.

**Changed in:** `ios/Classes/HumangoHealthDataDelegate.swift`, `ios/Classes/HealthMetrics/HRVObserverManager.swift`

---

#### Health Metrics — EventChannel and `HRVStreamHandler` removed; `hrvUpdates` Dart stream removed

`HRVStreamHandler.swift` and the `com.humango.health/metrics/hrv_updates` `FlutterEventChannel` have been deleted. The `hrvUpdates` Dart stream getter and the `EventChannel` constant in `HealthMetricsManager` have been removed.

All delivery — foreground and background — now goes exclusively through `HumangoHealthDataDelegate.onHealthMetricSamplesReady`. There is no Flutter-side stream for metrics.

**Removed from iOS:**
- `ios/Classes/HealthMetrics/HRVStreamHandler.swift` — deleted
- `HumangoHealthPlugin.swift`: `healthMetricsHRVEventChannel` `FlutterEventChannel` registration and `HRVStreamHandler()` set-up removed
- `HRVObserverManager.swift`: `eventSink: FlutterEventSink?`, `attachEventSink(_:)`, `Flutter` import removed

**Removed from Dart:**
- `_hrvEventChannel` `EventChannel` constant — removed from `HealthMetricsManager`
- `hrvUpdates` stream getter — removed from `HealthMetricsManager`
- Unused `dart:async` import removed

**Migration:** Remove any `metricsManager.hrvUpdates.listen(...)` subscriptions and `StreamSubscription` state. Implement `HumangoHealthDataDelegate.onHealthMetricSamplesReady(json:metricType:fetchedAt:)` in your iOS Runner to receive metric batches in both foreground and background.

**Changed in:** `ios/Classes/HealthMetrics/HRVStreamHandler.swift` *(deleted)*, `ios/Classes/HumangoHealthPlugin.swift`, `ios/Classes/HealthMetrics/HRVObserverManager.swift`, `lib/src/managers/health_metrics_manager.dart`

---

### Features

#### Health Metrics — Foreground monitoring upgraded to `HKAnchoredObjectQueryDescriptor`

The foreground monitoring path in `HRVObserverManager` has been upgraded from a one-shot initial fetch to a persistent `HKAnchoredObjectQueryDescriptor` async stream per `HealthMetricType`.

**New behaviour:**
- On `startMonitoring()`, if the app is in the foreground, one `HKAnchoredObjectQueryDescriptor` stream is started per type. Each stream fires whenever HealthKit adds new samples of that type; on each batch the full lookback window is fetched and delivered to the delegate.
- Anchors per type are stored in memory (`[HealthMetricType: HKQueryAnchor]`) and preserved across foreground/background mode switches — the descriptor resumes without missing samples.
- An initial snapshot fetch is performed for all types immediately on foreground entry.
- On `appDidEnterBackground`, descriptor streams are cancelled and `HKObserverQuery` instances are started (previous behaviour). On `appDidEnterForeground`, observers are stopped and descriptor streams are restarted.

**Background path unchanged:** `HKObserverQuery` per type remains the background/suspended delivery mechanism.

| App state | Mechanism | Delivery path |
|-----------|-----------|---------------|
| Foreground | `HKAnchoredObjectQueryDescriptor` (per type) | `HumangoHealthDataDelegate.onHealthMetricSamplesReady` |
| Background / suspended | `HKObserverQuery` (per type) + `enableBackgroundDelivery` | `HumangoHealthDataDelegate.onHealthMetricSamplesReady` |

**Changed in:** `ios/Classes/HealthMetrics/HRVObserverManager.swift`

---

#### Health Metrics — `HealthMetricsManager` circular `rawJson` reference fixed

`convertQuantitySampleToDict` previously set `dict["rawJson"] = dict`, attaching a snapshot of the partially-built dictionary as a nested key. This was unnecessary and confusing. The line has been removed.

**Changed in:** `ios/Classes/HealthMetrics/HealthMetricsManager.swift`

---

### Example App Updates

#### `example/lib/health_metrics_screen.dart` — Removed stream subscription; updated monitoring card

- Removed `dart:async` import, `StreamSubscription _hrvSubscription`, `_lastHrvUpdate`, `_restoreHrvStreamIfNativeMonitoringActive()`, and `_onHrvUpdate()` — no stream to subscribe to.
- `_toggleHRVMonitoring()` now only calls `startHRVMonitoring()` / `stopHRVMonitoring()`.
- `initState` now calls `_restoreMonitoringState()` which reads `isHRVMonitoringActive()` and updates the toggle.
- The auto-read card description updated to explain `HKAnchoredObjectQueryDescriptor` (foreground) / `HKObserverQuery` (background) and delegate-only delivery.
- Last-update label renamed from `'Last update'` to `'Last delegate batch'` (populated by the host delegate, not a Dart stream).

**Changed in:** `example/lib/health_metrics_screen.dart`

#### `example/ios/Runner/ExampleHealthDataHandler.swift` — Updated delegate signature

- `onHealthMetricSamplesReady` signature updated: `metricType: HealthMetricType` (was `String`).
- Log output now includes `sampleCount` extracted from the JSON payload.
- Comment shows the exact `post(path: "metrics/\(metricType.key)", json: json)` pattern to wire upload.
- `extractSampleCount(from:)` private helper added.

**Changed in:** `example/ios/Runner/ExampleHealthDataHandler.swift`

---

## 0.0.20 — 2026-03-26

### Bug Fixes

#### Workout Reading — Route data and quantity samples were always empty

Fixed a critical bug where `fetchWorkoutRoutes` and `fetchAllQuantitySeriesForWorkout` silently returned empty results for every workout.

`HKHealthStore.authorizationStatus(for:)` only reflects **write** (sharing) authorization — Apple intentionally hides read authorization status for privacy. Because the plugin requests read-only access (not write) for routes and quantity types, the status was always `.sharingDenied` / `.notDetermined`, causing both guards (`guard authStatus == .sharingAuthorized`) to bail with `return []` on every fetch.

**Fix:** Removed both incorrect `sharingAuthorized` guards and let HealthKit queries run directly. Queries already return empty results if the user hasn't granted read access, and errors are caught by the existing `do/catch` at each call site.

**Impact:** Workouts with GPS route data now correctly return route locations and quantity samples (e.g. a 34-minute outdoor cycling workout previously showing 0 GPS points now returns 2043 route points and 2740 quantity samples).

**Changed in:** `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`

---

## 0.0.19 — 2026-03-26

### Improvements

#### Workout Reading — `HuWorkout` and `HuRouteData` refactored and hardened

`HuWorkout` and `HuRouteData` have been rewritten to match the server-side API contract and eliminate the processing errors that occurred when the previous implementation produced malformed payloads.

**Key changes:**

- **`struct` instead of `class`** — Both types are now Swift value-types (`struct`), making them thread-safe and copy-safe by default.
- **Type-safe `workoutActivities`** — Changed from `[Any]` to `[HKWorkoutActivity]?`, removing all `compactMap`/`as?` casts at use sites.
- **ISO 8601 timestamps in `HuRouteData.toDict()`** — Location and sample timestamps now use `ISO8601DateFormatter` with `.withInternetDateTime` + `.withFractionalSeconds` instead of Swift string interpolation (`"\(date)"`), which produced non-standard locale-dependent strings and caused server parse failures.
- **`@available(iOS 16.0, *)` annotation** — Added to both types; matches the minimum iOS version used by `HKAnchoredObjectQueryDescriptor` and related APIs.
- **`public` access modifiers** — All properties, `init`, and methods are now `public` for correct framework visibility.
- **Circular `rawJson` reference removed** — The previous `toDict()` had `dict["rawJson"] = dict` which caused `JSONSerialization` to throw and silently return `nil` for every workout.
- **`formatMetadata()` extended** — Added `isScheduledWorkout` → `IS_SCHEDULED_WORKOUT` and `scheduledWorkoutId` → `SCHEDULED_WORKOUT_ID` key mappings so scheduled workout linkage is preserved in the API payload.
- **`HuRouteData.empty()` static helper** — Added for convenience at call sites that synthesise workouts without route data.
- **`toDict()` / `toJson()` split** — `toJson()` now delegates to `toDict()` instead of duplicating the entire serialisation logic.

**Changed in:** `ios/Classes/WorkoutReading/HuWorkout.swift`

---

## 0.0.18 — 2026-03-26

### Breaking Changes

#### Delegate — `onWorkoutReady` now delivers `HuWorkout` instead of a JSON string

The `HumangoHealthDataDelegate.onWorkoutReady` signature has changed:

```swift
// Before
func onWorkoutReady(json: String, deviceId: String)

// After
func onWorkoutReady(workout: HuWorkout, deviceId: String)
```

The delegate now receives the assembled `HuWorkout` struct directly, giving the host app typed access to `workout.sport`, `workout.duration`, `workout.statistics`, `workout.routeData`, `workout.metadata`, etc. without parsing JSON. Call `workout.toDict()` → `JSONSerialization` if you still need a JSON string for upload.

**Migration:** Update your `HumangoHealthDataDelegate` implementation to accept `workout: HuWorkout` instead of `json: String`. See [ExampleHealthDataHandler](example/ios/Runner/ExampleHealthDataHandler.swift) for the updated pattern.

**Changed in:** `ios/Classes/HumangoHealthDataDelegate.swift`, `ios/Classes/WorkoutReading/RouteService.swift`, `example/ios/Runner/ExampleHealthDataHandler.swift`

### Features

#### Workout Scheduling — Expanded sport support (28 HKWorkoutActivityType mappings)

The `Sport` enum now supports 28 workout activity types (up from 4), covering all sports used in the Humango training plans:

| Category | Sports |
|----------|--------|
| **Endurance** | RUNNING, CYCLING, SWIMMING, POOL_SWIMMING, OPEN_WATER_SWIMMING, WALKING, HIKING, ROWING, CARDIO, HIIT, HYROX |
| **Winter** | ALPINE_SKIING, NORDIC_SKIING, SNOWSHOEING |
| **Strength & Flexibility** | STRENGTH, YOGA |
| **Water** | PADDLING |
| **Ball Sports** | SOCCER, TENNIS, SQUASH, PICKLEBALL, BADMINTON, BASEBALL, HOCKEY, VOLLEYBALL, HANDBALL, BASKETBALL |
| **Multi-discipline** | MULTISPORT *(accepted in enum; scheduling deferred — requires SwimBikeRunWorkout builder)* |

**Routing logic:**
- **SWIMMING / POOL_SWIMMING / OPEN_WATER_SWIMMING** → `SingleGoalWorkout` (POOL_SWIMMING forces `.indoor` location; OPEN_WATER_SWIMMING forces `.outdoor`)
- **MULTISPORT** → Skipped at scheduling time with a logged warning (SwimBikeRunWorkout builder is a future task)
- **All other sports** → `CustomWorkout`, with automatic **fallback to `SingleGoalWorkout`** if `CustomWorkout` throws a `StateError` (e.g., ball sports that don't support interval blocks)

**Validation** now derives valid values from `Sport.allCases` — no hardcoded array to maintain.

**Changed in:** `ios/Classes/WorkoutScheduling/WorkoutInstanceModel.swift`, `ios/Classes/WorkoutScheduling/WorkoutPlanManager.swift`, `ios/Classes/WorkoutScheduling/WorkoutPlanBuilder.swift`, `ios/Classes/Extensions/HKWorkoutActivityType+Extensions.swift`, `lib/src/models/enums/workout_enums.dart`

#### Background Monitoring — Individual subsystem start methods

The host app can now start each monitoring subsystem independently instead of all-at-once:

```swift
// Start everything (existing — still works)
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()

// Or start individually:
HumangoHealthPlugin.shared?.startActivityBackgroundMonitoring()      // workouts only
HumangoHealthPlugin.shared?.startSleepBackgroundMonitoring()         // sleep only
HumangoHealthPlugin.shared?.startHealthMetricsBackgroundMonitoring() // HRV / metrics only
```

All four methods share the same login + delegate precondition check. The existing `startAllBackgroundMonitoring()` is unchanged and continues to start all three subsystems.

**Changed in:** `ios/Classes/HumangoHealthPlugin.swift`

---

## 0.0.17 — 2026-03-25

### Breaking Changes

#### Workout Reading — `enterForegroundMode()` / `enterBackgroundMode()` removed from Dart API

The `WorkoutReadManager.enterForegroundMode()` and `WorkoutReadManager.enterBackgroundMode()` Dart methods have been removed. The corresponding `"enterForeground"` / `"enterBackground"` method channel cases have also been removed from `WorkoutServiceChannel.swift` and the plugin's method channel routing in `HumangoHealthPlugin.swift`.

Foreground/background switching is now handled **exclusively** by `AppLifecycleManager`. Both `WorkoutService` and `SleepDataManager` conformant to `AppLifecycleObserver` and register themselves in `init()` — `AppLifecycleManager` drives all transitions automatically via native `UIApplication` notifications. There is no need for Dart to participate.

**Removed from Dart:**
- `WorkoutReadManager.enterForegroundMode()` — removed
- `WorkoutReadManager.enterBackgroundMode()` — removed

**Removed from iOS:**
- `WorkoutServiceChannel`: `"enterForeground"` / `"enterBackground"` switch cases removed; `"enterForeground"` / `"enterBackground"` removed from `loginOptional` set
- `HumangoHealthPlugin`: `"enterForeground"` / `"enterBackground"` removed from workout channel routing list

**Migration:** Remove any calls to `enterForegroundMode()` or `enterBackgroundMode()` — mode switching is fully automatic.

**Changed in:** `lib/src/managers/workout_read_manager.dart`, `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `ios/Classes/HumangoHealthPlugin.swift`

### Bug Fixes

#### Workout Reading — `fetchAllWorkouts` was silently unrouted in `HumangoHealthPlugin`

`WorkoutServiceChannel.handleFetchAllWorkouts` was implemented and exposed via Dart but was missing from the method channel routing allowlist in `HumangoHealthPlugin.swift`. Every `fetchAllWorkouts()` call fell through to `FlutterMethodNotImplemented`. The method is now correctly included in the routing list alongside `readWorkouts`, `startWorkoutMonitoring`, `stopWorkoutMonitoring`, `setImportPreferences`.

**Changed in:** `ios/Classes/HumangoHealthPlugin.swift`

---

## 0.0.16 — 2026-03-25

### Improvements

#### Sleep — inBed / 30-min timer logic removed from background pipeline

The background observer pipeline no longer branches on an inBed check or arms a 15-minute re-check timer. Every `HKObserverQuery` fire now executes the same straight pipeline:

```
observer fires → guard: user logged in
  → fetchSleepSamples(6PM window)
  → calculateSleepPayload (grouping + source selection)
  → delegate.onSleepSessionReady(json:sessionId:)
```

Dead code removed from `SleepDataManager.swift`: `pipelineStartTime`, `stageCounts`, `sourcesFound`, `windowStartStr`/`windowEndStr`, `[STEP 1/2/3]` debug prints, `logPayload()` method, and the old 5-parameter `deliverPayload(samples:queryStart:queryEnd:trigger:pipelineStartTime:)` signature.

All stale comments referencing the old inBed/timer/UserDefaults/KVO pattern have been removed from `HumangoHealthPlugin.swift`, `sleep_data_manager.dart`, and `sleep_data_screen.dart`.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`, `ios/Classes/HumangoHealthPlugin.swift`, `lib/src/managers/sleep_data_manager.dart`, `example/lib/sleep_data_screen.dart`

#### Sleep — dead "Fetch stored data" button removed from example app

The storage icon button in `SleepDataScreen` called `_fetchStoredData()` which was a no-op wrapper around `_fetchSleepData()`. Both are removed — there is no local queue to drain under the delegate delivery model.

**Changed in:** `example/lib/sleep_data_screen.dart`

#### Tests — Sleep background pipeline cross-tested with real dataset

Two new XCTest classes added to `RunnerTests.swift`:

- **`SleepDataManagerCalculateSleepPayloadTests`** (11 tests) — verifies `calculateSleepPayload` against the real 2026-03-23 Apple Watch dataset (391 min = 23 460 s), group filtering (nap suppression, ≥ 3 h requirement, exactly-3 h boundary), key presence, bed/wake times, and sort-order independence.

- **`SleepDataManagerDeliverPayloadTests`** (10 tests) — verifies `deliverPayload` calls `HumangoHealthDataDelegate.onSleepSessionReady` exactly once with valid JSON, correct `TOTAL_SLEEP`, all 14 required keys, `sessionId == BED_TIME`, and that the delegate is correctly suppressed (not called) for short sessions, empty samples, or a nil delegate.

All 21 new tests pass on iPhone 16 simulator (iOS 18.3.1).

**Changed in:** `example/ios/RunnerTests/RunnerTests.swift`, `ios/Classes/SleepData/SleepDataManager.swift` (`deliverPayload` access level `private` → `internal`)

---

## 0.0.15 — 2026-03-24


### Breaking Changes

#### Sleep — Background delivery pipeline removed; delegate replaces local storage

The `SleepBackgroundDeliveryManager` (local UserDefaults queue) and its companion `SleepPayloadObserver` (KVO watcher) have been deleted. The plugin no longer stores finalized sleep sessions in `UserDefaults`. HealthKit now delivers finalized sleep sessions directly to the host app via the **`HumangoHealthDataDelegate`** protocol.

**Removed from iOS:**
- `ios/Classes/SleepData/SleepBackgroundDeliveryManager.swift` — deleted
- `ios/Classes/SleepData/SleepPayloadObserver.swift` — deleted
- `SleepDataManager.swift`: removed `SleepDataKeys`, `deliveryManager` property, `handleFetchStoredSleepData`, `handleClearStoredSleepData`, `handleConfigureSleepBackgroundDelivery`, `handleGetLocalSleepSessions`, `buildRawSnapshot`, `storeSleepDataToUserDefaults`, `fetchStoredSleepDataFromUserDefaults`, `clearStoredSleepData`, all `SleepBackgroundDeliveryManager` references
- `HumangoHealthPlugin.swift`: removed routing for `fetchStoredSleepData`, `clearStoredSleepData`, `enterSleepForeground`, `enterSleepBackground`, `configureSleepBackgroundDelivery`, `getLocalSleepSessions`

**Removed from Dart:**
- `fetchStoredSleepData()` — removed from `SleepDataManager`
- `clearStoredSleepData()` — removed from `SleepDataManager`
- `enterForeground()` — removed from `SleepDataManager`
- `enterBackground()` — removed from `SleepDataManager`
- `configureSleepBackgroundDelivery(SleepBackgroundDeliveryConfig)` — removed from `SleepDataManager`
- `getLocalSleepSessions()` — removed from `SleepDataManager`
- `SleepBackgroundDeliveryConfig` model — removed
- Export removed from `lib/humango_health.dart`

**`SleepDataManager` public API after this change:**

| Method | Signature |
|--------|-----------|
| `getSleepData` | `Future<SleepDataResponse> getSleepData({DateTime? startDate, DateTime? endDate})` |
| `startMonitoring` | `Future<void> startMonitoring({DateTime? startDate})` |
| `stopMonitoring` | `Future<void> stopMonitoring()` |
| `calculateSleepPayload` | `Future<Map<String,dynamic>> calculateSleepPayload({DateTime? startDate, DateTime? endDate})` |

**Migration:** Implement `HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:)` in your iOS Runner. The native `SleepDataManager` calls this delegate directly after finalizing a session — no UserDefaults queue to drain. See [README — Delegate Delivery](#delegate-delivery) for the wiring.

#### Workout Reading — `configureBackgroundDelivery` and `WorkoutStreamDelivery` removed; delegate replaces stream

`WorkoutStreamDelivery.swift` and the `configureBackgroundDelivery` Dart method have been deleted. Completed workouts are delivered directly through `HumangoHealthDataDelegate.onWorkoutReady(json:deviceId:)` — no EventChannel stream, no UserDefaults pending queue, no `BackgroundDeliveryConfig`.

**Removed from iOS:**
- `ios/Classes/WorkoutReading/WorkoutStreamDelivery.swift` — deleted
- `WorkoutServiceChannel.swift`: removed `FlutterStreamHandler` conformance, `eventSink`, `onListen`, `onCancel`, `handleConfigureBackground`

**Removed from Dart:**
- `configureBackgroundDelivery(BackgroundDeliveryConfig)` — removed from `WorkoutReadManager`
- `workoutStream` EventChannel — removed from `WorkoutReadManager`
- `BackgroundDeliveryConfig` model — removed
- Export removed from `lib/humango_health.dart`

**Migration:** Implement `HumangoHealthDataDelegate.onWorkoutReady(json:deviceId:)` in your iOS Runner. Remove all calls to `configureBackgroundDelivery` and any `workoutStream` subscriptions.

#### Example app — `HealthSyncCoordinator` simplified

`ensureBackgroundDeliveryConfigured()` and `backgroundDeliveryStatus` have been removed. `setUserLoggedIn` no longer accepts `configureBackground:`. The coordinator now simply gates `ExampleSessionManager` on login/logout.

---

## 0.0.14 — 2026-03-24

### Breaking Changes

#### Workout Reading — `WorkoutRecordStore` and deduplication removed

The native `WorkoutRecordStore` actor and all associated client-facing Dart API have been removed. Deduplication tracking is the responsibility of the client Flutter app, which has full context on when workouts have been successfully uploaded.

**Removed from iOS:**
- `ios/Classes/WorkoutReading/WorkoutRecordStore.swift` — deleted
- `WorkoutServiceChannel.swift`: removed `shouldPush` / `upsertRecordPending` block from `fetchWorkoutsBatched`, removed `handleMarkWorkoutsAsPushed` and `handleGetWorkoutStoreRecords` handlers
- `RouteService.swift`: removed `shouldPush`, `upsertRecordPending`, and `printAllRecords` calls from `pushWorkout`
- `WorkoutService.swift`: removed `hasRecord`, `updateLastSeen`, `recordFirstSeen` touches from `handleWorkouts`
- `HumangoHealthPlugin.swift`: removed `WorkoutRecordStore.shared.clearAll()` from the logout cleanup path

**Removed from Dart:**
- `markWorkoutsAsPushed(List<String> deviceActivityIds)` — removed from `WorkoutReadManager`
- `getWorkoutStoreRecords()` — removed from `WorkoutReadManager`
- `lib/src/models/workout_store_record.dart` (`WorkoutStoreRecord`) — deleted
- Export removed from `lib/humango_health.dart`

**Migration:** `readWorkouts()` now returns every matching workout that passes the import-preference filter — no dedup gate at the library layer. Track which workouts you have uploaded in your own app state or backend.

**Changed in:** `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `ios/Classes/WorkoutReading/RouteService.swift`, `ios/Classes/WorkoutReading/WorkoutService.swift`, `ios/Classes/HumangoHealthPlugin.swift`, `lib/src/managers/workout_read_manager.dart`, `lib/humango_health.dart`

---

## 0.0.13 — 2026-03-24

### Bug Fixes

#### Workouts — `removeAllScheduledWorkouts` and `removeScheduledWorkouts` were silently no-ops

`removeAllScheduledWorkouts` and `removeScheduledWorkouts` were fully implemented in `WorkoutPlanManager.swift` but never registered in the plugin's method-channel routing table in `HumangoHealthPlugin.swift`. Every call silently fell through to `FlutterMethodNotImplemented`, and the Dart layer swallowed the error by returning a default empty map, making the bug invisible at call sites.

Both methods have been added to the routing allowlist. No behaviour change — only the routing fix was required.

**Changed in:** `ios/Classes/HumangoHealthPlugin.swift`

#### Sleep — Stage durations now match Apple Health displayed values

`buildAggregatedPayload` and `fetchSleepData` previously summed raw `Double` seconds, producing totals that could differ from Apple Health by 1–2 minutes due to floating-point accumulation and tie-rounding errors.

**New algorithm (both accumulation loops):**
1. Convert each sample's `startDate` / `endDate` to **integer epoch seconds** (`Int(date.timeIntervalSince1970)`) to eliminate sub-second floating-point noise.
2. If the resulting integer duration is **< 60 s**, contribute **0 minutes** — these are Watch algorithm micro-artifacts that Apple Health also ignores.
3. Otherwise apply `(intSec + 30) / 60 * 60` — standard integer round-half-up to nearest minute.

This matches Apple Health's own per-segment rounding rule precisely (verified against real samples: 391 min = 6 h 31 m).

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`

---

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

### Example app

The bundled Flutter [`example/`](example/) app demonstrates coordinator + tab flows (including sleep screens that call `calculateSleepPayload` and format durations as `Xh Ym`). See [example/README.md](example/README.md). Production integration patterns also live in [README.md](README.md) and [docs/client_app_integration_guide.md](docs/client_app_integration_guide.md).

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
- **Host app integration** — describe a coordinator module (session + idempotent `configure*`, single stream subscriptions); see [docs/client_app_integration_guide.md](docs/client_app_integration_guide.md). *(Runnable reference: bundled [`example/`](example/) — [example/README.md](example/README.md).)*

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
`getLocalWorkouts()` has been removed from both the Dart API and native iOS layer. Completed workouts are delivered on `workoutStream` when a listener exists, or queued under `BackgroundWorkouts.pending` for your app to consume — the plugin does not POST to your API.

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
The `RouteService` debounce window — the time iOS waits after the last GPS route update before finalising and emitting the workout — has been reduced from **3 minutes** to **1 minute**. Completed workouts reach `workoutStream` / pending storage sooner after the final route point arrives.

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
