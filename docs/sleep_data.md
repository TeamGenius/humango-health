# Sleep Data Subsystem

**Plugin:** `humango_health`  
**Document Date:** March 18, 2026

---

## Overview

The sleep subsystem reads Apple HealthKit `HKCategoryTypeIdentifier.sleepAnalysis` data and makes it available to Flutter apps. It supports four operating modes that can be freely combined:

| Mode | When used | Mechanism |
|------|-----------|-----------|
| One-shot fetch | Any time | `HKSampleQuery` |
| Foreground monitoring | App in foreground | `HKAnchoredObjectQueryDescriptor` (iOS 15+) |
| Background monitoring | App suspended/background | `HKObserverQuery` + `enableBackgroundDelivery` |
| Automatic lifecycle switching | Always (preferred) | Native `AppLifecycleManager` |

The app lifecycle (foreground ↔ background) is detected **natively on iOS** via `AppLifecycleManager`. The Dart-side `enterForeground` / `enterBackground` methods exist only as manual overrides and are not normally needed.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                 Flutter Application                      │
└─────────────────────┬────────────────────────────────────┘
                      │
        ┌─────────────▼─────────────┐
        │    SleepDataManager.dart  │  Method Channel only
        │                           │  com.humango.health/sleep
        └─────────────┬─────────────┘
                      │ MethodChannel
        ┌─────────────▼─────────────┐
        │   SleepDataManager.swift  │  (iOS singleton)
        │  ├─ fetchSleepData()      │
        │  ├─ startLiveUpdates()    │  HKAnchoredObjectQueryDescriptor
        │  ├─ startBackgroundMonitoring() │  HKObserverQuery
        │  ├─ SleepSessionDetector  │  freeze-window algorithm
        │  └─ SleepBackgroundDeliveryManager │  API or localStorage
        └─────────────┬─────────────┘
                      │
        ┌─────────────▼─────────────┐
        │       Apple HealthKit     │
        └───────────────────────────┘
```

There is **no EventChannel** for sleep. All data flows through the method channel — either as direct responses or via the background delivery pipeline (API POST or UserDefaults).

---

## Files

### Swift (iOS native)

| File | Responsibility |
|------|---------------|
| `ios/Classes/SleepData/SleepDataManager.swift` | Entry point — handles all MethodChannel calls, orchestrates queries and mode switching |
| `ios/Classes/SleepData/SleepSessionDetector.swift` | Freeze-window algorithm — accumulates segments and decides when a sleep session has ended |
| `ios/Classes/SleepData/SleepBackgroundDeliveryManager.swift` | Delivery pipeline — HTTP POST to API or persist to UserDefaults |

### Dart (Flutter)

| File | Responsibility |
|------|---------------|
| `lib/src/managers/sleep_data_manager.dart` | Public Dart API wrapping the MethodChannel |
| `lib/src/models/sleep_sample.dart` | `SleepSample`, `SleepStageTotals`, `SleepDataResponse` data classes |
| `lib/src/models/sleep_background_delivery_config.dart` | `SleepBackgroundDeliveryMode` enum + `SleepBackgroundDeliveryConfig` data class |

All types are exported from `lib/humango_health.dart`.

---

## Data Model

### Sleep Stages

Apple HealthKit provides six sleep stage values (iOS 16+):

| HealthKit value | Stage name | Description |
|-----------------|-----------|-------------|
| 0 | `inBed` | In bed but not necessarily asleep |
| 1 | `asleepUnspecified` | Asleep, stage unknown (pre-iOS 16) |
| 2 | `awake` | Awoke during the night |
| 3 | `asleepCore` | Core / light sleep |
| 4 | `asleepDeep` | Deep sleep |
| 5 | `asleepREM` | REM sleep |

`inBed` and `awake` are **excluded** from total sleep time calculations.

### SleepSample (Dart)

```dart
class SleepSample {
  final String uuid;          // HealthKit UUID (used for deduplication)
  final DateTime startDate;
  final DateTime endDate;
  final int value;            // Raw HealthKit integer (0-5)
  final String sleepStage;    // Human-readable stage name
  final double durationSeconds;
  final double durationMinutes;
  final String? sourceName;   // e.g. "Apple Watch"
  final String? sourceBundle;
  final SleepDevice? device;
  final Map<String, dynamic>? metadata;
  final Map<String, dynamic> rawJson;

