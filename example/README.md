# humango_health_example

Demonstrates how to use the humango_health plugin.

## Features

This example app demonstrates:

### Integration pattern (client contract)

- **[`HealthSyncCoordinator`](lib/health_sync_coordinator.dart)** — Single place for `UserSessionManager` + idempotent `configureBackgroundDelivery` (workouts → local storage) and `configureSleepBackgroundDelivery` (sleep → logs API). Call **Set Logged In** on the Sleep tab to run the same flow a production app would run after auth.
- **Tabs** subscribe to library streams (`workoutStream`, permission stream, HRV) or one-shot APIs; they do **not** duplicate background configuration.
- **Other apps:** follow the plugin’s **[Client app integration guide](../docs/client_app_integration_guide.md)** (same pattern in your codebase); semantics: [`client_integration_contract.md`](../docs/client_integration_contract.md).

### Permission Management
- Request and verify HealthKit permissions
- Handle permission denials with deep-link to Settings

### Workout Push (Tab 1)
- Schedule workouts to Apple Watch via WorkoutKit
- Request workout push authorization
- View scheduled workouts

### Activity Read (Tab 2)
- One-shot fetch and live `workoutStream` monitoring (background config via coordinator)

### Sleep Data (Tab 3)
- Fetch sleep data from the last 24 hours
- View sleep stage breakdown (Deep, REM, Core, Awake, In Bed)
- Inspect raw JSON from each sleep sample
- View aggregated sleep statistics

## Getting Started

1. Run on a physical iOS device (HealthKit requires real hardware)
2. Grant HealthKit permissions when prompted
3. Navigate through the tabs to explore each feature

## Requirements

- iOS 14.0+ for sleep data
- iOS 16.0+ for detailed sleep stages (asleepCore, asleepDeep, asleepREM)
- iOS 17.0+ for WorkoutKit features
