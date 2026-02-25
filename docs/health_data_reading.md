# Read Health Data Subsystem - Requirements & Design

**Document Version:** 1.0  
**Date:** February 24, 2026  
**Plugin:** humango_workouts  
**Subsystem:** Health Data Reading & Monitoring

---

## Requirements

### Functional Requirements

#### 1. Permission Verification

- **MUST** verify user has READ permission for requested health data types
- **MUST** use cached permission status from Permission Manager
- **MUST** return clear error if permission not granted
- Guide user to request permission if not available

#### 2. Three Reading Methods

Provide three distinct methods for reading health data:

| Method | Description | Use Case |
|--------|-------------|----------|
| `readHealthData(types, startDate, endDate)` | One-shot fetch of historical data | Initial sync, historical analysis |
| `startMonitoring(types, startDate)` | Continuous monitoring for new data | Real-time tracking, live updates |
| `getLocalHealthData()` | Retrieve data stored locally from background | App startup, offline access |

All monitoring methods accept flexible health data types specified by the user.

#### 3. Dual-Mode Monitoring Strategy

**Foreground Mode (App Active):**
- Use `HKAnchoredObjectQueryDescriptor` with live streaming
- Push data immediately to Flutter via **Event Channel**
- Real-time updates without delay
- Separate streams per data type or combined stream

**Background Mode (App Suspended):**
- Use `HKObserverQuery` for system wake-ups
- Use `enableBackgroundDelivery()` for each monitored type
- Store samples in UserDefaults as JSON
- NO API calls - only local storage
- Retrieve on app resume

#### 4. Supported Health Data Types

Must support (at minimum):
- **Sleep:** HKCategoryTypeIdentifierSleepAnalysis
- **HRV:** HKQuantityTypeIdentifierHeartRateVariabilitySDNN
- **Resting Heart Rate:** HKQuantityTypeIdentifierRestingHeartRate
- **Heart Rate:** HKQuantityTypeIdentifierHeartRate
- **Steps:** HKQuantityTypeIdentifierStepCount
- **Active Calories:** HKQuantityTypeIdentifierActiveEnergyBurned
- **Body Mass:** HKQuantityTypeIdentifierBodyMass
- **VO2 Max:** HKQuantityTypeIdentifierVO2Max
- **Respiratory Rate:** HKQuantityTypeIdentifierRespiratoryRate
- **Oxygen Saturation:** HKQuantityTypeIdentifierOxygenSaturation

**Extensible:** User can specify any valid HealthKit type identifier dynamically.

#### 5. Data Structure

Each health data sample includes:
- **Type:** Health data type identifier
- **Value:** Numeric value (for quantity types) or category value (for category types)
- **Unit:** Unit of measurement (e.g., "count/min", "ms", "count")
- **Start Date:** Sample start timestamp
- **End Date:** Sample end timestamp
- **Source:** Device/app that recorded the sample
- **Metadata:** Additional key-value pairs

#### 6. Local Storage Only

- **NO API calls** for health data
- Background delivery stores samples in UserDefaults
- Retrieve on app resume via `getLocalHealthData()`
- Clear from storage after retrieval
- Limit storage to prevent UserDefaults bloat (e.g., max 1000 samples)

---

## Technical Design

### Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                Flutter Application Layer                 │
└─────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│          Health Data Read Manager (Dart)                 │
│  ├─ readHealthData(types, startDate, endDate)            │
│  ├─ startMonitoring(types, startDate)                    │
│  ├─ stopMonitoring()                                     │
│  ├─ getLocalHealthData()                                 │
│  └─ Stream<HealthDataSample> healthDataStream            │
└─────────────────────┬────────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          │                       │
    MethodChannel           EventChannel
  "com.humango.workouts/health"  "com.humango.workouts/health/stream"
          │                       │
          └───────────┬───────────┘
┌─────────────────────┴────────────────────────────────────┐
│           iOS Native - Health Data Monitoring            │
│  ┌─ HealthDataService (main orchestrator)                │
│  │   ├─ Foreground: HKAnchoredObjectQueryDescriptor      │
│  │   ├─ Background: HKObserverQuery + background delivery│
│  │   ├─ Type registry (monitors multiple types)          │
│  │   └─ Mode switching (foreground/background)           │
│  │                                                        │
│  ┌─ HealthDataStore (local storage)                      │
│  │   ├─ UserDefaults persistence                         │
│  │   ├─ JSON serialization                               │
│  │   ├─ Storage limit enforcement (max 1000 samples)     │
│  │   └─ Retrieval and clear logic                        │
│  │                                                        │
│  └─ HealthDataFetcher (one-shot queries)                 │
│      ├─ Date range bounded fetches                       │
│      ├─ Multi-type support                               │
│      └─ JSON serialization                               │
└──────────────────────────────────────────────────────────┘
                      │