  bool get isActualSleep;     // true when stage ≠ inBed, awake, unknown
}
```

### SleepDataResponse (Dart)

```dart
class SleepDataResponse {
  final List<SleepSample> samples;
  final int sampleCount;
  final double totalSleepSeconds;   // excludes inBed + awake
  final double totalSleepMinutes;
  final double totalSleepHours;
  final SleepStageTotals stageTotals;
  final DateTime fetchedFrom;
  final DateTime fetchedTo;
  final Map<String, dynamic> rawJson;

  bool get hasSleepData;
  List<SleepSample> get actualSleepSamples; // filters out inBed/awake
}
```

---

## Dart API (SleepDataManager)

### One-Shot Fetch

```dart
final SleepDataManager sleepManager = SleepDataManager();

// Defaults to the last 24 hours
final SleepDataResponse response = await sleepManager.getSleepData();

// Custom range
final response = await sleepManager.getSleepData(
  startDate: DateTime.now().subtract(const Duration(days: 7)),
  endDate: DateTime.now(),
);

print('${response.totalSleepHours.toStringAsFixed(1)}h total sleep');
for (final sample in response.actualSleepSamples) {
  print('${sample.sleepStage}: ${sample.durationMinutes.toStringAsFixed(1)} min');
}
```

### Continuous Monitoring

```dart
// Start (defaults to last 24 h lookback)
await sleepManager.startMonitoring();

// Stop
await sleepManager.stopMonitoring();
```

### Session Status

```dart
final status = await sleepManager.getSleepSessionStatus();
// status['status']               → "active" | "ended" | "freeze_expired"
// status['isInFreezeWindow']     → bool
// status['segmentCount']         → int
// status['totalSleepMinutes']    → double
// status['hasRecentDeepSleep']   → bool
// status['isFinalized']          → bool

await sleepManager.resetSleepSession(); // clear for next night
```

### Configure Session Detection

```dart
await sleepManager.configureSleepSession(
  freezeWindowStartHour: 0,     // midnight
  freezeWindowEndHour: 12,      // noon
  minimumSleepMinutes: 240,     // 4 hours
  stalenessThresholdMinutes: 60,
  deepSleepAbsenceWindowMinutes: 90,
);
```

---

## Background delivery (local queue only)

Finalized sleep sessions are stored as JSON strings in `UserDefaults` (`com.humango.health.sleepPendingLocal`). The plugin does **not** POST them to your API. Call `getLocalSleepSessions()` from your app and upload (Dart or Runner native).

```dart
enum SleepBackgroundDeliveryMode {
  localStorage,
}

await sleepManager.configureSleepBackgroundDelivery(
  const SleepBackgroundDeliveryConfig(),
);
```

- Arming persists to `UserDefaults` (`HumangoSleepDeliveryArmed`) and survives app restarts. Legacy keys from removed API mode are cleared when you arm.
- On app launch, `SleepDataManager.autoStartIfConfigured()` runs from the plugin `register()` when the user is logged in and delivery is armed.
- Passing `mode: api` to the channel fails (`INVALID_MODE` on iOS — only `localStorage` is accepted).

### Background payload

The JSON stored for each finalized session follows this shape (example — actual keys match native aggregation):

```json
{
  "SOURCE": "Apple Watch",
  "SOURCE_BUNDLE": "com.apple.health.…",
  "TIMEZONE": "Asia/Kolkata",
  "TOTAL_SLEEP": 25200,
  "SLEEP_IN_BED": 0,
  "SLEEP_LIGHT": 10800,
  "SLEEP_DEEP": 3600,
  "SLEEP_REM": 7200,
  "SLEEP_UNSPECIFIED": 3600,
  "SLEEP_AWAKE": 900,
  "BED_TIME": "2026-03-17T22:30:00.000Z",
  "WAKE_TIME": "2026-03-18T06:15:00.000Z",
  "START_DATE": "2026-03-17T18:00:00.000Z",
  "END_DATE": "2026-03-18T06:30:00.000Z"
}
```

Numeric stage fields are **seconds** (see `SleepDataManager.buildAggregatedPayload` on iOS).

---

## Sleep Session Detection Algorithm

### Freeze Window

The freeze window (default: **midnight → noon local time**) prevents false session endings during sleep.

```
12:00 AM ──────────────[  FREEZE WINDOW  ]─────────────── 12:00 PM
             ↑ session stays open regardless of gaps              ↑ auto-finalize
