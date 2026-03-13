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
