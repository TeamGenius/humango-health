## 1.0.10 — 2026-04-26

### Bug Fixes

#### Multisport workout JSON: removed parent-level `distance` and `duration`

**iOS (`HuWorkout.swift`):**
- `toMultisportDict()` no longer emits `distance` and `duration` at the top-level workout object. These keys are only meaningful per-session and their presence at the parent level was rejected by the backend. Each session's `distance` and `duration` remain unchanged.

---

## 1.0.9 — 2026-04-26

### Features

#### Biological sex reading from HealthKit

Added support for reading the user's biological sex characteristic from HealthKit end-to-end.

**iOS (`PermissionManager.swift`):**
- `readTypes` now includes `HKCharacteristicType.characteristicType(forIdentifier: .biologicalSex)` so the full-type permission request covers biological sex.
- `filteredReadTypes(for:)` handles the `"HKCharacteristicTypeIdentifierBiologicalSex"` identifier string, allowing targeted permission requests.

**iOS (`HealthMetricsManager.swift`):**
- New `case "fetchBiologicalSex"` in `handle(_:result:)` routing.
- New private `handleFetchBiologicalSex(result:)` — reads `healthStore.biologicalSex()` and returns `["biologicalSex": "female" | "male" | "other" | "notSet"]` on the main queue.

**iOS (`HumangoHealthPlugin.swift`):**
- Added `"fetchBiologicalSex"` and `"fetchLatestHealthMetric"` to the method routing allowlist so both reach `HealthMetricsManager.shared.handle`.

**Dart (`HealthDataType`):**
- New `biologicalSex` case with identifier `HKCharacteristicTypeIdentifierBiologicalSex` — pass to `requestAuthorization(types:)` to prompt the HealthKit permission sheet.

**Dart (`HealthMetricsManager`):**
- New `fetchBiologicalSex()` → `Future<String?>` — invokes `fetchBiologicalSex` on the `com.humango.health/metrics` channel and returns one of `"female"`, `"male"`, `"other"`, `"notSet"`, or throws `HealthMetricsException` on error.

**Example app (`health_metrics_screen.dart`):**
- Biological Sex card added to the Health Metrics Fetch tab with gender-appropriate icon/colour, loading spinner, error display, and a manual refresh button.

---

## 1.0.8 — 2026-04-25

### Enhancements

#### Normalised Apple source name for health metrics and sleep data

When returning HealthKit samples to the client, samples from Apple-platform
sources (`com.apple.health` bundle prefix — Apple Watch, iPhone Health app) now
report `sourceName` / `SOURCE` as `"Apple"` instead of the raw device name
(e.g. "Varun's Apple Watch"). The full bundle identifier is still available in
`sourceBundle` / `SOURCE_BUNDLE`.

**Affected serialisation points:**

- `HealthMetricsManager.convertQuantitySampleToDict()` — `sourceName` normalised
- `HealthMetricMonitor.buildSampleDict()` — `sourceName` normalised
- `SleepDataManager.convertSampleToHuSleepSample()` — per-sample `sourceName` normalised
- `SleepDataManager.buildAggregatedPayload()` — grouping key normalised so Apple Watch
  and iPhone Health samples merge under a single `"Apple"` source; `SOURCE` field normalised

**New utility:**

- `HealthKitConverter.normalizedSourceName(name:bundle:)` — returns `"Apple"` when
  `bundle.hasPrefix("com.apple.health")`, raw name otherwise

**Not changed:** Workout channels (`WorkoutServiceChannel`, `RouteService`) — `dataSource`
metadata is left as-is. Dart models are unchanged — they parse whatever the native side sends.

---

## 1.0.7 — 2026-04-25

### Features

#### Multisport workout support (Triathlon / SwimBikeRun)

Multisport workouts (e.g. Triathlon recorded on Apple Watch) now produce a
sessions-based JSON payload where each sub-activity (Run, Transition, Bike,
Transition, Swim) is a separate session object.

**iOS — `HuWorkout`:**

- New `isMultisport` computed property — `true` when `workoutActivities.count > 1`
- `toDict()` now branches: multisport workouts produce a top-level object with a
  `sessions` array; single-sport workouts use the existing flat format (no breaking change)
- Each session includes: `session_id`, `sport`, `start_time`, `end_time`, `duration`,
  `distance` (summed from per-activity statistics), `events`, `statistics`, `metadata`,
  and `series_data` (full workout data duplicated per session)
- New `extractDistance(from:)` helper sums `distanceWalkingRunning`, `distanceCycling`,
  and `distanceSwimming` from an activity's `HKStatistics`

**Multisport JSON structure:**

```json
{
  "start_time": "...",
  "end_time": "...",
  "activity_id": "<uuid>",
  "sport": "Triathlon",
  "duration": 935,
  "distance": 1660,
  "sessions": [
    {
      "session_id": "<uuid>_0",
      "sport": "Running",
      "type": "session",
      "start_time": "...",
      "end_time": "...",
      "duration": 347,
      "distance": 30,
      "series_data": { ... },
      "statistics": [ ... ],
      "events": [ ... ],
      "metadata": { ... }
    },
    { "sport": "Other", ... },
    { "sport": "Cycling", ... },
    ...
  ]
}
```

**Dart — `WorkoutData`:**

- New `WorkoutSession` class — mirrors the per-session JSON fields
- `WorkoutData.sessions` — `List<WorkoutSession>?`, non-null for multisport workouts
- `WorkoutData.isMultisport` — convenience getter
- `WorkoutData.fromJson()` — parses `sessions` key when present; resolves `series_data`
  from either `series_data` or legacy `routeData` key; reads `device_activity_id` with
  `deviceActivityId` fallback

### Bug Fixes

#### Fixed `QuantitySeries.fromSamplesJson` crash on formatted dict input

`QuantitySeries.fromSamplesJson()` only handled raw arrays
(`[{quantityType, startDate, value}]`) but `HuRouteData.toDict()` produces a
formatted dict (`{type: "HK...", series: [{value, timestamp}]}`). When the parser
tried to call `.first` on a Map, Dart threw
`type 'String' is not a subtype of type 'int' of 'index'`. Added a `Map` branch
that handles the `{type, series}` format.

#### Fixed `WorkoutData.fromJson` crash on iOS statistics format

iOS sends `statistics` as `List<Map<String, double>>` (e.g.
`[{"HKQuantityTypeIdentifierHeartRate": 72.5}]`), but `activeCalories` parsing
tried `json['statistics']?['activeEnergy']?['sum']` — indexing a `List` with a
`String` key. Replaced with `_extractActiveCalories()` that safely handles both
the `List` format (iOS) and the legacy nested `Map` format.

### Example App

- Simplified Read Workouts screen: date+time pickers, single Fetch button, tap-to-view
  raw JSON with copy-to-clipboard
- Multisport workouts show session count badge and per-session breakdown
  (sport, duration, distance with colored dots)
- Removed import preference toggles and live monitoring controls from the read screen

---

## 1.0.6 — 2026-04-23

### Enhancements

#### Apple-source filtering and user-entry exclusion for HRV and resting heart rate

`HealthMetricsManager.fetchMetricSamples` now applies a two-step filter pipeline
for metrics where `HealthMetricType.requiresAppleSourceFilter` is `true`
(currently `heartRateVariabilitySDNN` and `restingHeartRate`):

**Step 1 — Drop user-entered samples**
Samples where `HKMetadataKeyWasUserEntered == true` are excluded before any
source check. Manually entered values are not sensor measurements and skew statistics
such as the daily average.

**Step 2 — Prefer Apple-platform sources**
From the remaining samples, only those whose `sourceBundle` is prefixed by
`com.apple.health` (Apple Watch and the Health app) are kept. Falls back to all
remaining samples when no Apple samples exist.

`bodyFatPercentage`, `bodyMass`, and `height` are unaffected —
`requiresAppleSourceFilter` is `false` for those types.

**`HealthMetricType`** — new property added to `HealthMetricType.swift`:

```swift
var requiresAppleSourceFilter: Bool
// .heartRateVariabilitySDNN → true
// .restingHeartRate         → true
// .bodyFatPercentage        → false
// .bodyMass                 → false
// .height                   → false
```

To add filtering for a future metric type, flip its flag to `true` in
`HealthMetricType` — no changes to `HealthMetricsManager` are required.

---

## 1.0.5 — 2026-04-21

### Bug Fixes

#### Fixed build error: `convertSampleToDict` removed but still referenced in `handleFetchSleepSamples`

After renaming `convertSampleToDict` to `convertSampleToHuSleepSample` in `1.0.4`,
the `handleFetchSleepSamples` Flutter method channel handler still called the deleted
method, causing a Swift compiler error on device builds:

