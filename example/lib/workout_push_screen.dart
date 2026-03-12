import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

// ---------------------------------------------------------------------------
// Scenario descriptor
// ---------------------------------------------------------------------------
class _Scenario {
  final String label;
  final IconData icon;
  final Color color;
  final List<Map<String, dynamic>> workouts;

  const _Scenario({
    required this.label,
    required this.icon,
    required this.color,
    required this.workouts,
  });
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class WorkoutPushScreen extends StatefulWidget {
  const WorkoutPushScreen({super.key});

  @override
  State<WorkoutPushScreen> createState() => _WorkoutPushScreenState();
}

class _WorkoutPushScreenState extends State<WorkoutPushScreen> {
  final WorkoutPushManager _pushManager = WorkoutPushManager();
  final TextEditingController _jsonController = TextEditingController();

  bool _isPushing = false;
  WorkoutPushResponse? _lastResponse;
  String? _errorMessage;
  String? _activeScenarioLabel;

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  // ── Scenario definitions ──────────────────────────────────────────────────

  List<_Scenario> get _scenarios => [
    _Scenario(
      label: 'Mock Interval Run',
      icon: Icons.directions_run,
      color: Colors.blue,
      workouts: [
        {
          'schedule_id': 'mock-interval-run-001',
          'sport': 'RUNNING',
          'summary': {
            'name': 'Mock Interval Run',
            'sport': 'RUNNING',
            'measurement_unit': 'second',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 508.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 616, 'high': 493},
            },
            {
              'type': 'REPEAT',
              'repeat': 5,
              'duration': 300,
              'distance': 615.0,
              'blocks': [
                {
                  'type': 'INTERVAL',
                  'duration': 30,
                  'distance': 72.0,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 433, 'high': 391},
                },
                {
                  'type': 'RECOVERY',
                  'duration': 30,
                  'distance': 51.0,
                  'measurement_unit': 'second',
                  'sport': 'RUNNING',
                  'zone_unit': 'PACE',
                  'target_range': {'low': 616, 'high': 493},
                },
              ],
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 833.0,
              'measurement_unit': 'second',
              'sport': 'RUNNING',
              'zone_unit': 'PACE',
              'target_range': {'low': 900, 'high': 600},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — 25 m Pool (meters)',
      icon: Icons.pool,
      color: Colors.cyan,
      workouts: [
        {
          'schedule_id': 'swim-25m-test-001',
          'sport': 'SWIMMING',
          'distance': 1500.0,
          'duration': 2700,
          'pool_size': '25m',
          'summary': {
            'name': 'Test: 25 m Pool Swim',
            'sport': 'SWIMMING',
            'indoor_outdoor': 'INDOOR',
            'measurement_unit': 'meter',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 200.0,
              'measurement_unit': 'meter',
            },
            {
              'type': 'INTERVAL',
              'duration': 1800,
              'distance': 1000.0,
              'measurement_unit': 'meter',
              'zone_unit': 'HR',
              'target_range': {'low': 130, 'high': 160},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'distance': 300.0,
              'measurement_unit': 'meter',
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Swimming — 25 yd Pool (yards)',
      icon: Icons.pool,
      color: Colors.teal,
      workouts: [
        {
          'schedule_id': 'swim-25y-test-001',
          'sport': 'SWIMMING',
          'distance': 1650.0,
          'duration': 2700,
          'pool_size': '25y',
          'summary': {
            'name': 'Test: 25 yd Pool Swim',
            'sport': 'SWIMMING',
            'indoor_outdoor': 'INDOOR',
            'measurement_unit': 'yard',
          },
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 300,
              'distance': 200.0,
              'measurement_unit': 'yard',
            },
            {
              'type': 'INTERVAL',
              'duration': 1800,
              'distance': 1200.0,
              'measurement_unit': 'yard',
              'zone_unit': 'HR',
              'target_range': {'low': 130, 'high': 165},
            },
            {
              'type': 'COOLDOWN',
              'duration': 420,
              'distance': 250.0,
              'measurement_unit': 'yard',
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup only',
      icon: Icons.whatshot,
      color: Colors.orange,
      workouts: [
        {
          'schedule_id': 'warmup-only-test-001',
          'sport': 'CYCLING',
          'duration': 600,
          'summary': {'name': 'Test: Warmup Only', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 100, 'high': 150},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Cooldown only',
      icon: Icons.ac_unit,
      color: Colors.lightBlue,
      workouts: [
        {
          'schedule_id': 'cooldown-only-test-001',
          'sport': 'CYCLING',
          'duration': 600,
          'summary': {'name': 'Test: Cooldown Only', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup + Cooldown (no interval)',
      icon: Icons.swap_horiz,
      color: Colors.purple,
      workouts: [
        {
          'schedule_id': 'warmup-cooldown-test-001',
          'sport': 'RUNNING',
          'duration': 1200,
          'summary': {'name': 'Test: Warmup + Cooldown', 'sport': 'RUNNING'},
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 433, 'high': 616},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'PACE',
              'target_range': {'low': 493, 'high': 650},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Interval + Cooldown (no warmup)',
      icon: Icons.fitness_center,
      color: Colors.deepOrange,
      workouts: [
        {
          'schedule_id': 'interval-cooldown-test-001',
          'sport': 'CYCLING',
          'duration': 1800,
          'summary': {'name': 'Test: Interval + Cooldown', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'INTERVAL',
              'duration': 1200,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 191, 'high': 222},
            },
            {
              'type': 'COOLDOWN',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
          ],
        },
      ],
    ),
    _Scenario(
      label: 'Warmup + Interval (no cooldown)',
      icon: Icons.trending_up,
      color: Colors.green,
      workouts: [
        {
          'schedule_id': 'warmup-interval-test-001',
          'sport': 'CYCLING',
          'duration': 1800,
          'summary': {'name': 'Test: Warmup + Interval', 'sport': 'CYCLING'},
          'blocks': [
            {
              'type': 'WARMUP',
              'duration': 600,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 85, 'high': 128},
            },
            {
              'type': 'INTERVAL',
              'duration': 1200,
              'measurement_unit': 'second',
              'zone_unit': 'POWER',
              'target_range': {'low': 191, 'high': 222},
            },
          ],
        },
      ],
    ),
  ];

  // ── Core push logic ───────────────────────────────────────────────────────

  /// Injects a valid forward-looking date into every workout map and pushes.
  Future<void> _pushWorkouts(
    List<Map<String, dynamic>> workouts,
    String scenarioLabel,
  ) async {
    setState(() {
      _isPushing = true;
      _lastResponse = null;
      _errorMessage = null;
      _activeScenarioLabel = scenarioLabel;
    });

    try {
      // Deep-copy so the original scenario maps are not mutated
      final List<Map<String, dynamic>> mutable = workouts
          .map((w) => Map<String, dynamic>.from(w))
          .toList();

      // Apple WorkoutKit requires dates strictly between now and +7 days.
      // Strip sub-second precision — Swift's .iso8601 decoder rejects fractional seconds.
      for (final map in mutable) {
        final forward = DateTime.now().add(const Duration(hours: 2)).toUtc();
        map['date'] = '${forward.toIso8601String().substring(0, 19)}Z';
      }

      final response = await _pushManager.pushRawWorkouts(mutable);

      setState(() {
        _lastResponse = response;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    } finally {
      setState(() {
        _isPushing = false;
      });
    }
  }

  /// Parses pasted JSON and pushes it.
  Future<void> _pushPastedJson() async {
    final raw = _jsonController.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorMessage = 'Paste field is empty.');
      return;
    }

    late final List<Map<String, dynamic>> workouts;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        workouts = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else if (decoded is Map) {
        workouts = [Map<String, dynamic>.from(decoded)];
      } else {
        setState(() => _errorMessage = 'JSON must be an object or array.');
        return;
      }
    } catch (e) {
      setState(() => _errorMessage = 'Invalid JSON: $e');
      return;
    }

    await _pushWorkouts(workouts, 'Pasted JSON');
  }

  Future<void> _clearCache() async {
    setState(() {
      _isPushing = true;
      _lastResponse = null;
      _errorMessage = null;
      _activeScenarioLabel = 'Clearing…';
    });

    try {
      // Step 1 — find all workouts currently on Apple Watch
      final scheduled = await _pushManager.getScheduledWorkouts();

      // Step 2 — remove them from Apple Watch (+ local store entries)
      if (scheduled.isNotEmpty) {
        final planIds = scheduled
            .map((w) => w.workoutPlanId)
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toList();
        if (planIds.isNotEmpty) {
          await _pushManager.removeScheduledWorkouts(planIds);
        }
      }

      // Step 3 — clear any remaining local deduplication entries
      final cleared = await _pushManager.clearDeduplicationCache();

      setState(() {
        _errorMessage = cleared
            ? 'Apple Watch workouts removed & local cache cleared.\n'
                  'Push a fresh scenario to test with the latest native code.'
            : 'Partial clear — some local cache entries may remain.';
        _activeScenarioLabel = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Clear failed: $e';
        _activeScenarioLabel = null;
      });
    } finally {
      setState(() => _isPushing = false);
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  Widget _buildScenarioButton(_Scenario s) {
    final bool isActive = _isPushing && _activeScenarioLabel == s.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ElevatedButton.icon(
        onPressed: _isPushing ? null : () => _pushWorkouts(s.workouts, s.label),
        icon: isActive
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(s.icon, size: 18),
        label: Text(s.label),
        style: ElevatedButton.styleFrom(
          backgroundColor: s.color,
          foregroundColor: Colors.white,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        ),
      ),
    );
  }

  Widget _buildResultsPanel() {
    final response = _lastResponse;
    final error = _errorMessage;

    if (error != null && response == null) {
      return _infoBox(
        color: Colors.red.shade50,
        border: Colors.red.shade200,
        child: Text(
          '❌ $error',
          style: TextStyle(
            color: Colors.red.shade800,
            fontFamily: 'Courier',
            fontSize: 13,
          ),
        ),
      );
    }

    if (response == null) {
      return _infoBox(
        color: Colors.grey.shade100,
        border: Colors.grey.shade300,
        child: Text(
          'Results will appear here after pushing.',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      );
    }

    final successCount = response.successful;
    final skippedCount = response.skipped;
    final failedCount = response.failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.grey.shade800,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _activeScenarioLabel ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _summaryChip('$successCount scheduled', Colors.green),
                  const SizedBox(width: 6),
                  _summaryChip('$skippedCount skipped', Colors.amber.shade700),
                  const SizedBox(width: 6),
                  _summaryChip('$failedCount failed', Colors.red),
                ],
              ),
            ],
          ),
        ),
        // Per-result tiles
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(8),
            ),
          ),
          child: response.results.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No results returned.'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: response.results.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (_, i) => _buildResultTile(response.results[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildResultTile(WorkoutPushResult r) {
    final (icon, color, title, subtitle) = switch (r.status) {
      WorkoutPushStatus.success => (
        Icons.check_circle,
        Colors.green,
        'Scheduled',
        'Plan ID: ${r.workoutPlanId ?? "—"}\nWorkout ID: ${r.workoutId}',
      ),
      WorkoutPushStatus.skipped => (
        Icons.skip_next,
        Colors.amber.shade700,
        'Skipped',
        r.skipReason ?? 'Already scheduled (no changes)',
      ),
      WorkoutPushStatus.validationError => (
        Icons.warning_amber,
        Colors.orange,
        'Validation Error',
        r.errorMessage ?? 'Unknown validation error',
      ),
      WorkoutPushStatus.failed => (
        Icons.error,
        Colors.red,
        'Failed',
        r.errorMessage ?? 'Unknown error',
      ),
    };

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        '$title  ·  ${r.scheduleId}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontFamily: 'Courier', fontSize: 11),
      ),
    );
  }

  Widget _summaryChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _infoBox({
    required Color color,
    required Color border,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Push Workouts')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Section: Scenarios ───────────────────────────────────────
            const Text(
              'Test Scenarios',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Each button pushes a pre-built workout to Apple Watch via WorkoutKit. '
              'Re-pushing the same scenario will be deduped (skipped) unless the date '
              'changes content hash.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            ..._scenarios.map(_buildScenarioButton),

            const SizedBox(height: 24),
            const Divider(),

            // ── Section: Paste JSON ──────────────────────────────────────
            const SizedBox(height: 8),
            const Text(
              'Paste Custom JSON',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Paste a single workout object {} or an array [{}] of workouts. '
              'The date field will be overwritten to +2 h from now automatically.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _jsonController,
              enabled: !_isPushing,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
              decoration: InputDecoration(
                hintText:
                    '{\n  "schedule_id": "...",\n  "sport": "CYCLING",\n  ...\n}',
                hintStyle: TextStyle(color: Colors.grey.shade400),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.all(12),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear',
                  onPressed: () => _jsonController.clear(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isPushing ? null : _pushPastedJson,
              icon: _isPushing && _activeScenarioLabel == 'Pasted JSON'
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.upload_file, size: 18),
              label: const Text('Push Pasted JSON'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),

            const SizedBox(height: 24),
            const Divider(),

            // ── Section: Cache ────────────────────────────────────────────
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _isPushing ? null : _clearCache,
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Clear Local Deduplication Cache'),
            ),

            const SizedBox(height: 24),

            // ── Section: Results ──────────────────────────────────────────
            _buildResultsPanel(),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
