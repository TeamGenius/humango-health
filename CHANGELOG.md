## 0.0.4 — 2026-03-13

### Improvements

#### Sleep — Out-of-Bed Detection (Primary Session Trigger)
Sleep sessions are now finalized as soon as the user gets out of bed, instead of waiting for the freeze window or staleness threshold.

**How it works:**
Every time a new batch of sleep samples arrives (foreground `HKAnchoredObjectQueryDescriptor` or background `HKObserverQuery`), the native layer now checks the `endDate` of the most recent `inBed` sample:
- `inBed.endDate` < 5 minutes ago → user still in bed → continue accumulating
- `inBed.endDate` ≥ 5 minutes ago → user is out of bed → finalize session immediately and deliver

This fires **before** the existing multi-factor scoring, making it the primary finalization path when `inBed` samples are present.

**`reason` field in the delivery payload:**

| Value | Trigger |
|-------|---------|
| `user_out_of_bed` | New — `inBed` ended > 5 min ago |
| `sleep>=Xm, no_deep_sleep_recently, stale_Ym` | Existing multi-factor scoring |
| `freeze_window_expired` | Existing freeze window auto-finalization |

**Changed in iOS:**
- `SleepSessionState` — new field `latestInBedEndDate: String?` tracks the `endDate` of the latest `inBed` sample (persisted/restored via `Codable`)
- `SleepSessionDetector.updateState()` — `inBed` case now records `latestInBedEndDate` (previously a no-op `break`)
- `SleepSessionDetector.isUserInBed(state:currentTime:thresholdMinutes:)` — new method; returns `false` when `latestInBedEndDate` is > 5 min in the past
- `SleepDataManager.checkInBedStatusAndDeliverIfNeeded()` — new private method; calls `isUserInBed()` and finalizes + delivers the session when the user is out of bed
- `SleepDataManager.startLiveUpdates()` — calls `checkInBedStatusAndDeliverIfNeeded()` after every foreground sample batch
- `SleepDataManager.fetchAccumulateAndEvaluate()` — calls `checkInBedStatusAndDeliverIfNeeded()` after every background accumulation

---

#### Workout Scheduling — Multi-Format Date Parsing
Scheduling a workout with a date that lacks fractional seconds (e.g. `2026-03-13T00:30:00Z`) no longer throws `PlatformException(SCHEDULE_ERROR, The data couldn't be read because it is missing., null, null)`.

**Root cause:** Swift's built-in `.iso8601` `JSONDecoder` date strategy requires fractional seconds on some iOS versions. When it failed to parse the `date` field, Swift surfaced the failure as a cryptic `keyNotFound` ("missing") error rather than a format mismatch.

**Fix:** Replaced `decoder.dateDecodingStrategy = .iso8601` with a custom strategy backed by `DateUtils.parseDate` — the same multi-format parser already used in the Dart/iOS validation step. All four ISO8601 variants are now accepted:

| Format | Example |
|--------|---------|
| No millis, with Z | `2026-03-13T00:30:00Z` ✅ |
| Millis, with Z | `2026-03-13T00:30:00.000Z` ✅ |
| Microseconds, with Z | `2026-03-13T00:30:00.000000Z` ✅ |
| No timezone | `2026-03-13T00:30:00` ✅ |

**Improved error messages:** Decoding errors now include the full JSON field path in the `PlatformException` details (e.g. `Missing key 'sport' at path: Index 0 → sport`) instead of `null`.

**Changed in iOS:** `WorkoutPlanManager.scheduleWorkouts()` — custom `dateDecodingStrategy` + explicit `DecodingError` catch with coding-path surfacing.

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
