# Permission Handling Subsystem - Requirements & Design

**Document Version:** 1.1  
**Date:** March 24, 2026  
**Plugin:** `humango_health`  
**Subsystem:** Permission Management

**Runtime channels:** `healthkit/method` (MethodChannel), `healthkit/event` (EventChannel). Dart API: `PermissionManager.verifyAuthorization()`, `requestAuthorization()`, `permissionStream`.

---

## Requirements

### Functional Requirements

#### 1. Three-Method Permission API

The permission manager must provide exactly three public methods:

1. **`verify()`** - Returns current permission status
   - Synchronously checks authorization status
   - Returns response with current state
   - Does NOT show permission dialog
   - Must handle both read and write permissions separately

2. **`request()`** - Requests permissions from user
   - Shows iOS native permission dialog
   - Fire-and-forget: returns immediately without waiting for user decision
   - NO response expected from native to Flutter
   - Must request all specified types in single dialog

3. **`listen()`** - Monitors permission changes
   - Returns event channel stream
   - Emits updates when permission status changes
   - Triggers when app resumes from background/settings
   - Supports multiple concurrent listeners

#### 2. Health Data Type Specification

Users must specify health data types including:
- **Core metrics:** Sleep, HRV (Heart Rate Variability), Resting Heart Rate
- **Workouts:** Workout data access
- **Extensible:** Support for additional types (heart rate, active calories, steps, body measurements, etc.)

#### 3. Read/Write Permission Arrays

Users provide TWO separate arrays:
- **Read array:** Data types for reading/querying
- **Write array:** Data types for writing/saving

This separation is required by HealthKit's permission model.

### Non-Functional Requirements

1. **Type Safety:** Use enums to prevent invalid type strings
2. **Memory Safety:** Proper stream disposal and lifecycle management
3. **Error Handling:** Graceful handling of HealthKit unavailability (iPad)
4. **Performance:** Efficient permission checking without blocking UI
5. **Privacy Compliance:** Document HealthKit's read permission limitations
6. **Cross-app Reusability:** Plugin-based architecture for use in multiple apps

---

## Technical Design

### Architecture Overview

```
┌─────────────────────────────────────────┐
│         Flutter (Dart Layer)            │
├─────────────────────────────────────────┤
│  PermissionManager                      │
│  ├─ verifyAuthorization() → Future<HealthKitAuthorizationResult>
│  ├─ requestAuthorization() → Future<void>
│  └─ permissionStream → Stream<HealthKitAuthorizationResult>
└────────────┬────────────────────────────┘
             │
         ┌───┴────┐
         │        │
    MethodChannel EventChannel
         │        │
         └───┬────┘
┌────────────┴────────────────────────────┐
│       iOS Native (Swift Layer)          │
├─────────────────────────────────────────┤
│  PermissionManager.swift                │
│  ├─ verifyPermissions()                 │
│  ├─ requestPermissions()                │
│  └─ PermissionStreamHandler             │
│      └─ Monitors app lifecycle          │
└────────────┬────────────────────────────┘
             │
┌────────────┴────────────────────────────┐
│      HealthKit Framework (iOS)          │
│  HKHealthStore                          │
│  ├─ authorizationStatus(for:)           │
│  └─ requestAuthorization(toShare:read:) │
└─────────────────────────────────────────┘
```

### Data Models

#### HealthDataType Enum
```dart
enum HealthDataType {
  // Cardiovascular
  heartRate,
  hrv,                    // Heart Rate Variability SDNN
  restingHeartRate,
  
  // Sleep
  sleep,
  
  // Activity & Workouts
  workout,
  activeCalories,
  steps,
  
  // Body
  bodyMass,
  height,
  bodyFatPercentage,
  
  // Additional
  vo2Max,
  respiratoryRate,
  oxygenSaturation
}
```

