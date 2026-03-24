# Push Workouts Subsystem - Requirements & Design

**Document Version:** 1.0  
**Date:** February 24, 2026  
**Plugin:** `humango_health`  
**Subsystem:** Workout Pushing (WorkoutKit Integration)

---

## Requirements

### Functional Requirements

#### 1. Permission-Based Access Control

- **MUST** verify user has WRITE permission for workout data before pushing
- **MUST** cache permission status in library to avoid repeated native calls
- **MUST** return clear error if permission not granted
- Guide user to request permission if not available

#### 2. Dart Models Matching iOS WorkoutKit Classes

Create Dart equivalents for all WorkoutKit classes:

| iOS WorkoutKit Class | Dart Model | Purpose |
|---------------------|------------|---------|
| `WorkoutPlan` | `WorkoutPlan` | Container for scheduled workout |
| `CustomWorkout` | `CustomWorkout` | Multi-step custom workout structure |
| `SingleGoalWorkout` | `SingleGoalWorkout` | Simple single-goal workout (swimming) |
| `SwimBikeRunWorkout` | `SwimBikeRunWorkout` | Triathlon multi-sport workout |
| `WorkoutStep` | `WorkoutStep` | Individual workout step/segment |
| `IntervalBlock` | `IntervalBlock` | Repeating interval block |
| `IntervalStep` | `IntervalStep` | Step within interval block |
| `WorkoutGoal` | `WorkoutGoal` | Goal for step (distance, time, calories, etc.) |
| `WorkoutAlert` | `WorkoutAlert` | Alerts during workout execution |

#### 3. Workout Type Mapping

- **Swimming workouts** → `SingleGoalWorkout`
- **All other activities** (running, cycling, HIIT, strength, etc.) → `CustomWorkout`
- **Triathlon workouts** → `SwimBikeRunWorkout`

#### 4. Validation Rules

Before accepting workout for pushing:

1. **DateTime Validation:**
   - Must be within **next 7 days** from current date/time
   - Cannot be in the past
   - Must be valid ISO 8601 format

2. **Batch Size Limit:**
   - Maximum **50 workouts** per push operation
   - Return error if exceeds limit

3. **Workout ID Requirements:**
   - Every workout **MUST** have unique ID (String/UUID)
   - IDs must be consistent across push operations
   - Used for deduplication and tracking

4. **IntervalBlock Validation:**
   - If workout contains `IntervalBlock`, it **CANNOT be empty**
   - Must have at least 1 `IntervalStep`
   - Must have valid `iterations` count (≥ 1)
   - Empty interval blocks cause silent failures in WorkoutKit

5. **Workout Structure Validation:**
   - `CustomWorkout`: Must have at least 1 step
   - `SwimBikeRunWorkout`: Must have swim, bike, and run segments
   - Goals must have valid types and target values

#### 5. Push Workflow

**High-level flow:**

```
1. User calls pushWorkouts([workout1, workout2, ...])
2. Library validates permission (cached)
3. Library validates each workout (rules above)
4. For each workout:
   a. Check deduplication (ID, dateTime, JSON size)
   b. If needs push: add to batch
   c. If duplicate: skip
5. Serialize batch to JSON
6. Send via method channel to iOS
7. iOS processes each workout:
   a. Parse JSON → WorkoutKit classes
   b. Create WorkoutPlan with scheduled date
   c. Schedule workout → get hash value
   d. Store hash in UserDefaults (key: workoutId, value: hash)
8. iOS returns response with:
   - workoutId, hashValue, scheduledDateTime, jsonSize
9. Flutter library stores locally:
   - workoutId → {dateTime, hashValue, jsonSize}
10. Return success/failure response to user
```

#### 6. Deduplication Logic

Before pushing each workout, check local storage:

| Scenario | Action |
|----------|--------|
| ID not found | **PUSH** - new workout |
| ID found, same dateTime, same JSON size | **SKIP** - already pushed, no changes |
| ID found, different dateTime | **PUSH** - schedule changed |
| ID found, same dateTime, different size | **PUSH** - workout structure changed |

**JSON Size Calculation:**
- Calculate size in bytes of serialized JSON for each workout
- Used as fingerprint to detect changes without deep comparison
- Store size alongside hash and dateTime

#### 7. Local Persistence

**Storage Structure (Dart):**
```dart
// SharedPreferences or Hive storage
Map<String, WorkoutPushRecord> pushedWorkouts = {
  "workout_uuid_1": WorkoutPushRecord(
    workoutId: "workout_uuid_1",
    scheduledDateTime: "2026-02-27T18:00:00Z",
    hashValue: "1234567890",
    jsonSizeBytes: 2048,
    pushedAt: "2026-02-24T10:30:00Z",
  ),
  // ... more records
};
```

**Storage Structure (iOS UserDefaults):**
```swift
// Key: workout ID, Value: hash value
UserDefaults.standard.set("1234567890", forKey: "workout_uuid_1")
```

---

## Technical Design

### Architecture Overview

```
┌──────────────────────────────────────────────────┐
│           Flutter Application Layer              │
└────────────────┬─────────────────────────────────┘
                 │
┌────────────────┴─────────────────────────────────┐
│         Workout Push Manager (Dart)              │
│  ├─ Permission validation (cached)               │
│  ├─ Workout validation (rules)                   │
│  ├─ Deduplication check (local storage)          │
│  ├─ JSON serialization                           │
│  └─ Local persistence (SharedPreferences/Hive)   │
└────────────────┬─────────────────────────────────┘
                 │
            MethodChannel
         "com.humango.workouts/push"
                 │
┌────────────────┴─────────────────────────────────┐
│      iOS Native - WorkoutKit Integration         │
│  ├─ JSON parsing                                 │
│  ├─ WorkoutKit model construction                │
│  ├─ WorkoutPlan scheduling                       │
│  ├─ Hash value extraction                        │
│  └─ UserDefaults persistence                     │
└────────────────┬─────────────────────────────────┘
                 │
┌────────────────┴─────────────────────────────────┐
│          iOS WorkoutKit Framework                │
│  ├─ CustomWorkout                                │
│  ├─ SingleGoalWorkout                            │
│  ├─ SwimBikeRunWorkout                           │
│  └─ WorkoutPlan.schedule()                       │
└──────────────────────────────────────────────────┘
```