```

### Multi-Factor Scoring (inside freeze window)

A session is declared ended only when **all three** factors are true simultaneously:

| Factor | Condition | Default threshold |
|--------|-----------|-----------------|
| Minimum sleep | Accumulated sleep ≥ threshold | 240 min (4 h) |
| No recent deep sleep | Deep sleep last seen > N minutes ago | 90 min |
| Staleness | No new segments for ≥ N minutes | 60 min |

Example reason string: `"sleep>=420m, no_deep_sleep_recently, stale_65m"`

### Outside Freeze Window

Any accumulated session with `totalSleepMinutes > 0` is **auto-finalized** when the freeze window expires (12:00 PM).

### Timer-Based Check

A background `Timer` fires every **15 minutes** to re-evaluate the session even if no new HealthKit data arrives. This guarantees sessions are finalized after noon even when the device is idle.

### State Persistence

`SleepSessionState` is serialised to `UserDefaults` via `JSONEncoder` so it survives background kills and app restarts.

```
UserDefaults key: com.humango.health.sleepSessionState
```

### SleepSessionState fields

| Field | Type | Description |
|-------|------|-------------|
| `sessionStartDate` | ISO8601 string | Start of the first segment seen |
| `latestSegmentEndDate` | ISO8601 string | End of the most recent segment |
| `totalSleepMinutes` | Double | Accumulated sleep (excl. inBed/awake) |
| `totalAwakeMinutes` | Double | Accumulated awake time |
| `segmentCount` | Int | Number of segments received |
| `hasRecentDeepSleep` | Bool | Deep sleep within `deepSleepAbsenceWindowMinutes` |
| `lastDeepSleepEndDate` | ISO8601 string | End of the most recent deep sleep segment |
| `isFinalized` | Bool | Whether the session has been delivered |
| `finalizedAt` | ISO8601 string | When finalization occurred |
| `sampleUUIDs` | [String] | Seen UUIDs — prevents double-counting |

---

## Method Channel Reference

**Channel name:** `com.humango.health/sleep`

| Method | Parameters | Response |
|--------|-----------|----------|
| `getSleepData` | `startDate?: ISO8601`, `endDate?: ISO8601` | Full `SleepDataResponse` JSON |
| `startSleepMonitoring` | `startDate?: ISO8601` | `{status, startDate, deliveryMode}` |
| `stopSleepMonitoring` | — | `{status}` |
| `fetchStoredSleepData` | — | `SleepDataResponse` JSON (from UserDefaults) |
| `clearStoredSleepData` | — | `{status}` |
| `configureSleepSession` | `freezeWindowStartHour?, freezeWindowEndHour?, minimumSleepMinutes?, stalenessThresholdMinutes?, deepSleepAbsenceWindowMinutes?` | `{status, ...config}` |
| `getSleepSessionStatus` | — | `{status, reason, isInFreezeWindow, segmentCount, totalSleepMinutes, hasRecentDeepSleep, isFinalized, ...}` |
| `resetSleepSession` | — | `{status}` |
| `configureSleepBackgroundDelivery` | `mode: "localStorage"` only | `{status, mode}` |
| `getLocalSleepSessions` | — | `[String]` — list of session JSON strings |
| `enterForeground` | — | `null` (manual override, rarely needed) |
| `enterBackground` | — | `null` (manual override, rarely needed) |

---

## UserDefaults Keys (iOS)

| Key | Contents |
|-----|----------|
| `com.humango.health.storedSleepData` | Latest full sleep data snapshot (binary JSON) |
| `com.humango.health.lastSleepFetchDate` | Date of last UserDefaults write |
| `com.humango.health.sleepSessionState` | Serialised `SleepSessionState` |
| `HumangoSleepDeliveryArmed` | `true` after successful configure (auto-start gate) |
| `com.humango.health.sleepPendingLocal` | Pending finalized session JSON strings (cleared after `getLocalSleepSessions`) |
| *(legacy)* `com.humango.health.sleepDeliveryMode` / `sleepDeliveryURL` / `sleepDeliveryHeaders` | Removed on arm; not used for delivery |

---

## Lifecycle and Auto-Start

```
App Launch / Background Wake
        │
        ▼