**Mapping to HealthKit:**
| HealthDataType | HealthKit Identifier | Type |
|----------------|---------------------|------|
| hrv | HKQuantityTypeIdentifierHeartRateVariabilitySDNN | Quantity |
| sleep | HKCategoryTypeIdentifierSleepAnalysis | Category |
| restingHeartRate | HKQuantityTypeIdentifierRestingHeartRate | Quantity |
| workout | HKWorkoutType | Special |

#### PermissionStatus Enum
```dart
enum PermissionStatus {
  notDetermined,  // Never asked
  authorized,     // Permission granted (or appears granted)
  denied,         // Permission explicitly denied
  restricted      // OS restriction (e.g., parental controls)
}
```

#### PermissionResponse Model
```dart
class PermissionResponse {
  final Map<HealthDataType, PermissionStatus> readStatuses;
  final Map<HealthDataType, PermissionStatus> writeStatuses;
  
  PermissionResponse({
    required this.readStatuses,
    required this.writeStatuses,
  });
}
```

### Method Signatures

#### Dart API
```dart
class PermissionManager {
  /// Checks current authorization status for specified data types.
  /// 
  /// **WARNING:** READ permissions may show 'authorized' but still fail
  /// during queries due to HealthKit privacy protection. Always handle
  /// query errors gracefully.
  /// 
  /// - [readTypes]: Data types requesting read access
  /// - [writeTypes]: Data types requesting write access
  /// - Returns: Current permission status for each type
  Future<PermissionResponse> verify(
    List<HealthDataType> readTypes,
    List<HealthDataType> writeTypes,
  );

  /// Requests authorization for specified data types.
  /// 
  /// Shows iOS native permission dialog. Returns immediately without
  /// waiting for user decision (fire-and-forget). Use [verify()] or
  /// [listen()] to check results after user responds.
  /// 
  /// **Note:** Permission dialog appears only ONCE per data type.
  /// Users must enable in Settings app after initial denial.
  /// 
  /// - [readTypes]: Data types requesting read access
  /// - [writeTypes]: Data types requesting write access
  Future<void> request(
    List<HealthDataType> readTypes,
    List<HealthDataType> writeTypes,
  );

  /// Creates stream that emits permission status updates.
  /// 
  /// Emits immediately upon subscription with current status.
  /// Emits again when app resumes from background or Settings app.
  /// 
  /// Returns broadcast stream supporting multiple listeners.
  /// Remember to cancel subscription when no longer needed.
  /// 
  /// - [readTypes]: Data types to monitor for read access
  /// - [writeTypes]: Data types to monitor for write access
  /// - Returns: Stream of permission status updates
  Stream<PermissionResponse> listen(
    List<HealthDataType> readTypes,
    List<HealthDataType> writeTypes,
  );
}
```

#### iOS Native Methods
```swift
class PermissionManager {
  /// Returns authorization status for specified types
  func verifyPermissions(
    readTypes: [String], 
    writeTypes: [String]
  ) -> [String: Any]
  
  /// Requests authorization, calls completion immediately
  func requestPermissions(
    readTypes: [String],
    writeTypes: [String],
    completion: @escaping (Result<Void, Error>) -> Void
  )
}

class PermissionStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError?
  
  func onCancel(
    withArguments arguments: Any?
  ) -> FlutterError?
}
```

### Platform Channels

#### Method Channel
- **Name:** `"com.humango.workouts/permissions"`
- **Methods:**
  - `"verify"` - Check permission status
  - `"request"` - Request permissions

**Arguments Format:**
```json
{
  "readTypes": ["heartRateVariabilitySDNN", "sleepAnalysis", "restingHeartRate"],
  "writeTypes": ["workoutType"]
}
```

**Response Format (verify only):**
```json
{
  "readStatuses": {
    "heartRateVariabilitySDNN": "authorized",
    "sleepAnalysis": "notDetermined",
    "restingHeartRate": "authorized"
  },
  "writeStatuses": {
    "workoutType": "notDetermined"
  }
}
```

