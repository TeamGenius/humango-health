# Sleep Data Subsystem - Requirements & Design

**Document Version:** 3.1  
**Date:** March 5, 2026  
**Plugin:** humango_health  
**Subsystem:** Sleep Data Reading, Monitoring & Background Delivery

---

## Overview

This subsystem provides access to Apple HealthKit's sleep analysis data (`HKCategoryTypeIdentifier.sleepAnalysis`). It supports:
- **One-shot fetch**: Query sleep data for a configurable time range (`getSleepData`)
- **Foreground monitoring**: `HKAnchoredObjectQueryDescriptor` accumulates samples into on-device session state
- **Background monitoring**: `HKObserverQuery` + `enableBackgroundDelivery`; same accumulation path when the app is suspended
- **Session finalization**: In-bed-first pipeline + grouping-based `calculateSleepPayload` where applicable; finalized **flat JSON** is appended to a **local pending queue** only — the plugin does **not** POST session payloads to your API
- **No EventChannel** for sleep payloads: use `getLocalSleepSessions()` (and optional native KVO in the host Runner) to upload from your app

---

## Requirements

### Functional Requirements

#### 1. Sleep Data Retrieval

- **MUST** support configurable date range via `startDate` and `endDate` parameters
- **MUST** default to last 24 hours when no parameters provided
- **MUST** return all sleep samples with full HealthKit metadata
- **MUST** include device and source information when available
- **MUST** return raw JSON for each sample for user inspection

#### 2. Foreground accumulation

- **MUST** use `HKAnchoredObjectQueryDescriptor` for incremental updates while the app is active (iOS 15+)
- **MUST** accumulate samples into session state (no per-sample EventChannel to Dart)

#### 3. Background monitoring

- **MUST** use `HKObserverQuery` for background change detection
- **MUST** enable `HKHealthStore.enableBackgroundDelivery()` for wake-ups
- **MUST** use the same accumulation path as foreground; on finalize, store **one** flat JSON per night in `com.humango.health.sleepPendingLocal`

#### 4. Foreground/background mode switching

- **MUST** support `enterForeground()` / `enterBackground()` overrides (normally unused — native `AppLifecycleManager` switches modes)
- **MUST** automatically switch modes based on app lifecycle

#### 5. Sleep session detection (native automatic pipeline)

Session boundaries, in-bed checks, optional 15‑minute re-check timer, grouping-based `calculateSleepPayload` in the background path, and finalization are implemented in Swift — **not** configurable from Dart (legacy `configureSleepSession` / `getSleepSessionStatus` / `resetSleepSession` APIs were removed in v0.0.8). See `SleepDataManager.swift` and README for behavioral detail.

#### 6. Background delivery (local queue only)

```dart
enum SleepBackgroundDeliveryMode {
  localStorage,
}
```

- **`configureSleepBackgroundDelivery`** arms delivery (`HumangoSleepDeliveryArmed`), clears legacy API `UserDefaults` keys, and enables auto-start when the user is logged in.
- When a session is finalized, native code builds the flat aggregated JSON and appends it to `com.humango.health.sleepPendingLocal`. The plugin **does not** POST session payloads to your API.
- **`getLocalSleepSessions()`** returns pending JSON strings and clears the queue.

**Key difference from workouts:** workout delivery emits per completed workout (stream or pending). Sleep accumulates overnight, then stores **one** finalized JSON per session.

#### 7. Sleep stage classification

Support all iOS sleep stages (iOS 16+):

| Value | Stage | Description |
|-------|-------|-------------|
| 0 | `inBed` | User is in bed but not necessarily asleep |
| 1 | `asleepUnspecified` | User is asleep (stage unknown, pre-iOS 16) |
| 2 | `awake` | User woke up during sleep |
| 3 | `asleepCore` | Core/light sleep |
| 4 | `asleepDeep` | Deep sleep |
| 5 | `asleepREM` | REM sleep |

#### 8. Aggregated statistics

Return computed totals:
- Total sleep time (excluding `inBed` and `awake`)
- Time spent in each sleep stage
- Duration in seconds, minutes, and hours

---

## Technical Design

### Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                Flutter Application Layer                 │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│           Sleep Data Manager (Dart)                      │
│  ├─ getSleepData({startDate?, endDate?}) → Response      │
│  ├─ startMonitoring() / stopMonitoring()                 │
│  ├─ fetchStoredSleepData() → Response                    │
│  ├─ configureSleepBackgroundDelivery() → local queue     │
│  ├─ getLocalSleepSessions() → [String] (pending JSON)   │
│  ├─ calculateSleepPayload({startDate?, endDate?})        │
│  └─ enterForeground() / enterBackground() (optional)      │
└─────────────────────┬────────────────────────────────────┘
                      │ Method Channel only