HumangoHealthPlugin.register()
        │
        ▼
SleepDataManager.autoStartIfConfigured()
        ├─ user NOT logged in → skip
        ├─ sleep delivery not armed → skip
        ├─ already monitoring → skip
        └─ else → set monitorStartDate (12 h lookback)
                   start live updates (foreground) OR background monitoring
```

On **logout**, `stopAndClearAll()` must be called:
- Stops all queries
- Clears `monitorStartDate` and session state
- Removes all UserDefaults keys (session state, delivery config, stored data)

---

## Error Handling

| Error | Dart Exception | Description |
|-------|---------------|-------------|
| HealthKit unavailable | `SleepDataException(SLEEP_FETCH_ERROR)` | Device does not support HealthKit |
| Sleep type unavailable | `SleepDataException(SLEEP_FETCH_ERROR)` | `HKCategoryTypeIdentifier.sleepAnalysis` not found |
| Invalid delivery mode | `SleepDataException(INVALID_MODE)` | `mode` is not `"localStorage"` |
| Missing mode argument | `SleepDataException(INVALID_ARGS)` | `configureSleepBackgroundDelivery` called without `mode` |
| Legacy `api` mode | `PlatformException` (`INVALID_MODE` on iOS) | Use local queue + app-side upload |

All Dart exceptions are of type `SleepDataException`:

```dart
class SleepDataException implements Exception {
  final String code;
  final String message;
  final dynamic details;
}
```

---

## Usage Examples

### Minimal: fetch last night's sleep

```dart
import 'package:humango_health/humango_health.dart';

final mgr = SleepDataManager();
final data = await mgr.getSleepData(
  startDate: DateTime.now().subtract(const Duration(hours: 12)),
);
print('Slept ${data.totalSleepHours.toStringAsFixed(1)} hours');
print('Deep sleep: ${data.stageTotals.asleepDeepMinutes.toStringAsFixed(0)} min');
```

### Full setup: arm delivery + drain pending sessions

```dart
// 1. After login — arm local delivery (persists across restarts)
await mgr.configureSleepBackgroundDelivery(const SleepBackgroundDeliveryConfig());

// 2. Optional: startMonitoring / auto-start when logged in — see README

// 3. Upload from your app when the engine runs
final sessions = await mgr.getLocalSleepSessions();
for (final json in sessions) {
  // POST `json` to your API
}
```

### Retrieve on app open

```dart
final sessions = await mgr.getLocalSleepSessions();
for (final json in sessions) {
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  final totalSec = decoded['TOTAL_SLEEP'] as int? ?? 0;
  print('Total sleep: ${totalSec / 3600} h');
}
```

---

## Key Design Decisions

1. **No EventChannel for sleep.** Unlike workout reading, sleep data is not streamed sample-by-sample to Flutter. The entire finalized session is delivered as one payload after session end is detected. This mirrors how sleep data is naturally consumed (post-sleep summary rather than real-time feed).

2. **Freeze window prevents false session endings.** Without it, a 20-minute awake period at 3 AM would incorrectly end the session. The freeze window keeps the session open regardless of gaps until noon, then auto-finalizes.

3. **UUID-based deduplication.** Because both the foreground descriptor and the background observer can deliver overlapping samples, `SleepSessionState.sampleUUIDs` tracks all seen UUIDs to prevent double-counting `totalSleepMinutes`.

4. **Native lifecycle detection.** `AppLifecycleManager` uses `UIApplication` notifications to detect foreground/background transitions natively, removing the need for Flutter to send lifecycle events. Manual `enterForeground()`/`enterBackground()` calls still work as overrides.

5. **API fallback to localStorage.** Any API failure (non-2xx or network error) automatically falls back to storing the session locally, ensuring no data is lost.
