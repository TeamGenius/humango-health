import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RawWorkoutsScreen extends StatefulWidget {
  const RawWorkoutsScreen({super.key});

  @override
  State<RawWorkoutsScreen> createState() => _RawWorkoutsScreenState();
}

class _RawWorkoutsScreenState extends State<RawWorkoutsScreen> {
  static const _channel = MethodChannel('com.humango.example/rawWorkouts');

  bool _isLoading = false;
  String _status = 'Tap Fetch to load workouts';
  List<Map<String, dynamic>> _workouts = [];
  List<bool> _expanded = [];

  /// Per-workout detail data (route + samples + activities), loaded on demand.
  final Map<int, Map<String, dynamic>> _details = {};
  final Set<int> _detailLoading = {};

  DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 7)),
    end: DateTime.now(),
  );

  // ── Fetch workout list ──────────────────────────────────────────────────

  Future<void> _fetch() async {
    setState(() {
      _isLoading = true;
      _status = 'Fetching…';
      _workouts = [];
      _expanded = [];
      _details.clear();
      _detailLoading.clear();
    });

    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'fetchRawWorkouts',
        {
          'startDate': _range.start.toUtc().toIso8601String(),
          'endDate': _range.end.toUtc().toIso8601String(),
        },
      );

      final parsed = (result ?? []).map((e) {
        try {
          return jsonDecode(e.toString()) as Map<String, dynamic>;
        } catch (_) {
          return <String, dynamic>{'_raw': e.toString()};
        }
      }).toList();

      setState(() {
        _workouts = parsed;
        _expanded = List.filled(parsed.length, false);
        _status = parsed.isEmpty
            ? 'No workouts found in selected range'
            : '${parsed.length} workout(s) found';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Fetch detail (route + samples + activities) on demand ───────────────

  Future<void> _loadDetail(int index) async {
    if (_details.containsKey(index) || _detailLoading.contains(index)) return;
    final uuid = _workouts[index]['uuid'] as String?;
    if (uuid == null) return;

    setState(() => _detailLoading.add(index));

    try {
      final raw = await _channel.invokeMethod<String>(
        'fetchRawWorkoutDetail',
        {'uuid': uuid},
      );
      if (raw != null) {
        final detail = jsonDecode(raw) as Map<String, dynamic>;
        setState(() => _details[index] = detail);
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Detail error: ${e.message}')),
        );
      }
    } finally {
      setState(() => _detailLoading.remove(index));
    }
  }

  // ── Date range picker ───────────────────────────────────────────────────

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: _range,
    );
    if (picked != null) {
      setState(() {
        _range = picked;
        _workouts = [];
        _expanded = [];
        _details.clear();
        _detailLoading.clear();
        _status = 'Range updated — tap Fetch';
      });
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  String _workoutTitle(Map<String, dynamic> w) {
    final type = w['workoutActivityType'] as String? ?? 'Unknown';
    final start = w['startDate'] as String? ?? '';
    final shortDate = start.length >= 10 ? start.substring(0, 10) : start;
    return '$type  ·  $shortDate';
  }

  String _workoutSubtitle(Map<String, dynamic> w) {
    final parts = <String>[];
    final dur = w['durationSeconds'];
    if (dur is num && dur > 0) {
      final mins = (dur / 60).round();
      parts.add('${mins}m');
    }
    final dist = w['totalDistanceMeters'];
    if (dist is num && dist > 0) {
      parts.add('${(dist / 1000).toStringAsFixed(2)} km');
    }
    final kcal = w['totalEnergyBurnedKcal'];
    if (kcal is num && kcal > 0) {
      parts.add('${kcal.round()} kcal');
    }
    final src = w['sourceName'] as String? ?? '';
    if (src.isNotEmpty) parts.add(src);
    return parts.join('  ·  ');
  }

  /// Merge detail into summary for copy-to-clipboard.
  String _fullJson(int index) {
    final merged = Map<String, dynamic>.from(_workouts[index]);
    if (_details.containsKey(index)) {
      merged.addAll(_details[index]!);
    }
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(merged);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Controls ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _pickRange,
                  icon: const Icon(Icons.date_range, size: 18),
                  label: Text(
                    '${_fmtDate(_range.start)}  →  ${_fmtDate(_range.end)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isLoading ? null : _fetch,
                child: _isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Fetch'),
              ),
            ],
          ),
        ),
        // ── Status bar ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _status,
              style: TextStyle(
                fontSize: 13,
                color: _status.startsWith('Error')
                    ? Colors.red[700]
                    : Colors.grey[700],
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        // ── Results ───────────────────────────────────────────────────────
        Expanded(
          child: _workouts.isEmpty
              ? Center(
                  child: Text(
                    _isLoading ? '' : 'No data',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _workouts.length,
                  itemBuilder: (context, i) => _buildWorkoutCard(i),
                ),
        ),
      ],
    );
  }

  // ── Workout card ────────────────────────────────────────────────────────

  Widget _buildWorkoutCard(int i) {
    final w = _workouts[i];
    final detail = _details[i];
    final isLoadingDetail = _detailLoading.contains(i);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _expanded[i] = !_expanded[i]),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _workoutTitle(w),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _workoutSubtitle(w),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy JSON',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _fullJson(i)));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('JSON copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  Icon(
                    _expanded[i]
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: Colors.grey[600],
                  ),
                ],
              ),
            ),
          ),

          // Expanded content
          if (_expanded[i]) ...[
            const Divider(height: 1),

            // Load Detail button
            if (detail == null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: FilledButton.icon(
                  onPressed: isLoadingDetail ? null : () => _loadDetail(i),
                  icon: isLoadingDetail
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.download, size: 16),
                  label: Text(
                    isLoadingDetail
                        ? 'Loading route & samples…'
                        : 'Load Detail (Route + Samples)',
                  ),
                ),
              ),

            // Activities section
            if (detail != null && detail['workoutActivities'] != null)
              _buildSection(
                'Workout Activities',
                Icons.sports_score,
                _buildActivitiesContent(detail['workoutActivities'] as List),
              ),

            // Route section
            if (detail != null && detail['route'] != null)
              _buildSection(
                'Route',
                Icons.route,
                _buildRouteContent(detail['route'] as List),
              ),

            // Associated samples section
            if (detail != null && detail['associatedSamples'] != null)
              _buildSection(
                'Associated Samples',
                Icons.show_chart,
                _buildSamplesContent(
                    detail['associatedSamples'] as Map<String, dynamic>),
              ),

            // Raw JSON (always shown)
            _buildSection(
              'Raw JSON',
              Icons.data_object,
              Container(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _fullJson(i),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Section wrapper ─────────────────────────────────────────────────────

  Widget _buildSection(String title, IconData icon, Widget content) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: ExpansionTile(
        leading: Icon(icon, size: 18, color: Colors.blueGrey),
        title: Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        childrenPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [content],
      ),
    );
  }

  // ── Activities content ──────────────────────────────────────────────────

  Widget _buildActivitiesContent(List activities) {
    if (activities.isEmpty) {
      return const Text('No workout activities (single-activity workout)',
          style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${activities.length} activity segment(s)',
            style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        const SizedBox(height: 6),
        ...activities.map<Widget>((a) {
          final act = a as Map<String, dynamic>;
          final type = act['workoutActivityType'] ?? 'Unknown';
          final start = (act['startDate'] as String? ?? '').split('T').first;
          final dur = act['durationSeconds'];
          final durStr =
              dur is num ? '${(dur / 60).round()}m' : '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '• $type  $start  $durStr',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          );
        }),
      ],
    );
  }

  // ── Route content ───────────────────────────────────────────────────────

  Widget _buildRouteContent(List route) {
    if (route.isEmpty) {
      return const Text('No GPS route data for this workout',
          style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    final first = route.first as Map<String, dynamic>;
    final last = route.last as Map<String, dynamic>;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${route.length} GPS point(s)',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey[800])),
        const SizedBox(height: 6),
        _kvRow('First',
            '${_fmtCoord(first['latitude'])} , ${_fmtCoord(first['longitude'])}  alt ${_fmtNum(first['altitude'])}m'),
        _kvRow('Last',
            '${_fmtCoord(last['latitude'])} , ${_fmtCoord(last['longitude'])}  alt ${_fmtNum(last['altitude'])}m'),
        _kvRow('First timestamp', '${first['timestamp'] ?? ''}'),
        _kvRow('Last timestamp', '${last['timestamp'] ?? ''}'),
      ],
    );
  }

  // ── Samples content ─────────────────────────────────────────────────────

  Widget _buildSamplesContent(Map<String, dynamic> samples) {
    if (samples.isEmpty) {
      return const Text('No associated quantity samples',
          style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: samples.entries.map((entry) {
        final typeId = entry.key;
        final data = entry.value as Map<String, dynamic>;
        final count = data['count'] ?? 0;
        final unit = data['unit'] ?? '';
        final sampleList = data['samples'] as List? ?? [];

        // Compute min/avg/max from the sample values.
        double? minVal, maxVal, sumVal;
        for (final s in sampleList) {
          final v = (s as Map<String, dynamic>)['value'];
          if (v is num) {
            final d = v.toDouble();
            minVal = (minVal == null || d < minVal) ? d : minVal;
            maxVal = (maxVal == null || d > maxVal) ? d : maxVal;
            sumVal = (sumVal ?? 0) + d;
          }
        }
        final avgVal =
            (sumVal != null && sampleList.isNotEmpty)
                ? sumVal / sampleList.length
                : null;

        // Shorten the identifier for display.
        final shortName = typeId.split('.').last;

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$shortName  ($count samples, $unit)',
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    fontFamily: 'monospace'),
              ),
              if (minVal != null)
                Text(
                  '  min: ${minVal.toStringAsFixed(2)}  avg: ${avgVal?.toStringAsFixed(2)}  max: ${maxVal?.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.grey[700]),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Tiny helpers ────────────────────────────────────────────────────────

  Widget _kvRow(String key, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text('$key: $value',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
      );

  String _fmtCoord(dynamic v) =>
      v is num ? v.toStringAsFixed(6) : v.toString();

  String _fmtNum(dynamic v) =>
      v is num ? v.toStringAsFixed(1) : v.toString();

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