#### Event Channel
- **Name:** `"com.humango.workouts/permissions/stream"`
- **Arguments:** Same as method channel
- **Events:** Emits `PermissionResponse` JSON when status changes

---

## HealthKit Permission Behavior

### Critical Privacy Limitation

**READ Permissions Are Opaque:**

HealthKit intentionally hides whether READ permissions were granted to protect user privacy. This prevents apps from inferring health conditions based on denied permissions.

**Implications:**
- `authorizationStatus()` returns `.sharingAuthorized` or `.notDetermined` for read permissions
- Status may show "authorized" but queries still fail
- Cannot distinguish between "never asked" and "explicitly denied" for reads
- Developers MUST handle query failures gracefully

**WRITE Permissions Are Transparent:**
- `authorizationStatus()` accurately reflects write permission status
- Can reliably check if write access granted

### One-Time Permission Prompt

- iOS shows permission dialog **only ONCE** per data type
- Subsequent `requestPermissions()` calls return immediately
- Users must manually enable in **Settings > Privacy & Security > Health**
- Apps should guide users to Settings when permissions denied

### Granular Permissions

- Each data type has independent permission
- Users can grant/deny individual types
- Must request authorization for each specific type needed

### Background Behavior

- Permission status can change while app in background
- User may modify in Settings app
- `listen()` stream detects changes on app resume

### Platform Availability

- HealthKit **NOT available on iPad**
- Must check `HKHealthStore.isHealthDataAvailable()` before use
- Return appropriate errors when unavailable

---

## Implementation Strategy

### Phase 1: Core Models & Types
1. Create `HealthDataType` enum with HealthKit identifier mapping
2. Create `PermissionStatus` enum
3. Create `PermissionResponse` model with JSON serialization
4. Add comprehensive documentation about privacy limitations

### Phase 2: iOS Native Layer
1. Create `PermissionManager.swift`
2. Implement `verifyPermissions()` using `authorizationStatus(for:)`
3. Implement `requestPermissions()` using `requestAuthorization(toShare:read:)`
4. Handle HealthKit availability check
5. Add error handling for invalid types

### Phase 3: Event Streaming
1. Create `PermissionStreamHandler.swift`
2. Register for `UIApplication.didBecomeActiveNotification`
3. Implement `onListen()` to start monitoring
4. Implement `onCancel()` for cleanup
5. Emit status updates on app resume

### Phase 4: Flutter Integration
1. Create `PermissionManager` Dart class
2. Set up `MethodChannel` for verify/request
3. Set up `EventChannel` for listen
4. Implement stream management with broadcast controller
5. Add proper disposal/cleanup methods

### Phase 5: Testing & Examples
1. Create unit tests with mocked channels
2. Create integration tests on iOS device
3. Build example permission screen
4. Demonstrate proper error handling
5. Show Settings deep-linking for denied permissions

---

## Testing Strategy

### Unit Tests (Dart)
- Mock `MethodChannel` responses
- Mock `EventChannel` stream
- Test verify returns correct status maps
- Test request completes without response
- Test stream emits on simulated events
- Test error handling
- Test stream disposal

### Integration Tests (iOS)
- Test on iOS 18+ physical device
- Request multiple permissions simultaneously
- Verify dialog shows correct types
- Test permission persistence across app restarts
- Test stream updates on app resume
- Test Settings app navigation
- Test iPad unavailability

### Edge Cases
- HealthKit unavailable (iPad)
- Invalid type strings
- Empty read/write arrays
- Only read OR only write permissions
- Mixed granted/denied permissions
- App killed during permission dialog
- Background permission changes

---

## Error Scenarios

| Scenario | Error Handling |
|----------|----------------|
| HealthKit unavailable (iPad) | Return error, don't crash |
| Invalid type identifier | Validate and throw descriptive error |
| Empty type arrays | Allow (no-op), or require at least one |
| Permission already determined | Request returns immediately (expected) |
| User denies all permissions | Return status, guide to Settings |
| App killed during dialog | iOS handles gracefully, recheck on resume |