```
Value of type 'SleepDataManager' has no member 'convertSampleToDict'
```

The call site in `handleFetchSleepSamples` now uses
`convertSampleToHuSleepSample($0).toDict(formatter:)`, which produces the same
`[[String: Any]]` shape for the Dart method channel.

---

## 1.0.4 — 2026-04-21

### Breaking Changes

#### Type-safe `HuSleepSession` model replaces `[String: Any]` / JSON-string sleep API

All sleep delivery and fetch APIs now use the strongly-typed `HuSleepSession` struct
(and nested `HuSleepSample` / `HuSleepDevice`) instead of untyped dictionaries or raw
JSON strings. This mirrors the existing `HuWorkout` pattern.

**`HumangoHealthDataDelegate`** — signature change:

```swift
// Before
func onSleepSessionReady(json: String, sessionId: String) async

// After
func onSleepSessionReady(_ session: HuSleepSession) async
```

Host apps that previously decoded the raw JSON string can now access all fields
directly on the struct. To send the same JSON payload to a backend, call
`session.toJson()` — key names are identical to the legacy flat payload
(`SOURCE`, `TOTAL_SLEEP`, `BED_TIME`, etc.), so no backend changes are required.

**`HumangoHealthPlugin.fetchSleep(startDate:endDate:)`** — return type change:

```swift
// Before
public func fetchSleep(startDate: Date, endDate: Date) async throws -> [String: Any]

// After
public func fetchSleep(startDate: Date, endDate: Date) async throws -> HuSleepSession
```

**New types** — `ios/Classes/SleepData/HuSleepSession.swift`:

| Type | Description |
|------|-------------|
| `HuSleepSession` | Aggregated session: source, all stage durations, bed/wake times, query window, samples |
| `HuSleepSample` | Single HealthKit sleep-analysis sample with typed fields |
| `HuSleepDevice` | Device information attached to a sample |

`HuSleepSession` provides `toDict() -> [String: Any]` and `toJson() -> String?` for
backend serialisation. The `samples` array is populated when calling `fetchSleep`;
it is empty (`[]`) in the delegate delivery path (background monitoring).

---

## 1.0.3 — 2026-04-21

### Enhancements

#### Exposed `fetchSleep(startDate:endDate:)` on `HumangoHealthPlugin` for native iOS callers

Native iOS host apps can now query aggregated sleep data on-demand without going through
the Flutter method channel.

**`HumangoHealthPlugin`** — new public method:

```swift
public func fetchSleep(startDate: Date, endDate: Date) async throws -> [String: Any]
```

Delegates to `SleepDataManager.shared.fetchSleepData(startDate:endDate:)` and returns
the same dictionary shape already used by the `getSleepData` Flutter channel method:

| Key | Type | Description |
|-----|------|-------------|
| `samples` | `[[String: Any]]` | Per-sample list (Apple-source filtered) |
| `sampleCount` | `Int` | Number of samples after source filter |
| `totalSleepSeconds` | `Double` | Total sleep (Core + Deep + REM) in seconds |
| `totalSleepMinutes` | `Double` | Same value in minutes |
| `totalSleepHours` | `Double` | Same value in hours |
| `stageTotals` | `[String: Any]` | Per-stage seconds + minutes breakdown |
| `fetchedFrom` | `String` | ISO8601 query start date |
| `fetchedTo` | `String` | ISO8601 query end date |

Example usage:

```swift
let end   = Date()
let start = Calendar.current.date(byAdding: .day, value: -1, to: end)!

let sleep = try await HumangoHealthPlugin.shared?.fetchSleep(
    startDate: start, endDate: end
) ?? [:]

let totalHours = sleep["totalSleepHours"] as? Double ?? 0
```

**`SleepDataManager`** — `fetchSleepData(startDate:endDate:)` access widened from
`private` to `internal` so `HumangoHealthPlugin` can delegate to it. The method was
already used internally for the Flutter method channel; this change does not affect
Flutter callers.

---

## 1.0.2 — 2026-04-20

### Bug Fixes

#### Removed redundant `workoutPlan` fetch from `fetchWorkoutsBatched`

A `withCheckedContinuation` block that fetched `workout.workoutPlan` (with a 15-second
timeout) was being executed **per workout** inside the `fetchWorkoutsBatched` loop in
`WorkoutServiceChannel`. The result was never used — the fetch existed only to produce
a debug log line. This added up to 15 seconds of latency for every workout in the batch.

Removed the block and its associated debug print. Scheduled workout resolution is
still performed inside `processWorkout` (via `try? await workout.workoutPlan`) and via
the dedicated `resolveScheduledWorkoutId(workoutUUID:)` public API, both of which
are unchanged.

---

## 1.0.1 — 2026-04-19

### Enhancements

#### Observer registration moved to `application(_:didFinishLaunchingWithOptions:)`

Apple requires `HKObserverQuery` instances to be registered synchronously in
`application(_:didFinishLaunchingWithOptions:)` so HealthKit can fire them immediately
on a cold background relaunch — before the Flutter engine initialises.

**`AppDelegate.swift`** (example app) — `didFinishLaunchingWithOptions` now reads
`UserDefaults` for `"com.humango.example.isLoggedIn"`. When `true`, it directly calls:
- `SleepDataManager.shared.startMonitoring()`
- `WorkoutServiceChannel.shared.startMonitoring()`
- `HealthMetricsManager.shared.startMonitoring(.restingHeartRate)`
- `HealthMetricsManager.shared.startMonitoring(.bodyFatPercentage)`

This covers the case where iOS kills the app under memory pressure and then relaunches
it in the background to deliver a HealthKit notification — a scenario where
`HumangoHealthPlugin.shared` is `nil` and Flutter channel calls cannot be made.

#### `WorkoutServiceChannel` made a singleton and `public`

`WorkoutServiceChannel` is now `public class` with `public static let shared` and
`private override init()`. `HumangoHealthPlugin` uses `WorkoutServiceChannel.shared`
instead of allocating a new instance. This allows `AppDelegate` to call
`WorkoutServiceChannel.shared.startMonitoring()` directly without depending on
`HumangoHealthPlugin.shared`.

`startMonitoring()` is now `public func`.

#### `SleepDataManager` visibility

`SleepDataManager.shared` and `startMonitoring()` are now `public`, allowing
`AppDelegate` to call them directly on cold background launch.

#### `HealthMetricsManager.shared` made `public`

`public static let shared` so `AppDelegate` can call `startMonitoring(_:)` directly.

#### `HealthMetricMonitor.stopBackgroundMonitoring` — removed `disableBackgroundDelivery`

Calling `disableBackgroundDelivery` on every foreground transition globally unregistered
the HealthKit wake-up for the metric type, preventing background delivery after the first
foreground → background cycle. Removed entirely. Background delivery now stays enabled
for the lifetime of the app install, matching the existing `WorkoutService` and
`SleepDataManager` behaviour.

#### All monitoring entry points aligned

All three monitoring entry points in the example app now start Sleep + Workouts +
HealthMetrics consistently:

- **`setLoggedIn`** — added `startSleepBackgroundMonitoring()` and
  `startMetricsMonitoring(for: [.restingHeartRate, .bodyFatPercentage])`
- **`startBackgroundMonitoring`** — uncommented
  `startMetricsMonitoring(for: [.restingHeartRate, .bodyFatPercentage])`;
  added `UserDefaults.set(true, forKey: "com.humango.example.isLoggedIn")`
- **`stopBackgroundMonitoring`** — added
  `UserDefaults.set(false, forKey: "com.humango.example.isLoggedIn")`
- **`AppDelegate.didFinishLaunchingWithOptions`** — added HealthMetrics registration



---

## 1.0.0 — 2026-04-17

### Breaking Changes

#### Library is now fully stateless — `UserAuthStateManager` and `MonitoringConfig` removed

The library no longer persists any auth-state or per-subsystem flags. All auto-start logic
(`autoStartPersistedSubsystems`, `autoStartIfConfigured`) has been removed.

**Deleted files:**
- `ios/Classes/UserAuthStateManager.swift`
- `ios/Classes/MonitoringConfig.swift`
- `lib/src/managers/user_session_manager.dart`
- `HumangoHealthPlugin.startActivityBackgroundMonitoring()` — use `startAllBackgroundMonitoring()` instead

**New contract:** The client app calls start methods on every app open after setting the delegate.
The library does nothing until explicitly started.