---

## Data Models

### 1. WorkoutPlan

```dart
class WorkoutPlan {
  final String id;
  final DateTime scheduledDate;
  final WorkoutBase workout; // Can be CustomWorkout, SingleGoalWorkout, or SwimBikeRunWorkout
  
  WorkoutPlan({
    required this.id,
    required this.scheduledDate,
    required this.workout,
  });
  
  Map<String, dynamic> toJson();
  factory WorkoutPlan.fromJson(Map<String, dynamic> json);
}
```

### 2. WorkoutBase (Abstract)

```dart
abstract class WorkoutBase {
  final WorkoutActivityType activityType;
  final WorkoutLocation location; // indoor/outdoor
  
  Map<String, dynamic> toJson();
}

enum WorkoutActivityType {
  running,
  cycling,
  swimming,
  walking,
  hiking,
  yoga,
  functionalStrengthTraining,
  traditionalStrengthTraining,
  coreTraining,
  flexibility,
  cooldown,
  // ... more types
}

enum WorkoutLocation {
  indoor,
  outdoor,
  unknown,
}
```

### 3. CustomWorkout

```dart
class CustomWorkout extends WorkoutBase {
  final List<WorkoutStep> steps;
  final String? displayName;
  
  CustomWorkout({
    required WorkoutActivityType activityType,
    required this.steps,
    required WorkoutLocation location,
    this.displayName,
  }) : super(activityType: activityType, location: location);
  
  // Validation
  bool isValid() {
    return steps.isNotEmpty && 
           steps.every((step) => step.isValid());
  }
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'custom',
      'activityType': activityType.name,
      'location': location.name,
      'displayName': displayName,
      'steps': steps.map((s) => s.toJson()).toList(),
    };
  }
}
```

### 4. SingleGoalWorkout (for Swimming)

```dart
class SingleGoalWorkout extends WorkoutBase {
  final WorkoutGoal goal;
  final String? displayName;
  
  SingleGoalWorkout({
    required WorkoutActivityType activityType,
    required this.goal,
    required WorkoutLocation location,
    this.displayName,
  }) : super(activityType: activityType, location: location);
  
  bool isValid() {
    return activityType == WorkoutActivityType.swimming && 
           goal.isValid();
  }
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'singleGoal',
      'activityType': activityType.name,
      'location': location.name,
      'displayName': displayName,
      'goal': goal.toJson(),
    };
  }
}
```

### 5. SwimBikeRunWorkout (Triathlon)

```dart
class SwimBikeRunWorkout extends WorkoutBase {
  final SingleGoalWorkout swim;
  final CustomWorkout bike;
  final CustomWorkout run;
  final String? displayName;
  
  SwimBikeRunWorkout({
    required this.swim,
    required this.bike,
    required this.run,
    this.displayName,
  }) : super(
    activityType: WorkoutActivityType.triathlon,
    location: WorkoutLocation.outdoor,
  );
  
  bool isValid() {
    return swim.activityType == WorkoutActivityType.swimming &&
           bike.activityType == WorkoutActivityType.cycling &&
           run.activityType == WorkoutActivityType.running &&
           swim.isValid() && bike.isValid() && run.isValid();
  }
  
  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'swimBikeRun',
      'displayName': displayName,
      'swim': swim.toJson(),
      'bike': bike.toJson(),
      'run': run.toJson(),
    };
  }
}
```

### 6. WorkoutStep

```dart
class WorkoutStep {
  final WorkoutGoal? goal;
  final WorkoutAlert? alert;
  final WorkoutStepType stepType; // work, recovery, warmup, cooldown
  
  WorkoutStep({
    this.goal,
    this.alert,
    required this.stepType,
  });
  
  bool isValid() {
    // Step must have at least a goal or be a valid type
    return goal?.isValid() ?? true;
  }
  
  Map<String, dynamic> toJson() {
    return {
      'stepType': stepType.name,
      'goal': goal?.toJson(),
      'alert': alert?.toJson(),
    };
  }
}

enum WorkoutStepType {
  work,
  recovery,
  warmup,
  cooldown,
}
```

### 7. IntervalBlock

```dart
class IntervalBlock {
  final List<IntervalStep> steps;
  final int iterations; // Number of times to repeat
  
  IntervalBlock({
    required this.steps,
    required this.iterations,
  });
  
  bool isValid() {
    return steps.isNotEmpty && 
           iterations >= 1 &&
           steps.every((step) => step.isValid());
  }
  
  Map<String, dynamic> toJson() {
    return {
      'steps': steps.map((s) => s.toJson()).toList(),
      'iterations': iterations,
    };
  }
}
```

### 8. IntervalStep

```dart
class IntervalStep extends WorkoutStep {
  IntervalStep({
    required WorkoutGoal goal,
    WorkoutAlert? alert,
    required WorkoutStepType stepType,
  }) : super(goal: goal, alert: alert, stepType: stepType);
  
  @override
  bool isValid() {
    // Interval steps MUST have a goal
    return goal != null && goal!.isValid();
  }
}
```

### 9. WorkoutGoal

