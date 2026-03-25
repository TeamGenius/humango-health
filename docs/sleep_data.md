# Sleep Data Subsystem

**Plugin:** `humango_health`  
**Document version:** 2.0  
**Date:** March 25, 2026 (aligned with **0.0.15+** delegate delivery)

---

## Overview

The sleep subsystem reads Apple HealthKit **`HKCategoryTypeIdentifier.sleepAnalysis`** and exposes it to Flutter via a **MethodChannel only** (`com.humango.health/sleep`).

| Capability | Mechanism |
|------------|-----------|
| One-shot fetch | `getSleepData` |
| Foreground monitoring | `HKAnchoredObjectQueryDescriptor` + on-device session accumulation |
| Background monitoring | `HKObserverQuery` + `enableBackgroundDelivery` |
| Lifecycle switching | Native **`AppLifecycleManager`** (no Dart `enterForeground` / `enterBackground` on sleep) |

**Finalized sleep sessions** (flat aggregated JSON) are delivered to the host app through **`HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:)`**. There is **no** `getLocalSleepSessions`, **no** `configureSleepBackgroundDelivery`, and **no** UserDefaults pending queue for sleep payloads in current builds.

The plugin does **not** POST sleep JSON to your API.

---

## Architecture

```
Flutter                           iOS
────────                          ───
SleepDataManager ──Method──────► SleepDataManager.swift
  getSleepData                      ├─ one-shot queries
  startMonitoring                   ├─ anchored + observer paths
  stopMonitoring                    ├─ calculateSleepPayload / grouping
  calculateSleepPayload             └─ on finalize → HumangoHealthDataDelegate

(no EventChannel for sleep payloads)
```

---

## Files

| Location | Role |
|----------|------|
| `lib/src/managers/sleep_data_manager.dart` | Dart API |
| `lib/src/models/sleep_sample.dart` | `SleepSample`, `SleepDataResponse`, totals |
| `ios/Classes/SleepData/SleepDataManager.swift` | Native orchestration |
| `ios/Classes/SleepData/SleepSessionDetector.swift` | Session boundary helper (if present in tree) |

Types are exported from `package:humango_health/humango_health.dart`.

---

## Sleep stages (iOS 16+)

| Value | Stage |
|-------|--------|
| 0 | `inBed` |
| 1 | `asleepUnspecified` |
| 2 | `awake` |
| 3 | `asleepCore` |
| 4 | `asleepDeep` |
| 5 | `asleepREM` |

`inBed` and `awake` are excluded from “total sleep” style aggregates in the flat payload (see README sleep JSON example).

---

## Dart API

### `getSleepData`

```dart
final sleep = SleepDataManager();
final response = await sleep.getSleepData(
  startDate: DateTime.now().subtract(const Duration(days: 1)),
  endDate: DateTime.now(),
);
```

### `startMonitoring` / `stopMonitoring`

```dart
await sleep.startMonitoring(
  startDate: DateTime.now().subtract(const Duration(hours: 24)),
);
await sleep.stopMonitoring();
```

While monitoring, finalized nights are reported on the **iOS delegate**, not to Dart.

### `calculateSleepPayload`

On-demand aggregation using the same group-based algorithm as the native pipeline (gap ≤ 2 h, discard groups with span < 3 h):

```dart
final payload = await sleep.calculateSleepPayload();
```

Throws `SleepDataException` when no qualifying session exists (`NO_VALID_SLEEP`, etc.).

---

## Background observer pipeline (native)

On `HKObserverQuery` delivery (when the user is logged in and sleep monitoring is active), the native manager typically:

1. Fetches samples for the configured window (e.g. 6 PM → now semantics — see `SleepDataManager.swift`).
2. Runs **`calculateSleepPayload`** (grouping + source handling).
3. Calls **`HumangoHealthDataDelegate.onSleepSessionReady`** once per finalized session when appropriate, with deduplication so unchanged sessions are not re-fired.

See **CHANGELOG 0.0.16** for simplifications (e.g. removal of in-bed/timer branches in favor of a straight pipeline).

---

## Aggregate JSON shape (delegate / docs)

Same flat keys as in [README — Sleep Session JSON Shape](../README.md#sleep-session-json-shape); stage durations are **integer seconds**.

---

## Integration checklist

1. Set **`HumangoHealthPlugin.delegate`** in your Runner and implement **`onSleepSessionReady`**.
2. After login, set **`UserAuthStateManager.shared.isLoggedIn`** and start monitoring via **`HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()`** (or call `startMonitoring` from Dart when the user enters the sleep feature).
3. Upload JSON from **`onSleepSessionReady`** (e.g. `URLSession` on a background queue).

---

## Related documentation

- [README.md](../README.md) — sleep section, delegate wiring  
- [SLEEP_DATA_SUBSYSTEM.md](../SLEEP_DATA_SUBSYSTEM.md) — subsystem summary  
- [CHANGELOG.md](../CHANGELOG.md) — removals in 0.0.15+  