┌─────────────────────┴────────────────────────────────────┐
│                HealthKit Framework (iOS)                 │
│  ├─ HKAnchoredObjectQueryDescriptor (foreground)         │
│  ├─ HKObserverQuery (background)                         │
│  ├─ HKQuantityType (numeric measurements)                │
│  ├─ HKCategoryType (sleep, etc.)                         │
│  └─ enableBackgroundDelivery() / disableBackgroundDelivery() │
└──────────────────────────────────────────────────────────┘
```

---

## Data Models

### 1. HealthDataSample (Dart)

```dart
class HealthDataSample {
  final String type;              // e.g., "heartRateVariabilitySDNN"
  final HealthDataValue value;    // Quantity or category value
  final DateTime startDate;
  final DateTime endDate;
  final String? sourceApp;        // App that recorded the sample
  final String? sourceDevice;     // Device that recorded the sample
  final Map<String, dynamic>? metadata;
  
  HealthDataSample({
    required this.type,
    required this.value,
    required this.startDate,
    required this.endDate,
    this.sourceApp,
    this.sourceDevice,
    this.metadata,
  });
  
  factory HealthDataSample.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}

// Union type for quantity vs category values
class HealthDataValue {
  final double? numericValue;     // For quantity types
  final String? unit;             // For quantity types (e.g., "ms", "count")
  final int? categoryValue;       // For category types (e.g., sleep stage)
  
  bool get isQuantity => numericValue != null;
  bool get isCategory => categoryValue != null;
  
  HealthDataValue.quantity({
    required this.numericValue,
    required this.unit,
  }) : categoryValue = null;
  
  HealthDataValue.category({
    required this.categoryValue,
  }) : numericValue = null,
       unit = null;
  
  factory HealthDataValue.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}
```

### 2. HealthDataType (Dart)

```dart
/// Enum representing supported HealthKit data types
/// Maps to HealthKit identifiers on iOS
enum HealthDataType {
  // Cardiovascular
  heartRate,                    // HKQuantityTypeIdentifierHeartRate
  hrv,                          // HKQuantityTypeIdentifierHeartRateVariabilitySDNN
  restingHeartRate,             // HKQuantityTypeIdentifierRestingHeartRate
  
  // Sleep
  sleepAnalysis,                // HKCategoryTypeIdentifierSleepAnalysis
  
  // Activity
  steps,                        // HKQuantityTypeIdentifierStepCount
  activeCalories,               // HKQuantityTypeIdentifierActiveEnergyBurned
  
  // Body
  bodyMass,                     // HKQuantityTypeIdentifierBodyMass
  height,                       // HKQuantityTypeIdentifierHeight
  bodyFatPercentage,            // HKQuantityTypeIdentifierBodyFatPercentage
  
  // Fitness
  vo2Max,                       // HKQuantityTypeIdentifierVO2Max
  
  // Respiratory
  respiratoryRate,              // HKQuantityTypeIdentifierRespiratoryRate
  oxygenSaturation,             // HKQuantityTypeIdentifierOxygenSaturation
}

extension HealthDataTypeExtension on HealthDataType {
  /// Returns HealthKit identifier string
  String get identifier {
    switch (this) {
      case HealthDataType.heartRate:
        return 'HKQuantityTypeIdentifierHeartRate';
      case HealthDataType.hrv:
        return 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN';
      case HealthDataType.restingHeartRate:
        return 'HKQuantityTypeIdentifierRestingHeartRate';
      case HealthDataType.sleepAnalysis:
        return 'HKCategoryTypeIdentifierSleepAnalysis';
      case HealthDataType.steps:
        return 'HKQuantityTypeIdentifierStepCount';
      case HealthDataType.activeCalories:
        return 'HKQuantityTypeIdentifierActiveEnergyBurned';
      case HealthDataType.bodyMass:
        return 'HKQuantityTypeIdentifierBodyMass';
      case HealthDataType.height:
        return 'HKQuantityTypeIdentifierHeight';
      case HealthDataType.bodyFatPercentage:
        return 'HKQuantityTypeIdentifierBodyFatPercentage';
      case HealthDataType.vo2Max:
        return 'HKQuantityTypeIdentifierVO2Max';
      case HealthDataType.respiratoryRate:
        return 'HKQuantityTypeIdentifierRespiratoryRate';
      case HealthDataType.oxygenSaturation:
        return 'HKQuantityTypeIdentifierOxygenSaturation';
    }
  }
}
```

### 3. HealthDataReadOptions (Dart)

```dart
class HealthDataReadOptions {
  final List<HealthDataType> types;
  final DateTime startDate;
  final DateTime endDate;
  final int? limit;               // Max samples to return
  