┌─────────────────────┴────────────────────────────────────┐
│           Sleep Data Manager (iOS/Swift)                 │
│  ├─ fetchSleepData() → one-shot query                    │
│  ├─ startLiveUpdates() → HKAnchoredObjectQueryDescriptor │
│  │   └─ accumulate samples → session state               │
│  ├─ startBackgroundMonitoring() → HKObserverQuery        │
│  │   └─ accumulate → session state                       │
│  ├─ Session / inBed pipeline + grouping (native)        │
│  ├─ SleepBackgroundDeliveryManager → local queue only    │
│  └─ UserDefaults storage for background data             │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│                  Apple HealthKit                         │
│  └─ HKCategoryTypeIdentifier.sleepAnalysis               │
└──────────────────────────────────────────────────────────┘
```

### Channels

| Channel | Type | Name |
|---------|------|------|
| Method Channel | Request/Response | `com.humango.health/sleep` |

### Method Channel API

| Method | Direction | Parameters | Response |
|--------|-----------|------------|----------|
| `getSleepData` | Dart → iOS | `startDate?: ISO8601, endDate?: ISO8601` | `SleepDataResponse` |
| `startSleepMonitoring` | Dart → iOS | `startDate?: ISO8601` | `{status, startDate, deliveryMode}` |
| `stopSleepMonitoring` | Dart → iOS | None | `{status}` |
| `fetchStoredSleepData` | Dart → iOS | None | `SleepDataResponse` |
| `clearStoredSleepData` | Dart → iOS | None | `{status}` |
| `configureSleepBackgroundDelivery` | Dart → iOS | `mode: "localStorage"` only | `{status, mode}` |
| `getLocalSleepSessions` | Dart → iOS | None | `[String]` (JSON array) |
| `calculateSleepPayload` | Dart → iOS | `startDate?, endDate?` (ISO8601) | flat payload map |
| `enterSleepForeground` | Dart → iOS | None | `null` |
| `enterSleepBackground` | Dart → iOS | None | `null` |

### Real-time streaming

There is **no** EventChannel for sleep sample payloads. Finalized nights are retrieved with `getLocalSleepSessions()` (or host Runner code that reads `UserDefaults`).

---

## Response JSON Structure

```json
{
  "samples": [
    {
      "uuid": "ABC-123-DEF",
      "startDate": "2026-03-04T23:00:00.000Z",
      "endDate": "2026-03-05T01:30:00.000Z",
      "value": 3,
      "sleepStage": "asleepCore",
      "durationSeconds": 9000.0,
      "durationMinutes": 150.0,
      "sourceName": "Apple Watch",
      "sourceBundle": "com.apple.health",
      "device": {
        "name": "Apple Watch",
        "model": "Watch7,1",
        "manufacturer": "Apple Inc.",
        "hardwareVersion": "...",
        "softwareVersion": "10.0"
      },
      "metadata": {
        "HKTimeZone": "America/New_York"
      },
      "rawJson": { ... }
    }
  ],
  "sampleCount": 8,
  "totalSleepSeconds": 25200.0,
  "totalSleepMinutes": 420.0,
  "totalSleepHours": 7.0,
  "stageTotals": {
    "inBed": { "seconds": 1800.0, "minutes": 30.0 },
    "asleepUnspecified": { "seconds": 0.0, "minutes": 0.0 },
    "awake": { "seconds": 900.0, "minutes": 15.0 },
    "asleepCore": { "seconds": 14400.0, "minutes": 240.0 },
    "asleepDeep": { "seconds": 5400.0, "minutes": 90.0 },
    "asleepREM": { "seconds": 5400.0, "minutes": 90.0 }
  },
  "fetchedFrom": "2026-03-04T10:00:00.000Z",
  "fetchedTo": "2026-03-05T10:00:00.000Z"
}
```

---

## Error Handling

| Error Code | Description |
|------------|-------------|
| `SLEEP_FETCH_ERROR` | General error during fetch |
| `LIVE_UPDATE_ERROR` | Error during live streaming |
| `UNSUPPORTED` | iOS version below 14.0 |
| `INVALID_ARGS` | Missing or invalid method arguments |
| `INVALID_MODE` | Invalid delivery mode (must be `localStorage`) |

**Authorization Errors (embedded in SLEEP_FETCH_ERROR):**
- HealthKit not available on device
- Sleep analysis type not available
- Sleep data access denied by user

---

## Usage Examples

### One-Shot Fetch

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void fetchSleepData() async {
  try {
    final response = await sleepManager.getSleepData();
    
    if (response.hasSleepData) {
      print('🛏️ Sleep Summary:');
      print('   Total sleep: ${response.totalSleepHours.toStringAsFixed(1)} hours');
      print('   Samples: ${response.sampleCount}');
      
      // Stage breakdown
      print('   Deep sleep: ${response.stageTotals.asleepDeepMinutes.toStringAsFixed(0)} min');
      print('   REM sleep: ${response.stageTotals.asleepREMMinutes.toStringAsFixed(0)} min');
    }
  } on SleepDataException catch (e) {
    print('Error: ${e.code} - ${e.message}');
  }
}
```

