# Sleep Data Subsystem - Requirements & Design

**Document Version:** 3.1  
**Date:** March 5, 2026  
**Plugin:** humango_health  
**Subsystem:** Sleep Data Reading, Monitoring & Background Delivery

---

## Overview

This subsystem provides access to Apple HealthKit's sleep analysis data (`HKCategoryTypeIdentifier.sleepAnalysis`). It supports:
- **One-shot fetch**: Query sleep data for a configurable time range
- **Live streaming (Foreground)**: Real-time updates via EventChannel using `HKAnchoredObjectQueryDescriptor`
- **Background monitoring**: Detect changes via `HKObserverQuery` and store in UserDefaults
- **Sleep session detection**: Freeze-window-aware algorithm detects when a sleep session ends using multi-factor scoring
- **Background API delivery**: Configurable delivery mode that POSTs finalized sleep sessions directly to a remote API (works in both foreground and background)

---

## Requirements

### Functional Requirements

#### 1. Sleep Data Retrieval

- **MUST** support configurable date range via `startDate` and `endDate` parameters
- **MUST** default to last 24 hours when no parameters provided
- **MUST** return all sleep samples with full HealthKit metadata
- **MUST** include device and source information when available
- **MUST** return raw JSON for each sample for user inspection

#### 2. Live Streaming (Foreground)

- **MUST** use `HKAnchoredObjectQueryDescriptor` for real-time updates (iOS 15+)
- **MUST** push each new sleep sample to Flutter via EventChannel
- **MUST** support sample deletion events
- **MUST** maintain anchor for incremental updates

#### 3. Background Monitoring

- **MUST** use `HKObserverQuery` for background change detection
- **MUST** enable `HKHealthStore.enableBackgroundDelivery()` for immediate updates
- **MUST** store fetched data in UserDefaults for later retrieval
- **MUST** provide `fetchStoredSleepData()` method to retrieve background data

#### 4. Foreground/Background Mode Switching

- **MUST** support `enterForeground()` to switch to live streaming mode
- **MUST** support `enterBackground()` to switch to observer mode
- **MUST** automatically switch modes based on app lifecycle
- **MUST** use same foreground/background query strategy for both delivery modes
- **MUST** in API mode, accumulate live samples into session state (not push to EventChannel)

#### 5. Sleep Session Detection (Freeze Window)

Intelligent detection of when a sleep session has ended, using a **freeze window** approach:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `freezeWindowStartHour` | 0 (midnight) | Local hour at which the freeze window opens |
| `freezeWindowEndHour` | 12 (noon) | Local hour at which the freeze window closes |
| `minimumSleepMinutes` | 240 (4 hrs) | Minimum accumulated sleep before session can end |
| `stalenessThresholdMinutes` | 60 | Minutes of no new data before declaring stale |
| `deepSleepAbsenceWindowMinutes` | 90 | If no deep sleep in this window, user is in late sleep |

**Session end detection (during freeze window) requires ALL conditions:**
1. Minimum 4 hours of accumulated sleep
2. No deep sleep in the last 90 minutes of segments
3. No new segments for >= 60 minutes (staleness)
4. Current time is within the freeze window (12 AM – 12 PM)

**After freeze window ends (12 PM):** any accumulated session is auto-finalized.

**Session lifecycle:**
- `configureSleepSession()` — set freeze window and detection parameters
- `getSleepSessionStatus()` — query current session state
- `resetSleepSession()` — clear state for next night

#### 6. Background Delivery System (API Mode)

Users configure how finalized sleep sessions are delivered:

```dart
enum SleepBackgroundDeliveryMode {
  api,          // POST to API endpoint — NO foreground streaming
  localStorage, // Store in UserDefaults (default)
}
```

**API Mode (`SleepBackgroundDeliveryMode.api`):**
- User provides: `apiURL`, `headers` (including auth tokens)
- **Foreground**: `HKAnchoredObjectQueryDescriptor` runs (live streaming), samples accumulate into session state (not pushed to EventChannel)
- **Background**: `HKObserverQuery` runs, samples accumulate into session state
- In **both** foreground and background, when a session ends, native iOS makes direct HTTP POST to the API
- Falls back to local storage on API failure (non-2xx or network error)
- Configuration persists across app restarts via UserDefaults
- The `sleepDataStream` still emits `sleepSessionEnded` events for awareness

**Local Storage Mode (`SleepBackgroundDeliveryMode.localStorage`):**
- Default behavior: foreground uses EventChannel live streaming, background stores to UserDefaults
- Retrieve stored sessions via `getLocalSleepSessions()` on app open
- Sessions cleared from storage after retrieval