  HealthDataReadOptions({
    required this.types,
    required this.startDate,
    required this.endDate,
    this.limit,
  });
  
  Map<String, dynamic> toJson() => {
    'types': types.map((t) => t.identifier).toList(),
    'startDate': startDate.toIso8601String(),
    'endDate': endDate.toIso8601String(),
    'limit': limit,
  };
}
```

### 4. HKSampleData (Swift)

```swift
struct HKSampleData: Codable {
    let type: String                // HealthKit identifier
    let value: SampleValue
    let startDate: String           // ISO8601
    let endDate: String             // ISO8601
    let sourceApp: String?
    let sourceDevice: String?
    let metadata: [String: Any]?
    
    enum SampleValue: Codable {
        case quantity(value: Double, unit: String)
        case category(value: Int)
    }
    
    func toJson() -> Data?
}
```

---

## Implementation Strategy

### Phase 1: Dart API Design

**Objective:** Create Flutter-side health data reading API

**Tasks:**
1. Create `HealthDataManager` class:
   ```dart
   class HealthDataManager {
     /// One-shot fetch of historical health data
     Future<List<HealthDataSample>> readHealthData(
       List<HealthDataType> types,
       DateTime startDate,
       DateTime endDate,
       {int? limit}
     );
     
     /// Start continuous monitoring (foreground + background)
     Future<void> startMonitoring(
       List<HealthDataType> types,
       {DateTime? startDate}  // Defaults to now
     );
     
     /// Stop monitoring
     Future<void> stopMonitoring();
     
     /// Get locally stored samples (from background)
     Future<List<HealthDataSample>> getLocalHealthData();
     
     /// Stream for real-time health data updates
     Stream<HealthDataSample> get healthDataStream;
   }
   ```

2. Create all Dart model classes:
   - `HealthDataSample`
   - `HealthDataValue`
   - `HealthDataType` enum
   - `HealthDataReadOptions`

3. Add JSON serialization/deserialization

4. Set up `MethodChannel` for commands:
   - `readHealthData`
   - `startMonitoring`
   - `stopMonitoring`
   - `getLocalHealthData`

5. Set up `EventChannel` for health data stream

**Files:**
- `lib/src/managers/health_data_manager.dart`
- `lib/src/models/health_data_sample.dart`
- `lib/src/models/health_data_type.dart`
- `lib/src/models/health_data_value.dart`

### Phase 2: iOS HealthDataService

**Objective:** Create iOS service for health data monitoring

**Tasks:**
1. Create `HealthDataService.swift`:
   ```swift
   class HealthDataService {
       private let healthStore = HKHealthStore()
       private var queries: [String: HKAnchoredObjectQuery] = [:]
       private var observers: [String: HKObserverQuery] = [:]
       private var eventSink: FlutterEventSink?
       private var monitoredTypes: Set<HKSampleType> = []
       private var isBackground = false
       
       func startMonitoring(types: [HKSampleType], startDate: Date?) async {
           // Check authorization
           // Start foreground queries with HKAnchoredObjectQueryDescriptor
           // Enable background delivery
       }
       
       func stopMonitoring() async {
           // Stop all queries
           // Disable background delivery
           // Clear observers
       }
       
       func enterForegroundMode() {
           isBackground = false
           // Start live queries
       }
       
       func enterBackgroundMode() {
           isBackground = true
           // Stop live queries, keep observers
       }
       
       private func handleSample(_ sample: HKSample, type: HKSampleType) async {
           if isBackground {
               // Store locally
               await HealthDataStore.shared.storeSample(sample, type: type)
           } else if let sink = eventSink {
               // Push to event channel
               let json = convertSampleToJson(sample, type: type)
               sink(json)
           }
       }
   }
   ```

2. Implement query setup:
   - Use `HKAnchoredObjectQueryDescriptor` for foreground
   - Use `HKObserverQuery` for background
   - Handle both `HKQuantityType` and `HKCategoryType`

3. Implement mode switching logic

**Files:**
- `ios/Classes/HealthDataService.swift`

### Phase 3: iOS HealthDataStore

**Objective:** Local storage for background samples

**Tasks:**
1. Create `HealthDataStore.swift`:
   ```swift
   actor HealthDataStore {
       static let shared = HealthDataStore()
       
       private let storageKey = "HealthDataSamples.pending"
       private let maxSamples = 1000
       
       func storeSample(_ sample: HKSample, type: HKSampleType) async {
           guard let json = convertToJson(sample, type: type) else { return }
           
           var existing = getSamples()
           existing.append(json)
           
           // Enforce limit
           if existing.count > maxSamples {
               existing = Array(existing.suffix(maxSamples))
           }
           
           UserDefaults.standard.set(existing, forKey: storageKey)
           UserDefaults.standard.synchronize()
       }
       
       func retrieveAndClearSamples() async -> [String] {
           let samples = getSamples()
           UserDefaults.standard.removeObject(forKey: storageKey)
           UserDefaults.standard.synchronize()
           return samples
       }
       
       private func getSamples() -> [String] {
           UserDefaults.standard.stringArray(forKey: storageKey) ?? []
       }
       
       private func convertToJson(_ sample: HKSample, type: HKSampleType) -> String? {
           // Convert HKQuantitySample or HKCategorySample to JSON
       }
   }
   ```

**Files:**
- `ios/Classes/HealthDataStore.swift`

### Phase 4: iOS HealthDataFetcher

**Objective:** One-shot historical fetches

**Tasks:**
1. Create `HealthDataFetcher.swift`:
   ```swift
   class HealthDataFetcher {
       static let shared = HealthDataFetcher()
       private let healthStore = HKHealthStore()
       
       func fetchHealthData(
           types: [HKSampleType],
           startDate: Date,
           endDate: Date,
           limit: Int?
       ) async throws -> [String] {
           var allSamples: [String] = []
           
           for type in types {
               let predicate = HKQuery.predicateForSamples(
                   withStart: startDate,
                   end: endDate,
                   options: .strictStartDate
               )
               
               let descriptor = HKSampleQueryDescriptor(
                   predicates: [.sample(type: type, predicate: predicate)],
                   sortDescriptors: [
                       SortDescriptor(\.startDate, order: .reverse)
                   ],
                   limit: limit
               )
               
               let samples = try await descriptor.result(for: healthStore)
               
               for sample in samples {
                   if let json = convertToJson(sample, type: type) {
                       allSamples.append(json)
                   }
               }
           }
           
           return allSamples
       }
       
       private func convertToJson(_ sample: HKSample, type: HKSampleType) -> String? {
           // Handle HKQuantitySample
           if let quantitySample = sample as? HKQuantitySample {
               return convertQuantitySample(quantitySample, type: type)
           }
           
           // Handle HKCategorySample
           if let categorySample = sample as? HKCategorySample {
               return convertCategorySample(categorySample, type: type)
           }
           
           return nil
       }
   }
   ```

**Files:**
- `ios/Classes/HealthDataFetcher.swift`

### Phase 5: Method Channel Integration

**Objective:** Wire up Flutter ↔ iOS communication

**Tasks:**
1. Create `HealthDataServiceChannel.swift`:
   ```swift
   class HealthDataServiceChannel: NSObject, FlutterStreamHandler {
       private var healthService: HealthDataService?
       private var eventSink: FlutterEventSink?
       
       func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
           switch call.method {
           case "readHealthData":
               handleReadHealthData(call, result)
           case "startMonitoring":
               handleStartMonitoring(call, result)
           case "stopMonitoring":
               handleStopMonitoring(result)
           case "getLocalHealthData":
               handleGetLocalHealthData(result)
           case "enterForeground":
               healthService?.enterForegroundMode()
               result(nil)
           case "enterBackground":
               healthService?.enterBackgroundMode()
               result(nil)
           default:
               result(FlutterMethodNotImplemented)
           }
       }
       
       // FlutterStreamHandler
       func onListen(
           withArguments arguments: Any?,
           eventSink events: @escaping FlutterEventSink
       ) -> FlutterError? {
           self.eventSink = events
           healthService?.setEventSink(events)
           return nil
       }
       
       func onCancel(withArguments arguments: Any?) -> FlutterError? {
           self.eventSink = nil
           healthService?.setEventSink(nil)
           return nil
       }
   }
   ```

2. Register channels in plugin:
   ```swift
   public static func register(with registrar: FlutterPluginRegistrar) {
       let methodChannel = FlutterMethodChannel(
           name: "com.humango.workouts/health",
           binaryMessenger: registrar.messenger()
       )
       
       let eventChannel = FlutterEventChannel(
           name: "com.humango.workouts/health/stream",
           binaryMessenger: registrar.messenger()
       )
       
       let instance = HealthDataServiceChannel()
       registrar.addMethodCallDelegate(instance, channel: methodChannel)
       eventChannel.setStreamHandler(instance)
   }
   ```

**Files:**
- `ios/Classes/HealthDataServiceChannel.swift`
- `ios/Classes/HumangoWorkoutsPlugin.swift` (modify)

### Phase 6: App Lifecycle Integration

**Objective:** Handle foreground/background transitions

**Tasks:**
1. In Flutter, listen to app lifecycle:
   ```dart
   class HealthDataMonitoringApp extends StatefulWidget {
     @override
     _HealthDataMonitoringAppState createState() => 
         _HealthDataMonitoringAppState();
   }
   
   class _HealthDataMonitoringAppState extends State<HealthDataMonitoringApp> 
       with WidgetsBindingObserver {
     
     final healthManager = HealthDataManager();
     
     @override
     void initState() {
       super.initState();
       WidgetsBinding.instance.addObserver(this);
     }
     
     @override
     void dispose() {
       WidgetsBinding.instance.removeObserver(this);
       super.dispose();
     }
     
     @override
     void didChangeAppLifecycleState(AppLifecycleState state) {
       if (state == AppLifecycleState.paused) {
         healthManager.enterBackgroundMode();
       } else if (state == AppLifecycleState.resumed) {
         healthManager.enterForegroundMode();
         _fetchLocalHealthData();
       }
     }
     
     Future<void> _fetchLocalHealthData() async {
       final localSamples = await healthManager.getLocalHealthData();
       if (localSamples.isNotEmpty) {
         print('Retrieved ${localSamples.length} samples from background');
       }
     }
   }
   ```

2. Add lifecycle methods to HealthDataManager:
   ```dart
   Future<void> enterForegroundMode() async {
     await _methodChannel.invokeMethod('enterForeground');
   }
   
   Future<void> enterBackgroundMode() async {
     await _methodChannel.invokeMethod('enterBackground');
   }
   ```

**Files:**
- `lib/src/managers/health_data_manager.dart` (add lifecycle methods)
- `example/lib/main.dart` (demonstrate lifecycle handling)

### Phase 7: Type Conversion Utilities

**Objective:** Convert between HealthKit types and JSON

**Tasks:**
1. Create helper methods in iOS:
   ```swift
   extension HKSampleType {
       static func fromIdentifier(_ identifier: String) -> HKSampleType? {
           // Quantity types
           if identifier.hasPrefix("HKQuantityTypeIdentifier") {
               return HKQuantityType.quantityType(
                   forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
               )
           }
           
           // Category types
           if identifier.hasPrefix("HKCategoryTypeIdentifier") {
               return HKCategoryType.categoryType(
                   forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)
               )
           }
           
           return nil
       }
   }
   
   func convertQuantitySample(
       _ sample: HKQuantitySample,
       type: HKSampleType
   ) -> String? {
       let unit = preferredUnit(for: sample.quantityType)
       let value = sample.quantity.doubleValue(for: unit)
       
       let dict: [String: Any] = [
           "type": type.identifier,
           "value": [
               "numericValue": value,
               "unit": unit.unitString
           ],
           "startDate": ISO8601DateFormatter().string(from: sample.startDate),
           "endDate": ISO8601DateFormatter().string(from: sample.endDate),
           "sourceApp": sample.sourceRevision.source.bundleIdentifier,
           "sourceDevice": sample.device?.name,
           "metadata": sample.metadata
       ]
       
       return try? JSONSerialization.data(withJSONObject: dict)
           .base64EncodedString()
   }
   
   func preferredUnit(for quantityType: HKQuantityType) -> HKUnit {
       switch quantityType.identifier {
       case HKQuantityTypeIdentifierHeartRate:
           return HKUnit.count().unitDivided(by: .minute())
       case HKQuantityTypeIdentifierHeartRateVariabilitySDNN:
           return HKUnit.secondUnit(with: .milli)
       case HKQuantityTypeIdentifierStepCount:
           return HKUnit.count()
       case HKQuantityTypeIdentifierActiveEnergyBurned:
           return HKUnit.kilocalorie()
       case HKQuantityTypeIdentifierBodyMass:
           return HKUnit.gramUnit(with: .kilo)
       // ... more types
       default:
           return HKUnit.count()
       }
   }
   ```

**Files:**
- `ios/Classes/Extensions/HKSampleTypeExtensions.swift`
- `ios/Classes/Utils/HealthKitConverter.swift`

### Phase 8: Testing Infrastructure

**Objective:** Comprehensive testing

**Unit Tests (Dart):**
1. Mock method channel responses
2. Test date range validation
3. Test JSON deserialization
4. Test stream subscription/cancellation
5. Test type conversion

**Integration Tests (iOS):**
1. Test HealthDataService foreground/background switching
2. Test HealthDataStore local storage
3. Test HealthDataFetcher with date ranges
4. Test app lifecycle transitions
5. Test on iOS 18+ device with real health data

**Files:**
- `test/managers/health_data_manager_test.dart`
- `test/models/health_data_sample_test.dart`
- `ios/Tests/HealthDataServiceTests.swift`
- `ios/Tests/HealthDataStoreTests.swift`

### Phase 9: Example Implementation

**Objective:** Demonstrate complete health data workflow

**Tasks:**
1. Create example screen showing:
   - Permission request for multiple types
   - "Read Health Data" button (one-shot)
   - "Start Monitoring" button (continuous)
   - "Stop Monitoring" button
   - Real-time sample list (from stream)
   - Local samples display (from background)
   - Type selector (sleep, HRV, heart rate, etc.)

2. Show all three reading patterns:
   - Historical fetch with date range
   - Real-time monitoring in foreground
   - Background storage retrieval

**Files:**
- `example/lib/health_data_screen.dart`
- `example/lib/widgets/health_sample_list_item.dart`
- `example/lib/widgets/type_selector_dialog.dart`

### Phase 10: Documentation

**Objective:** Comprehensive usage documentation

**Tasks:**
1. Update main README with health data workflow
2. Document all three reading methods
3. Explain foreground vs background behavior
4. Document supported data types
5. Show usage examples
6. Add troubleshooting section

**Files:**
- `README.md` (update)
- `docs/API_REFERENCE.md` (update)
- `docs/HEALTH_DATA_MONITORING.md` (new)

---

## Detailed Workflows

### Workflow 1: One-Shot Historical Fetch

**User Action:** Fetch sleep data from last 7 days

```dart
final manager = HealthDataManager();

