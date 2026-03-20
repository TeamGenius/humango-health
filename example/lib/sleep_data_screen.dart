import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:humango_health/humango_health.dart';
import 'health_sync_coordinator.dart';

class SleepDataScreen extends StatefulWidget {
  const SleepDataScreen({super.key});

  @override
  State<SleepDataScreen> createState() => _SleepDataScreenState();
}

class _SleepDataScreenState extends State<SleepDataScreen> {
  SleepDataManager get _sleepManager =>
      context.read<HealthSyncCoordinator>().sleep;

  SleepDataResponse? _sleepData;
  bool _isLoading = false;
  String? _error;

  // Date range selection
  String _selectedRange = 'Last 24 hours';
  DateTime? _customStartDate;
  DateTime? _customEndDate;

  // Live monitoring state
  bool _isMonitoring = false;

  // ── Test Setup ────────────────────────────────────────────────────────────
  final _userIdController =
      TextEditingController(text: 'test-user-001');

  @override
  void initState() {
    super.initState();
    // Note: App lifecycle (foreground/background) is now handled automatically
    // by native iOS AppLifecycleManager - no need to manually call
    // enterForeground/enterBackground from Flutter.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSleepData();
    });
  }

  @override
  void dispose() {
    if (_isMonitoring) {
      _sleepManager.stopMonitoring();
    }
    _userIdController.dispose();
    super.dispose();
  }

  // ── Test helpers ─────────────────────────────────────────────────────────

  Future<void> _setUserLoggedIn(bool loggedIn) async {
    final userId = _userIdController.text.trim();
    final coordinator = context.read<HealthSyncCoordinator>();
    await coordinator.setUserLoggedIn(
      loggedIn: loggedIn,
      userId: userId.isNotEmpty ? userId : null,
      configureBackground: loggedIn,
    );
  }

  /// Idempotent; same as after login.
  Future<void> _configureBgDelivery() async {
    await context.read<HealthSyncCoordinator>().ensureBackgroundDeliveryConfigured();
  }

  DateTime _getStartDate() {
    final now = DateTime.now();
    switch (_selectedRange) {
      case 'Last 24 hours':
        return now.subtract(const Duration(hours: 24));
      case 'Last 3 days':
        return now.subtract(const Duration(days: 3));
      case 'Last 7 days':
        return now.subtract(const Duration(days: 7));
      case 'Custom':
        return _customStartDate ?? now.subtract(const Duration(hours: 24));
      default:
        return now.subtract(const Duration(hours: 24));
    }
  }

  DateTime _getEndDate() {
    if (_selectedRange == 'Custom' && _customEndDate != null) {
      return _customEndDate!;
    }
    return DateTime.now();
  }

  Future<void> _fetchSleepData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _sleepManager.getSleepData(
        startDate: _getStartDate(),
        endDate: _getEndDate(),
      );
      setState(() {
        _sleepData = response;
        _isLoading = false;
      });
    } on SleepDataException catch (e) {
      print(e);
      setState(() {
        _error = '${e.code}: ${e.message}';
        _isLoading = false;
      });
    } catch (e) {
      print(e);
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _selectCustomDateRange() async {
    final now = DateTime.now();
    final pickedStart = await showDatePicker(
      context: context,
      initialDate: _customStartDate ?? now.subtract(const Duration(days: 1)),
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      helpText: 'Select start date',
    );

    if (pickedStart == null || !mounted) return;

    final pickedEnd = await showDatePicker(
      context: context,
      initialDate: _customEndDate ?? now,
      firstDate: pickedStart,
      lastDate: now,
      helpText: 'Select end date',
    );

    if (pickedEnd == null || !mounted) return;

    setState(() {
      _customStartDate = pickedStart;
      _customEndDate = pickedEnd.add(
        const Duration(hours: 23, minutes: 59, seconds: 59),
      );
      _selectedRange = 'Custom';
    });
    _fetchSleepData();
  }

  // MARK: - Live Monitoring

  Future<void> _toggleMonitoring() async {
    if (_isMonitoring) {
      await _stopMonitoring();
    } else {
      await _startMonitoring();
    }
  }

  Future<void> _startMonitoring() async {
    try {
      final result = await _sleepManager.startMonitoring(
        startDate: _getStartDate(),
      );

      setState(() {
        _isMonitoring = true;
      });

      print('🛏️ Started monitoring: $result');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Monitoring started')));
      }
    } catch (e) {
      print('🛏️ Error starting monitoring: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _stopMonitoring() async {
    try {
      await _sleepManager.stopMonitoring();

      setState(() {
        _isMonitoring = false;
      });

      print('🛏️ Stopped monitoring');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Monitoring stopped')));
      }
    } catch (e) {
      print('🛏️ Error stopping monitoring: $e');
    }
  }

  Future<void> _fetchStoredData() async {
    try {
      final storedData = await _sleepManager.fetchStoredSleepData();
      setState(() {
        _sleepData = storedData;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded ${storedData.sampleCount} stored samples'),
          ),
        );
      }
    } catch (e) {
      print('🛏️ Error fetching stored data: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sleep Data'),
        actions: [
          // Monitoring toggle
          IconButton(
            icon: Icon(
              _isMonitoring ? Icons.stop_circle : Icons.play_circle,
              color: _isMonitoring ? Colors.red : null,
            ),
            onPressed: _toggleMonitoring,
            tooltip: _isMonitoring ? 'Stop monitoring' : 'Start monitoring',
          ),
          // Fetch stored data (from background)
          IconButton(
            icon: const Icon(Icons.storage),
            onPressed: _fetchStoredData,
            tooltip: 'Fetch stored data',
          ),
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: _selectCustomDateRange,
            tooltip: 'Select custom date range',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchSleepData,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTestSetupCard(),
          _buildDateRangeSelector(),
          if (_isMonitoring) _buildMonitoringBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // ── Test Setup Card ───────────────────────────────────────────────────────

  Widget _buildTestSetupCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🧪 Background Delivery Test Setup',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _userIdController,
              decoration: const InputDecoration(
                labelText: 'Test User ID',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.login, size: 16),
                    label: const Text('Set Logged In'),
                    onPressed: () => _setUserLoggedIn(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.logout, size: 16),
                    label: const Text('Set Logged Out'),
                    onPressed: () => _setUserLoggedIn(false),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                ),
              ],
            ),
            Consumer<HealthSyncCoordinator>(
              builder: (context, coordinator, _) {
                final session = coordinator.sessionStatus;
                final bg = coordinator.backgroundDeliveryStatus;
                final err = coordinator.lastError;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (session != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        session,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.cloud_upload, size: 16),
                        label: const Text('Re-apply background config (idempotent)'),
                        onPressed: _configureBgDelivery,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                    if (bg != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        bg,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                    if (err != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        err,
                        style: const TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Sleep API: ${HealthSyncCoordinator.defaultSleepLogsApiUrl}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonitoringBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: Colors.green.shade100,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Live monitoring active - new sleep data will appear automatically',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateRangeSelector() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final range in [
              'Last 24 hours',
              'Last 3 days',
              'Last 7 days',
              'Custom',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: ChoiceChip(
                  label: Text(
                    range == 'Custom' && _customStartDate != null
                        ? '${_customStartDate!.month}/${_customStartDate!.day} - ${_customEndDate!.month}/${_customEndDate!.day}'
                        : range,
                  ),
                  selected: _selectedRange == range,
                  onSelected: (selected) {
                    if (selected) {
                      if (range == 'Custom') {
                        _selectCustomDateRange();
                      } else {
                        setState(() => _selectedRange = range);
                        _fetchSleepData();
                      }
                    }
                  },
                ),
              ),
          ],
        ),
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
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Error fetching sleep data',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _fetchSleepData,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_sleepData == null || !_sleepData!.hasSleepData) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bedtime_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No sleep data found'),
            const SizedBox(height: 8),
            const Text(
              'Sleep data from the last 24 hours will appear here',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchSleepData,
              child: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchSleepData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSummaryCard(),
            const SizedBox(height: 16),
            _buildStageBreakdownCard(),
            const SizedBox(height: 16),
            _buildSamplesSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final data = _sleepData!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bedtime, color: Colors.indigo),
                const SizedBox(width: 8),
                Text(
                  'Sleep Summary',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(),
            _buildStatRow(
              'Total Sleep',
              '${data.totalSleepHours.toStringAsFixed(1)} hours',
              Icons.access_time,
            ),
            _buildStatRow('Samples', '${data.sampleCount}', Icons.list),
            _buildStatRow(
              'Time Range',
              '${_formatTime(data.fetchedFrom)} - ${_formatTime(data.fetchedTo)}',
              Icons.date_range,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageBreakdownCard() {
    final totals = _sleepData!.stageTotals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bar_chart, color: Colors.purple),
                const SizedBox(width: 8),
                Text(
                  'Sleep Stages',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(),
            _buildStageRow(
              'Deep Sleep',
              totals.asleepDeepMinutes,
              Colors.indigo,
            ),
            _buildStageRow('REM Sleep', totals.asleepREMMinutes, Colors.purple),
            _buildStageRow('Core Sleep', totals.asleepCoreMinutes, Colors.blue),
            _buildStageRow('Awake', totals.awakeMinutes, Colors.orange),
            _buildStageRow('In Bed', totals.inBedMinutes, Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildStageRow(String label, double minutes, Color color) {
    final totalMinutes =
        _sleepData!.stageTotals.totalSleepMinutes +
        _sleepData!.stageTotals.awakeMinutes +
        _sleepData!.stageTotals.inBedMinutes;
    final percentage = totalMinutes > 0 ? (minutes / totalMinutes) * 100 : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text(
            '${minutes.toStringAsFixed(0)} min',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 50,
            child: Text(
              '${percentage.toStringAsFixed(0)}%',
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSamplesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.list_alt, color: Colors.teal),
            const SizedBox(width: 8),
            Text(
              'Individual Samples',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._sleepData!.samples.map((sample) => _buildSampleCard(sample)),
      ],
    );
  }

  Widget _buildSampleCard(SleepSample sample) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          _getStageIcon(sample.sleepStage),
          color: _getStageColor(sample.sleepStage),
        ),
        title: Text(
          _formatStageName(sample.sleepStage),
          style: TextStyle(
            color: _getStageColor(sample.sleepStage),
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          '${sample.durationMinutes.toStringAsFixed(0)} min • ${sample.sourceName ?? 'Unknown source'}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow('Start', _formatDateTime(sample.startDate)),
                _buildDetailRow('End', _formatDateTime(sample.endDate)),
                _buildDetailRow(
                  'Duration',
                  '${sample.durationMinutes.toStringAsFixed(1)} minutes',
                ),
                _buildDetailRow('Source', sample.sourceName ?? 'Unknown'),
                _buildDetailRow('Bundle', sample.sourceBundle ?? 'Unknown'),
                if (sample.device != null) ...[
                  _buildDetailRow('Device', sample.device!.name ?? 'Unknown'),
                  _buildDetailRow('Model', sample.device!.model ?? 'Unknown'),
                ],
                const Divider(),
                ExpansionTile(
                  title: const Text('Raw JSON'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        _formatJson(sample.rawJson),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Color _getStageColor(String stage) {
    switch (stage) {
      case 'asleepDeep':
        return Colors.indigo;
      case 'asleepREM':
        return Colors.purple;
      case 'asleepCore':
        return Colors.blue;
      case 'awake':
        return Colors.orange;
      case 'inBed':
        return Colors.grey;
      default:
        return Colors.teal;
    }
  }

  IconData _getStageIcon(String stage) {
    switch (stage) {
      case 'asleepDeep':
        return Icons.nights_stay;
      case 'asleepREM':
        return Icons.auto_awesome;
      case 'asleepCore':
        return Icons.bedtime;
      case 'awake':
        return Icons.wb_sunny;
      case 'inBed':
        return Icons.bed;
      default:
        return Icons.help_outline;
    }
  }

  String _formatStageName(String stage) {
    switch (stage) {
      case 'asleepDeep':
        return 'Deep Sleep';
      case 'asleepREM':
        return 'REM Sleep';
      case 'asleepCore':
        return 'Core Sleep';
      case 'asleepUnspecified':
        return 'Asleep';
      case 'awake':
        return 'Awake';
      case 'inBed':
        return 'In Bed';
      default:
        return stage;
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${_formatTime(dt)}';
  }

  String _formatJson(Map<String, dynamic> json) {
    // Simple JSON formatting
    final buffer = StringBuffer();
    _formatJsonValue(json, buffer, 0);
    return buffer.toString();
  }

  void _formatJsonValue(dynamic value, StringBuffer buffer, int indent) {
    final indentStr = '  ' * indent;
    if (value is Map) {
      buffer.writeln('{');
      final entries = value.entries.toList();
      for (int i = 0; i < entries.length; i++) {
        buffer.write('$indentStr  "${entries[i].key}": ');
        _formatJsonValue(entries[i].value, buffer, indent + 1);
        if (i < entries.length - 1) buffer.write(',');
        buffer.writeln();
      }
      buffer.write('$indentStr}');
    } else if (value is List) {
      buffer.writeln('[');
      for (int i = 0; i < value.length; i++) {
        buffer.write('$indentStr  ');
        _formatJsonValue(value[i], buffer, indent + 1);
        if (i < value.length - 1) buffer.write(',');
        buffer.writeln();
      }
      buffer.write('$indentStr]');
    } else if (value is String) {
      buffer.write('"$value"');
    } else {
      buffer.write('$value');
    }
  }
}
