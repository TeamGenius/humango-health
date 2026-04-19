import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

class WorkoutReadScreen extends StatefulWidget {
  const WorkoutReadScreen({super.key});

  @override
  State<WorkoutReadScreen> createState() => _WorkoutReadScreenState();
}

class _WorkoutReadScreenState extends State<WorkoutReadScreen> {
  final WorkoutReadManager _readManager = WorkoutReadManager();

  bool _isLoading = false;
  bool _isMonitoring = false;
  String _statusMessage = 'Idle';

  // One-shot fetched workouts
  List<WorkoutData> _fetchedWorkouts = [];

  // Import preference toggles
  bool _importRunning = true;
  bool _importCycling = true;
  bool _importSwimming = true;

  // ── Import preferences ──────────────────────────────────────────────────────

  Future<void> _applyImportPreferences() async {
    await _readManager.setImportPreferences(
      running: _importRunning,
      cycling: _importCycling,
      swimming: _importSwimming,
    );
    if (mounted) {
      setState(() => _statusMessage = 'Import preferences saved.');
    }
  }

  // ── One-shot fetch ───────────────────────────────────────────────────────────

  Future<void> _fetchPastWorkouts() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Fetching workouts...';
      _fetchedWorkouts = [];
    });

    try {
      final endDate = DateTime.now();
      final startDate = endDate.subtract(const Duration(days: 7));

      debugPrint(
        'WorkoutReadScreen: readWorkouts '
        'start=${startDate.toUtc().toIso8601String()} '
        'end=${endDate.toUtc().toIso8601String()}',
      );

      final rawJsons = await _readManager.readWorkouts(
        startDate,
        endDate: endDate,
      );
      debugPrint(
        'WorkoutReadScreen: received ${rawJsons.length} raw JSON string(s)',
      );

      final parsed = <WorkoutData>[];
      for (final (index, raw) in rawJsons.indexed) {
        final w = WorkoutData.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        final routeStatus = w.route.isNotEmpty
            ? '✅ ${w.route.length} GPS point(s)'
            : '⚠️ NO route locations';
        debugPrint(
          'WorkoutReadScreen: [${index + 1}/${rawJsons.length}] '
          'id=${w.workoutId.length > 8 ? w.workoutId.substring(0, 8) : w.workoutId}… '
          'sport=${w.activityType} '
          'start=${w.startTime.toLocal().toString().substring(0, 16)} '
          'duration=${w.duration.toStringAsFixed(0)}s '
          'distance=${w.distance != null ? '${w.distance!.toStringAsFixed(0)} m' : 'nil'} '
          'route=$routeStatus '
          'series=${w.quantitySeries.length} type(s)',
        );
        parsed.add(w);
      }

      // Newest first
      parsed.sort((a, b) => b.startTime.compareTo(a.startTime));

      setState(() {
        _fetchedWorkouts = parsed;
        _statusMessage =
            'Fetched ${parsed.length} workout(s) '
            'from ${startDate.toLocal().toString().substring(0, 10)} '
            'to ${endDate.toLocal().toString().substring(0, 10)}.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Error fetching workouts: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Live monitoring ──────────────────────────────────────────────────────────

  Future<void> _startMonitoring() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Starting monitoring...';
      _fetchedWorkouts = [];
    });

    try {
      final startDate = DateTime.now().subtract(const Duration(hours: 2));
      await _readManager.startMonitoring(startDate);
      setState(() {
        _isMonitoring = true;
        _statusMessage =
            'Monitoring active — workouts delivered via delegate to API.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Failed to start monitoring: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _stopMonitoring() async {
    try {
      await _readManager.stopMonitoring();
    } catch (_) {}
    setState(() {
      _isMonitoring = false;
      _statusMessage = 'Monitoring stopped.';
    });
  }

  // ── UI helpers ───────────────────────────────────────────────────────────────

  String _formatDuration(double seconds) {
    final d = Duration(seconds: seconds.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String _formatDistance(double? meters) {
    if (meters == null || meters == 0) return '—';
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  Widget _buildWorkoutCard(WorkoutData w) {
    final stats = w.statistics;
    final routePoints = w.route.length;
    final seriesCount = w.quantitySeries.length;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  w.activityType,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                Text(
                  _formatDuration(w.duration),
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${w.startTime.toLocal().toString().substring(0, 16)}'
              '  •  ID: ${w.workoutId.substring(0, 8)}…',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _chip(Icons.straighten, _formatDistance(w.distance)),
                if (w.activeCalories != null)
                  _chip(
                    Icons.local_fire_department,
                    '${w.activeCalories!.toStringAsFixed(0)} kcal',
                  ),
                if (stats.avgHeartRate != null)
                  _chip(
                    Icons.favorite,
                    '${stats.avgHeartRate!.toStringAsFixed(0)} bpm avg',
                  ),
                if (stats.maxHeartRate != null)
                  _chip(
                    Icons.monitor_heart,
                    '${stats.maxHeartRate!.toStringAsFixed(0)} bpm max',
                  ),
                if (stats.avgPower != null)
                  _chip(Icons.bolt, '${stats.avgPower!.toStringAsFixed(0)} W'),
                if (stats.avgCadence != null)
                  _chip(
                    Icons.rotate_right,
                    '${stats.avgCadence!.toStringAsFixed(0)} rpm',
                  ),
                _chip(Icons.route, '$routePoints pts'),
                _chip(Icons.show_chart, '$seriesCount series'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Colors.blueGrey),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Read Workouts')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Import preferences ─────────────────────────────────────────
            _buildImportPreferences(),
            const SizedBox(height: 10),

            // ── Action buttons ─────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _fetchPastWorkouts,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Fetch Past 7 Days'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _isMonitoring
                      ? ElevatedButton.icon(
                          onPressed: _stopMonitoring,
                          icon: const Icon(Icons.stop_circle, size: 16),
                          label: const Text('Stop Live'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade400,
                            foregroundColor: Colors.white,
                          ),
                        )
                      : ElevatedButton.icon(
                          onPressed: _isLoading ? null : _startMonitoring,
                          icon: const Icon(Icons.sensors, size: 16),
                          label: const Text('Start Live'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade600,
                            foregroundColor: Colors.white,
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // ── Status ─────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_statusMessage, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 8),

            // ── Workout list ───────────────────────────────────────────────
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _fetchedWorkouts.isEmpty
                  ? const Center(
                      child: Text(
                        'No workouts fetched yet.\nTap "Fetch Past 7 Days" to load.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _fetchedWorkouts.length,
                      itemBuilder: (context, index) =>
                          _buildWorkoutCard(_fetchedWorkouts[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportPreferences() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Import preferences',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
          Row(
            children: [
              _prefToggle(
                'Run',
                _importRunning,
                (v) => setState(() => _importRunning = v),
              ),
              _prefToggle(
                'Cycle',
                _importCycling,
                (v) => setState(() => _importCycling = v),
              ),
              _prefToggle(
                'Swim',
                _importSwimming,
                (v) => setState(() => _importSwimming = v),
              ),
              const Spacer(),
              TextButton(
                onPressed: _applyImportPreferences,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Apply', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _prefToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
      ],
    );
  }
}
