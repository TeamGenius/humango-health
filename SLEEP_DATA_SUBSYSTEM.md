# Sleep Data Subsystem - Requirements & Design

**Document Version:** 1.0  
**Date:** March 5, 2026  
**Plugin:** humango_health  
**Subsystem:** Sleep Data Reading

---

## Overview

This subsystem provides access to Apple HealthKit's sleep analysis data (`HKCategoryTypeIdentifier.sleepAnalysis`). It fetches sleep samples for a configurable time range (defaulting to the last 24 hours) and returns both individual samples and aggregated statistics.

---

## Requirements

### Functional Requirements

#### 1. Sleep Data Retrieval

- **MUST** support configurable date range via `startDate` and `endDate` parameters
- **MUST** default to last 24 hours when no parameters provided
- **MUST** return all sleep samples with full HealthKit metadata
- **MUST** include device and source information when available
- **MUST** return raw JSON for each sample for user inspection

#### 2. Sleep Stage Classification

Support all iOS sleep stages (iOS 16+):

| Value | Stage | Description |
|-------|-------|-------------|
| 0 | `inBed` | User is in bed but not necessarily asleep |
| 1 | `asleepUnspecified` | User is asleep (stage unknown, pre-iOS 16) |
| 2 | `awake` | User woke up during sleep |
| 3 | `asleepCore` | Core/light sleep |
| 4 | `asleepDeep` | Deep sleep |
| 5 | `asleepREM` | REM sleep |

#### 3. Aggregated Statistics

Return computed totals:
- Total sleep time (excluding `inBed` and `awake`)
- Time spent in each sleep stage
- Duration in seconds, minutes, and hours

#### 4. Permission Handling

- Check authorization status before querying
- Return clear error if permission denied
- Reference existing `PermissionManager` for requesting `sleepAnalysis` read permission

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
│  └─ Channel: com.humango.health/sleep                    │
└─────────────────────┬────────────────────────────────────┘
                      │ Method Channel
┌─────────────────────┴────────────────────────────────────┐
│           Sleep Data Manager (iOS/Swift)                 │
│  ├─ fetchSleepData(startDate:, endDate:) → [String: Any] │
│  ├─ HKSampleQuery for HKCategoryType.sleepAnalysis       │
│  └─ Predicate: configurable date range (default: 24h)    │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│                  Apple HealthKit                         │
│  └─ HKCategoryTypeIdentifier.sleepAnalysis               │
└──────────────────────────────────────────────────────────┘
```

### Method Channel

| Channel | Name |
|---------|------|
| Sleep Data | `com.humango.health/sleep` |

| Method | Direction | Parameters | Response |
|--------|-----------|------------|----------|
| `getSleepData` | Dart → iOS | `startDate?: String (ISO8601), endDate?: String (ISO8601)` | `SleepDataResponse` JSON |

### iOS Implementation

**File:** `ios/Classes/SleepData/SleepDataManager.swift`

```swift
@available(iOS 14.0, *)
public class SleepDataManager: NSObject {
    static let shared = SleepDataManager()
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult)
    private func fetchLastDaySleepData() async throws -> [String: Any]
    private func convertSampleToDict(_ sample: HKCategorySample) -> [String: Any]
    private func sleepStageString(from value: Int) -> String
}
```

**Query Configuration:**
- Sample Type: `HKCategoryType(.sleepAnalysis)`
- Predicate: `HKQuery.predicateForSamples(withStart: yesterday, end: now, options: .strictStartDate)`
- Sort: By start date, ascending
- Limit: `HKObjectQueryNoLimit`

### Dart Implementation

**Files:**
- `lib/src/managers/sleep_data_manager.dart` - Manager class
- `lib/src/models/sleep_sample.dart` - Data models

**Models:**

```dart
class SleepSample {
  final String uuid;
  final DateTime startDate;
  final DateTime endDate;
  final int value;
  final String sleepStage;
  final double durationSeconds;
  final double durationMinutes;
  final String? sourceName;
  final String? sourceBundle;
  final SleepDevice? device;
  final Map<String, dynamic>? metadata;
  final Map<String, dynamic> rawJson;
}

class SleepDataResponse {
  final List<SleepSample> samples;
  final int sampleCount;
  final double totalSleepSeconds;
  final double totalSleepMinutes;
  final double totalSleepHours;
  final SleepStageTotals stageTotals;
  final DateTime fetchedFrom;
  final DateTime fetchedTo;
  final Map<String, dynamic> rawJson;
}

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
| `UNSUPPORTED` | iOS version below 14.0 |

**Authorization Errors (embedded in SLEEP_FETCH_ERROR):**
- HealthKit not available on device
- Sleep analysis type not available
- Sleep data access denied by user

---

## Usage Example

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
      print('   Core sleep: ${response.stageTotals.asleepCoreMinutes.toStringAsFixed(0)} min');
      print('   Awake: ${response.stageTotals.awakeMinutes.toStringAsFixed(0)} min');
      
      // Individual samples
      for (final sample in response.samples) {
        print('   ${sample.sleepStage}: ${sample.durationMinutes.toStringAsFixed(0)} min');
        print('      Source: ${sample.sourceName}');
        print('      Raw JSON: ${sample.rawJson}');
      }
    } else {
      print('No sleep data found for the last 24 hours');
    }
  } on SleepDataException catch (e) {
    print('Error: ${e.code} - ${e.message}');
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
| Flutter | 3.0+ |
| Dart | 2.17+ |