**Key difference from workouts:**  
Workout delivery pushes individual workout records immediately.  
Sleep delivery accumulates data over the entire night (session detection), then delivers the **complete finalized session** as a single payload.

#### 7. Sleep Stage Classification

Support all iOS sleep stages (iOS 16+):

| Value | Stage | Description |
|-------|-------|-------------|
| 0 | `inBed` | User is in bed but not necessarily asleep |
| 1 | `asleepUnspecified` | User is asleep (stage unknown, pre-iOS 16) |
| 2 | `awake` | User woke up during sleep |
| 3 | `asleepCore` | Core/light sleep |
| 4 | `asleepDeep` | Deep sleep |
| 5 | `asleepREM` | REM sleep |

#### 8. Aggregated Statistics

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
│  ├─ sleepDataStream → Stream<SleepDataEvent>             │
│  ├─ fetchStoredSleepData() → Response                    │
│  ├─ configureSleepSession() → configure freeze window    │
│  ├─ getSleepSessionStatus() / resetSleepSession()        │
│  ├─ configureSleepBackgroundDelivery(config) → API/local │
│  ├─ getLocalSleepSessions() → [String] (locally stored)  │
│  └─ enterForeground() / enterBackground()                │
└─────────────────────┬────────────────────────────────────┘
                      │ Method Channel + Event Channel
┌─────────────────────┴────────────────────────────────────┐
│           Sleep Data Manager (iOS/Swift)                 │
│  ├─ fetchSleepData() → one-shot query                    │
│  ├─ startLiveUpdates() → HKAnchoredObjectQueryDescriptor │
│  │   └─ API mode: accumulate → session state             │
│  │   └─ localStorage: push → EventChannel                │
│  ├─ startBackgroundMonitoring() → HKObserverQuery        │
│  │   └─ Both modes: accumulate → session state            │
│  ├─ SleepSessionDetector → freeze window + multi-factor  │
│  ├─ SleepBackgroundDeliveryManager → API POST / local    │
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
| Event Channel | Streaming | `com.humango.health/sleep/stream` |

### Method Channel API

| Method | Direction | Parameters | Response |
|--------|-----------|------------|----------|
| `getSleepData` | Dart → iOS | `startDate?: ISO8601, endDate?: ISO8601` | `SleepDataResponse` |
| `startSleepMonitoring` | Dart → iOS | `startDate?: ISO8601` | `{status, startDate, deliveryMode}` |
| `stopSleepMonitoring` | Dart → iOS | None | `{status}` |
| `fetchStoredSleepData` | Dart → iOS | None | `SleepDataResponse` |
| `clearStoredSleepData` | Dart → iOS | None | `{status}` |
| `configureSleepSession` | Dart → iOS | `freezeWindowStartHour?, freezeWindowEndHour?, minimumSleepMinutes?, stalenessThresholdMinutes?, deepSleepAbsenceWindowMinutes?` | `{status, ...config}` |
| `getSleepSessionStatus` | Dart → iOS | None | `{status, reason, isInFreezeWindow, segmentCount, ...}` |
| `resetSleepSession` | Dart → iOS | None | `{status}` |
| `configureSleepBackgroundDelivery` | Dart → iOS | `mode: String, apiURL?: String, headers?: Map` | `{status, mode, apiURL, headersCount}` |
| `getLocalSleepSessions` | Dart → iOS | None | `[String]` (JSON array) |
| `enterSleepForeground` | Dart → iOS | None | `null` |
| `enterSleepBackground` | Dart → iOS | None | `null` |

### Event Channel Events

| Event Type | Payload | Mode |
|------------|---------|------|
| `sleepSample` | `{type, sample: SleepSample}` | localStorage mode only |
| `sleepSampleDeleted` | `{type, uuid: String}` | localStorage mode only |
| `sleepSessionEnded` | `{type, reason, segmentCount, totalSleepMinutes, totalAwakeMinutes, sessionStartDate, latestSegmentEndDate, isFinalized, finalizedAt}` | Both modes |
| `sleepSessionDelivered` | `{type, sessionId, data: JSON String}` | localStorage only |

class SleepStageTotals {
  final double inBedSeconds;
  final double asleepUnspecifiedSeconds;
  final double awakeSeconds;
  final double asleepCoreSeconds;
  final double asleepDeepSeconds;
  final double asleepREMSeconds;
}
```

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
| `INVALID_MODE` | Invalid delivery mode (must be `api` or `localStorage`) |

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

### Live Streaming (Foreground)

```dart
import 'dart:async';
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();
StreamSubscription<SleepDataEvent>? subscription;