```dart
class WorkoutGoal {
  final WorkoutGoalType type;
  final double targetValue;
  final WorkoutGoalUnit unit;
  
  WorkoutGoal({
    required this.type,
    required this.targetValue,
    required this.unit,
  });
  
  bool isValid() {
    return targetValue > 0 && _isUnitValidForType();
  }
  
  bool _isUnitValidForType() {
    // Validate unit matches type (e.g., distance must use meters/km)
    switch (type) {
      case WorkoutGoalType.distance:
        return unit == WorkoutGoalUnit.meters || 
               unit == WorkoutGoalUnit.kilometers ||
               unit == WorkoutGoalUnit.miles;
      case WorkoutGoalType.time:
        return unit == WorkoutGoalUnit.seconds || 
               unit == WorkoutGoalUnit.minutes;
      case WorkoutGoalType.energy:
        return unit == WorkoutGoalUnit.calories;
      default:
        return true;
    }
  }
  
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'targetValue': targetValue,
      'unit': unit.name,
    };
  }
}

enum WorkoutGoalType {
  distance,
  time,
  energy, // calories
  open, // no specific goal
}

enum WorkoutGoalUnit {
  meters,
  kilometers,
  miles,
  seconds,
  minutes,
  hours,
  calories,
  kilojoules,
}
```

### 10. WorkoutAlert

```dart
class WorkoutAlert {
  final WorkoutAlertType type;
  final double? targetValue; // For metric-based alerts
  final WorkoutAlertMetric? metric;
  
  WorkoutAlert({
    required this.type,
    this.targetValue,
    this.metric,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'targetValue': targetValue,
      'metric': metric?.name,
    };
  }
}

enum WorkoutAlertType {
  heartRate,
  pace,
  power,
  cadence,
  time,
  distance,
}

enum WorkoutAlertMetric {
  current,
  average,
  zone,
}
```

### 11. WorkoutPushRecord (Local Storage)

```dart
class WorkoutPushRecord {
  final String workoutId;
  final String scheduledDateTime; // ISO 8601
  final String hashValue; // From WorkoutKit
  final int jsonSizeBytes;
  final String pushedAt; // ISO 8601
  
  WorkoutPushRecord({
    required this.workoutId,
    required this.scheduledDateTime,
    required this.hashValue,
    required this.jsonSizeBytes,
    required this.pushedAt,
  });
  
  Map<String, dynamic> toJson();
  factory WorkoutPushRecord.fromJson(Map<String, dynamic> json);
}
```

### 12. WorkoutPushResponse

```dart
class WorkoutPushResponse {
  final List<WorkoutPushResult> results;
  final int totalSubmitted;
  final int successful;
  final int skipped;
  final int failed;
  
  WorkoutPushResponse({
    required this.results,
    required this.totalSubmitted,
    required this.successful,
    required this.skipped,
    required this.failed,
  });
}

class WorkoutPushResult {
  final String workoutId;
  final WorkoutPushStatus status;
  final String? hashValue;
  final String? errorMessage;
  final int? jsonSizeBytes;
  
  WorkoutPushResult({
    required this.workoutId,
    required this.status,
    this.hashValue,
    this.errorMessage,
    this.jsonSizeBytes,
  });
}

enum WorkoutPushStatus {
  success,      // Successfully pushed
  skipped,      // Already pushed (no changes)
  failed,       // Failed due to error
  validationError, // Failed validation
}
```

---

## Implementation Strategy

### Phase 1: Permission Caching System

**Objective:** Store and retrieve permission status to avoid repeated native calls

**Tasks:**
1. Create `PermissionCache` class with:
   - `Map<HealthDataType, PermissionStatus>` for read/write
   - `DateTime lastChecked` timestamp
   - TTL (time-to-live) configuration (default: 5 minutes)
2. Implement cache invalidation on:
   - Permission request completion
   - App resume from background
   - Manual refresh requested
3. Add `hasWorkoutWritePermission()` helper method
4. Store in memory (not persistent across app restarts)

**Files:**
- `lib/src/cache/permission_cache.dart`

### Phase 2: Dart Model Creation

**Objective:** Create all WorkoutKit equivalent Dart classes

**Tasks:**
1. Create base classes and enums:
   - `WorkoutBase` abstract class
   - `WorkoutActivityType` enum (30+ activity types)
   - `WorkoutLocation` enum
   - `WorkoutGoalType` and `WorkoutGoalUnit` enums
   - `WorkoutStepType` enum
2. Implement workout type classes:
   - `CustomWorkout` with steps array
   - `SingleGoalWorkout` with single goal
   - `SwimBikeRunWorkout` with three workout segments
3. Implement component classes:
   - `WorkoutStep` with goal, alert, type
   - `IntervalBlock` with steps and iterations
   - `IntervalStep` extending WorkoutStep
   - `WorkoutGoal` with type, value, unit
   - `WorkoutAlert` with type and metric
4. Implement `WorkoutPlan` container
5. Add JSON serialization/deserialization for all classes
6. Add `isValid()` method to all classes with validation logic

**Files:**
- `lib/src/models/workout_plan.dart`
- `lib/src/models/workouts/workout_base.dart`
- `lib/src/models/workouts/custom_workout.dart`
- `lib/src/models/workouts/single_goal_workout.dart`
- `lib/src/models/workouts/swim_bike_run_workout.dart`
- `lib/src/models/workout_components/workout_step.dart`
- `lib/src/models/workout_components/interval_block.dart`
- `lib/src/models/workout_components/interval_step.dart`
- `lib/src/models/workout_components/workout_goal.dart`
- `lib/src/models/workout_components/workout_alert.dart`
- `lib/src/models/enums/workout_enums.dart`

### Phase 3: Validation Engine

**Objective:** Implement all validation rules

**Tasks:**
1. Create `WorkoutValidator` class with methods:
   - `validateDateTime(DateTime scheduled)` - check 7-day window
   - `validateBatchSize(int count)` - max 50
   - `validateWorkoutId(String id)` - non-empty, valid format
   - `validateIntervalBlock(IntervalBlock block)` - non-empty steps
   - `validateWorkoutStructure(WorkoutBase workout)` - type-specific
2. Create `ValidationResult` class:
   - `bool isValid`
   - `List<ValidationError> errors`
3. Add validation error types:
   - `InvalidDateTimeError`
   - `BatchSizeExceededError`
   - `MissingWorkoutIdError`
   - `EmptyIntervalBlockError`
   - `InvalidWorkoutStructureError`