### Foreground monitoring

In the foreground, the iOS side uses `HKAnchoredObjectQueryDescriptor` to accumulate samples into session state. No per-sample stream is sent to Dart; when the session ends, JSON is appended to the local pending queue for `getLocalSleepSessions()`.

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

void startForegroundMonitoring() async {
  await sleepManager.startMonitoring(
    startDate: DateTime.now().subtract(const Duration(hours: 24)),
  );
}

void stopForegroundMonitoring() async {
  await sleepManager.stopMonitoring();
}
```

### Background Monitoring

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

// Start monitoring - native iOS will automatically switch between
// foreground/background modes based on app lifecycle
void initSleepMonitoring() async {
  await sleepManager.startMonitoring();
}

// Retrieve sleep data stored during background (collected by iOS)
void fetchBackgroundData() async {
  final storedData = await sleepManager.fetchStoredSleepData();
  print('📦 Stored ${storedData.sampleCount} samples from background');
}

// Clear stored data after processing
void clearBackgroundData() async {
  await sleepManager.clearStoredSleepData();
}

// NOTE: App lifecycle switching is now handled automatically by native iOS
// via AppLifecycleManager. You no longer need to call enterForeground/enterBackground
// from Flutter, though they remain available for manual override if needed.
```

### Session detection

Implemented natively only (in-bed checks, timers, grouping). There is **no** Dart API to configure or query internal session state.

### Background delivery — configure and drain

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

Future<void> afterLogin() async {
  await sleepManager.configureSleepBackgroundDelivery(const SleepBackgroundDeliveryConfig());
}

Future<void> uploadPending() async {
  final sessions = await sleepManager.getLocalSleepSessions();
  for (final sessionJson in sessions) {
    // POST sessionJson to your API from Dart or Runner native
  }
}
```

---

## Permission Requirements

Sleep data requires HealthKit read permission for `sleepAnalysis`. Ensure you:

1. Add to `Info.plist`:
```xml
<key>NSHealthShareUsageDescription</key>
<string>We need access to read your health data including sleep analysis.</string>
```

2. Request permission before fetching:
```dart
final permissionManager = PermissionManager();
await permissionManager.request(
  [HealthDataType.sleepAnalysis],  // Read types
  []  // Write types
);
```

---

## Files

| Layer | File | Description |
|-------|------|-------------|
| iOS | `ios/Classes/SleepData/SleepDataManager.swift` | Native HealthKit query, monitoring & session evaluation |
| iOS | `ios/Classes/SleepData/SleepSessionDetector.swift` | Freeze-window session detection algorithm |
| iOS | `ios/Classes/SleepData/SleepBackgroundDeliveryManager.swift` | Persists finalized session JSON to UserDefaults |
| iOS | `ios/Classes/HumangoHealthPlugin.swift` | Method channel routing |
| Dart | `lib/src/managers/sleep_data_manager.dart` | Dart manager class |
| Dart | `lib/src/models/sleep_sample.dart` | Data models (SleepSample, SleepDataResponse, SleepStageTotals) |
| Dart | `lib/src/models/sleep_background_delivery_config.dart` | Delivery config model (SleepBackgroundDeliveryConfig, SleepBackgroundDeliveryMode) |
| Dart | `lib/humango_health.dart` | Public exports |

---

## Background delivery — detailed design

After `configureSleepBackgroundDelivery` (`localStorage` only), foreground and background use the same HealthKit strategy (`HKAnchoredObjectQueryDescriptor` / `HKObserverQuery`). On finalize, `SleepDataManager.buildAggregatedPayload` produces flat JSON (stage totals as integer **seconds**), serialized and appended to `com.humango.health.sleepPendingLocal`.

### UserDefaults keys (delivery-related)

| Key | Purpose |
|-----|---------|
| `HumangoSleepDeliveryArmed` | Delivery armed after successful configure |
| `com.humango.health.sleepPendingLocal` | Pending finalized session JSON strings |
| `com.humango.health.sleepSessionState` | Persisted `SleepSessionState` (Codable) |
| `com.humango.health.storedSleepData` | Most recent sleep data snapshot |
| `com.humango.health.lastSleepFetchDate` | Timestamp of last background fetch |

Legacy `com.humango.health.sleepDeliveryMode` / `sleepDeliveryURL` / `sleepDeliveryHeaders` are cleared when arming; `mode: api` is rejected (`INVALID_MODE`).

---

## Compatibility

| Requirement | Version |
|-------------|---------|
| iOS Minimum | 14.0 |
| iOS Sleep Stages | 16.0+ (for asleepCore, asleepDeep, asleepREM) |
| iOS anchored queries | 15.0+ (`HKAnchoredObjectQueryDescriptor` for monitoring) |
| Flutter | 3.0+ |
| Dart | 2.17+ |
