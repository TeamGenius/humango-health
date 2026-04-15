import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

/// Fetches today's workouts via the humango_health library (WorkoutReadManager)
/// and renders the raw JSON the library returns alongside parsed fields.
class TodayActivitiesScreen extends StatefulWidget {
  const TodayActivitiesScreen({super.key});

  @override
  State<TodayActivitiesScreen> createState() => _TodayActivitiesScreenState();
}

class _TodayActivitiesScreenState extends State<TodayActivitiesScreen> {
  final _manager = WorkoutReadManager();
  // raw JSON strings exactly as returned by the library
  List<String> _rawJsonList = [];
  // parsed maps
  List<Map<String, dynamic>> _workouts = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final startOfToday = DateTime(now.year, now.month, now.day);
      // Use library method — returns raw JSON strings
      final rawList = await _manager.fetchAllWorkouts(startOfToday, endDate: now);
      final parsed = rawList.map((s) {
        try {
          return Map<String, dynamic>.from(json.decode(s) as Map);
        } catch (_) {
          return <String, dynamic>{'_parseError': s};
        }
      }).toList();
      if (mounted) {
        setState(() {
          _rawJsonList = rawList;
          _workouts = parsed;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Today\'s Activities'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _fetch,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }

    if (_workouts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fitness_center, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('No workouts recorded today.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    // Summary bar
    final userEntered = _workouts.where((w) => w['isUserEnteredWorkout'] == true).length;
    final deviceRecorded = _workouts.length - userEntered;

    return Column(
      children: [
        // ── Summary banner ────────────────────────────────────────────────
        Container(
          width: double.infinity,
          color: Colors.blue[50],
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_workouts.length} workout(s) today',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _badge('User entered: $userEntered', Colors.green[700]!),
              const SizedBox(width: 8),
              _badge('Device: $deviceRecorded', Colors.grey[600]!),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _workouts.length,
            padding: const EdgeInsets.all(8),
            itemBuilder: (context, index) => _WorkoutCard(
              workout: _workouts[index],
              rawJson: _rawJsonList[index],
              index: index,
            ),
          ),
        ),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Workout card — collapsed header, expandable detail
// ─────────────────────────────────────────────────────────────────────────────

class _WorkoutCard extends StatefulWidget {
  const _WorkoutCard({required this.workout, required this.rawJson, required this.index});
  final Map<String, dynamic> workout;
  final String rawJson;
  final int index;

  @override
  State<_WorkoutCard> createState() => _WorkoutCardState();
}

class _WorkoutCardState extends State<_WorkoutCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.workout;
    final isUserEntered = w['isUserEnteredWorkout'] == true;
    final activityName  = w['activityTypeName'] as String? ?? 'Unknown';
    final sourceName    = w['sourceName'] as String? ?? '';
    final duration      = (w['durationSeconds'] as num?)?.toDouble() ?? 0;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isUserEntered ? Colors.green[300]! : Colors.grey[300]!,
          width: isUserEntered ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  // isUserEnteredWorkout indicator
                  Tooltip(
                    message: isUserEntered
                        ? 'User-entered workout'
                        : 'Device-recorded workout',
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor:
                          isUserEntered ? Colors.green[100] : Colors.grey[200],
                      child: Icon(
                        isUserEntered ? Icons.edit : Icons.watch_outlined,
                        size: 16,
                        color: isUserEntered
                            ? Colors.green[800]
                            : Colors.grey[600],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              activityName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isUserEntered
                                    ? Colors.green[50]
                                    : Colors.grey[100],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                isUserEntered
                                    ? 'USER ENTERED'
                                    : 'DEVICE RECORDED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: isUserEntered
                                      ? Colors.green[700]
                                      : Colors.grey[600],
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$sourceName · ${_fmtDuration(duration)}',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                        Text(
                          w['startDate'] as String? ?? '',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.grey),
                ],
              ),
            ),
          ),

          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: _WorkoutDetails(workout: w, rawJson: widget.rawJson),
            ),
          ],
        ],
      ),
    );
  }

  String _fmtDuration(double s) {
    final h = (s / 3600).floor();
    final m = ((s % 3600) / 60).floor();
    final sec = (s % 60).floor();
    if (h > 0) return '${h}h ${m}m ${sec}s';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail section
// ─────────────────────────────────────────────────────────────────────────────

class _WorkoutDetails extends StatefulWidget {
  const _WorkoutDetails({required this.workout, required this.rawJson});
  final Map<String, dynamic> workout;
  final String rawJson;

  @override
  State<_WorkoutDetails> createState() => _WorkoutDetailsState();
}

class _WorkoutDetailsState extends State<_WorkoutDetails> {
  bool _showRaw = false;

  @override
  Widget build(BuildContext context) {
    final w = widget.workout;
    final isUserEntered = w['isUserEnteredWorkout'] == true;
    // pretty-print the raw JSON
    final prettyJson = const JsonEncoder.withIndent('  ').convert(
      json.decode(widget.rawJson),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Toggle: Parsed / Raw JSON
        Row(
          children: [
            const Spacer(),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Parsed')),
                ButtonSegment(value: true,  label: Text('Raw JSON')),
              ],
              selected: {_showRaw},
              onSelectionChanged: (s) => setState(() => _showRaw = s.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        if (_showRaw)
          // ── Raw JSON as returned by library ──────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              prettyJson,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.greenAccent,
              ),
            ),
          )
        else
          _ParsedView(workout: w, isUserEntered: isUserEntered),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Parsed fields view
// ─────────────────────────────────────────────────────────────────────────────

class _ParsedView extends StatelessWidget {
  const _ParsedView({required this.workout, required this.isUserEntered});
  final Map<String, dynamic> workout;
  final bool isUserEntered;

  @override
  Widget build(BuildContext context) {
    final w = workout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── isUserEnteredWorkout — the field we're testing ─────────────
        _highlightRow(
          'isUserEnteredWorkout',
          isUserEntered ? 'true ✓' : 'false ✗',
          isUserEntered ? Colors.green[700]! : Colors.red[700]!,
          isUserEntered ? Colors.green[50]! : Colors.red[50]!,
        ),
        const SizedBox(height: 6),

        // ── Identity ────────────────────────────────────────────────────
        _section('Identity'),
        _row('UUID',          w['uuid']),
        _row('Activity Type', '${w['activityTypeName']} (raw: ${w['activityTypeRaw']})'),

        // ── Timestamps ──────────────────────────────────────────────────
        _section('Timestamps'),
        _row('Start',    w['startDate']),
        _row('End',      w['endDate']),
        _row('Duration', _fmtDuration((w['durationSeconds'] as num?)?.toDouble() ?? 0)),

        // ── Quantities ──────────────────────────────────────────────────
        if (_anyNotNull(w, ['totalDistanceMeters', 'totalEnergyBurnedKcal',
            'totalFlightsClimbed', 'totalSwimmingStrokes'])) ...[
          _section('Quantities'),
          if (w['totalDistanceMeters'] != null)
            _row('Distance',      '${_fmt(w['totalDistanceMeters'])} m'),
          if (w['totalEnergyBurnedKcal'] != null)
            _row('Energy Burned', '${_fmt(w['totalEnergyBurnedKcal'])} kcal'),
          if (w['totalFlightsClimbed'] != null)
            _row('Flights',       _fmt(w['totalFlightsClimbed'])),
          if (w['totalSwimmingStrokes'] != null)
            _row('Swim Strokes',  _fmt(w['totalSwimmingStrokes'])),
        ],

        // ── Source ──────────────────────────────────────────────────────
        _section('Source'),
        _row('Name',         w['sourceName']),
        _row('Bundle ID',    w['sourceBundleId']),
        _row('Version',      w['sourceVersion']),
        _row('Product Type', w['sourceProductType']),
        _row('OS Version',   w['sourceOSVersion']),

        // ── Device ──────────────────────────────────────────────────────
        if (w['device'] != null) ...[
          _section('Device'),
          ..._deviceRows(w['device'] as Map),
        ],

        // ── Metadata (all raw HK keys) ───────────────────────────────────
        if (w['metadata'] != null) ...[
          _section('Metadata (raw HK keys)'),
          ..._mapRows(w['metadata'] as Map),
        ],

        // ── Events ──────────────────────────────────────────────────────
        if (w['events'] != null && (w['events'] as List).isNotEmpty) ...[
          _section('Events (${(w['events'] as List).length})'),
          _EventsList(events: List<Map>.from(w['events'] as List)),
        ],

        // ── Activities ──────────────────────────────────────────────────
        if (w['activities'] != null && (w['activities'] as List).isNotEmpty) ...[
          _section('Activities / Segments (${(w['activities'] as List).length})'),
          _ActivitiesList(activities: List<Map>.from(w['activities'] as List)),
        ],
      ],
    );
  }

  bool _anyNotNull(Map w, List<String> keys) => keys.any((k) => w[k] != null);

  List<Widget> _deviceRows(Map dev) => [
    _row('Name',             dev['name']),
    _row('Model',            dev['model']),
    _row('Manufacturer',     dev['manufacturer']),
    _row('HW Version',       dev['hardwareVersion']),
    _row('FW Version',       dev['firmwareVersion']),
    _row('Local Identifier', dev['localIdentifier']),
  ].whereType<Widget>().toList();

  List<Widget> _mapRows(Map meta) =>
      meta.entries.map((e) => _row(e.key.toString(), e.value)).toList();

  Widget _highlightRow(String label, String value, Color textColor, Color bgColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: textColor.withAlpha(80)),
      ),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: textColor)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold,
                  fontFamily: 'monospace', color: textColor)),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(title,
        style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 11,
            color: Colors.blueGrey, letterSpacing: 0.5)),
  );

  Widget _row(String label, dynamic value) {
    if (value == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ),
          Expanded(
            child: SelectableText(
              value.toString(),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDuration(double s) {
    final h = (s / 3600).floor();
    final m = ((s % 3600) / 60).floor();
    final sec = (s % 60).floor();
    if (h > 0) return '${h}h ${m}m ${sec}s';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  String _fmt(dynamic v) => v is double ? v.toStringAsFixed(2) : v.toString();
}

class _EventsList extends StatelessWidget {
  const _EventsList({required this.events});
  final List<Map> events;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: events.asMap().entries.map((entry) {
        final e = entry.value;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.orange[50],
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.orange[200]!),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${entry.key + 1}. ${e['typeName']} (raw: ${e['typeRaw']})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            Text('Start: ${e['startDate']}', style: const TextStyle(fontSize: 11)),
            Text('End:   ${e['endDate']}',   style: const TextStyle(fontSize: 11)),
            Text('Dur:   ${(e['durationSeconds'] as num).toStringAsFixed(1)}s',
                style: const TextStyle(fontSize: 11)),
          ]),
        );
      }).toList(),
    );
  }
}

class _ActivitiesList extends StatelessWidget {
  const _ActivitiesList({required this.activities});
  final List<Map> activities;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: activities.asMap().entries.map((entry) {
        final a = entry.value;
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.purple[50],
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.purple[200]!),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${entry.key + 1}. ${a['activityTypeName']} (raw: ${a['activityTypeRaw']})',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            Text('UUID:  ${a['uuid']}',       style: const TextStyle(fontSize: 11)),
            Text('Start: ${a['startDate']}',  style: const TextStyle(fontSize: 11)),
            if (a['endDate'] != null)
              Text('End:   ${a['endDate']}',  style: const TextStyle(fontSize: 11)),
            Text('Dur:   ${(a['durationSeconds'] as num).toStringAsFixed(1)}s',
                style: const TextStyle(fontSize: 11)),
          ]),
        );
      }).toList(),
    );
  }
}