final samples = await manager.readHealthData(
  [HealthDataType.sleepAnalysis],
  DateTime.now().subtract(Duration(days: 7)),
  DateTime.now(),
);

for (var sample in samples) {
  print('Sleep: ${sample.startDate} - ${sample.endDate}');
  print('Type: ${sample.value.categoryValue}'); // Sleep stage
}
```

**iOS Flow:**
1. Method channel receives `readHealthData` call
2. `HealthDataFetcher.shared.fetchHealthData()` called
3. Creates `HKSampleQueryDescriptor` for sleep analysis
4. Fetches samples within date range
5. Converts each `HKCategorySample` to JSON
6. Returns array of JSON strings to Flutter
7. Dart deserializes to `List<HealthDataSample>`

### Workflow 2: Real-Time Monitoring (Foreground)

**User Action:** Monitor HRV and resting heart rate in real-time

```dart
final manager = HealthDataManager();

// Start monitoring
await manager.startMonitoring([
  HealthDataType.hrv,
  HealthDataType.restingHeartRate,
]);

// Listen to stream
final subscription = manager.healthDataStream.listen((sample) {
  print('New sample: ${sample.type}');
  
  if (sample.type == HealthDataType.hrv.identifier) {
    print('HRV: ${sample.value.numericValue} ${sample.value.unit}');
  } else if (sample.type == HealthDataType.restingHeartRate.identifier) {
    print('RHR: ${sample.value.numericValue} ${sample.value.unit}');
  }
  
  // Update UI in real-time
  setState(() {
    _samples.add(sample);
  });
});