**`HumangoHealthPlugin.swift`** — removed `guardMonitoringPreconditions()`,
`autoStartPersistedSubsystems()`, and `startActivityBackgroundMonitoring()`; all start methods now
guard on `delegate != nil` only; `logout()` stops active monitors without clearing non-existent flags.

**`WorkoutServiceChannel.swift`** — replaced `autoStartIfConfigured()` with `startMonitoring()`
(delegate-nil guard only); registers `HKObserverQuery` synchronously via `prepareBackgroundObserver()`
before the async `Task` when the app is in the background; `handleStartMonitoring` is idempotent
(returns immediately when `workoutService != nil`).

**`WorkoutService.swift`** — added `prepareBackgroundObserver()` for synchronous cold-background
observer registration; `startBackgroundMonitoring()` stops any stale observer before re-registering
(prevents orphaned `HKObserverQuery` leaks).

**`SleepDataManager.swift`** — replaced `autoStartIfConfigured()` with `startMonitoring()`
(delegate-nil guard only); `stopBackgroundMonitoring()` no longer calls `disableBackgroundDelivery` —
background delivery stays persistently enabled across foreground transitions. This was the root cause
of sleep observers permanently breaking after a foreground → background transition cycle.

**`HealthMetricsManager.swift`** — removed `autoStartIfConfigured()` and `MonitoringConfig` flag
writes from Flutter channel handlers.

**`SleepRemoteLogger.swift`** — removed `userId` block entirely.

**`ExampleSessionChannel.swift`** (example app) — removed `UserAuthStateManager.shared.isLoggedIn = true`;
`setLoggedIn` now sets delegate and calls `startAllBackgroundMonitoring()` directly.

### Migration Guide

**Before (≤ 0.0.39):**
```swift
// On login (once)
UserAuthStateManager.shared.isLoggedIn = true
HumangoHealthPlugin.delegate = handler
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()   // arms flags, auto-restarts on relaunch
```

**After (1.0.0):**
```swift
// On EVERY app open when user is logged in
HumangoHealthPlugin.delegate = handler
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()
HumangoHealthPlugin.shared?.startMetricsMonitoring(for: [.restingHeartRate, .bodyMass])
```

No `isLoggedIn` flag to set. No auto-restart on relaunch — client is responsible for calling
start methods on every open.

---

## 0.0.39 — 2026-04-15

### Enhancements

#### SleepDataManager — 3-tier source-priority filter in `calculateSleepPayload`

Rewrote `calculateSleepPayload(from:)` to apply a strict source-priority hierarchy before
gap-grouping, ensuring that data from different devices/apps is never mixed into a single
aggregated payload.

**Tier 1 — Apple-platform samples (highest priority):**  
If any sample has a `sourceBundle` prefixed with `com.apple.health` (covers Apple Watch and
the iPhone Health app), **only those samples** are used. All third-party samples are discarded
and the method returns immediately. This is the common case for users wearing Apple Watch.

**Tier 2 — Known fitness-tracker exclusion:**  
If no Apple samples exist, samples from known fitness-tracker bundles (Whoop, Garmin Connect,
Oura, Coros, Fitbit, Hammerhead, Polar, Suunto, Wahoo) are stripped from the pool before
proceeding. These sources have historically produced unreliable or duplicate data.

**Tier 3 — Per-bundle independent calculation:**  
The remaining samples are grouped by `sourceBundle`. Gap-grouping and `buildAggregatedPayload`
are run **independently per bundle**. The payload with the highest `TOTAL_SLEEP` is returned.
Samples from two different bundle IDs are never passed to `buildAggregatedPayload` together.

Added private helper `runGroupingAndCalculation(on:label:)` containing the extracted
gap-grouping + span-filter + `buildAggregatedPayload` pipeline (called by Tier 1 and each
Tier 3 bundle iteration).

Added private static constant `excludedThirdPartyBundles` listing all Tier 2 prefixes.

---

## 0.0.38 — 2026-04-14

### Bug Fixes

#### WorkoutService — dangling reference on logout (`deallocated with non-zero retain count`)

Fixed the same class of memory-management bug as `HealthMetricMonitor` in `WorkoutService`.

**Bug 1 (primary):** `deinit` called `AppLifecycleManager.removeObserver(self)`, which dispatches
an `async(flags: .barrier)` block that strongly captures `self`, extending its retain count past
`deinit` and producing the dangling-reference warning.

- **Fix:** Removed `removeObserver` from `deinit`. Added an `invalidate()` method (mirrors
  `HealthMetricMonitor.invalidate()`) that sets `authorized = false`, stops both monitoring paths,
  and calls `removeObserver` explicitly — all while the strong reference from `WorkoutServiceChannel`
  still holds the object alive, so the async capture is safe.

**Bug 2 (secondary):** `WorkoutServiceChannel.stopAndClearAll()` called `stopLiveUpdates()` and
`stopBackgroundMonitoring()` separately then nilled the reference, but never set `authorized = false`.
Any in-flight lifecycle callback (`appDidEnterForeground` / `appDidEnterBackground`) dispatched
between the two stop calls and `workoutService = nil` could restart monitoring mid-logout.

- **Fix:** `stopAndClearAll()` now calls `workoutService?.invalidate()` (which sets `authorized = false`
  as its first action) before releasing the reference.

---

#### HealthMetricMonitor — dangling reference on logout (`deallocated with non-zero retain count`)

Fixed three memory-management bugs in `HealthMetricMonitor` that together caused the
`Object deallocated with non-zero retain count 2` warning on every logout.

**Bug 1 (primary):** `deinit` called `AppLifecycleManager.removeObserver(self)`, but
`removeObserver` dispatches an `async(flags: .barrier)` block that strongly captures the
observer argument. This extended the retain count past `deinit`, producing the dangling
reference. The logs confirmed the ordering: `"deallocated"` appeared before
`"Removed observer"`, meaning the async block ran against already-freed memory.

- **Fix:** Removed `removeObserver` from `deinit`. `invalidate()` already handles
  deregistration synchronously. `NSHashTable.weakObjects()` clears the entry automatically
  when the object is deallocated.

**Bug 2:** `stopBackgroundMonitoring()` passed `self.metricType.key` into the
`disableBackgroundDelivery` completion handler, creating a strong `self` capture. HealthKit
calls this callback asynchronously, so it could fire against a deallocated object.

- **Fix:** Captured `metricType.key` as a local `let key` constant before registering the
  closure. No `self` reference inside the callback.

**Bug 3:** `startBackgroundMonitoring()` launched a bare `Task {}` for
`enableBackgroundDelivery` with an implicit strong `self` capture. If `invalidate()` ran
before the task completed, `self` was kept alive past its intended lifetime.

- **Fix:** Changed to `Task { [weak self] in guard let self else { return } … }` with the
  pre-captured `key` used for log messages inside the task.

---

## 0.0.37 — 2026-04-13

### Breaking Changes

#### Sleep — removed `startMonitoring` / `stopMonitoring` Flutter API

The `startMonitoring({startDate})` and `stopMonitoring()` Dart methods have been
removed from `SleepDataManager` along with their native counterparts:

- Removed Dart: `SleepDataManager.startMonitoring()`, `SleepDataManager.stopMonitoring()`
- Removed native handlers: `handleStartMonitoring`, `handleStopMonitoring`
- Removed channel methods from routing: `startSleepMonitoring`, `stopSleepMonitoring`

Sleep background monitoring is started exclusively through the native iOS API
(`HumangoHealthPlugin.shared.startSleepBackgroundMonitoring()` /
`startAllBackgroundMonitoring()`). There is no Flutter-side start/stop API.

### Features

#### Sleep — `getSleepData` now uses `calculateSleepPayload` for duration calculation

`fetchSleepData` (backing the `getSleepData` method channel call) has been refactored
to use the same calculation pipeline as the background monitoring path:

- Delegates to `fetchSleepSamples(from:to:)` — single canonical HealthKit query with debug logging
- Delegates duration math to `calculateSleepPayload` — applies Apple-source priority filter
  (`com.apple.health` prefix), gap-based session grouping (≤ 2 h), and span filter (≥ 3 h)
- `stageTotals` values now come from `SLEEP_*` payload keys rather than raw per-sample accumulation
- `samples` array is filtered with the same `com.apple.health` prefix filter so sample list
  and totals are consistent

**Before:** `getSleepData` had its own duplicate `HKSampleQuery`, no Apple-source filter,
and manually accumulated stage durations per-sample.

**After:** `getSleepData` → `fetchSleepSamples` → `calculateSleepPayload` — identical
pipeline to background monitoring.

---

## 0.0.36 — 2026-04-13

### Features

#### Sleep Data — expose raw `fetchSleepSamples` query (Flutter + iOS bridge)

