# Sleep Data Subsystem - Requirements & Design

**Document Version:** 2.0  
**Date:** March 5, 2026  
**Plugin:** humango_health  
**Subsystem:** Sleep Data Reading & Monitoring

---

## Overview

This subsystem provides access to Apple HealthKit's sleep analysis data (`HKCategoryTypeIdentifier.sleepAnalysis`). It supports:
- **One-shot fetch**: Query sleep data for a configurable time range
- **Live streaming (Foreground)**: Real-time updates via EventChannel using `HKAnchoredObjectQueryDescriptor`
- **Background monitoring**: Detect changes via `HKObserverQuery` and store in UserDefaults

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

#### 5. Sleep Stage Classification

Support all iOS sleep stages (iOS 16+):

| Value | Stage | Description |
|-------|-------|-------------|
| 0 | `inBed` | User is in bed but not necessarily asleep |
| 1 | `asleepUnspecified` | User is asleep (stage unknown, pre-iOS 16) |
| 2 | `awake` | User woke up during sleep |
| 3 | `asleepCore` | Core/light sleep |
| 4 | `asleepDeep` | Deep sleep |
| 5 | `asleepREM` | REM sleep |

#### 6. Aggregated Statistics

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
│  └─ enterForeground() / enterBackground()                │
└─────────────────────┬────────────────────────────────────┘
                      │ Method Channel + Event Channel
┌─────────────────────┴────────────────────────────────────┐
│           Sleep Data Manager (iOS/Swift)                 │
│  ├─ fetchSleepData() → one-shot query                    │
│  ├─ startLiveUpdates() → HKAnchoredObjectQueryDescriptor │
│  ├─ startBackgroundMonitoring() → HKObserverQuery        │
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
| `startSleepMonitoring` | Dart → iOS | `startDate?: ISO8601` | `{status, startDate}` |
| `stopSleepMonitoring` | Dart → iOS | None | `{status}` |
| `fetchStoredSleepData` | Dart → iOS | None | `SleepDataResponse` |
| `clearStoredSleepData` | Dart → iOS | None | `{status}` |
| `enterSleepForeground` | Dart → iOS | None | `null` |
| `enterSleepBackground` | Dart → iOS | None | `null` |

### Event Channel Events

| Event Type | Payload |
|------------|---------|
| `sleepSample` | `{type: "sleepSample", sample: SleepSample}` |
| `sleepSampleDeleted` | `{type: "sleepSampleDeleted", uuid: String}` |

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
| iOS | `ios/Classes/SleepData/SleepDataManager.swift` | Native HealthKit query implementation |
| iOS | `ios/Classes/HumangoHealthPlugin.swift` | Method channel routing |
| Dart | `lib/src/managers/sleep_data_manager.dart` | Dart manager class |
| Dart | `lib/src/models/sleep_sample.dart` | Data models (SleepSample, SleepDataResponse, SleepStageTotals) |
| Dart | `lib/humango_health.dart` | Public exports |

---

## Compatibility

| Requirement | Version |
|-------------|---------|
| iOS Minimum | 14.0 |
| iOS Sleep Stages | 16.0+ (for asleepCore, asleepDeep, asleepREM) |
| iOS Live Streaming | 15.0+ (HKAnchoredObjectQueryDescriptor) |
| Flutter | 3.0+ |
| Dart | 2.17+ |