// Later: stop monitoring
await manager.stopMonitoring();
await subscription.cancel();
```

**iOS Flow:**
1. Method channel receives `startMonitoring` call
2. `HealthDataService.startMonitoring()` called with types
3. For each type:
   - Creates `HKAnchoredObjectQueryDescriptor`
   - Sets up initial query + updates handler
   - Enables background delivery
4. When new sample arrives:
   - Check if app is foreground
   - Convert sample to JSON
   - Push to event channel → Flutter stream
5. Flutter receives sample in real-time

### Workflow 3: Background Monitoring

**User Action:** App goes to background, samples continue to be captured

```dart
// App lifecycle observer handles this automatically
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused) {
    // Flutter calls enterBackgroundMode()
    healthManager.enterBackgroundMode();
  } else if (state == AppLifecycleState.resumed) {
    // Flutter calls enterForegroundMode()
    healthManager.enterForegroundMode();
    
    // Retrieve samples captured in background
    _fetchLocalHealthData();
  }
}
```

**iOS Flow:**
1. App lifecycle state changes to background
2. Flutter calls `enterBackgroundMode()`
3. `HealthDataService.enterBackgroundMode()`:
   - Stops live update queries
   - Keeps `HKObserverQuery` active
   - Background delivery already enabled
4. New health data recorded (e.g., sleep session completes)
5. System wakes app via background delivery
6. `HKObserverQuery` fires
7. `HealthDataService` fetches new samples
8. `HealthDataStore.storeSample()` saves to UserDefaults
9. App returns to background

**On App Resume:**
```dart
Future<void> _fetchLocalHealthData() async {
  final localSamples = await healthManager.getLocalHealthData();
  
  print('Retrieved ${localSamples.length} samples from background');
  
  for (var sample in localSamples) {
    print('Background sample: ${sample.type} at ${sample.startDate}');
    // Process and display...
  }
}
```

### Workflow 4: Multi-Type Monitoring

**User Action:** Monitor multiple types simultaneously

```dart
await manager.startMonitoring([
  HealthDataType.heartRate,
  HealthDataType.steps,
  HealthDataType.activeCalories,
  HealthDataType.sleepAnalysis,
]);