**Files:**
- `lib/src/validation/workout_validator.dart`
- `lib/src/validation/validation_result.dart`
- `lib/src/validation/validation_errors.dart`

### Phase 4: Deduplication System

**Objective:** Implement local storage and comparison logic

**Tasks:**
1. Create `WorkoutPushRecord` model (defined above)
2. Create `WorkoutStorage` class using SharedPreferences or Hive:
   - `saveRecord(WorkoutPushRecord record)`
   - `getRecord(String workoutId)`
   - `getAllRecords()`
   - `deleteRecord(String workoutId)`
   - `clearAll()`
3. Implement `WorkoutComparator` with:
   - `needsPush(WorkoutPlan plan, WorkoutPushRecord? existing)` → bool
   - `calculateJsonSize(Map<String, dynamic> json)` → int
4. Add comparison logic:
   - No existing record → PUSH
   - Same dateTime + same JSON size → SKIP
   - Different dateTime → PUSH
   - Different JSON size → PUSH

**Files:**
- `lib/src/storage/workout_storage.dart`
- `lib/src/storage/workout_push_record.dart`
- `lib/src/utils/workout_comparator.dart`

### Phase 5: Workout Push Manager (Dart)

**Objective:** Main API for pushing workouts

**Tasks:**
1. Create `WorkoutPushManager` class with:
   - `Future<WorkoutPushResponse> pushWorkouts(List<WorkoutPlan> workouts)`
2. Implement workflow:
   ```dart
   async pushWorkouts(List<WorkoutPlan> workouts) {
     // 1. Check permission
     if (!await _hasWritePermission()) {
       throw PermissionDeniedException();
     }
     
     // 2. Validate batch size
     if (workouts.length > 50) {
       throw BatchSizeExceededException();
     }
     
     // 3. Validate and filter workouts
     List<WorkoutPlan> toPush = [];
     List<WorkoutPushResult> results = [];
     
     for (var workout in workouts) {
       // Validate
       var validation = validator.validate(workout);
       if (!validation.isValid) {
         results.add(WorkoutPushResult.validationError());
         continue;
       }
       
       // Check deduplication
       var existing = await storage.getRecord(workout.id);
       var jsonMap = workout.toJson();
       var jsonSize = comparator.calculateJsonSize(jsonMap);
       
       if (comparator.needsPush(workout, existing, jsonSize)) {
         toPush.add(workout);
       } else {
         results.add(WorkoutPushResult.skipped());
       }
     }
     
     // 4. If nothing to push, return early
     if (toPush.isEmpty) {
       return WorkoutPushResponse(results: results, ...);
     }
     
     // 5. Serialize to JSON batch
     var jsonBatch = toPush.map((w) => w.toJson()).toList();
     
     // 6. Send via method channel
     var response = await methodChannel.invokeMethod(
       'pushWorkouts',
       {'workouts': jsonBatch},
     );
     
     // 7. Process response and save records
     for (var resultData in response['results']) {
       var record = WorkoutPushRecord.fromJson(resultData);
       await storage.saveRecord(record);
       results.add(WorkoutPushResult.success(record));
     }
     
     // 8. Return response
     return WorkoutPushResponse(results: results, ...);
   }
   ```

**Files:**
- `lib/src/managers/workout_push_manager.dart`
- `lib/src/models/workout_push_response.dart`

### Phase 6: iOS Native WorkoutKit Integration

**Objective:** Parse JSON, create WorkoutKit objects, schedule workouts

**Tasks:**
1. Create `WorkoutKitManager.swift` with:
   - `pushWorkouts(jsonBatch: [[String: Any]]) -> [[String: Any]]`
2. Implement JSON parsing for each workout type:
   - Parse `type` field to determine workout class
   - Create appropriate WorkoutKit object
3. Create helper methods:
   - `createCustomWorkout(json:) -> CustomWorkout`
   - `createSingleGoalWorkout(json:) -> SingleGoalWorkout`
   - `createSwimBikeRunWorkout(json:) -> SwimBikeRunWorkout`
   - `createWorkoutStep(json:) -> WorkoutStep`
   - `createIntervalBlock(json:) -> IntervalBlock`
   - `createWorkoutGoal(json:) -> WorkoutGoal`
   - `createWorkoutAlert(json:) -> WorkoutAlert?`
4. Schedule each workout:
   ```swift
   let workoutPlan = WorkoutPlan(
     workout: customWorkout,
     scheduledDate: scheduledDate
   )
   
   let scheduledWorkout = try await workoutPlan.schedule()
   let hashValue = scheduledWorkout.hashValue
   
   // Store in UserDefaults
   UserDefaults.standard.set(hashValue, forKey: workoutId)
   ```
5. Build response with:
   - workoutId
   - scheduledDateTime (ISO 8601)
   - hashValue (as String)
   - jsonSizeBytes
6. Handle errors:
   - Invalid JSON structure
   - WorkoutKit scheduling errors
   - Unsupported workout types

**Files:**
- `ios/Classes/WorkoutKitManager.swift`
- `ios/Classes/Extensions/WorkoutKit+JSON.swift`
- `ios/Classes/Utils/WorkoutKitValidator.swift`

### Phase 7: Method Channel Integration

**Objective:** Connect Dart and iOS layers

**Tasks:**
1. Register method channel in `HumangoWorkoutsPlugin.swift`:
   - Name: `"com.humango.workouts/push"`
   - Method: `"pushWorkouts"`
2. Handle method call:
   ```swift
   case "pushWorkouts":
     guard let workouts = call.arguments as? [[String: Any]] else {
       result(FlutterError(...))
       return
     }
     
     Task {
       do {
         let results = try await workoutKitManager.pushWorkouts(workouts)
         result(["results": results])
       } catch {
         result(FlutterError(...))
       }
     }
   ```
3. Handle errors and return appropriate FlutterError codes

**Files:**
- `ios/Classes/HumangoWorkoutsPlugin.swift` (update)

