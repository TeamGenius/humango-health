import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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

  // Live stream — each completed workout delivered by RouteService debounce (3-min)
  final List<WorkoutData> _liveWorkouts = [];
  StreamSubscription<String>? _streamSubscription;

  // Import preference toggles
  bool _importRunning = true;
  bool _importCycling = true;
  bool _importSwimming = true;

  // Which tab is selected: 0 = Fetched, 1 = Live
  int _selectedTab = 0;

  @override
  void dispose() {
    _streamSubscription?.cancel();
    super.dispose();
  }

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
      _selectedTab = 0;
    });

    try {
      final now = DateTime.now();
      final startDate = now.subtract(const Duration(days: 7));

      final rawJsons = await _readManager.readWorkouts(startDate);
      debugPrint('Fetched ${rawJsons.length} raw workout JSON strings');

      final parsed = rawJsons
          .map(
            (e) => WorkoutData.fromJson(jsonDecode(e) as Map<String, dynamic>),
          )
          .toList();

      // Newest first
      parsed.sort((a, b) => b.startTime.compareTo(a.startTime));

      setState(() {
        _fetchedWorkouts = parsed;
        _statusMessage =
            'Fetched ${parsed.length} workout(s) from past 7 days.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Error fetching workouts: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Live monitoring ──────────────────────────────────────────────────────────

  /// Starts the native WorkoutService (open-ended anchor query).
  /// The native layer automatically switches between foreground live-streaming
  /// and background observer mode via AppLifecycleManager — no manual calls needed.
  /// Each fully-routed workout is delivered to [workoutStream] once the
  /// 3-minute RouteService debounce timer fires.
  Future<void> _startMonitoring() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Starting live monitoring...';
      _liveWorkouts.clear();
      _selectedTab = 1;
    });

    try {
      final startDate = DateTime.now().subtract(const Duration(hours: 2));

      await _readManager.startMonitoring(startDate);

      // Background workouts are stored locally and delivered to the stream
      // when the app returns to foreground.
      await _readManager.configureBackgroundDelivery(
        BackgroundDeliveryConfig(mode: BackgroundDeliveryMode.localStorage),
      );

      // Subscribe once — accumulate every completed workout arriving on the stream.
      _streamSubscription?.cancel();
      _streamSubscription = _readManager.workoutStream.listen(
        (jsonString) {
          debugPrint('Live stream event received (${jsonString.length} chars)');
          try {
            final data = WorkoutData.fromJson(
              jsonDecode(jsonString) as Map<String, dynamic>,
            );
            if (mounted) {
              setState(() {
                _liveWorkouts.insert(0, data); // newest first
                _statusMessage =
                    '${_liveWorkouts.length} live workout(s) received.';
              });
            }
          } catch (e) {
            debugPrint('Failed to parse live workout JSON: $e');
          }
        },
        onError: (Object error) {
          if (mounted) {
            setState(() => _statusMessage = 'Stream error: $error');
          }
        },
      );

      setState(() {
        _isMonitoring = true;
        _statusMessage =
            'Monitoring active — waiting for completed workouts\n'
            '(delivered after 3-min route-update debounce).';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Failed to start monitoring: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _stopMonitoring() async {
    _streamSubscription?.cancel();
    _streamSubscription = null;
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

  Widget _buildWorkoutCard(WorkoutData w, {bool isLive = false}) {
    final stats = w.statistics;
    final routePoints = w.route.length;
    final seriesCount = w.quantitySeries.length;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: isLive ? Colors.green.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isLive)
                  const Icon(Icons.circle, color: Colors.green, size: 10),
                if (isLive) const SizedBox(width: 6),
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
    final activeWorkouts = _selectedTab == 0 ? _fetchedWorkouts : _liveWorkouts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Read Workouts'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Row(
            children: [
              _tabButton('Fetched (${_fetchedWorkouts.length})', 0),
              _tabButton(
                'Live (${_liveWorkouts.length})'
                '${_isMonitoring ? " 🟢" : ""}',
                1,
              ),
            ],
          ),
        ),
      ),
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
                  : activeWorkouts.isEmpty
                  ? Center(
                      child: Text(
                        _selectedTab == 0
                            ? 'No workouts fetched yet.\nTap "Fetch Past 7 Days" to load.'
                            : _isMonitoring
                            ? 'Waiting for workouts to complete…\n'
                                  'Each workout is delivered once its GPS route\n'
                                  'has settled (3-min debounce timer).'
                            : 'Tap "Start Live" to begin monitoring.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: activeWorkouts.length,
                      itemBuilder: (context, index) => _buildWorkoutCard(
                        activeWorkouts[index],
                        isLive: _selectedTab == 1,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final selected = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
              fontSize: 13,
            ),
          ),
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