manager.healthDataStream.listen((sample) {
  // Single stream receives all types
  switch (sample.type) {
    case 'HKQuantityTypeIdentifierHeartRate':
      _updateHeartRate(sample);
      break;
    case 'HKQuantityTypeIdentifierStepCount':
      _updateSteps(sample);
      break;
    case 'HKQuantityTypeIdentifierActiveEnergyBurned':
      _updateCalories(sample);
      break;
    case 'HKCategoryTypeIdentifierSleepAnalysis':
      _updateSleep(sample);
      break;
  }
});
```

---

## Storage Considerations

### UserDefaults Storage Limit

**Problem:** UserDefaults is not designed for large data sets.

**Solution:** Enforce limits
```swift
private let maxSamples = 1000

func storeSample(_ sample: HKSample, type: HKSampleType) async {
    var existing = getSamples()
    existing.append(json)
    
    // Keep only most recent 1000 samples
    if existing.count > maxSamples {
        existing = Array(existing.suffix(maxSamples))
    }
    
    UserDefaults.standard.set(existing, forKey: storageKey)
}
```

**Best Practices:**
- Clear local storage frequently (on every app open)
- Warn users if monitoring in background for extended periods
- Consider batching retrieval if needed

### Alternative Storage (Future Enhancement)

For apps requiring more robust storage:
- SQLite database
- Core Data
- File-based storage (JSON files)

---

## Performance Considerations

### Battery Impact

**Foreground:**
- Live queries using `HKAnchoredObjectQueryDescriptor`
- Moderate battery usage (app is active anyway)

**Background:**
- `HKObserverQuery` + background delivery
- System-optimized, minimal battery impact
- iOS throttles excessive wake-ups

### Memory Management

**HealthDataService:**
- Keep only active queries in memory
- Stop queries when monitoring stops
- Clean up observers on mode switching

**HealthDataStore:**
- Limit to 1000 samples max
- Clear on retrieval
- Periodic cleanup if needed

### Network Considerations

**NO network calls:**
- All data stays local
- No API overhead
- Privacy-friendly approach

---

## Error Handling

### Dart-Side Errors

| Error | When | User Action |
|-------|------|-------------|
| `PermissionDeniedException` | No read permission | Request health data permission |
| `InvalidDateRangeException` | Start date after end date | Fix date range |
| `MonitoringAlreadyActiveException` | startMonitoring() called twice | Stop existing monitoring first |
| `UnsupportedTypeException` | Invalid health data type | Use supported type |
| `PlatformException` | Native iOS error | Check logs, retry |

### iOS-Side Errors

| Error | When | Handling |
|-------|------|----------|
| `authorizationFailed` | HealthKit permission denied | Return error to Flutter |
| `queryFailed` | HKQuery error | Log error, return empty array |
| `backgroundDeliveryFailed` | Background delivery setup failed | Fall back to foreground only |
| `storageExceeded` | UserDefaults limit reached | Enforce max samples limit |

---

## Security & Privacy

### Info.plist Requirements

```xml
<key>NSHealthShareUsageDescription</key>
<string>We need to read your health data to provide personalized health insights.</string>
```

### Data Privacy

- **NO API calls:** Data never leaves device via plugin
- **Local storage only:** UserDefaults cleared on retrieval
- **User control:** Users choose which types to monitor
- **HealthKit protection:** Read permissions remain opaque

### Background Delivery Permissions

Must request background modes in Xcode:
- Capabilities → Background Modes
- Enable "Background fetch"

---

## Usage Examples

### Example 1: Fetch Last Week of Sleep

```dart
final samples = await healthManager.readHealthData(
  [HealthDataType.sleepAnalysis],
  DateTime.now().subtract(Duration(days: 7)),
  DateTime.now(),
);

