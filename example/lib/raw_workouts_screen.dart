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
  List<String> _rawJsons = [];
  List<bool> _expanded = [];

  DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 7)),
    end: DateTime.now(),
  );

  Future<void> _fetch() async {
    setState(() {
      _isLoading = true;
      _status = 'Fetching…';
      _rawJsons = [];
      _expanded = [];
    });

    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'fetchRawWorkouts',
        {
          'startDate': _range.start.toUtc().toIso8601String(),
          'endDate': _range.end.toUtc().toIso8601String(),
        },
      );

      final jsons = result?.map((e) => e.toString()).toList() ?? [];
      setState(() {
        _rawJsons = jsons;
        _expanded = List.filled(jsons.length, false);
        _status = jsons.isEmpty
            ? 'No workouts found in selected range'
            : '${jsons.length} workout(s) found';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

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
        _rawJsons = [];
        _expanded = [];
        _status = 'Range updated — tap Fetch';
      });
    }
  }

  String _workoutTitle(String rawJson) {
    try {
      final map = jsonDecode(rawJson) as Map<String, dynamic>;
      final type = map['workoutActivityType'] as String? ?? 'Unknown';
      final start = map['startDate'] as String? ?? '';
      final shortDate = start.length >= 10 ? start.substring(0, 10) : start;
      return '$type  ·  $shortDate';
    } catch (_) {
      return 'Workout';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Controls ────────────────────────────────────────────────────────
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
        // ── Status bar ──────────────────────────────────────────────────────
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
        // ── Results ─────────────────────────────────────────────────────────
        Expanded(
          child: _rawJsons.isEmpty
              ? Center(
                  child: Text(
                    _isLoading ? '' : 'No data',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _rawJsons.length,
                  itemBuilder: (context, i) {
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Header row
                          InkWell(
                            onTap: () => setState(
                              () => _expanded[i] = !_expanded[i],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _workoutTitle(_rawJsons[i]),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Copy JSON',
                                    icon: const Icon(Icons.copy, size: 18),
                                    onPressed: () {
                                      Clipboard.setData(
                                        ClipboardData(text: _rawJsons[i]),
                                      );
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
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
                          // Expandable raw JSON
                          if (_expanded[i])
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.grey[50],
                                border: Border(
                                  top: BorderSide(color: Colors.grey[200]!),
                                ),
                              ),
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                _rawJsons[i],
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                  height: 1.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