Added a new sleep method-channel API to fetch raw `HKCategorySample` sleep records
for an explicit date window (without aggregation):

- New channel method: `fetchSleepSamples`
- Routed in `HumangoHealthPlugin.handle(...)` to `SleepDataManager`
- New native handler `handleFetchSleepSamples` in `SleepDataManager`
- Supports optional ISO `startDate` / `endDate` args (defaults to last 24 hours)
- Returns serialized sample dictionaries in the same shape as
  `getSleepData().samples`
- New Dart API: `SleepDataManager.fetchSleepSamples({startDate, endDate})`
  returning `List<SleepSample>`

---

## 0.0.35 — 2026-04-11

### Bug Fixes

#### `requestAuthorizationForWorkoutPush` — removed unnecessary HealthKit authorization

`requestWorkoutPushAuthorization()` in `WorkoutPlanManager` was calling
`ensureHealthKitWorkoutTypesAuthorized()` before requesting WorkoutKit authorization.
Since this method is purely for WorkoutKit scheduling permissions, the HealthKit
pre-authorization step was unnecessary and could present a confusing HealthKit
permission dialog to the user.

**Before:** Requested HealthKit write (`HKWorkoutType`) + read (`HKWorkoutType`,
`HKWorkoutRoute`) authorization, then WorkoutKit scheduling authorization.

**After:** Requests only `WorkoutScheduler.shared.requestAuthorization()` (WorkoutKit).

> The HealthKit pre-authorization call remains in the scheduling path
> (`scheduleWorkoutsFromFlutter`) where it is still needed.

---

## 0.0.34 — 2026-04-10

### Features

#### Monitoring Config — Per-subsystem auto-start flags persisted across launches

**New: `MonitoringConfig`** (`ios/Classes/MonitoringConfig.swift`)

A new singleton that persists per-subsystem flags to `UserDefaults` to explicitly gate which
HealthKit observers auto-restart on every app relaunch.

Previous behaviour — every relaunch with `isLoggedIn = true` and a delegate set would auto-start
**all** subsystems unconditionally. The new behaviour requires the host app to deliberately arm
each subsystem at least once (via a native iOS call or a Flutter method channel call) before
it can auto-restart.

| Flag | Key | Armed by (native iOS) | Armed by (Flutter channel) |
|---|---|---|---|
| `workoutsEnabled` | `com.humango.health.monitoring.workouts` | `startActivityBackgroundMonitoring()` / `startAllBackgroundMonitoring()` | `startWorkoutMonitoring` |
| `sleepEnabled` | `com.humango.health.monitoring.sleep` | `startSleepBackgroundMonitoring()` / `startAllBackgroundMonitoring()` | `startSleepMonitoring` |
| `enabledMetricKeys: Set<String>` | `com.humango.health.monitoring.metricKeys` | `startMetricsMonitoring(for:)` / `stopMetricsMonitoring(for:)` | `startMetricMonitoring` / `stopMetricMonitoring` |

Supported individual metric keys (match `HealthMetricType.key`):
`heartRateVariabilitySDNN`, `restingHeartRate`, `bodyFatPercentage`, `bodyMass`, `height`

**Login reset** — `UserAuthStateManager.isLoggedIn: false → true`:
`MonitoringConfig.clearAll()` is called automatically, resetting all flags to `false`.
This ensures each new login starts from a clean slate — subsystems must be re-armed explicitly.

**`HumangoHealthPlugin`** (`ios/Classes/HumangoHealthPlugin.swift`)

**Key change: `register(with:)` now calls `autoStartPersistedSubsystems()` (internal, reads-only)**
instead of the public `startAllBackgroundMonitoring()`. This means on every app launch the plugin
only reads the persisted flags — it never arms them. Observers only auto-restart for subsystems
that were previously armed by the client.

Public start methods still both arm the flag **and** start the observer:

```swift
// Arms workoutsEnabled + sleepEnabled, restarts metric monitors for persisted keys
HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()

// Arms workoutsEnabled only
HumangoHealthPlugin.shared?.startActivityBackgroundMonitoring()

// Arms sleepEnabled only
HumangoHealthPlugin.shared?.startSleepBackgroundMonitoring()

// Arms "restingHeartRate" + "bodyMass" in enabledMetricKeys
HumangoHealthPlugin.shared?.startMetricsMonitoring(for: [.restingHeartRate, .bodyMass])

// Removes keys from enabledMetricKeys (will not restart on next relaunch)
HumangoHealthPlugin.shared?.stopMetricsMonitoring(for: [.restingHeartRate])
```

**Flutter method channel handlers now arm flags too:**

| Flutter channel method | Flag armed |
|---|---|
| `startWorkoutMonitoring` | `workoutsEnabled = true` |
| `startSleepMonitoring` | `sleepEnabled = true` |
| `startMetricMonitoring` | adds metric key to `enabledMetricKeys` |
| `stopMetricMonitoring` | removes metric key from `enabledMetricKeys` |

**`autoStartIfConfigured()` guard chain** (WorkoutServiceChannel, SleepDataManager, HealthMetricsManager)

Each manager guards with its flag before starting:
```
1. isLoggedIn == true            → else skip
2. delegate != nil               → else skip
3. <subsystem flag> == true      → else skip
4. not already running           → else skip
5. → start observer
```

**`autoStartPersistedSubsystems()`** (new internal method on `HumangoHealthPlugin`)
— Called by `register(with:)`. Reads `MonitoringConfig` flags and calls each manager's
`autoStartIfConfigured()`. Never writes flags — purely read-only.

**`HealthMetricsManager.autoStartIfConfigured()`** — Re-starts monitors for all types
in `MonitoringConfig.enabledMetricKeys`.

**Lifecycle:**

| Event | Flags | Observers |
|---|---|---|
| Fresh install, first launch | all `false` | none start |
| Client calls `startAllBackgroundMonitoring()` | workouts + sleep armed | start |
| Client calls `startSleepBackgroundMonitoring()` | sleep armed only | sleep starts |
| Flutter calls `startWorkoutMonitoring` | workouts armed | starts |
| Kill + relaunch | flags read from UserDefaults | only armed subsystems restart |
| New login (`false → true`) | `clearAll()` → all `false` | must re-arm |

---

## 0.0.33 — 2026-04-10

### Features

#### Workout Reading — Native iOS API (`readWorkouts` / `fetchAllWorkouts`)

**`WorkoutServiceChannel`** (`ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`)

Two new package-internal methods callable from `HumangoHealthPlugin`:

| Method | Description |
|---|---|
| `readWorkouts(startDate:endDate:)` | Batched HealthKit fetch, applies import preferences |
| `fetchAllWorkouts(startDate:endDate:)` | Same fetch, no preference filter |

Both are `async throws -> [String]` returning compact JSON strings (one per workout), identical output to the Flutter method channel equivalents.

**`HumangoHealthPlugin`** (`ios/Classes/HumangoHealthPlugin.swift`)

New `// MARK: - Public Native iOS Workout Read API` section with two public methods forwarding to `WorkoutServiceChannel`:

```swift
public func readWorkouts(startDate: Date, endDate: Date) async throws -> [String]
public func fetchAllWorkouts(startDate: Date, endDate: Date) async throws -> [String]
```

Usage:

```swift
let end   = Date()
let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!

let workouts = try await HumangoHealthPlugin.shared?.readWorkouts(
    startDate: start, endDate: end
) ?? []
```

#### Workout Monitoring — Anchor priming on `start()` (no more history replay)

**`WorkoutService`** (`ios/Classes/WorkoutReading/WorkoutService.swift`)

Added `primeAnchor()` called at the top of `start()` before the foreground/background branch. It runs one anchored snapshot (`startDate → now`, no delivery) to advance `self.anchor` to the current HealthKit position. Both the live stream and the background observer inherit this anchor so they only surface workouts written **after** monitoring began — not historical replays.

- Non-fatal: if the priming query fails, `anchor` stays `nil` and `WorkoutDedup` in the delegate handles any re-delivered duplicates.
- Does not affect lifecycle transitions (`enterForegroundMode` / `enterBackgroundMode`) — those carry the already-advancing anchor forward.

---

## 0.0.32 — 2026-04-10

### Features

#### Health Metrics — `fetchLatestMetric` (Flutter + native iOS)

**Flutter / Dart** (`lib/src/managers/health_metrics_manager.dart`)

Added `fetchLatestMetric(HealthMetricType)` — fetches the single most-recent HealthKit
record for a metric type without requiring a date range. Returns a `HealthMetricResponse`
with `sampleCount` 0 or 1 and `latestSample` / `latestValue` populated.