for (var sample in samples) {
  final sleepStage = sample.value.categoryValue;
  final duration = sample.endDate.difference(sample.startDate);
  
  print('Sleep stage $sleepStage for ${duration.inMinutes} minutes');
}
```

### Example 2: Monitor HRV in Real-Time

```dart
await healthManager.startMonitoring([HealthDataType.hrv]);

healthManager.healthDataStream.listen((sample) {
  if (sample.value.isQuantity) {
    final hrv = sample.value.numericValue!;
    final unit = sample.value.unit!;
    
    print('HRV: $hrv $unit');
    
    // Show notification if HRV is low
    if (hrv < 20) {
      _showLowHRVAlert();
    }
  }
});
```

### Example 3: Retrieve Background Samples on App Launch

```dart
@override
void initState() {
  super.initState();
  _loadBackgroundSamples();
}

Future<void> _loadBackgroundSamples() async {
  final samples = await healthManager.getLocalHealthData();
  
  if (samples.isEmpty) {
    print('No background samples');
    return;
  }
  
  print('Processing ${samples.length} background samples');
  
  for (var sample in samples) {
    _processSample(sample);
  }
  
  setState(() {
    _backgroundSamples = samples;
  });
}
```

### Example 4: Multi-Type Dashboard

```dart
class HealthDashboard extends StatefulWidget {
  @override
  _HealthDashboardState createState() => _HealthDashboardState();
}

