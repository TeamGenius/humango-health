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

## Background Delivery System

### Delivery Modes

```dart
enum SleepBackgroundDeliveryMode {
  api,          // POST finalized session JSON to a remote API
  localStorage, // Store finalized session in UserDefaults (default)
}
```

#### API Mode

```dart
await sleepManager.configureSleepBackgroundDelivery(
  SleepBackgroundDeliveryConfig(
    mode: SleepBackgroundDeliveryMode.api,
    apiURL: 'https://api.example.com/sleep-sessions',
    headers: {'Authorization': 'Bearer <token>'},
  ),
);
// No need to call startMonitoring() — auto-starts on next app launch
// if API is configured and user is logged in.
```

- Configuration is persisted to UserDefaults and survives app restarts.
- On app launch `SleepDataManager.autoStartIfConfigured()` is called automatically from the plugin's `register()`.
- If the API call returns a non-2xx HTTP status or a network error occurs, the session JSON is stored locally as a fallback.

### Background payload

The JSON delivered (via API POST or local storage) contains:

```json
{
  "samples": [ /* full list of SleepSample objects */ ],
  "sampleCount": 42,
  "totalSleepSeconds": 25200,
  "totalSleepMinutes": 420,
  "totalSleepHours": 7.0,
  "stageTotals": {
    "inBed":            { "seconds": 300,  "minutes": 5   },
    "asleepCore":       { "seconds": 9000, "minutes": 150 },
    "asleepDeep":       { "seconds": 5400, "minutes": 90  },
    "asleepREM":        { "seconds": 7200, "minutes": 120 },
    "asleepUnspecified":{ "seconds": 3600, "minutes": 60  },
    "awake":            { "seconds": 600,  "minutes": 10  }
  },
  "fetchedFrom": "2026-03-17T22:00:00.000Z",
  "fetchedTo":   "2026-03-18T07:00:00.000Z",
  "reason": "sleep>=420m, no_deep_sleep_recently, stale_65m",
  "segmentCount": 42,
  "isFinalized": true,
  "finalizedAt": "2026-03-18T07:15:00.000Z",
  "sessionStartDate": "2026-03-17T22:05:00.000Z",
  "latestSegmentEndDate": "2026-03-18T06:50:00.000Z"
}
```

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
| `configureSleepBackgroundDelivery` | `mode: "api"\|"localStorage"`, `apiURL?: String`, `headers?: Map` | `{status, mode, apiURL, headersCount}` |
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
| `com.humango.health.sleepDeliveryMode` | `"api"` or `"localStorage"` |
| `com.humango.health.sleepDeliveryURL` | Configured API URL |
| `com.humango.health.sleepDeliveryHeaders` | Custom HTTP headers dictionary |
| `com.humango.health.sleepPendingLocal` | Array of locally-stored session JSON strings |

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
        ├─ no API config in UserDefaults → skip
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
| Invalid delivery mode | `SleepDataException(INVALID_MODE)` | `mode` is not `"api"` or `"localStorage"` |
| Missing mode argument | `SleepDataException(INVALID_ARGS)` | `configureSleepBackgroundDelivery` called without `mode` |
| API HTTP error (non-2xx) | — (falls back to localStorage) | Logged on iOS, session stored locally |
| API network error | — (falls back to localStorage) | Logged on iOS, session stored locally |

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

### Full setup with API delivery

```dart
// 1. Configure delivery (persists across restarts)
await mgr.configureSleepBackgroundDelivery(
  SleepBackgroundDeliveryConfig(
    mode: SleepBackgroundDeliveryMode.api,
    apiURL: 'https://api.example.com/sleep',
    headers: {'Authorization': 'Bearer $token'},
  ),
);

// 2. Optionally customise session detection
await mgr.configureSleepSession(minimumSleepMinutes: 300);

// 3. Start monitoring (not required — autoStartIfConfigured() does it on next launch)
await mgr.startMonitoring();

// 4. On logout
await mgr.stopMonitoring();
// + call UserSessionManager.shared.setLoggedOut() which triggers stopAndClearAll()
```

### localStorage mode — retrieve on app open

```dart
// On app resume
final sessions = await mgr.getLocalSleepSessions();
for (final json in sessions) {
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  print('Session: ${decoded['totalSleepHours']} h, reason: ${decoded['reason']}');
}
```

---

## Key Design Decisions

1. **No EventChannel for sleep.** Unlike workout reading, sleep data is not streamed sample-by-sample to Flutter. The entire finalized session is delivered as one payload after session end is detected. This mirrors how sleep data is naturally consumed (post-sleep summary rather than real-time feed).

2. **Freeze window prevents false session endings.** Without it, a 20-minute awake period at 3 AM would incorrectly end the session. The freeze window keeps the session open regardless of gaps until noon, then auto-finalizes.

3. **UUID-based deduplication.** Because both the foreground descriptor and the background observer can deliver overlapping samples, `SleepSessionState.sampleUUIDs` tracks all seen UUIDs to prevent double-counting `totalSleepMinutes`.

4. **Native lifecycle detection.** `AppLifecycleManager` uses `UIApplication` notifications to detect foreground/background transitions natively, removing the need for Flutter to send lifecycle events. Manual `enterForeground()`/`enterBackground()` calls still work as overrides.

5. **API fallback to localStorage.** Any API failure (non-2xx or network error) automatically falls back to storing the session locally, ensuring no data is lost.