---

## Usage Examples

### Example 1: Check Status Before Requesting
```dart
final permissionManager = PermissionManager();

// Check current status
final status = await permissionManager.verify(
  [HealthDataType.sleep, HealthDataType.hrv],
  [HealthDataType.workout],
);

if (status.readStatuses[HealthDataType.sleep] == PermissionStatus.notDetermined) {
  // Haven't asked yet, safe to request
  await permissionManager.request(
    [HealthDataType.sleep, HealthDataType.hrv],
    [HealthDataType.workout],
  );
}
```

### Example 2: Listen to Permission Changes
```dart
final subscription = permissionManager.listen(
  [HealthDataType.sleep, HealthDataType.hrv, HealthDataType.restingHeartRate],
  [HealthDataType.workout],
).listen((response) {
  print('Read statuses: ${response.readStatuses}');
  print('Write statuses: ${response.writeStatuses}');
});

// Later, clean up
await subscription.cancel();
```

### Example 3: Handle Denied Permissions
```dart
final status = await permissionManager.verify(readTypes, writeTypes);

final deniedTypes = status.readStatuses.entries
    .where((e) => e.value == PermissionStatus.denied)
    .map((e) => e.key)
    .toList();

if (deniedTypes.isNotEmpty) {
  // Show dialog explaining why permissions needed
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Permissions Required'),
      content: Text('Please enable health data access in Settings'),
      actions: [
        TextButton(
          onPressed: () => PermissionUtils.openAppSettings(),
          child: Text('Open Settings'),
        ),
      ],
    ),
  );
}
```

---

## Security & Privacy Considerations

### Info.plist Requirements

Must add privacy usage descriptions:

```xml
<key>NSHealthShareUsageDescription</key>
<string>We need access to read your health data to provide personalized insights.</string>

<key>NSHealthUpdateUsageDescription</key>
<string>We need access to save workout data to your Health app.</string>
```

### Data Minimization
- Only request permissions actually needed
- Request just-in-time, not at app startup
- Clearly explain why each permission needed

### User Transparency
- Show clear rationale before requesting
- Explain how data will be used
- Provide opt-out options where possible

### HealthKit Guidelines Compliance
- Cannot sell health data
- Cannot use for advertising without consent
- Must handle data securely
- Follow Apple's HealthKit review guidelines

---

## Open Questions & Decisions

### Decisions Made

1. **Fire-and-forget request()**: Aligns with HealthKit's async behavior, developers use verify/listen for status
2. **Broadcast stream**: Supports multiple listeners without additional state management
3. **Separate read/write arrays**: Matches HealthKit's permission model exactly
4. **Document privacy limitations**: Developers understand READ status unreliability
5. **Event-driven updates**: More efficient than polling, triggers on app resume

### Questions for Future Consideration

1. Should we provide convenience method for "all permissions" vs specifying individual types?
2. How to handle workout-specific permissions (e.g., workout routes require location)?
3. Should we cache permission status to avoid frequent native calls?
4. Provide helper to determine which permissions needed for specific features?
5. Support for background delivery and observer queries?

---

## References

- [Apple HealthKit Documentation](https://developer.apple.com/documentation/healthkit)
- [HKHealthStore Authorization](https://developer.apple.com/documentation/healthkit/hkhealthstore/1614152-requestauthorization)
- [Flutter Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
- [Flutter Event Channels](https://docs.flutter.dev/development/platform-integration/platform-channels#event-channels)

---

**Next Steps:**
1. Review and approve this design
2. Begin implementation Phase 1 (Core Models)
3. Set up iOS project with HealthKit capability
4. ✅ Permission UX reference: bundled [`example/`](../example/) — see [example/README.md](../example/README.md); extend as needed
