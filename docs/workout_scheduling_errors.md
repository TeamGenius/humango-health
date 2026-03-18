# Workout Scheduling — Error Reference

This document lists every error and failure state the `humango_health` library can produce during workout scheduling, organised by the layer in which it originates. Use this as a reference when handling responses in your implementation.

---

## 1. Dart Layer — `WorkoutPushManager.pushRawWorkouts()`

### 1.1 Hard throw — stops the entire batch

| Error Class | Message | Condition |
|---|---|---|
| `BatchSizeExceededError` | `"Cannot schedule more than 50 workouts at once."` | You call `WorkoutValidator.validateBatch()` with more than 50 workouts |

> **Note:** `pushRawWorkouts()` itself does **not** enforce a batch size limit — this error is only thrown if you use the lower-level `WorkoutValidator` directly.

---

### 1.2 Per-workout validation failures (Dart-side, before native is called)

Each workout is validated individually. Failures are collected into the response as `WorkoutPushStatus.validationError` and **do not stop** the rest of the batch.

| Condition | `errorMessage` value |
|---|---|
| `schedule_id` key is `null` | `"Missing required field: 'schedule_id'"` |
| `date` key is `null` | `"Missing required field: 'date'"` |
| `date` value is not a `String` | `"Invalid 'date' type: expected String, got <runtimeType>"` |
| `date` string cannot be parsed as ISO8601 | `"Invalid date format: '<value>'. Expected ISO8601 format."` |
| `blocks` key is `null` | `"Missing required field: 'blocks' (must be a non-empty array)"` |
| `blocks` value is not a `List` | `"Invalid 'blocks' type: expected List, got <runtimeType>"` |
| `blocks` is an empty list | `"'blocks' array cannot be empty"` |

**Result shape in `WorkoutPushResponse.results`:**
```dart
WorkoutPushResult(
  workoutId: '<schedule_id or N/A>',
  status: WorkoutPushStatus.validationError,
  errorMessage: '<all errors joined by ", ">',
  currentJson: <original workout map>,
)
```

---

### 1.3 Platform channel failures (Dart catch block, affects all valid workouts in batch)

If the native method channel call throws a `PlatformException` (or any exception), every workout that passed Dart validation is returned as `WorkoutPushStatus.failed`.

| Catch condition | `errorMessage` value |
|---|---|
| Any unhandled exception from `invokeMethod` | `e.toString()` — the native `PlatformException` message |
| iOS returns `null` or response map missing `scheduledRecords` | `"Missing detailed scheduled record array from iOS"` |

---

### 1.4 `WorkoutValidator` validation errors (if used directly)

These are returned as `ValidationResult.failure(errors)` per workout, not thrown:

| Error class | Condition | Message |
|---|---|---|
| `MissingWorkoutIdError` | `WorkoutPlan.id` is empty | `"WorkoutPlan must have a non-empty ID."` |
| `InvalidDateTimeError` | `scheduledDate` is more than 5 minutes in the past | `"Workout scheduledDate cannot be in the past."` |
| `InvalidDateTimeError` | `scheduledDate` is more than 7 days in the future | `"WorkoutKit only supports scheduling workouts within 7 days."` |
| `InvalidWorkoutStructureError` | `workout.toJson()` returns an empty map | `"Workout structure failed serialization checks."` |
| `InvalidWorkoutStructureError` | `CustomWorkout` has no blocks, no warmup, and no cooldown | `"CustomWorkout must have at least one step or block."` |
| `EmptyIntervalBlockError` | An `IntervalBlock` inside `CustomWorkout.blocks` has no steps | `"IntervalBlock cannot be empty. It must contain at least one step."` |

---

## 2. iOS / Native Layer — `WorkoutPlanManager`

### 2.1 `PlatformException` errors returned to Flutter

These are surfaced in Dart as a `PlatformException` with the matching `code`.

#### `scheduleWorkoutsFromFlutter`

| `code` | `message` | Condition |
|---|---|---|
| `INVALID_ARGS` | `"Expected array of workout dictionaries"` | Arguments passed to the channel are not `[[String: Any]]` |
| `UNSUPPORTED` | `"Workout scheduling requires iOS 17.4+"` | Device is running iOS 17.0–17.3 |
| `UNSUPPORTED` | `"WorkoutKit requires iOS 17.0+"` | Device is running below iOS 17.0 |
| `SCHEDULE_ERROR` | `error.localizedDescription` | Any unhandled Swift `throw` inside `scheduleWorkouts(...)` — see Section 2.2 |

#### `requestAuthorizationForWorkoutPush`

| `code` | `message` | Condition |
|---|---|---|
| `AUTH_ERROR` | `error.localizedDescription` | `WorkoutScheduler.requestAuthorization()` throws |
| `UNSUPPORTED` | `"WorkoutKit requires iOS 17.0+"` | Device is running below iOS 17.0 |

