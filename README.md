# Humango Health Plugin

A Flutter plugin for integrating iOS HealthKit and WorkoutKit functionalities natively into the Humango platform. 

Currently, this plugin specifically supports the **Permission Handling Subsystem**.

## Requirements
- **iOS 18.0** minimum deployment target
- This plugin requires physical devices for testing HealthKit permission popups and reading/writing Health data.

### iOS Setup (Info.plist)
Any application using this plugin must declare the following keys in their `ios/Runner/Info.plist` file. Apple requires clear explanations for why your app needs to read and write Health data. Without these, your app will crash upon requesting permissions.

```xml
<key>NSHealthShareUsageDescription</key>
<string>We need access to read your health data to track your training metrics.</string>
<key>NSHealthUpdateUsageDescription</key>
<string>We need access to write your health data to save workouts and activities.</string>
```

---

## Permission Handling

iOS HealthKit requires specific capability definitions and uses a nuanced permissions model.
Permissions on iOS are split strictly between **Read** and **Write** (`Share`). 

### Apple's Strict Privacy Rules (Must Read)
When building systems dependent on HealthKit, you must understand two core iOS behaviors:

1. **The "One-Time Prompt" Rule**: iOS will only *ever* show the HealthKit permission popup **once** per device for a specific set of data types. If the user taps "Don't Allow," you **cannot** trigger the sheet again via code. Calling `request()` again simply returns success silently without showing the prompt.
2. **The "Blind Read" Rule**: Apple protects user privacy by making it impossible to check if a user explicitly denied `Read` access. A denied read permission simply appears as `notDetermined` or behaves as if there is no data. You can only deterministically check the status of `Write` (share) access.

**Handling Denials:** Because you cannot show the prompt twice, if you determine (via the write status) that a user is missing permissions, your app must show a custom Flutter UI explaining why access is needed, and provide a button to deep-link the user into the `iOS Settings -> Health -> Data Access & Devices` to toggle the switches manually.

### Supported Data Types
The `HealthDataType` enum maps Dart instances to correct `HKQuantityTypeIdentifier` strings natively.
Supported values currently include:
- `HealthDataType.workout`
- `HealthDataType.heartRate`
- `HealthDataType.hrv`
- `HealthDataType.restingHeartRate`
- `HealthDataType.steps`
- `HealthDataType.activeCalories`
- `HealthDataType.sleepAnalysis`
... and more.

### 1. Verification
You can manually check the current iOS authorization status.

```dart
import 'package:humango_health/humango_health.dart';

final permissionManager = PermissionManager();

void checkPermissions() async {
  final response = await permissionManager.verify(
    [HealthDataType.heartRate, HealthDataType.steps], // Read types 
    [HealthDataType.workout] // Write types
  );

  final writeStatus = response.writeStatuses[HealthDataType.workout];
  if (writeStatus == PermissionStatus.authorized) {
    print("Allowed to write workouts!");
  }
}
```

### 2. Requesting
Apple requires all permissions to be requested simultaneously on a unified permissions sheet. This is a fire-and-forget request returning `Future<void>`, as iOS displays the modal independently.

```dart
void requestPermissions() async {
  // Pass identical lists to verify()
  await permissionManager.request(
    [HealthDataType.heartRate, HealthDataType.steps],
    [HealthDataType.workout]
  );
  
  // Natively, iOS will surface the permissions dialog to the user here.
}
```

### 3. Listening (Continuous Monitoring)
Because users can leave your App, toggle permissions natively in the iOS Settings, and return, you should rely on the `listen()` stream. This ties natively into `UIApplication.didBecomeActiveNotification` ensuring your Dart logic automatically reacts when users background/foreground the app.

```dart
StreamSubscription? _sub;

void startListening() {
  _sub = permissionManager.listen(
    [HealthDataType.heartRate, HealthDataType.steps],
    [HealthDataType.workout]
  ).listen((PermissionResponse response) {
      // Rebuild UI, handle logic here according to returned status.
      print(response.readStatuses);
  });
}

void dispose() {
  _sub?.cancel();
}
```

See the `example/` app directory for a complete working demonstration on requesting, verifying, and streaming Permission actions. 
