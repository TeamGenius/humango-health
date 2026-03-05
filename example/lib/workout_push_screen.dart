import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

class WorkoutPushScreen extends StatefulWidget {
  const WorkoutPushScreen({super.key});

  @override
  State<WorkoutPushScreen> createState() => _WorkoutPushScreenState();
}

class _WorkoutPushScreenState extends State<WorkoutPushScreen> {
  final WorkoutPushManager _pushManager = WorkoutPushManager();
  bool _isPushing = false;
  String _statusMessage = 'Press the button to push a mock workout.';

  Future<void> _pushMockWorkout() async {
    setState(() {
      _isPushing = true;
      _statusMessage = 'Parsing backend JSON and pushing to iOS...';
    });

    try {
      // 1. Raw Humango JSON payload
      const String mockHumangoJson = '''
[
  {
    "schedule_id": 3232443,
    "average_intensity": 73,
    "date": "2026-03-03T14:00:00+00:00",
    "blocks": [
      {
        "description": "Activation - leg swings, walking lunges...",
        "distance": 508,
        "duration": 300,
        "equipment_type": "",
        "measurement_unit": "second",
        "sport": "RUNNING",
        "target_range": { "high": 493, "low": 616 },
        "training_load": 3,
        "type": "WARMUP",
        "zone_target": { "zone": "RECOVERY" },
        "zone_unit": "PACE"
      },
      {
        "distance": 625,
        "duration": 300,
        "equipment_type": "",
        "measurement_unit": "second",
        "sport": "RUNNING",
        "target_range": { "high": 434, "low": 492 },
        "training_load": 4,
        "type": "WARMUP",
        "zone_target": { "zone": "ENDURANCE" },
        "zone_unit": "PACE"
      },
      {
        "blocks": [
          {
            "distance": 72,
            "duration": 30,
            "equipment_type": "",
            "measurement_unit": "second",
            "sport": "RUNNING",
            "target_range": { "high": 391, "low": 433 },
            "training_load": 0,
            "type": "INTERVAL",
            "zone_target": { "zone": "TEMPO" },
            "zone_unit": "PACE"
          },
          {
            "description": "walk or VERY easy run",
            "distance": 51,
            "duration": 30,
            "equipment_type": "",
            "measurement_unit": "second",
            "sport": "RUNNING",
            "target_range": { "high": 493, "low": 616 },
            "training_load": 0,
            "type": "RECOVERY",
            "zone_target": { "zone": "RECOVERY" },
            "zone_unit": "PACE"
          }
        ],
        "distance": 615,
        "duration": 300,
        "repeat": 5,
        "training_load": 4,
        "type": "REPEAT"
      },
      {
        "distance": 833,
        "duration": 600,
        "equipment_type": "",
        "measurement_unit": "second",
        "sport": "RUNNING",
        "target_range": { "high": 600, "low": 900 },
        "training_load": 3,
        "type": "COOLDOWN",
        "zone_target": { "range": { "focus_max_range": 60, "focus_min_range": 40 } },
        "zone_unit": "PACE"
      }
    ],
    "id": 16797,
    "sport": "RUNNING",
    "summary": {
      "name": "vinay vudatala running",
      "measurement_unit": "second",
      "sport": "RUNNING"
    }
  }
]
''';

      // 2. Decode and enforce valid forward-looking date
      final List<dynamic> decodedJson = jsonDecode(mockHumangoJson);
      final List<Map<String, dynamic>> rawList = decodedJson
          .cast<Map<String, dynamic>>()
          .toList();

      for (var map in rawList) {
        // Apple WorkoutKit REQUIRES the date to be strictly between now and 7 days.
        // Bumping the backend static date to +2 hours from invocation:
        final forwardDate = DateTime.now().add(const Duration(hours: 2));
        map['date'] = forwardDate.toUtc().toIso8601String();
      }

      // 3. Push Wait
      final response = await _pushManager.pushRawWorkouts(rawList);

      setState(() {
        if (response.results.isEmpty && response.failed > 0) {
          _statusMessage = '❌ Failed entirely. Check console.';
          return;
        }

        final result = response.results.first;
        if (result.status == WorkoutPushStatus.success) {
          _statusMessage =
              '✅ Success!\nWorkout ID: ${result.workoutId}\nPlan ID: ${result.record?.workoutPlanId}';
        } else if (result.status == WorkoutPushStatus.skipped) {
          _statusMessage = '⏭️ Skipped (Already Pushed natively)';
        } else {
          _statusMessage = '❌ Failed.\nError: ${result.errorMessage}';
        }
      });
    } catch (e) {
      setState(() {
        _statusMessage = '❌ Exception: $e';
      });
    } finally {
      setState(() {
        _isPushing = false;
      });
    }
  }

  Future<void> _clearCache() async {
    await _pushManager.clearDeduplicationCache();
    setState(() {
      _statusMessage = 'Local Deduplication Cache Cleared.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Push Workouts')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'WorkoutKit Scheduling',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'This module tests pushing `WorkoutPlan`s mapping to native Apple Health iOS 17 constraints. It includes automatic deduplication caching.',
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _isPushing ? null : _pushMockWorkout,
              icon: _isPushing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload),
              label: Text(_isPushing ? 'Pushing...' : 'Push Mock Interval Run'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _isPushing ? null : _clearCache,
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Clear Local Deduplication Cache'),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _statusMessage,
                style: const TextStyle(fontFamily: 'Courier', fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
