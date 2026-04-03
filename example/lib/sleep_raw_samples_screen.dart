import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:humango_health/humango_health.dart';
import 'package:path_provider/path_provider.dart';

class SleepRawSamplesScreen extends StatefulWidget {
  const SleepRawSamplesScreen({super.key});

  @override
  State<SleepRawSamplesScreen> createState() => _SleepRawSamplesScreenState();
}

class _SleepRawSamplesScreenState extends State<SleepRawSamplesScreen> {
  final SleepDataManager _sleepManager = SleepDataManager();
  static const _encoder = JsonEncoder.withIndent('  ');

  List<Map<String, dynamic>> _rawSamples = [];
  bool _isLoading = false;
  String? _error;

  late DateTime _windowStart;
  late DateTime _windowEnd;

  @override
  void initState() {
    super.initState();
    _resetWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchSamples());
  }

  /// Mirrors the sixPMWindow logic from SleepDataManager.swift:
  /// - If current time is before today 18:00 → start = yesterday 18:00
  /// - Otherwise → start = today 18:00
  DateTime _sixPmWindowStart() {
    final now = DateTime.now();
    final todaySixPm = DateTime(now.year, now.month, now.day, 18, 0, 0);
    return now.isBefore(todaySixPm)
        ? todaySixPm.subtract(const Duration(days: 1))
        : todaySixPm;
  }

  void _resetWindow() {
    _windowEnd = DateTime.now();
    _windowStart = _sixPmWindowStart();
  }

  Future<void> _fetchSamples() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await _sleepManager.getSleepData(
        startDate: _windowStart,
        endDate: _windowEnd,
      );
      setState(() {
        _rawSamples = response.samples.map((s) => s.toJson()).toList();
        _isLoading = false;
      });
    } on SleepDataException catch (e) {
      setState(() {
        _error = '${e.code}: ${e.message}';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _allSamplesJson() => _encoder.convert(_rawSamples);

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _allSamplesJson()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Copied ${_rawSamples.length} sample${_rawSamples.length == 1 ? '' : 's'} to clipboard',
          ),
        ),
      );
    }
  }

  Future<void> _saveToFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final file = File('${dir.path}/sleep_raw_$ts.json');
      await file.writeAsString(_allSamplesJson());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved → ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatDateTime(DateTime dt) {
    final y = dt.year;
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$mi';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Raw Sleep Samples'),
        actions: [
          if (_rawSamples.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.copy_all),
              tooltip: 'Copy all to clipboard',
              onPressed: _copyAll,
            ),
            IconButton(
              icon: const Icon(Icons.save_alt),
              tooltip: 'Save to file',
              onPressed: _saveToFile,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              _resetWindow();
              _fetchSamples();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildWindowBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildWindowBanner() {
    return Container(
      color: Colors.blueGrey[50],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.access_time, size: 16, color: Colors.blueGrey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${_formatDateTime(_windowStart)}  →  ${_formatDateTime(_windowEnd)}',
              style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
            ),
          ),
          if (!_isLoading)
            Text(
              '${_rawSamples.length} sample${_rawSamples.length == 1 ? '' : 's'}',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.blueGrey,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 40),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                onPressed: _fetchSamples,
              ),
            ],
          ),
        ),
      );
    }

    if (_rawSamples.isEmpty) {
      return const Center(
        child: Text(
          'No sleep samples in this window.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _rawSamples.length,
      separatorBuilder: (context, i) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildSampleCard(context, index),
    );
  }

  Widget _buildSampleCard(BuildContext context, int index) {
    final sample = _rawSamples[index];
    final stage = sample['sleepStage'] as String? ?? 'unknown';
    final prettyJson = _encoder.convert(sample);

    return Card(
      elevation: 1,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: _StageDot(stage: stage),
          title: Text(
            '#${index + 1}  $stage',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          subtitle: Text(
            '${sample['startDate'] ?? ''}  –  ${sample['endDate'] ?? ''}',
            style: const TextStyle(fontSize: 11),
          ),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              color: Colors.grey[50],
              child: SelectableText(
                prettyJson,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: prettyJson));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Sample JSON copied'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StageDot extends StatelessWidget {
  const _StageDot({required this.stage});

  final String stage;

  @override
  Widget build(BuildContext context) {
    final Color color;
    switch (stage) {
      case 'asleepDeep':
        color = Colors.indigo;
        break;
      case 'asleepCore':
        color = Colors.blue;
        break;
      case 'asleepREM':
        color = Colors.purple;
        break;
      case 'asleepUnspecified':
        color = Colors.teal;
        break;
      case 'awake':
        color = Colors.orange;
        break;
      case 'inBed':
      default:
        color = Colors.blueGrey;
    }
    return CircleAvatar(radius: 10, backgroundColor: color);
  }
}