### Phase 8: Testing Infrastructure

**Objective:** Comprehensive testing for push workflow

**Unit Tests (Dart):**
1. Model serialization/deserialization tests
2. Validation rule tests:
   - DateTime within 7 days
   - Batch size limit
   - IntervalBlock non-empty
   - Workout structure validity
3. Deduplication logic tests:
   - New workout → push
   - Same ID + same date + same size → skip
   - Different date → push
   - Different size → push
4. JSON size calculation tests
5. Mock method channel tests

**Integration Tests (iOS):**
1. WorkoutKit object creation from JSON
2. Workout scheduling and hash extraction
3. UserDefaults storage/retrieval
4. Error handling for invalid workouts
5. Test on iOS 18+ device with WorkoutKit

**Files:**
- `test/models/workout_plan_test.dart`
- `test/validation/workout_validator_test.dart`
- `test/utils/workout_comparator_test.dart`
- `test/managers/workout_push_manager_test.dart`
- `ios/Tests/WorkoutKitManagerTests.swift`

### Phase 9: Host app integration

**Objective:** Exercise push workout flows in a real consumer app.

The bundled [`example/`](../example/) app includes a **Workout Push** tab (`example/lib/workout_push_screen.dart`); see [example/README.md](../example/README.md). For your own app, implement screens using [README.md](../README.md) (push workouts, validation outcomes) and [client_app_integration_guide.md](client_app_integration_guide.md) (coordinator pattern).

### Phase 10: Documentation

**Objective:** Comprehensive usage documentation

**Tasks:**
1. Update main README with push workflow
2. Add API documentation for all public classes
3. Create migration guide from HealthKit workouts
4. Document WorkoutKit limitations and gotchas
5. Add troubleshooting section

**Files:**
- `README.md` (update)
- `docs/API_REFERENCE.md`
- `docs/WORKOUT_MODELS.md`

---

## Validation Rules (Detailed)

### 1. DateTime Validation

```dart
ValidationResult validateDateTime(DateTime scheduled) {
  final now = DateTime.now();
  final maxDate = now.add(Duration(days: 7));
  
  if (scheduled.isBefore(now)) {
    return ValidationResult.error(
      'Scheduled time cannot be in the past'
    );
  }
  
  if (scheduled.isAfter(maxDate)) {
    return ValidationResult.error(
      'Scheduled time must be within next 7 days'
    );
  }
  
  return ValidationResult.success();
}
```

### 2. Batch Size Validation

```dart
ValidationResult validateBatchSize(int count) {
  if (count > 50) {
    return ValidationResult.error(
      'Cannot push more than 50 workouts at once. Current: $count'
    );
  }
  
  if (count == 0) {
    return ValidationResult.error(
      'Must provide at least 1 workout'
    );
  }
  
  return ValidationResult.success();
}
```

### 3. Workout ID Validation

```dart
ValidationResult validateWorkoutId(String? id) {
  if (id == null || id.isEmpty) {
    return ValidationResult.error(
      'Workout ID is required'
    );
  }
  
  // Optional: Validate UUID format
  if (!_isValidUuid(id)) {
    return ValidationResult.error(
      'Workout ID must be valid UUID format'
    );
  }
  
  return ValidationResult.success();
}
```

### 4. IntervalBlock Validation

```dart
ValidationResult validateIntervalBlock(IntervalBlock block) {
  if (block.steps.isEmpty) {
    return ValidationResult.error(
      'IntervalBlock cannot have empty steps array. '
      'This will cause silent failure in WorkoutKit.'
    );
  }
  
  if (block.iterations < 1) {
    return ValidationResult.error(
      'IntervalBlock iterations must be at least 1'
    );
  }
  
  // Validate each step
  for (var step in block.steps) {
    if (!step.isValid()) {
      return ValidationResult.error(
        'IntervalBlock contains invalid step'
      );
    }
  }
  
  return ValidationResult.success();
}
```

### 5. CustomWorkout Validation

```dart
ValidationResult validateCustomWorkout(CustomWorkout workout) {
  if (workout.steps.isEmpty) {
    return ValidationResult.error(
      'CustomWorkout must have at least 1 step'
    );
  }
  
  // Check for interval blocks
  for (var step in workout.steps) {
    if (step is IntervalBlock) {
      var result = validateIntervalBlock(step as IntervalBlock);
      if (!result.isValid) {
        return result;
      }
    }
  }
  
  return ValidationResult.success();
}
```

### 6. SwimBikeRunWorkout Validation

```dart
ValidationResult validateSwimBikeRunWorkout(SwimBikeRunWorkout workout) {
  if (workout.swim.activityType != WorkoutActivityType.swimming) {
    return ValidationResult.error(
      'Swim segment must have swimming activity type'
    );
  }
  
  if (workout.bike.activityType != WorkoutActivityType.cycling) {
    return ValidationResult.error(
      'Bike segment must have cycling activity type'
    );
  }
  
  if (workout.run.activityType != WorkoutActivityType.running) {
    return ValidationResult.error(
      'Run segment must have running activity type'
    );
  }
  
  // Validate each segment
  var swimValid = validateSingleGoalWorkout(workout.swim);
  if (!swimValid.isValid) return swimValid;
  
  var bikeValid = validateCustomWorkout(workout.bike);
  if (!bikeValid.isValid) return bikeValid;
  
  var runValid = validateCustomWorkout(workout.run);
  if (!runValid.isValid) return runValid;
  
  return ValidationResult.success();
}
```

---

## Deduplication Logic (Detailed)

### Comparison Algorithm