class _HealthDashboardState extends State<HealthDashboard> 
    with WidgetsBindingObserver {
  
  final healthManager = HealthDataManager();
  
  double? _latestHRV;
  int? _dailySteps;
  double? _activeCalories;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startMonitoring();
  }
  
  Future<void> _startMonitoring() async {
    await healthManager.startMonitoring([
      HealthDataType.hrv,
      HealthDataType.steps,
      HealthDataType.activeCalories,
    ]);
    
    healthManager.healthDataStream.listen((sample) {
      setState(() {
        switch (sample.type) {
          case 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN':
            _latestHRV = sample.value.numericValue;
            break;
          case 'HKQuantityTypeIdentifierStepCount':
            _dailySteps = sample.value.numericValue?.toInt();
            break;
          case 'HKQuantityTypeIdentifierActiveEnergyBurned':
            _activeCalories = sample.value.numericValue;
            break;
        }
      });
    });
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      healthManager.enterBackgroundMode();
    } else if (state == AppLifecycleState.resumed) {
      healthManager.enterForegroundMode();
      _fetchBackgroundSamples();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Health Dashboard')),
      body: Column(
        children: [
          HealthMetricCard(
            title: 'HRV',
            value: _latestHRV,
            unit: 'ms',
          ),
          HealthMetricCard(
            title: 'Steps',
            value: _dailySteps,
            unit: 'steps',
          ),
          HealthMetricCard(
            title: 'Active Calories',
            value: _activeCalories,
            unit: 'kcal',
          ),
        ],
      ),
    );
  }
}
```

---

## Limitations

1. **iOS 18+ Required:** `HKAnchoredObjectQueryDescriptor` requires iOS 18+
2. **UserDefaults Limit:** Max 1000 samples in background storage
3. **Background Throttling:** iOS may throttle background wake-ups
4. **No API Push:** Health data stays local (by design)
5. **Read-Only:** No writing/saving health data (outside of workouts)

---

## Future Enhancements

1. **Aggregated Queries:** Daily/weekly/monthly summaries
2. **Statistics:** Min/max/average calculations on iOS side
3. **Correlation Queries:** Combine multiple types (e.g., sleep + HRV)
4. **SQLite Storage:** Replace UserDefaults for larger data sets
5. **Export to CSV/JSON:** Download health data locally
6. **Charts/Visualizations:** Built-in plotting widgets

---

## References

### Apple Documentation
- [HKAnchoredObjectQueryDescriptor](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquerydescriptor)
- [HKObserverQuery](https://developer.apple.com/documentation/healthkit/hkobserverquery)
- [HKQuantityType](https://developer.apple.com/documentation/healthkit/hkquantitytype)
- [HKCategoryType](https://developer.apple.com/documentation/healthkit/hkcategorytype)
- [Background Delivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/1614175-enablebackgrounddelivery)

### Flutter Documentation
- [Platform Channels](https://docs.flutter.dev/development/platform-integration/platform-channels)
- [Event Channels](https://docs.flutter.dev/development/platform-integration/platform-channels#event-channels)
- [App Lifecycle](https://docs.flutter.dev/get-started/fundamentals/app-lifecycle)

---

## Next Steps

1. ✅ Review and approve this design
2. Begin Phase 1: Dart API design and models
3. Begin Phase 2: iOS HealthDataService implementation
4. Set up method and event channels
5. Test foreground/background mode switching
6. Test local storage with multiple data types
7. Create comprehensive example app

**This completes the planning for all four subsystems:**
1. ✅ Permission Management
2. ✅ Push Workouts (WorkoutKit)
3. ✅ Read Workouts (HealthKit monitoring)
4. ✅ Read Health Data (HealthKit monitoring)

**Ready to begin implementation!**