```dart
final response = await metrics.fetchLatestMetric(HealthMetricType.bodyMass);
print('Weight: ${response.latestValue} ${response.unit}');
```

Bridges to the new `fetchLatestHealthMetric` method channel method (see below).

**Swift method channel** (`ios/Classes/HealthMetrics/HealthMetricsManager.swift`)

- Added `case "fetchLatestHealthMetric"` to the `handle(_:result:)` switch.
- Added private `handleFetchLatestHealthMetric(_:result:)` — validates `metricType` arg,
  calls `fetchLatestMetric(_:)` (async), returns the `[String: Any]` payload.

#### Health Metrics — Completion handler convenience API (native iOS)

**`HealthMetricsManager`** (`ios/Classes/HealthMetrics/HealthMetricsManager.swift`)

Four new public completion-handler overloads for non-`async` native iOS call sites.
All callbacks are delivered on the **main queue**.

| Method | Description |
|---|---|
| `fetchMetric(_ type:startDate:endDate:completion:)` | Single metric, typed enum, date range |
| `fetchMetric(key:startDate:endDate:completion:)` | Single metric, string key (validates against `HealthMetricType.allCases`) |
| `fetchLatestMetric(_ type:completion:)` | Most-recent sample, typed enum |
| `fetchAllMetrics(startDate:endDate:completion:)` | All five metric types, errors per-type |

---

## 0.0.31 — 2026-04-09

### Features

#### Workout Push — `ELLIPTICAL` sport added

**`Sport` enum** (`ios/Classes/WorkoutScheduling/WorkoutInstanceModel.swift`)**

- Added `case elliptical = "ELLIPTICAL"` to the Swift `Sport` enum.
- Added `.elliptical: return .elliptical` mapping in `hkWorkoutType` — routes to `HKWorkoutActivityType.elliptical` on Apple Watch.

**`AppleSport` enum** (`lib/src/models/enums/workout_enums.dart`)**

- Added `elliptical` case to `AppleSport`.
- `AppleSport.elliptical.jsonValue` → `'ELLIPTICAL'`
- `AppleSportExtension.fromJsonValue('ELLIPTICAL')` → `AppleSport.elliptical`

#### Workout Push — example app scenario buttons for HIKING · ELLIPTICAL · ROWING · HIIT · WALKING

**`WorkoutPushScreen`** (`example/lib/workout_push_screen.dart`)**

Five new real-backend workout scenarios added to the push screen test harness, each using `dateOffset: Duration(minutes: 15)` so the scheduled time is always ~15 minutes ahead of tap time:

| Button label | `schedule_id` | Sport | `workout_id` |
|---|---|---|---|
| HPH Hiking Tempo Intervals | `46002051` | `HIKING` | `902151` |
| HPH Elliptical Tempo Intervals | `46002052` | `ELLIPTICAL` | `902139` |
| HPH Rowing Tempo Intervals | `46002053` | `ROWING` | `902133` |
| HPH HIIT Tempo Intervals | `46002054` | `HIIT` | `902145` |
| HPH Walking Tempo Intervals | `46002055` | `WALKING` | `902127` |

All five scenarios share the same WARMUP → REPEAT(INTERVAL × 600 s + RECOVERY × 180 s) × 2 → COOLDOWN structure with HR zone targets.

**`_Scenario` class** — added `dateOffset` field (`Duration`, defaults to `const Duration(hours: 2)`) so scenarios can specify how far ahead to schedule without touching `preserveDates`. `_pushWorkouts` and `_buildScenarioButton` updated accordingly.

### Bug Fixes

#### Workout Push — JSON decode crash for workouts with unknown block-level `sport` values (e.g. `RUCKING`)

**`WorkoutInstanceModelBlock` / `BlockBlock`** (`ios/Classes/WorkoutScheduling/WorkoutInstanceModel.swift`)**

- Changed `sport: Sport?` → `sport: String?` in both `WorkoutInstanceModelBlock` and `BlockBlock`.
- **Root cause:** Block-level `"sport"` fields containing backend-only values not in the `Sport` enum (e.g. `"RUCKING"`) caused `JSONDecoder` to throw `DecodingError.dataCorruptedError`, silently aborting the entire decode. The log trail cut off immediately after `jsonData … bytes` with no native scheduling following.
- **Impact:** Only `WorkoutInstanceModelElement.sport` (the top-level field, still `Sport`) drives `HKWorkoutActivityType` selection; block-level sport is unused by the builder, so `String?` is the correct type.
- **Verification:** Decoding a workout whose blocks carry `"sport": "RUCKING"` now succeeds; the workout is built and scheduled on Apple Watch as the top-level sport (e.g. `HIKING`).

---

## 0.0.30 — 2026-04-09

### Features

#### Workout Reading — WorkoutPlan-based scheduled workout matching

**`WorkoutServiceChannel` (`ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`)**