```dart
class WorkoutComparator {
  bool needsPush(
    WorkoutPlan newWorkout,
    WorkoutPushRecord? existingRecord,
    int newJsonSize,
  ) {
    // No existing record → definitely push
    if (existingRecord == null) {
      return true;
    }
    
    // Compare scheduled date
    final newDate = newWorkout.scheduledDate.toIso8601String();
    final existingDate = existingRecord.scheduledDateTime;
    
    if (newDate != existingDate) {
      // Schedule changed → push
      return true;
    }
    
    // Same date, compare JSON size
    if (newJsonSize != existingRecord.jsonSizeBytes) {
      // Workout structure changed → push
      return true;
    }
    
    // Everything matches → skip
    return false;
  }
  
  int calculateJsonSize(Map<String, dynamic> json) {
    // Convert to JSON string and calculate UTF-8 byte size
    final jsonString = jsonEncode(json);
    final bytes = utf8.encode(jsonString);
    return bytes.length;
  }
}
```

### Example Scenarios

**Scenario 1: First time pushing workout**
```dart
// No existing record
existingRecord = null
Result: PUSH ✓
```

**Scenario 2: Push same workout again (no changes)**
```dart
// Existing: 2026-02-27T18:00:00Z, 2048 bytes
// New:      2026-02-27T18:00:00Z, 2048 bytes
Result: SKIP (already pushed)
```

**Scenario 3: Changed schedule time**
```dart
// Existing: 2026-02-27T18:00:00Z, 2048 bytes
// New:      2026-02-27T19:00:00Z, 2048 bytes (same structure)
Result: PUSH ✓ (different time)
```

**Scenario 4: Modified workout structure**
```dart
// Existing: 2026-02-27T18:00:00Z, 2048 bytes
// New:      2026-02-27T18:00:00Z, 2156 bytes (added interval)
Result: PUSH ✓ (different size = different structure)
```

**Scenario 5: Same ID, different workout entirely**
```dart
// Existing: Running workout, 2026-02-27T18:00:00Z
// New:      Swimming workout, 2026-02-28T09:00:00Z
Result: PUSH ✓ (both date and structure different)
```

---

## iOS WorkoutKit Integration (Detailed)

### JSON to WorkoutKit Mapping

#### CustomWorkout Example

**JSON Input:**
```json
{
  "id": "workout_123",
  "scheduledDate": "2026-02-27T18:00:00Z",
  "workout": {
    "type": "custom",
    "activityType": "running",
    "location": "outdoor",
    "displayName": "Interval Run",
    "steps": [
      {
        "stepType": "warmup",
        "goal": {
          "type": "time",
          "targetValue": 600,
          "unit": "seconds"
        }
      },
      {
        "stepType": "work",
        "intervalBlock": {
          "iterations": 5,
          "steps": [
            {
              "stepType": "work",
              "goal": {
                "type": "distance",
                "targetValue": 400,
                "unit": "meters"
              }
            },
            {
              "stepType": "recovery",
              "goal": {
                "type": "time",
                "targetValue": 120,
                "unit": "seconds"
              }
            }
          ]
        }
      },
      {
        "stepType": "cooldown",
        "goal": {
          "type": "time",
          "targetValue": 300,
          "unit": "seconds"
        }
      }
    ]
  }
}
```

**Swift Code:**
```swift
func createCustomWorkout(json: [String: Any]) throws -> CustomWorkout {
    guard let activityTypeStr = json["activityType"] as? String,
          let activityType = mapActivityType(activityTypeStr),
          let locationStr = json["location"] as? String,
          let location = mapLocation(locationStr),
          let stepsJson = json["steps"] as? [[String: Any]] else {
        throw WorkoutError.invalidJSON
    }
    
    let steps = try stepsJson.map { try createWorkoutStep($0) }
    let displayName = json["displayName"] as? String
    
    return CustomWorkout(
        activity: activityType,
        location: location,
        displayName: displayName,
        warmup: nil, // Extract if present
        blocks: steps,
        cooldown: nil // Extract if present
    )
}

func createWorkoutStep(_ json: [String: Any]) throws -> WorkoutStep {
    guard let stepTypeStr = json["stepType"] as? String else {
        throw WorkoutError.invalidJSON
    }
    
    // Check for interval block
    if let intervalBlockJson = json["intervalBlock"] as? [String: Any] {
        return try createIntervalBlock(intervalBlockJson)
    }
    
    // Regular step
    let goal = try createWorkoutGoal(json["goal"] as? [String: Any])
    let alert = try? createWorkoutAlert(json["alert"] as? [String: Any])
    
    return WorkoutStep(goal: goal, alert: alert)
}

func createIntervalBlock(_ json: [String: Any]) throws -> IntervalBlock {
    guard let iterations = json["iterations"] as? Int,
          let stepsJson = json["steps"] as? [[String: Any]],
          !stepsJson.isEmpty else {
        throw WorkoutError.emptyIntervalBlock
    }
    
    let steps = try stepsJson.map { try createIntervalStep($0) }
    
    return IntervalBlock(steps: steps, iterations: iterations)
}

func createWorkoutGoal(_ json: [String: Any]?) throws -> WorkoutGoal {
    guard let json = json,
          let typeStr = json["type"] as? String,
          let targetValue = json["targetValue"] as? Double,
          let unitStr = json["unit"] as? String else {
        throw WorkoutError.invalidGoal
    }
    
    return try WorkoutGoal(
        type: mapGoalType(typeStr),
        target: targetValue,
        unit: mapUnit(unitStr)
    )
}
```

#### Scheduling Workout

```swift
func scheduleWorkout(
    workoutId: String,
    workout: any SchedulableWorkout,
    scheduledDate: Date
) async throws -> [String: Any] {
    // Create workout plan
    let plan = WorkoutPlan(
        workout: workout,
        scheduledDate: scheduledDate
    )
    
    // Schedule (requires iOS 18+)
    let scheduledWorkout = try await plan.schedule()
    
    // Get hash value
    let hashValue = String(scheduledWorkout.hashValue)
    
    // Store in UserDefaults
    UserDefaults.standard.set(hashValue, forKey: workoutId)
    UserDefaults.standard.synchronize()
    
    // Calculate JSON size (from original input)
    let jsonData = try JSONSerialization.data(
        withJSONObject: originalJson,
        options: []
    )
    let jsonSize = jsonData.count
    
    // Return result
    return [
        "workoutId": workoutId,
        "scheduledDateTime": ISO8601DateFormatter().string(from: scheduledDate),
        "hashValue": hashValue,
        "jsonSizeBytes": jsonSize,
    ]
}
```

