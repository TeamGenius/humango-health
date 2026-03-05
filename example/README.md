# humango_health_example

Demonstrates how to use the humango_health plugin.

## Features

This example app demonstrates:

### Permission Management
- Request and verify HealthKit permissions
- Handle permission denials with deep-link to Settings

### Workout Push (Tab 1)
- Schedule workouts to Apple Watch via WorkoutKit
- Request workout push authorization
- View scheduled workouts

### Activity Read (Tab 2)
- Read workout data from HealthKit
- Configure background delivery
- Monitor workouts in real-time

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