- In `processWorkout`, resolves `scheduleId` from `ScheduledWorkoutStore` using `workout.workoutPlan.id` (Apple's `WorkoutKit` plan UUID) instead of fuzzy date+type matching.
- Stamps `isScheduledWorkout` and `scheduledWorkoutId` into `dictMetaData`, which `HuWorkout.formatMetadata()` maps to `IS_SCHEDULED_WORKOUT` and `SCHEDULED_WORKOUT_ID` in the JSON payload.
- Uses `try? await workout.workoutPlan` — safe, non-throwing; no impact on workouts without a plan.

**`RouteService` (`ios/Classes/WorkoutReading/RouteService.swift`)**

- `handleCompleteWorkout` now uses the same WorkoutPlan-based matching as `WorkoutServiceChannel`.
- Primary path: fetches `workout.workoutPlan`, extracts `.id.uuidString`, calls `ScheduledWorkoutStore.shared.findWorkoutByPlanId(_:)`.
- Falls back to the existing `getScheduledWorkoutId` (date+type) if `workoutPlan` is nil (pre-WorkoutKit workouts).
- Added `debugPrint` at every branch logging `workoutPlanId` and `scheduledWorkoutId`.

### Bug Fixes

#### Workout Reading — `WorkoutStatistics` Dart parsing crash

**`WorkoutData` (`lib/src/models/workout_data.dart`)**

- Fixed crash: `type 'String' is not a subtype of type 'int' of 'index'` when fetching workouts.
- Root cause: iOS sends `statistics` as `List<Map<String, Double>>` (e.g. `[{"HKQuantityTypeIdentifierHeartRate": 72.5}]`) but `WorkoutStatistics.fromJson` expected a `Map<String, dynamic>` and indexed it with string keys.
- `WorkoutStatistics.fromJson` now accepts `dynamic`, flattens the iOS list into a `Map<String, double>` keyed by HealthKit identifiers, and retains backward compatibility with nested-map format.

---


**`AppleSport` enum** (`lib/src/models/enums/workout_enums.dart`)

A new `AppleSport` enum with 28 cases mirrors the iOS native `Sport` enum exactly, eliminating hardcoded uppercase strings in push payloads. Two helpers via `AppleSportExtension`:

- `jsonValue` — converts to the iOS raw string (`AppleSport.poolSwimming.jsonValue` → `'POOL_SWIMMING'`)
- `fromJsonValue(String)` — reverse lookup; returns `null` for unknown values (forward-compatible)

**`WorkoutPushEntry` class** (`lib/src/models/workout_push_entry.dart`) — new file

`WorkoutPushManager.pushRawWorkouts` now accepts `List<WorkoutPushEntry>` instead of `List<Map<String, dynamic>>`. `WorkoutPushEntry` takes `scheduleId` and `sport` as typed fields alongside a raw `data` map (backend blob). `toMap()` stamps both into the serialized payload automatically.

Before / after:

```dart
// Before (raw strings, typo-prone)
await pushManager.pushRawWorkouts([
  {'schedule_id': 'abc', 'sport': 'RUNNING', 'date': '...', 'blocks': [...]},
]);

// After (typed)
await pushManager.pushRawWorkouts([
  WorkoutPushEntry(
    scheduleId: 'abc',
    sport: AppleSport.running,
    data: {'date': '...', 'blocks': [...]},
  ),
]);
```

**`ScheduledWorkoutInfo.sport`** (`lib/src/models/scheduled_workout_info.dart`)

`getScheduledWorkouts()` now populates `AppleSport? sport` on each returned `ScheduledWorkoutInfo`. The native handler forwards the stored `sport` string from the local push record; `sport` is `null` only when a workout was not matched in the local push store.

```dart
final workouts = await pushManager.getScheduledWorkouts();
print(workouts.first.sport?.jsonValue); // → 'RUNNING'
```

**Changed in:**
- `lib/src/models/enums/workout_enums.dart` — `AppleSport` enum + `AppleSportExtension`
- `lib/src/models/workout_push_entry.dart` *(new)*
- `lib/src/managers/workout_push_manager.dart` — `pushRawWorkouts` signature changed to `List<WorkoutPushEntry>`
- `lib/src/models/scheduled_workout_info.dart` — `AppleSport? sport` field added
- `lib/humango_health.dart` — export `workout_push_entry.dart`
- `ios/Classes/WorkoutScheduling/WorkoutPlanManager.swift` — forward `sport` key in `getScheduledWorkouts`

---

## 0.0.29 — 2026-04-08

### Features

#### Sleep Data — Apple-platform source priority filter in `buildAggregatedPayload`

When HealthKit contains sleep samples from multiple sources (e.g. Apple Watch alongside a third-party app such as Garmin Connect or Oura), the aggregation now discards all non-Apple samples before grouping and winner-selection. Apple-platform sources are identified by their **bundle ID prefix** (`com.apple.health`), which covers:

- **Apple Watch** — `com.apple.health.<device-UUID>` (the UUID is assigned at Watch pairing time and does not change even if the user renames their Watch)
- **iPhone Health app** — `com.apple.health`

The source *name* (e.g. "Hardik's Apple Watch") is explicitly **not** used for identification because it is user-editable and unreliable.

Fallback: if no Apple-platform samples are present, all samples are used as before (third-party-only scenario).

A `debugPrint` line is emitted whenever third-party samples are dropped, logging the discarded bundle IDs.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift` — `buildAggregatedPayload`

---

### Bug Fixes

#### Sleep Data — incorrect query window when dates are passed from a non-UTC device timezone

`SleepDataManager.getSleepData`, `calculateSleepPayload`, and `startSleepMonitoring` all receive date arguments serialised by Dart over the Flutter method channel. The Dart SDK's `DateTime.toIso8601String()` emits a timezone-naive string (e.g. `"2026-04-06T18:00:00.000000"`) when called on a local `DateTime`. Swift's `ISO8601DateFormatter` rejects strings without a timezone designator and `DateUtils.parseDate` falls through to a UTC `DateFormatter`, silently interpreting the local time as UTC. On a device in IST (+5:30) this shifts the HealthKit query window 5 h 30 m into the future, causing the first ~55 minutes of sleep samples to fall outside the query range and be excluded.

**Consequence for the reported session (Apr 06–07, IST):** The query started at 18:00 UTC (23:30 IST) instead of 18:00 IST (12:30 UTC), excluding 4 samples covering 10:34 PM – 11:29 PM IST. Only 29 of 33 samples were returned, reporting 6 h 24 m instead of ≈ 7 h 15 m.

**Fix:** All three method-channel call sites in `sleep_data_manager.dart` now call `.toUtc().toIso8601String()`, producing a `Z`-suffixed string that `ISO8601DateFormatter` parses correctly regardless of device timezone.

Additionally, `DateUtils.parseDate` now emits a `⚠️` console warning whenever it receives a timezone-naive string, making this class of bug immediately visible in the Xcode console for future callers.

**Changed in:**
- `lib/src/managers/sleep_data_manager.dart` — `getSleepData`, `startMonitoring`, `calculateSleepPayload`
- `ios/Classes/Utils/DateUtils.swift` — `parseDate`

---

## 0.0.28 — 2026-04-07

### Bug Fixes

#### Workout Reading — activities not displayed for users who never set import preferences

`WorkoutService.handleSpotImporting()` used `UserDefaults.standard.bool(forKey:)` to read the three import-preference flags (`isImportRunning`, `isImportCycling`, `isImportSwimming`). `bool(forKey:)` returns `false` when the key has never been written, causing all three sport types to be added to `excludeImporting` and every live-monitoring workout to be silently dropped. Users who had never explicitly saved preferences (the default state) saw no activities delivered through the monitoring pipeline.

**Fix:** Changed all three reads to `object(forKey:) as? Bool ?? true`, matching the existing correct default-to-import pattern already used in `WorkoutServiceChannel.unImportWorkout`. The default is now *import everything* when no preference has been saved.

**Changed in:** `ios/Classes/WorkoutReading/WorkoutService.swift`

---

### Changes

#### Workout Reading — import-preference filtering removed from `WorkoutService` (live monitoring path)

Import-preference filtering (`isImportRunning`, `isImportCycling`, `isImportSwimming`) has been removed from the live monitoring pipeline (`WorkoutService`). The sport-type filter now lives exclusively in `WorkoutServiceChannel.unImportWorkout`, which covers the one-shot `readWorkouts` and `fetchAllWorkouts` paths. The client app is responsible for filtering workout types delivered via `HumangoHealthDataDelegate.onWorkoutReady`.

**Removed from `WorkoutService`:**
- `handleSpotImporting()` method and its call in `init`
- Private properties: `importRunning`, `importCycling`, `importSwimming`, `excludeImporting`
- Sport-name string constants: `cycling`, `running`, `swimminng`, `strength`

**Changed in:** `ios/Classes/WorkoutReading/WorkoutService.swift`

---

### Features

#### Workout Reading — comprehensive remote logging across the full fetch pipeline

All workout reading and delivery paths now emit structured `SleepRemoteLogger` events (`subsystem: "WorkoutReading"`) in addition to `debugPrint`. Every stage from HealthKit query through delegate delivery is individually tagged with `class`, `method`, step key, and contextual metadata. Workout JSON payloads are attached at the point of serialization and at delegate delivery so missing-activity issues can be diagnosed from remote logs alone.

**`WorkoutServiceChannel` — new log steps:**

| Step | Description |
|---|---|
| `readWorkouts.start` / `.complete` / `.error` | One-shot fetch entry, success, failure |
| `fetchBatched.start` / `.batch` / `.skip` / `.processError` / `.complete` | Paginated batch fetch lifecycle |
| `fetchBatched.payload` | Full JSON payload per serialized workout |
| `processWorkout.start` / `.series` / `.seriesError` | Quantity series fetch per workout |
| `processWorkout.routes` / `.routesError` | Route fetch per workout |
| `processWorkout.locations` / `.locationsError` | Location build per workout |
| `processWorkout.complete` | Assembled `HuWorkout` with full JSON payload |
| `fetchRoutes.start` / `.complete` | `HKWorkoutRoute` query |
| `buildRouteData.start` / `.complete` | Location point extraction |
| `fetchQuantitySeries.typeError` | Per-type quantity fetch failure |
| `startMonitoring.start` / `.alreadyActive` / `.parse` | Monitoring start |
| `stopMonitoring` | Monitoring stop |
| `setImportPreferences` | Preference update |
| `fetchAllWorkouts.start` / `.complete` / `.error` | Unfiltered fetch entry, success, failure |
| `fetchAllRaw.start` / `.batch` / `.skip` / `.complete` | Unfiltered paginated fetch lifecycle |
| `fetchAllRaw.payload` | Full JSON payload per serialized workout |

**`WorkoutService` — new log steps:**

| Step | Description |
|---|---|
| `workoutService.start` | Service start with mode (foreground/background) and startDate |
| `liveUpdates.start` / `.streaming` / `.update` / `.workout` / `.ended` / `.error` / `.stop` | Full live stream lifecycle, per-update count, per-workout metadata |
| `fetchWorkouts.skip` / `.start` / `.result` / `.handle` / `.error` | Background snapshot fetch lifecycle |
| `bgMonitoring.stop` / `.disableDelivery` | Background observer teardown |
| `handleWorkouts.skip` / `.classify` / `.snapshot` / `.routeMode` / `.oneShot` / `.oneShotComplete` | Per-workout classification and RouteService path |

**`RouteService` — new log steps:**

| Step | Description |
|---|---|
| `routeService.workoutBuilt` | Assembled `HuWorkout` with full JSON payload before delivery |
| `routeService.buildError` | Build failure with `uuid` and error |
| `routeService.delivering` | Delegate call with full JSON payload |
| `routeService.delivered` | Delegate returned successfully |
| `routeService.delegateNil` | Delegate absent — payload still logged |

**Changed in:** `ios/Classes/WorkoutReading/WorkoutServiceChannel.swift`, `ios/Classes/WorkoutReading/WorkoutService.swift`, `ios/Classes/WorkoutReading/RouteService.swift`

---

## 0.0.27 — 2026-04-04

### Features

#### Permissions — Selective `requestAuthorization` by type

`PermissionManager.requestAuthorization()` now accepts an optional `readTypes` parameter so callers can request only the HealthKit types their feature requires, rather than always prompting the full fixed set.

**Dart (`lib/src/managers/permission_manager.dart`):**
- `requestAuthorization({List<HealthDataType>? readTypes})` — when `readTypes` is `null` the existing full-set behavior is preserved (fully backward-compatible). When provided, only the specified types are requested on iOS.

**iOS (`ios/Classes/PermissionManager.swift`):**
- Added `workoutSupportingQuantityIdentifiers` — the 16 ancillary quantity identifiers (heartRate, stepCount, distanceCycling, swimmingStrokeCount, distanceSwimming, vo2Max, distanceWalkingRunning, activeEnergyBurned, bodyMassIndex, runningGroundContactTime, runningPower, runningSpeed, runningStrideLength, runningVerticalOscillation, cyclingCadence, cyclingPower).
- Added `filteredReadTypes(for identifiers: [String]?)` — resolves the `HKObjectType` read set from the Dart-side identifier strings. `"HKWorkoutType"` expands automatically to `workoutType + workoutRoute + workoutSupportingQuantityIdentifiers`. All other identifiers are resolved to their `HKQuantityType` or `HKCategoryType` by identifier string.
- `requestAuthorization` signature changed to `requestAuthorization(typeIdentifiers: [String]? = nil, result:)`. Default value keeps it backward-compatible with all existing call sites.

**iOS (`ios/Classes/HumangoHealthPlugin.swift`):**
- `handle(_:result:)` now extracts `types` from `call.arguments` and forwards it to `PermissionManager.shared.requestAuthorization(typeIdentifiers:result:)`.

**Example app (`example/lib/health_permissions_provider.dart`):**
- Added `requestWorkoutPermissions()` — requests `[HealthDataType.workout]` only.
- Added `requestSleepPermissions()` — requests `[HealthDataType.sleepAnalysis]` only.
- Added `requestPermissionsForTypes(List<HealthDataType>)` — requests an arbitrary caller-defined subset.
- Existing `requestPermissions()` unchanged (requests full set).

**Note:** `verifyAuthorization()` and `permissionStream` are unaffected — they always return statuses for all tracked types regardless of what was requested.

**Changed in:** `lib/src/managers/permission_manager.dart`, `ios/Classes/PermissionManager.swift`, `ios/Classes/HumangoHealthPlugin.swift`, `example/lib/health_permissions_provider.dart`

---

## 0.0.27 — 2026-04-04

### Bug Fixes

#### WorkoutScheduler — crash on `requestAuthorization` (`NSInvalidArgumentException` SIGABRT)

**Problem:** Calling `requestAuthorizationForWorkoutPush` or `scheduleWorkoutsFromFlutter` from Flutter caused an immediate SIGABRT:

```
NSInvalidArgumentException: Authorization for HKWorkoutTypeIdentifier should also be
requested when requesting authorization to read HKWorkoutRouteTypeIdentifier
```

Apple's `WorkoutScheduler.shared.requestAuthorization()` (WorkoutKit) internally calls `HKHealthStore.requestAuthorization` with `HKWorkoutRouteTypeIdentifier` in the read set but **without** `HKWorkoutTypeIdentifier`. HealthKit enforces that the two types must always be requested together — violating the constraint throws an uncaught `NSException` and kills the process.

**Fix:** Added `ensureHealthKitWorkoutTypesAuthorized()` — a private async helper in `WorkoutPlanManager` that pre-authorizes `HKWorkoutType` (write) and `[HKWorkoutType, HKWorkoutRoute]` (read) together before every `WorkoutScheduler.shared.requestAuthorization()` call. Once HealthKit has seen both types, WorkoutKit's internal request passes the constraint check silently. Errors from the pre-auth call are swallowed (best-effort); the WorkoutKit `authorizationState` remains the authoritative result returned to Flutter.

**Changed in:** `ios/Classes/WorkoutScheduling/WorkoutPlanManager.swift`

---

## 0.0.26 — 2026-04-04

### Features

#### Health Metrics — Per-metric background monitoring + native iOS fetch API

The `HealthMetricsManager` now supports **per-metric HealthKit monitoring** started and stopped entirely from native iOS. A new `HealthMetricMonitor` class (mirrors the `WorkoutService` / `SleepDataManager` pattern) installs an `HKAnchoredObjectQueryDescriptor` stream in the foreground and an `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` in the background; mode switching follows `AppLifecycleManager`.

**Added — iOS:**
- `ios/Classes/HealthMetrics/HealthMetricMonitor.swift` — new `@available(iOS 17.0, *)` class; `AppLifecycleObserver` conformance; `fetchAndDeliverCurrentDay()` re-fetches midnight→now on every HealthKit notification (not a delta)
- `HumangoHealthDataDelegate.onHealthMetricReady(payload:metricType:)` — new async protocol method; default no-op in extension
- `HealthMetricsManager.startMonitoring(_:)` / `stopMonitoring(_:)` / `stopAllMonitoring()` — idempotent monitor registry protected by a concurrent barrier queue
- `HealthMetricsManager.fetchMetric(_:startDate:endDate:)` / `fetchLatestMetric(_:)` / `fetchAllMetrics(startDate:endDate:)` — native iOS fetch API
- `HumangoHealthPlugin.shared.startMetricsMonitoring(for:)` / `stopMetricsMonitoring(for:)` — public host-app entry points for monitoring
- `HumangoHealthPlugin.shared.fetchHealthMetric(_:startDate:endDate:)` / `fetchLatestHealthMetric(_:)` / `fetchAllHealthMetrics(startDate:endDate:)` — public host-app generic fetch
- 10 per-type convenience wrappers on `HumangoHealthPlugin.shared`: `fetchHRV`, `fetchLatestHRV`, `fetchRestingHeartRate`, `fetchLatestRestingHeartRate`, `fetchBodyFatPercentage`, `fetchLatestBodyFatPercentage`, `fetchWeight`, `fetchLatestWeight`, `fetchHeight`, `fetchLatestHeight`
- `PermissionManager.quantityIdentifiers` converted to a computed `var` driven by `HealthMetricType.allCases`
- `clearAllDataOnLogout()` now calls `HealthMetricsManager.shared.stopAllMonitoring()`

**Added — Flutter channel (4 methods on `com.humango.health/metrics`):**
- `fetchHealthMetric` — replaces old `getMetric` / `getLatestMetric` / `getAllMetrics`
- `startMetricMonitoring` — starts a native monitor for one metric type (verification / debug use)
- `stopMetricMonitoring` — stops a specific monitor
- `stopAllMetricMonitoring` — stops all active monitors

**Added — Dart(`lib/src/managers/health_metrics_manager.dart`):**
- `fetchHealthMetric(HealthMetricType, {startDate, endDate})` — single method replacing the old 8-method surface
- `startMetricMonitoring(HealthMetricType)` / `stopMetricMonitoring(HealthMetricType)` / `stopAllMetricMonitoring()` — Dart-side monitoring control (debug / verification only; no Dart callback fires)

**Breaking changes:**
- `getMetric`, `getLatestMetric`, `getAllMetrics`, `getHRV`, `getRestingHeartRate`, `getBodyFatPercentage`, `getWeight`, `getHeight` — all removed; migrate to `fetchHealthMetric`
- `HealthMetricsManager.queryMetric` / `queryLatestMetric` / `queryAllMetrics` (iOS) — replaced by `HealthMetricsManager.fetchMetric` / `fetchLatestMetric` / `fetchAllMetrics` and the public `HumangoHealthPlugin.shared` wrappers

**Monitoring behavior:**
- Payload delivers **re-fetched current-day samples** (midnight → now). It is **not** a delta.
- `completion()` in `HKObserverQuery` handler is called only after the full `await fetchAndDeliverCurrentDay()` chain — never via `defer`.
- Requires iOS 17+.

**Changed in:** `ios/Classes/HealthMetrics/HealthMetricsManager.swift`, `ios/Classes/HealthMetrics/HealthMetricMonitor.swift` (new), `ios/Classes/HumangoHealthPlugin.swift`, `ios/Classes/HumangoHealthDataDelegate.swift`, `ios/Classes/PermissionManager.swift`, `lib/src/managers/health_metrics_manager.dart`

---

## 0.0.25 — 2026-04-03

### Breaking Changes

#### Health Metrics — monitoring removed; query-only API on Flutter and native iOS

Health metrics are now **query-only**. The plugin no longer installs HealthKit metric observers or delivers metric batches through `HumangoHealthDataDelegate`.

**Removed:**

- **iOS**: `HRVObserverManager.swift` deleted
- **iOS**: `HumangoHealthDataDelegate.onHealthMetricSamplesReady(json:metricType:fetchedAt:)` removed
- **Flutter**: `HealthMetricsManager.startHRVMonitoring()` removed
- **Flutter**: `HealthMetricsManager.stopHRVMonitoring()` removed
- **Flutter**: `HealthMetricsManager.getPendingHRVUpdates()` removed
- **Flutter**: `HealthMetricsManager.isHRVMonitoringActive()` removed
- **iOS plugin**: `HumangoHealthPlugin.startHealthMetricsBackgroundMonitoring()` removed

**Added:**

- **iOS**: `HealthMetricsManager.queryMetric(_:startDate:endDate:limit:)`
- **iOS**: `HealthMetricsManager.queryLatestMetric(_:)`
- **iOS**: `HealthMetricsManager.queryAllMetrics(startDate:endDate:)`

**Client migration:**

- **Flutter clients** must use `getMetric`, `getLatestMetric`, or `getAllMetrics` with explicit `startDate` / `endDate`
- **Native iOS clients** must query `HealthMetricsManager.shared` directly instead of implementing a metric delegate callback
- Any client code still referencing `startHRVMonitoring`, `getPendingHRVUpdates`, or `onHealthMetricSamplesReady` must be updated

**Changed in:** `ios/Classes/HealthMetrics/HealthMetricsManager.swift`, `ios/Classes/HumangoHealthPlugin.swift`, `ios/Classes/HumangoHealthDataDelegate.swift`, `lib/src/managers/health_metrics_manager.dart`

---

## 0.0.24 — 2026-04-03

### Breaking Changes

#### Health Metrics — `heartRate` metric removed

Standalone heart rate monitoring and sample fetching have been removed. The `heartRate` case no longer exists in:

- **Dart**: `HealthMetricType` enum (`lib/src/models/health_metric_sample.dart`) — `heartRate` case, `displayName`, `defaultUnit` all removed
- **Dart**: `HealthDataType` enum (`lib/src/models/health_data_type.dart`) — `heartRate` case and `HKQuantityTypeIdentifierHeartRate` identifier mapping removed
- **Dart**: `HealthKitAuthorizationResult` — `heartRateStatus` key no longer mapped; the `statuses` map will no longer contain a `HealthDataType.heartRate` entry
- **Dart**: `AllHealthMetricsResponse` — `.heartRate` convenience getter removed
- **Dart**: `HealthMetricsManager` — `getHeartRate()` method removed; callers must migrate to `getRestingHeartRate()` or `getHRV()` as appropriate
- **iOS**: `HealthMetricType.swift` — `heartRate` case fully removed (done in 0.0.23 patch)
- **iOS**: `PermissionManager.swift` — `heartRateStatus` removed from `typesToCheck`; `.heartRate` is still requested in the authorization set because it is required for workout heart rate statistics (avgHeartRate / maxHeartRate)

**Remaining metrics:** `heartRateVariabilitySDNN`, `restingHeartRate`, `bodyFatPercentage`, `bodyMass`, `height`.

**Workout heart rate statistics are unaffected** — `WorkoutData.avgHeartRate` and `WorkoutData.maxHeartRate` continue to be populated from workout-session samples via the workout reading subsystem.

---

## 0.0.23 — 2026-04-02

### Bug Fixes

#### Health Metrics — All 6 quantity types now auto-arm on login (HRV, HR, RHR, BodyFat, Weight, Height)

`HRVObserverManager.autoStartIfConfigured()` previously required a persisted `isMonitoringEnabled` flag (`com.humango.health.hrvMonitoringEnabled`) that was only written when `startHRVMonitoring` was explicitly called from the Dart/UI layer. This meant that on every fresh login the health metrics `HKObserverQuery` / `HKAnchoredObjectQueryDescriptor` observers were never installed, so no HealthKit change for any quantity type (weight, HRV, heart rate, resting HR, body fat, height) triggered `onHealthMetricSamplesReady`.

**Fix:** Removed the `guard isMonitoringEnabled` gate from `autoStartIfConfigured`. The method now mirrors the same pattern used by `SleepDataManager` and `WorkoutServiceChannel`: starts immediately whenever `isLoggedIn == true` and `HumangoHealthPlugin.delegate != nil`. The `isMonitoringEnabled` flag and `isHRVMonitoringActive()` Dart API are still updated by `startMonitoring` / `stopMonitoring` and continue to work correctly.

**All 6 types affected:** `heartRateVariabilitySDNN`, `heartRate`, `restingHeartRate`, `bodyFatPercentage`, `bodyMass`, `height`.

**Changed in:** `ios/Classes/HealthMetrics/HRVObserverManager.swift` (`autoStartIfConfigured`)

---

### Features

#### Health Metrics — HRV observer delivers unrounded daily average

When the HRV (`heartRateVariabilitySDNN`) observer fires, the fetch window is now scoped to the **full current calendar day in local time** (today `00:00:00` → tomorrow `00:00:00`) instead of a rolling lookback. All samples recorded today are fetched and a daily average is computed using raw `Double` arithmetic — no rounding or truncation is applied at any step.

Three new keys are added to the `onHealthMetricSamplesReady` payload **for HRV only**:

| Key | Type | Description |
|-----|------|-------------|
| `dailyAverage` | `Double` | Unrounded mean of all HRV samples today (ms) |
| `windowStart` | `String` (ISO 8601) | Today at `00:00:00` local time |
| `windowEnd` | `String` (ISO 8601) | Tomorrow at `00:00:00` local time (exclusive bound) |

All other metric types (HR, RHR, BodyFat, Weight, Height) are unaffected and continue to use their configured `observerLookbackDays` window with no average calculation.

**Changed in:** `ios/Classes/HealthMetrics/HRVObserverManager.swift` (`fetchAndDeliverUpdates`)

---

## 0.0.22 — 2026-04-02

### Improvements

#### Sleep Data — Transition from minute-based to second-based precision

Sleep duration calculations and session tracking have been optimized to use **raw seconds** instead of minutes, eliminating accumulated rounding errors and improving precision when interfacing with HealthKit's native `timeIntervalSince` API.

**Key changes:**

- **Sleep duration storage and calculation** — All sleep segment durations now use raw seconds (e.g., `Double` from `timeIntervalSince`) rather than integer-truncated minutes. This preserves sub-minute precision from HealthKit.
- **Session state refactored** — `SleepSessionState` properties changed: `totalSleepMinutes` → `totalSleepSeconds`, `totalAwakeMinutes` → `totalAwakeSeconds`. Session detection thresholds (`minimumSleepMinutes`, `stalenessThresholdMinutes`, `deepSleepAbsenceWindowMinutes`) are now expressed in seconds.
- **Payload output unchanged (for now)** — Sleep metric payloads still deliver `TOTAL_SLEEP`, `SLEEP_LIGHT`, etc. as raw seconds (no conversion); clients must decide display policy (hours/minutes/seconds) based on their UI requirements.
- **Logging improvements** — Debug logs now display durations in seconds (e.g., `stale_3600s` instead of `stale_60m`) for clarity.
- **Internal config** — `SleepSessionConfig.default` updated: `minimumSleepSeconds: 14400` (4 hours), `stalenessThresholdSeconds: 3600`, `deepSleepAbsenceWindowSeconds: 5400` (90 minutes).

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift`, `ios/Classes/SleepData/SleepSessionDetector.swift`

---

#### Sleep Data — Optimized 6 PM query window with hourly time logic

The sleep HealthKit query window calculation (6 PM yesterday → now) has been rewritten to handle overnight and late-delivery scenarios more intuitively.

**Previous logic:** Always set `windowStart = today_00:00 - 6_hours = yesterday_18:00`, which was opaque.

**New logic:** Compute the window based on the current **hour of day**:

```
Before noon  (00:00 – 11:59) : start = yesterday 18:00  → overnight sleep window
Noon – 18:00 (12:00 – 17:59) : start = yesterday 18:00  → late-delivery of last night's sleep
After 18:00  (18:00 – 23:59) : start = today     18:00  → new sleep session starting tonight
```

In all cases, `end = now`. This makes the query window semantically clearer and easier to debug (queries are logged with hour and window range). The behavior is identical to the previous version but more maintainable.

**Changed in:** `ios/Classes/SleepData/SleepDataManager.swift` (`sixPMWindow()` method refactored)

---

### Example App Updates

#### `example/lib/sleep_data_screen.dart` — Updated algorithm description text

- Sleep calculation description updated: `'ceiling-round durations'` → `'keeps raw-second durations'` to reflect the new second-based precision.

**Changed in:** `example/lib/sleep_data_screen.dart`

---

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