---

## Error Handling

### Dart-Side Errors

| Error | When | User Action |
|-------|------|-------------|
| `PermissionDeniedException` | No write permission | Request permission first |
| `BatchSizeExceededException` | > 50 workouts | Split into multiple batches |
| `ValidationException` | Invalid workout data | Fix validation errors |
| `StorageException` | Local storage failure | Check device storage |
| `PlatformException` | Native error | Check iOS logs |

### iOS-Side Errors

| Error | When | Handling |
|-------|------|----------|
| `WorkoutError.invalidJSON` | Malformed JSON | Return error to Flutter |
| `WorkoutError.emptyIntervalBlock` | Empty interval steps | Return validation error |
| `WorkoutError.schedulingFailed` | WorkoutKit failure | Return with error message |
| `WorkoutError.unsupportedType` | Unknown workout type | Return error |

---

## Usage Examples

### Example 1: Push Simple Running Workout

```dart
final pushManager = WorkoutPushManager();

// Create workout
final runningWorkout = WorkoutPlan(
  id: 'run_workout_1',
  scheduledDate: DateTime.now().add(Duration(days: 1)),
  workout: CustomWorkout(
    activityType: WorkoutActivityType.running,
    location: WorkoutLocation.outdoor,
    displayName: 'Easy Run',
    steps: [
      WorkoutStep(
        stepType: WorkoutStepType.work,
        goal: WorkoutGoal(
          type: WorkoutGoalType.time,
          targetValue: 1800, // 30 minutes
          unit: WorkoutGoalUnit.seconds,
        ),
      ),
    ],
  ),
);

// Push
final response = await pushManager.pushWorkouts([runningWorkout]);
print('Success: ${response.successful}');
print('Skipped: ${response.skipped}');
print('Failed: ${response.failed}');
```

### Example 2: Push Interval Training

```dart
final intervalWorkout = WorkoutPlan(
  id: 'interval_1',
  scheduledDate: DateTime.now().add(Duration(days: 2)),
  workout: CustomWorkout(
    activityType: WorkoutActivityType.running,
    location: WorkoutLocation.outdoor,
    displayName: '5x400m Intervals',
    steps: [
      // Warmup
      WorkoutStep(
        stepType: WorkoutStepType.warmup,
        goal: WorkoutGoal(
          type: WorkoutGoalType.time,
          targetValue: 600,
          unit: WorkoutGoalUnit.seconds,
        ),
      ),
      // Intervals
      IntervalBlock(
        iterations: 5,
        steps: [
          IntervalStep(
            stepType: WorkoutStepType.work,
            goal: WorkoutGoal(
              type: WorkoutGoalType.distance,
              targetValue: 400,
              unit: WorkoutGoalUnit.meters,
            ),
          ),
          IntervalStep(
            stepType: WorkoutStepType.recovery,
            goal: WorkoutGoal(
              type: WorkoutGoalType.time,
              targetValue: 120,
              unit: WorkoutGoalUnit.seconds,
            ),
          ),
        ],
      ),
      // Cooldown
      WorkoutStep(
        stepType: WorkoutStepType.cooldown,
        goal: WorkoutGoal(
          type: WorkoutGoalType.time,
          targetValue: 300,
          unit: WorkoutGoalUnit.seconds,
        ),
      ),
    ],
  ),
);

final response = await pushManager.pushWorkouts([intervalWorkout]);
```

### Example 3: Push Swimming Workout

```dart
final swimWorkout = WorkoutPlan(
  id: 'swim_1',
  scheduledDate: DateTime.now().add(Duration(days: 3)),
  workout: SingleGoalWorkout(
    activityType: WorkoutActivityType.swimming,
    location: WorkoutLocation.indoor,
    displayName: '2km Swim',
    goal: WorkoutGoal(
      type: WorkoutGoalType.distance,
      targetValue: 2000,
      unit: WorkoutGoalUnit.meters,
    ),
  ),
);

final response = await pushManager.pushWorkouts([swimWorkout]);
```

### Example 4: Push Triathlon Workout

```dart
final triathlonWorkout = WorkoutPlan(
  id: 'triathlon_1',
  scheduledDate: DateTime.now().add(Duration(days: 5)),
  workout: SwimBikeRunWorkout(
    displayName: 'Sprint Triathlon Training',
    swim: SingleGoalWorkout(
      activityType: WorkoutActivityType.swimming,
      location: WorkoutLocation.outdoor,
      goal: WorkoutGoal(
        type: WorkoutGoalType.distance,
        targetValue: 750,
        unit: WorkoutGoalUnit.meters,
      ),
    ),
    bike: CustomWorkout(
      activityType: WorkoutActivityType.cycling,
      location: WorkoutLocation.outdoor,
      steps: [
        WorkoutStep(
          stepType: WorkoutStepType.work,
          goal: WorkoutGoal(
            type: WorkoutGoalType.distance,
            targetValue: 20,
            unit: WorkoutGoalUnit.kilometers,
          ),
        ),
      ],
    ),
    run: CustomWorkout(
      activityType: WorkoutActivityType.running,
      location: WorkoutLocation.outdoor,
      steps: [
        WorkoutStep(
          stepType: WorkoutStepType.work,
          goal: WorkoutGoal(
            type: WorkoutGoalType.distance,
            targetValue: 5,
            unit: WorkoutGoalUnit.kilometers,
          ),
        ),
      ],
    ),
  ),
);

final response = await pushManager.pushWorkouts([triathlonWorkout]);
```

### Example 5: Batch Push with Deduplication