#### `getScheduledWorkouts`

| `code` | `message` | Condition |
|---|---|---|
| `UNSUPPORTED` | `"WorkoutKit requires iOS 17.0+"` | Device is running below iOS 17.0 |

#### `removeScheduledWorkouts`

| `code` | `message` | Condition |
|---|---|---|
| `INVALID_ARGS` | `"Expected a non-empty array of workoutPlanId strings"` | Arguments are not a non-empty `[String]` |
| `UNSUPPORTED` | `"WorkoutKit requires iOS 17.0+"` | Device is running below iOS 17.0 |

---

### 2.2 Internal `throw` inside `scheduleWorkouts()` → surfaced as `SCHEDULE_ERROR`

These Swift errors are caught by the outer `Task { do { ... } catch { result(FlutterError(code: "SCHEDULE_ERROR", ...)) } }` block.

| Trigger | Error domain / description |
|---|---|
| `WorkoutKit` authorization is `.denied` | `NSError(domain: "WorkoutKit", code: 0)` — `"WorkoutKit authorization was denied. Please go to Settings → Health → Data Access to permit Workout scheduling."` |
| `WorkoutPlanBuilder.createCustomWorkouts()` throws | `NSError(domain: "PlanManager", code: 2)` — `"Builder failed: <builder error description>"` |
| `JSONDecoder` fails to decode `[WorkoutInstanceModelElement]` | Swift `DecodingError` — message describes the malformed field |

---

### 2.3 Per-workout inline status values (not PlatformExceptions)

These are returned inside `WorkoutPushResponse.results` as regular result objects, not thrown errors.

| `status` value | Dart `WorkoutPushStatus` | Description |
|---|---|---|
| `"scheduled"` | `success` | Workout was successfully pushed to Apple Watch |
| `"skipped"` | `skipped` | Workout was skipped — see `reason` below |
| `"validation_error"` | `validationError` | Native-side validation failed — see `reason` field |
| `"device_not_supported"` | `failed` | `WorkoutScheduler.isSupported == false` on this device |

#### Possible `reason` values for `"skipped"` status

| `reason` | Meaning |
|---|---|
| `"date_outside_window"` | Workout date is in the past or more than 7 days from now |
| `"ios_unchanged"` | Deduplication: payload is identical to the already-scheduled version |
| Any other string | Returned verbatim from the native deduplication check |

#### Possible `reason` values for `"validation_error"` status (native-side)

| `reason` | Condition |
|---|---|
| `"Missing required field: 'schedule_id'"` | `schedule_id` key is absent in the JSON |
| `"Missing required field: 'date'"` | `date` key is absent |
| `"Invalid date format: '<value>'. Expected ISO8601 format."` | `date` cannot be parsed |
| `"Missing required field: 'blocks' (must be a non-empty array)"` | `blocks` key is absent |
| `"'blocks' array cannot be empty"` | `blocks` is present but empty |
| `"Internal error: no schedule_id after validation"` | Should never happen; indicates a logic bug |

---

## 3. `requestAuthorizationForWorkoutPush` — Dart result shape

This call never throws. On any native exception it returns a result object:

| `WorkoutPushAuthorizationStatus` | Condition |
|---|---|
| `notDetermined` | User has not yet been prompted |
| `authorized` | User granted permission |
| `denied` | User denied permission |
| `unknown` | Unexpected authorization state from WorkoutKit |
| `error` | Exception was caught — check `errorMessage` field |

---

## 4. How to handle in your implementation

```dart
final response = await WorkoutPushManager().pushRawWorkouts(workouts);

for (final result in response.results) {
  switch (result.status) {
    case WorkoutPushStatus.success:
      // Workout is on the watch, store result.workoutPlanId
      break;

    case WorkoutPushStatus.skipped:
      // Already up to date — check result.reason for detail
      break;

    case WorkoutPushStatus.validationError:
      // Bad input data — check result.errorMessage
      // Fix the payload before retrying
      break;

    case WorkoutPushStatus.failed:
      // Platform / device error — check result.errorMessage
      // Could be: UNSUPPORTED, SCHEDULE_ERROR, AUTH_ERROR, device_not_supported
      break;
  }
}
```

### Common `PlatformException` codes to catch explicitly

```dart
try {
  // ...
} on PlatformException catch (e) {
  switch (e.code) {
    case 'UNSUPPORTED':
      // iOS version too old — disable scheduling UI
      break;
    case 'AUTH_ERROR':
      // Authorization failed — prompt user to open Settings
      break;
    case 'SCHEDULE_ERROR':
      // WorkoutKit error — check e.message for specifics:
      //   "WorkoutKit authorization was denied..."
      //   "Builder failed: ..."
      break;
    case 'INVALID_ARGS':
      // Developer error — bad arguments passed to channel
      break;
  }
}
```