void startLiveMonitoring() async {
  // Subscribe to live sleep data stream
  subscription = sleepManager.sleepDataStream.listen((event) {
    if (event is SleepSampleEvent) {
      print('🛏️ New sleep sample: ${event.sample.sleepStage}');
      print('   Duration: ${event.sample.durationMinutes} min');
    } else if (event is SleepSampleDeletedEvent) {
      print('❌ Sleep sample deleted: ${event.uuid}');
    }
  });

  // Start monitoring from a specific date
  await sleepManager.startMonitoring(
    startDate: DateTime.now().subtract(const Duration(hours: 24)),
  );
}

void stopLiveMonitoring() async {
  await subscription?.cancel();
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

### Sleep Session Detection

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

// Configure the freeze window and detection parameters (optional — defaults are sensible)
void configureSleepDetection() async {
  await sleepManager.configureSleepSession(
    freezeWindowStartHour: 0,   // midnight
    freezeWindowEndHour: 12,    // noon
    minimumSleepMinutes: 240,   // 4 hours
    stalenessThresholdMinutes: 60,
    deepSleepAbsenceWindowMinutes: 90,
  );
}

// Listen for session-ended notifications
void listenForSessionEnd() {
  sleepManager.sleepDataStream.listen((event) {
    if (event is SleepSessionEndedEvent) {
      print('🛏️ Sleep session ended: ${event.reason}');
      print('   ${event.segmentCount} segments, ${event.totalSleepMinutes.toStringAsFixed(0)}m sleep');
      
      // After processing, reset for next night
      sleepManager.resetSleepSession();
    }
  });
}

// Check session status on demand
void checkSessionStatus() async {
  final status = await sleepManager.getSleepSessionStatus();
  print('Session status: ${status['status']}');
  print('In freeze window: ${status['isInFreezeWindow']}');
  print('Total sleep: ${status['totalSleepMinutes']}m');
}
```

### Background API Delivery (API Mode)

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

// Configure API delivery mode BEFORE starting monitoring.
// This should be called early in app lifecycle (e.g., after login).
void configureSleepAPIDelivery() async {
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.api,
      apiURL: 'https://api.example.com/v1/sleep-sessions',
      headers: {
        'Authorization': 'Bearer YOUR_AUTH_TOKEN',
        'X-Device-Id': 'device-123',
      },
    ),
  );
  
  // Start monitoring — in API mode, both foreground (HKAnchoredObjectQueryDescriptor)
  // and background (HKObserverQuery) run normally. Samples accumulate into session
  // state and are POSTed to the API when the session ends.
  await sleepManager.startMonitoring(
    startDate: DateTime.now().subtract(const Duration(hours: 12)),
  );
}

// Switch back to localStorage mode if needed
void switchToLocalStorage() async {
  await sleepManager.configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.localStorage,
    ),
  );
}
```

### Background Local Storage Delivery

```dart
import 'package:humango_health/humango_health.dart';

final sleepManager = SleepDataManager();

// On app startup, retrieve any sleep sessions stored while app was in background
void retrieveBackgroundSessions() async {
  final sessions = await sleepManager.getLocalSleepSessions();
  for (final sessionJson in sessions) {
    // Each session is a JSON string containing the full sleep data
    print('Retrieved stored session: ${sessionJson.substring(0, 100)}...');
    // Parse and process the session data as needed
  }
}

// Listen for delivered sessions via stream (when app is in foreground)
void listenForDeliveredSessions() {
  sleepManager.sleepDataStream.listen((event) {
    if (event is SleepSessionDeliveredEvent) {
      print('Session delivered: ${event.sessionId}');
      // event.data contains the full JSON string
    }
  });
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
| iOS | `ios/Classes/SleepData/SleepBackgroundDeliveryManager.swift` | Background delivery manager (API POST / local storage) |
| iOS | `ios/Classes/HumangoHealthPlugin.swift` | Method channel routing |
| Dart | `lib/src/managers/sleep_data_manager.dart` | Dart manager class |
| Dart | `lib/src/models/sleep_sample.dart` | Data models (SleepSample, SleepDataResponse, SleepStageTotals) |
| Dart | `lib/src/models/sleep_background_delivery_config.dart` | Delivery config model (SleepBackgroundDeliveryConfig, SleepBackgroundDeliveryMode) |
| Dart | `lib/humango_health.dart` | Public exports |

---

## Background Delivery — Detailed Design

### Delivery Mode Switching

```
                  configureSleepBackgroundDelivery(mode)
                              │
              ┌───────────────┴───────────────┐
              │                               │
       mode == .api                    mode == .localStorage
              │                               │
    ┌─────────┴─────────┐           ┌─────────┴─────────┐
    │ Same fg/bg query   │           │ Same fg/bg query   │
    │ strategy:          │           │ strategy:          │
    │ FG: AnchoredQuery  │           │ FG: AnchoredQuery  │
    │ BG: ObserverQuery  │           │ BG: ObserverQuery  │
    │                    │           │                    │
    │ Data routing:      │           │ Data routing:      │
    │ Accumulate →       │           │ FG: EventChannel   │
    │ session state →    │           │ BG: UserDefaults   │
    │ POST to apiURL     │           │                    │
    │ on session end     │           │ On session end:    │
    │                    │           │ local storage      │
    └────────────────────┘           └────────────────────┘
```

### API Mode Flow

```
1. App calls configureSleepBackgroundDelivery(mode: .api, apiURL: ..., headers: ...)
2. Config persists to UserDefaults (survives restart)
3. App calls startMonitoring()
   └─ Starts HKAnchoredObjectQueryDescriptor (foreground) or HKObserverQuery (background)
   └─ Same query strategy as localStorage mode — only data routing differs
4. Foreground (HKAnchoredObjectQueryDescriptor):
   └─ Live samples received → accumulated into SleepSessionState (NOT pushed to EventChannel)
   └─ Session state persisted, SleepSessionDetector evaluates multi-factor scoring
5. Background (HKObserverQuery):
   └─ Observer fires → SleepDataManager fetches + accumulates into SleepSessionState
   └─ SleepSessionDetector evaluates multi-factor scoring
6. When session ends (or freeze window expires) — in EITHER foreground or background:
   └─ Full sleep data fetched (all samples from session)
   └─ JSON serialized and POSTed to configured apiURL
   └─ Custom headers included (Authorization, etc.)
   └─ On 2xx: success logged
   └─ On failure: falls back to local storage
7. EventChannel still emits sleepSessionEnded event (for awareness)
```

### API Request Format

When a sleep session is finalized, the following JSON payload is POSTed:

```json
{
  "samples": [ ... ],
  "sampleCount": 19,
  "totalSleepSeconds": 28260.0,
  "totalSleepMinutes": 471.0,
  "totalSleepHours": 7.85,
  "stageTotals": {
    "asleepCore": { "seconds": 16800.0, "minutes": 280.0 },
    "asleepDeep": { "seconds": 3600.0, "minutes": 60.0 },
    "asleepREM": { "seconds": 7860.0, "minutes": 131.0 },
    "awake": { "seconds": 900.0, "minutes": 15.0 },
    "inBed": { "seconds": 0.0, "minutes": 0.0 },
    "asleepUnspecified": { "seconds": 0.0, "minutes": 0.0 }
  },
  "fetchedFrom": "2026-03-04T22:00:00.000Z",
  "fetchedTo": "2026-03-05T06:00:00.000Z",
  "reason": "sleep>=471m, no_deep_sleep_recently, stale_65m",
  "segmentCount": 19,
  "isFinalized": true,
  "finalizedAt": "2026-03-05T06:05:00.000Z",
  "sessionStartDate": "2026-03-04T22:00:00.000Z",
  "latestSegmentEndDate": "2026-03-05T05:00:00.000Z"
}
```

**HTTP Request:**
```
POST https://api.example.com/v1/sleep-sessions
Content-Type: application/json
Authorization: Bearer YOUR_AUTH_TOKEN
X-Device-Id: device-123

<body: JSON above>
```

### UserDefaults Persistence Keys

| Key | Purpose |
|-----|---------|
| `com.humango.health.sleepDeliveryMode` | Delivery mode (`api` or `localStorage`) |
| `com.humango.health.sleepDeliveryURL` | Configured API endpoint URL |
| `com.humango.health.sleepDeliveryHeaders` | Custom HTTP headers dictionary |
| `com.humango.health.sleepPendingLocal` | Pending locally stored session JSON strings |
| `com.humango.health.sleepSessionState` | Persisted SleepSessionState (Codable) |
| `com.humango.health.storedSleepData` | Most recent sleep data snapshot |
| `com.humango.health.lastSleepFetchDate` | Timestamp of last background fetch |

---

## Compatibility

| Requirement | Version |
|-------------|---------|
| iOS Minimum | 14.0 |
| iOS Sleep Stages | 16.0+ (for asleepCore, asleepDeep, asleepREM) |
| iOS Live Streaming | 15.0+ (HKAnchoredObjectQueryDescriptor) |
| Flutter | 3.0+ |
| Dart | 2.17+ |
