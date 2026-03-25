# humango_health_example

Demonstrates how to use the humango_health plugin.

## Features

### Integration pattern (client contract)

- **[`HealthSyncCoordinator`](lib/health_sync_coordinator.dart)** — Calls **`ExampleSessionManager`** (Flutter → `com.humango.example/session`) so native code sets **`UserAuthStateManager`**, injects **`HumangoHealthPlugin.delegate`**, and runs **`startAllBackgroundMonitoring()`** on login; **`logout()`** on sign-out. This mirrors how a production app should gate health sync.
- **Tabs** use one-shot Dart APIs (`readWorkouts`, `getSleepData`, …) and Dart streams (`permissionStream`, `hrvUpdates`). They **do not** perform session setup on every screen.
- **Workout** completions and **sleep** sessions are uploaded from **`ExampleHealthDataHandler`** (Swift) via **`HumangoHealthDataDelegate`**, not from a Dart `workoutStream`.

**Docs:** [Client app integration guide](../docs/client_app_integration_guide.md), [client integration contract](../docs/client_integration_contract.md).

### Permission Management

- Request and verify HealthKit permissions
- Handle permission denials with deep-link to Settings

### Workout Push (Tab 1)

- Schedule workouts to Apple Watch via WorkoutKit
- Request workout push authorization
- View scheduled workouts

### Activity Read (Tab 2)

- One-shot `readWorkouts` / `fetchAllWorkouts`
- Start/stop **`WorkoutReadManager`** monitoring (completions → native delegate)

### Sleep Data (Tab 3)

- Fetch sleep data from HealthKit
- View sleep stage breakdown (Deep, REM, Core, Awake, In Bed)
- Start/stop sleep monitoring (finalized nights → native delegate)

### Health metrics (if present in app)

- Uses **`HealthMetricsManager`**; foreground **`hrvUpdates`**; background batches → delegate

## Getting Started

1. Run on a **physical** iOS device (HealthKit requires real hardware for most flows).
2. Grant HealthKit permissions when prompted.
3. Use **Set Logged In** on the Sleep tab (or equivalent) to arm native monitoring.

## Requirements

- iOS **18.0+** (example project deployment target)
- iOS **17.0+** for WorkoutKit scheduling features
- iOS **16.0+** for detailed sleep stages (asleepCore, asleepDeep, asleepREM)