```dart
final workouts = [
  runningWorkout,
  intervalWorkout,
  swimWorkout,
];

// First push
var response = await pushManager.pushWorkouts(workouts);
print('First push - Success: ${response.successful}'); // 3

// Push again without changes
response = await pushManager.pushWorkouts(workouts);
print('Second push - Skipped: ${response.skipped}'); // 3

// Modify one workout
workouts[0] = workouts[0].copyWith(
  scheduledDate: DateTime.now().add(Duration(days: 2)),
);

// Push again
response = await pushManager.pushWorkouts(workouts);
print('Third push - Success: ${response.successful}'); // 1
print('Third push - Skipped: ${response.skipped}'); // 2
```

---

## Testing Strategy

### Unit Tests

**Model Tests:**
```dart
test('CustomWorkout serialization', () {
  final workout = CustomWorkout(...);
  final json = workout.toJson();
  final restored = CustomWorkout.fromJson(json);
  
  expect(restored.activityType, workout.activityType);
  expect(restored.steps.length, workout.steps.length);
});

test('IntervalBlock validation fails when empty', () {
  final block = IntervalBlock(steps: [], iterations: 3);
  
  expect(block.isValid(), false);
});
```

**Validation Tests:**
```dart
test('DateTime validation rejects past dates', () {
  final past = DateTime.now().subtract(Duration(days: 1));
  final result = validator.validateDateTime(past);
  
  expect(result.isValid, false);
  expect(result.errors.first, isA<InvalidDateTimeError>());
});

test('DateTime validation rejects dates beyond 7 days', () {
  final future = DateTime.now().add(Duration(days: 8));
  final result = validator.validateDateTime(future);
  
  expect(result.isValid, false);
});

test('Batch size validation rejects > 50', () {
  final result = validator.validateBatchSize(51);
  
  expect(result.isValid, false);
});
```

**Deduplication Tests:**
```dart
test('needsPush returns true for new workout', () {
  final workout = createTestWorkout();
  final needs = comparator.needsPush(workout, null, 1024);
  
  expect(needs, true);
});

test('needsPush returns false for identical workout', () {
  final workout = createTestWorkout();
  final existing = WorkoutPushRecord(
    workoutId: workout.id,
    scheduledDateTime: workout.scheduledDate.toIso8601String(),
    jsonSizeBytes: 1024,
    hashValue: '123',
    pushedAt: DateTime.now().toIso8601String(),
  );
  
  final needs = comparator.needsPush(workout, existing, 1024);
  
  expect(needs, false);
});

test('needsPush returns true for changed schedule', () {
  final workout = createTestWorkout();
  final existing = WorkoutPushRecord(
    workoutId: workout.id,
    scheduledDateTime: '2026-02-25T10:00:00Z', // Different
    jsonSizeBytes: 1024,
    hashValue: '123',
    pushedAt: DateTime.now().toIso8601String(),
  );
  
  final needs = comparator.needsPush(workout, existing, 1024);
  
  expect(needs, true);
});
```

### Integration Tests

**iOS Tests:**
```swift
func testCustomWorkoutCreation() async throws {
    let json: [String: Any] = [
        "type": "custom",
        "activityType": "running",
        "location": "outdoor",
        "steps": [
            [
                "stepType": "work",
                "goal": [
                    "type": "time",
                    "targetValue": 1800,
                    "unit": "seconds"
                ]
            ]
        ]
    ]
    
    let workout = try manager.createCustomWorkout(json: json)
    
    XCTAssertEqual(workout.activity, .running)
    XCTAssertEqual(workout.blocks.count, 1)
}

func testWorkoutScheduling() async throws {
    let workout = createTestWorkout()
    let scheduledDate = Date().addingTimeInterval(86400)
    
    let result = try await manager.scheduleWorkout(
        workoutId: "test_1",
        workout: workout,
        scheduledDate: scheduledDate
    )
    
    XCTAssertNotNil(result["hashValue"])
    XCTAssertNotNil(result["jsonSizeBytes"])
    
    // Verify stored in UserDefaults
    let stored = UserDefaults.standard.string(forKey: "test_1")
    XCTAssertEqual(stored, result["hashValue"] as? String)
}
```

---

## Security & Privacy

### Info.plist Requirements

```xml
<key>NSHealthUpdateUsageDescription</key>
<string>We need to save workout plans to your Apple Workout app so you can train with guided workouts.</string>
```

### Data Storage

- **Dart:** Store workout metadata only (ID, dateTime, hash, size)
- **iOS:** Store hash values in UserDefaults (can be cleared)
- **No sensitive data:** Workout structure can be reconstructed from app

### User Control

- Users can delete scheduled workouts in Apple Workout app
- Library provides method to query/delete local records
- Clear separation between app data and HealthKit data

---

## WorkoutKit Limitations & Gotchas

1. **iOS 18+ Required:** WorkoutKit only available on iOS 18 and later
2. **7-Day Window:** Cannot schedule workouts beyond 7 days
3. **50 Workout Limit:** System limitation on scheduled workouts
4. **Empty Intervals Fail Silently:** Must validate non-empty interval blocks
5. **Hash Values Change:** If user modifies workout in Apple app, hash changes
6. **No Query API:** Cannot list scheduled workouts programmatically
7. **Activity Type Specific:** Some workout types don't support all features

---

## References

- [WorkoutKit Framework](https://developer.apple.com/documentation/WorkoutKit)
- [WorkoutPlan](https://developer.apple.com/documentation/WorkoutKit/WorkoutPlan)
- [CustomWorkout](https://developer.apple.com/documentation/workoutkit/customworkout)
- [SingleGoalWorkout](https://developer.apple.com/documentation/workoutkit/singlegoalworkout)
- [SwimBikeRunWorkout](https://developer.apple.com/documentation/workoutkit/swimbikerunworkout)

---

## Next Steps

1. Review and approve this design
2. Begin Phase 1: Permission caching
3. Begin Phase 2: Dart model creation
4. Set up iOS WorkoutKit capability in Xcode
