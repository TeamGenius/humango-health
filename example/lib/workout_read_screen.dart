import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:humango_health/humango_health.dart';

class WorkoutReadScreen extends StatefulWidget {
  const WorkoutReadScreen({super.key});

  @override
  State<WorkoutReadScreen> createState() => _WorkoutReadScreenState();
}

class _WorkoutReadScreenState extends State<WorkoutReadScreen> {
  final WorkoutReadManager _readManager = WorkoutReadManager();

  bool _isLoading = false;
  String _statusMessage = 'Pick a date range and tap Fetch.';

  DateTime _startDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime _endDate = DateTime.now();

  List<WorkoutData> _fetchedWorkouts = [];
  // Raw JSON strings for detail view
  List<String> _rawJsonStrings = [];

  // ── Date / time picker ───────────────────────────────────────────────────────

  Future<void> _pickDateTime({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted) return;

    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? initial.hour,
      time?.minute ?? initial.minute,
    );

    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  // ── Fetch ────────────────────────────────────────────────────────────────────

  Future<void> _fetchWorkouts() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Fetching…';
      _fetchedWorkouts = [];
      _rawJsonStrings = [];
    });

    try {
      final rawJsons = await _readManager.readWorkouts(
        _startDate,
        endDate: _endDate,
      );

      final parsed = <WorkoutData>[];
      for (final raw in rawJsons) {
        parsed.add(
          WorkoutData.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      }
      parsed.sort((a, b) => b.startTime.compareTo(a.startTime));

      setState(() {
        _fetchedWorkouts = parsed;
        _rawJsonStrings = rawJsons;
        _statusMessage = '${parsed.length} workout(s) returned.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String _fmt(DateTime dt) =>
      '${dt.year}-${_p(dt.month)}-${_p(dt.day)}  ${_p(dt.hour)}:${_p(dt.minute)}';
  String _p(int n) => n.toString().padLeft(2, '0');

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

  // ── Workout card ─────────────────────────────────────────────────────────────

  Widget _buildWorkoutCard(WorkoutData w, int index) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showRawJson(index),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Text(
                    w.activityType,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  if (w.isMultisport)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.shade50,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${w.sessions!.length} sessions',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.deepPurple.shade700,
                        ),
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
                '${_fmt(w.startTime.toLocal())}  •  ${w.workoutId.length > 8 ? w.workoutId.substring(0, 8) : w.workoutId}…',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  _chip(Icons.straighten, _formatDistance(w.distance)),
                  if (w.statistics.avgHeartRate != null)
                    _chip(
                      Icons.favorite,
                      '${w.statistics.avgHeartRate!.toStringAsFixed(0)} bpm',
                    ),
                  _chip(Icons.route, '${w.route.length} pts'),
                  _chip(Icons.show_chart, '${w.quantitySeries.length} series'),
                ],
              ),
              // Multisport sessions breakdown
              if (w.isMultisport) ...[
                const Divider(height: 16),
                ...w.sessions!.map(_buildSessionRow),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionRow(WorkoutSession s) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _sportColor(s.sport),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            s.sport,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(s.duration),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (s.distance > 0) ...[
            const SizedBox(width: 8),
            Text(
              _formatDistance(s.distance),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  Color _sportColor(String sport) {
    switch (sport) {
      case 'Running':
        return Colors.orange;
      case 'Cycling':
        return Colors.blue;
      case 'Swimming':
        return Colors.cyan;
      default:
        return Colors.grey;
    }
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

  // ── Raw JSON detail ──────────────────────────────────────────────────────────

  void _showRawJson(int index) {
    if (index >= _rawJsonStrings.length) return;
    final pretty = const JsonEncoder.withIndent('  ')
        .convert(jsonDecode(_rawJsonStrings[index]));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('Raw JSON'),
            actions: [
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copy JSON',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: pretty));
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('JSON copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              pretty,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
      ),
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
            // ── Date pickers ───────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: _dateButton(
                    label: 'Start',
                    value: _fmt(_startDate),
                    onTap: () => _pickDateTime(isStart: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _dateButton(
                    label: 'End',
                    value: _fmt(_endDate),
                    onTap: () => _pickDateTime(isStart: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // ── Fetch button ───────────────────────────────────────────────
            SizedBox(
              height: 44,
              child: FilledButton.icon(
                onPressed: _isLoading ? null : _fetchWorkouts,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Fetch Workouts'),
              ),
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
                            'No workouts.\nPick dates and tap Fetch.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _fetchedWorkouts.length,
                          itemBuilder: (context, index) =>
                              _buildWorkoutCard(_fetchedWorkouts[index], index),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateButton({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
