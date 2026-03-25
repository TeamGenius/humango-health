# Sleep Data Subsystem — Requirements & Design

**Document version:** 4.0  
**Date:** March 25, 2026  
**Plugin:** `humango_health` (**0.0.17+**)

---

## Overview

Sleep analysis (`HKCategoryTypeIdentifier.sleepAnalysis`) is exposed through:

- **One-shot:** `getSleepData`
- **Monitoring:** `startSleepMonitoring` / `stopSleepMonitoring` (foreground anchored + background observer)
- **On-demand aggregation:** `calculateSleepPayload`

**Finalized session payloads** are delivered only through **`HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:)`** in the host iOS Runner.

Removed in **0.0.15**: local UserDefaults queue, `getLocalSleepSessions`, `configureSleepBackgroundDelivery`, `SleepBackgroundDeliveryManager`, Dart `enterForeground` / `enterBackground` for sleep, and related method-channel routes.

---

## Requirements (current)

| Requirement | Behavior |
|-------------|----------|
| Date range | `getSleepData` accepts optional `startDate` / `endDate`; defaults to last 24 h |
| Foreground | `HKAnchoredObjectQueryDescriptor` accumulates into session state — **no** per-sample EventChannel |
| Background | `HKObserverQuery` + `enableBackgroundDelivery`; same accumulation model |
| Lifecycle | **`AppLifecycleManager`** switches modes — no Flutter sleep lifecycle calls |
| Finalization | Native pipeline computes flat JSON → **delegate** |
| HTTP | **Never** from the plugin for session payloads |

---

## Dart API (`SleepDataManager`)

| Method | Returns |
|--------|---------|
| `getSleepData({startDate, endDate})` | `SleepDataResponse` |
| `startMonitoring({startDate})` | `Map` status from native |
| `stopMonitoring()` | void |
| `calculateSleepPayload({startDate, endDate})` | `Map<String, dynamic>` flat payload |

**Channel:** `com.humango.health/sleep` (MethodChannel only).

---

## Native methods (illustrative)

Handled in `SleepDataManager.swift`: `getSleepData`, `startSleepMonitoring`, `stopSleepMonitoring`, `calculateSleepPayload`. Legacy methods (`getLocalSleepSessions`, `configureSleepBackgroundDelivery`, …) are **not** registered.

---

## Architecture

```
Dart: SleepDataManager
  │
  ▼ MethodChannel  com.humango.health/sleep
  │
iOS: SleepDataManager.swift
  ├─ One-shot queries
  ├─ Anchored + observer monitoring
  ├─ Grouping / calculateSleepPayload
  └─ HumangoHealthDataDelegate.onSleepSessionReady
```

---

## Related documentation

- [docs/sleep_data.md](docs/sleep_data.md)  
- [README.md](README.md)  
- [CHANGELOG.md](CHANGELOG.md)  
