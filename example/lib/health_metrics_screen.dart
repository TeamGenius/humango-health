import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Log entry for Monitor tab
// ─────────────────────────────────────────────────────────────────────────────

class _LogEntry {
  final DateTime time;
  final String message;
  final bool isError;

  const _LogEntry({
    required this.time,
    required this.message,
    this.isError = false,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class HealthMetricsScreen extends StatefulWidget {
  const HealthMetricsScreen({super.key});
  @override
  State<HealthMetricsScreen> createState() => _HealthMetricsScreenState();
}

class _HealthMetricsScreenState extends State<HealthMetricsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final HealthMetricsManager _metricsManager = HealthMetricsManager();

  late final TabController _tabController;

  // ── Fetch tab ──────────────────────────────────────────────────────────────
  bool _isLoading = false;
  String? _error;
  AllHealthMetricsResponse? _allMetrics;
  HealthMetricResponse? _selectedDetail;

  String _selectedRange = 'Last 30 days';
  DateTime? _customStartDate;
  DateTime? _customEndDate;

  // ── Monitor tab ────────────────────────────────────────────────────────────
  final Set<HealthMetricType> _activeMonitors = {};
  final Map<HealthMetricType, HealthMetricResponse?> _todayPreviews = {};
  final Map<HealthMetricType, bool> _monitorLoading = {};
  final List<_LogEntry> _log = [];

  // ── Metric display config ──────────────────────────────────────────────────
  static const _metricConfig = <HealthMetricType, (IconData, Color)>{
    HealthMetricType.heartRateVariabilitySDNN: (
      Icons.monitor_heart,
      Colors.purple,
    ),
    HealthMetricType.restingHeartRate: (Icons.favorite, Colors.red),
    HealthMetricType.bodyFatPercentage: (Icons.percent, Colors.orange),
    HealthMetricType.bodyMass: (Icons.scale, Colors.blue),
    HealthMetricType.height: (Icons.height, Colors.teal),
  };

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _fetchAllMetrics();
  }

  @override
  void dispose() {
    _tabController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetchAllMetrics();
    }
  }

  // ── Date helpers ───────────────────────────────────────────────────────────

  DateTime _getStartDate() {
    final now = DateTime.now();
    switch (_selectedRange) {
      case 'Last 7 days':
        return now.subtract(const Duration(days: 7));
      case 'Last 30 days':
        return now.subtract(const Duration(days: 30));
      case 'Last 90 days':
        return now.subtract(const Duration(days: 90));
      case 'Last year':
        return now.subtract(const Duration(days: 365));
      case 'Custom':
        return _customStartDate ?? now.subtract(const Duration(days: 30));
      default:
        return now.subtract(const Duration(days: 30));
    }
  }

  DateTime _getEndDate() {
    if (_selectedRange == 'Custom' && _customEndDate != null) {
      return _customEndDate!;
    }
    return DateTime.now();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FETCH TAB – actions
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _fetchAllMetrics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final start = _getStartDate();
      final end = _getEndDate();
      final results = <String, HealthMetricResponse>{};
      final errors = <String, String>{};

      for (final type in HealthMetricType.values) {
        try {
          results[type.key] = await _metricsManager.fetchHealthMetric(
            type,
            startDate: start,
            endDate: end,
          );
        } on HealthMetricsException catch (e) {
          errors[type.key] = e.message;
        }
      }

      setState(() {
        _allMetrics = AllHealthMetricsResponse(
          metrics: results,
          errors: errors,
          fetchedFrom: start,
          fetchedTo: end,
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchSingleMetric(HealthMetricType type) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _metricsManager.fetchHealthMetric(
        type,
        startDate: _getStartDate(),
        endDate: _getEndDate(),
      );
      setState(() {
        _selectedDetail = response;
        _isLoading = false;
      });
    } on HealthMetricsException catch (e) {
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

  Future<void> _selectCustomDateRange() async {
    final now = DateTime.now();
    final pickedStart = await showDatePicker(
      context: context,
      initialDate: _customStartDate ?? now.subtract(const Duration(days: 30)),
      firstDate: now.subtract(const Duration(days: 365 * 5)),
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
    _fetchAllMetrics();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MONITOR TAB – actions
  // ══════════════════════════════════════════════════════════════════════════

  void _addLog(String message, {bool isError = false}) {
    setState(() {
      _log.insert(
        0,
        _LogEntry(time: DateTime.now(), message: message, isError: isError),
      );
      if (_log.length > 50) _log.removeLast();
    });
  }

  Future<void> _startMonitor(HealthMetricType type) async {
    setState(() => _monitorLoading[type] = true);
    try {
      await _metricsManager.startMetricMonitoring(type);
      setState(() => _activeMonitors.add(type));
      _addLog('Started monitoring ${type.displayName}');
    } on HealthMetricsException catch (e) {
      _addLog('Start error [${type.displayName}]: ${e.message}', isError: true);
    } catch (e) {
      _addLog('Start error [${type.displayName}]: $e', isError: true);
    } finally {
      setState(() => _monitorLoading.remove(type));
    }
  }

  Future<void> _stopMonitor(HealthMetricType type) async {
    setState(() => _monitorLoading[type] = true);
    try {
      await _metricsManager.stopMetricMonitoring(type);
      setState(() {
        _activeMonitors.remove(type);
        _todayPreviews.remove(type);
      });
      _addLog('Stopped monitoring ${type.displayName}');
    } on HealthMetricsException catch (e) {
      _addLog('Stop error [${type.displayName}]: ${e.message}', isError: true);
    } catch (e) {
      _addLog('Stop error [${type.displayName}]: $e', isError: true);
    } finally {
      setState(() => _monitorLoading.remove(type));
    }
  }

  Future<void> _stopAllMonitors() async {
    try {
      await _metricsManager.stopAllMetricMonitoring();
      setState(() {
        _activeMonitors.clear();
        _todayPreviews.clear();
      });
      _addLog('Stopped all monitors');
    } on HealthMetricsException catch (e) {
      _addLog('Stop-all error: ${e.message}', isError: true);
    } catch (e) {
      _addLog('Stop-all error: $e', isError: true);
    }
  }

  /// Fetch today (midnight → now) to preview what onHealthMetricReady would deliver.
  Future<void> _fetchTodayPreview(HealthMetricType type) async {
    final startOfToday = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    try {
      final response = await _metricsManager.fetchHealthMetric(
        type,
        startDate: startOfToday,
        endDate: DateTime.now(),
      );
      setState(() => _todayPreviews[type] = response);
      _addLog(
        'Today preview [${type.displayName}]: ${response.sampleCount} samples'
        '${response.hasData ? ", latest ${_rawValue(response.latestValue)} ${response.unit}" : ""}',
      );
    } on HealthMetricsException catch (e) {
      _addLog(
        'Fetch-today error [${type.displayName}]: ${e.message}',
        isError: true,
      );
    } catch (e) {
      _addLog('Fetch-today error [${type.displayName}]: $e', isError: true);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Metrics'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.download), text: 'Fetch'),
            Tab(icon: Icon(Icons.sensors), text: 'Monitor'),
          ],
        ),
        actions: [
          // Fetch tab: back / calendar / refresh
          ListenableBuilder(
            listenable: _tabController,
            builder: (context, _) {
              if (_tabController.index == 0) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_selectedDetail != null)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => setState(() => _selectedDetail = null),
                        tooltip: 'Back to overview',
                      ),
                    IconButton(
                      icon: const Icon(Icons.calendar_today),
                      onPressed: _selectCustomDateRange,
                      tooltip: 'Select custom date range',
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _fetchAllMetrics,
                    ),
                  ],
                );
              }
              // Monitor tab
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.sensors_off),
                    onPressed: _activeMonitors.isEmpty
                        ? null
                        : _stopAllMonitors,
                    tooltip: 'Stop all monitors',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_sweep),
                    onPressed: () => setState(() => _log.clear()),
                    tooltip: 'Clear log',
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildFetchTab(), _buildMonitorTab()],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FETCH TAB
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildFetchTab() {
    return Column(
      children: [
        _buildDateRangeSelector(),
        Expanded(child: _buildFetchBody()),
      ],
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
              'Last 7 days',
              'Last 30 days',
              'Last 90 days',
              'Last year',
              'Custom',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: ChoiceChip(
                  label: Text(
                    range == 'Custom' && _customStartDate != null
                        ? '${_customStartDate!.month}/${_customStartDate!.day}'
                              ' – ${_customEndDate!.month}/${_customEndDate!.day}'
                        : range,
                  ),
                  selected: _selectedRange == range,
                  onSelected: (selected) {
                    if (selected) {
                      if (range == 'Custom') {
                        _selectCustomDateRange();
                      } else {
                        setState(() => _selectedRange = range);
                        _fetchAllMetrics();
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

  Widget _buildFetchBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('Error', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _fetchAllMetrics,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_selectedDetail != null) {
      return _buildDetailView(_selectedDetail!);
    }

    return _buildOverview();
  }

  // ── Overview ───────────────────────────────────────────────────────────────

  Widget _buildOverview() {
    if (_allMetrics == null) {
      return const Center(child: Text('No data loaded'));
    }

    return RefreshIndicator(
      onRefresh: _fetchAllMetrics,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildMetricCard(
            HealthMetricType.heartRateVariabilitySDNN,
            _allMetrics!.hrv,
            Icons.monitor_heart,
            Colors.purple,
          ),
          _buildMetricCard(
            HealthMetricType.restingHeartRate,
            _allMetrics!.restingHeartRate,
            Icons.favorite,
            Colors.red,
          ),
          _buildMetricCard(
            HealthMetricType.bodyFatPercentage,
            _allMetrics!.bodyFatPercentage,
            Icons.percent,
            Colors.orange,
          ),
          _buildMetricCard(
            HealthMetricType.bodyMass,
            _allMetrics!.weight,
            Icons.scale,
            Colors.blue,
          ),
          _buildMetricCard(
            HealthMetricType.height,
            _allMetrics!.height,
            Icons.height,
            Colors.teal,
          ),
          if (_allMetrics!.errors.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Errors',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final entry in _allMetrics!.errors.entries)
                      Text(
                        '${entry.key}: ${entry.value}',
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricCard(
    HealthMetricType type,
    HealthMetricResponse? response,
    IconData icon,
    Color color,
  ) {
    final hasData = response != null && response.hasData;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: hasData ? () => _fetchSingleMetric(type) : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (hasData) ...[
                      Text(
                        'Latest: ${_rawValue(response.latestValue)} ${response.unit}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${response.sampleCount} samples  •  '
                        'Avg: ${_rawValue(response.statistics.average)} ${response.unit}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ] else
                      Text(
                        'No data',
                        style: TextStyle(color: Colors.grey[400]),
                      ),
                  ],
                ),
              ),
              if (hasData) Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  // ── Detail view ────────────────────────────────────────────────────────────

  Widget _buildDetailView(HealthMetricResponse response) {
    final type = HealthMetricType.fromKey(response.metricType);
    return RefreshIndicator(
      onRefresh: () async {
        if (type != null) await _fetchSingleMetric(type);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatisticsCard(response),
          const SizedBox(height: 16),
          Text(
            'Samples (${response.sampleCount})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...response.samples.map((s) => _buildSampleTile(s, type)),
        ],
      ),
    );
  }

  Widget _buildStatisticsCard(HealthMetricResponse response) {
    final stats = response.statistics;
    final type = HealthMetricType.fromKey(response.metricType);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              type?.displayName ?? response.metricType,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Divider(),
            _buildStatRow(
              'Average',
              '${_rawValue(stats.average)} ${response.unit}',
              Icons.trending_flat,
            ),
            _buildStatRow(
              'Min',
              '${_rawValue(stats.min)} ${response.unit}',
              Icons.arrow_downward,
            ),
            _buildStatRow(
              'Max',
              '${_rawValue(stats.max)} ${response.unit}',
              Icons.arrow_upward,
            ),
            _buildStatRow(
              'Sum',
              '${_rawValue(stats.sum)} ${response.unit}',
              Icons.functions,
            ),
            _buildStatRow('Samples', '${response.sampleCount}', Icons.list),
            _buildStatRow(
              'From',
              _formatDateTimeFull(response.fetchedFrom),
              Icons.calendar_today,
            ),
            _buildStatRow(
              'To',
              _formatDateTimeFull(response.fetchedTo),
              Icons.event,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSampleTile(HealthMetricSample sample, HealthMetricType? type) {
    final duration = sample.endDate.difference(sample.startDate);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: CircleAvatar(
          radius: 16,
          child: Text(
            _rawValue(sample.value),
            style: const TextStyle(fontSize: 9),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        title: Text(
          '${_rawValue(sample.value)} ${sample.unit}',
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          '${_formatDateTimeFull(sample.startDate)} • ${sample.sourceName ?? "Unknown"}',
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow('UUID', sample.uuid),
                _buildDetailRow('Start', _formatDateTimeFull(sample.startDate)),
                _buildDetailRow('End', _formatDateTimeFull(sample.endDate)),
                _buildDetailRow('Duration', _formatDuration(duration)),
                _buildDetailRow('Source', sample.sourceName ?? 'Unknown'),
                _buildDetailRow('Bundle', sample.sourceBundle ?? 'Unknown'),
                if (sample.device != null) ...[
                  _buildDetailRow('Device', sample.device!.name ?? 'Unknown'),
                  _buildDetailRow('Model', sample.device!.model ?? 'Unknown'),
                ],
                if (sample.metadata != null && sample.metadata!.isNotEmpty) ...[
                  const Divider(),
                  const Text(
                    'Metadata',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  for (final entry in sample.metadata!.entries)
                    _buildDetailRow(entry.key, '${entry.value}'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // MONITOR TAB
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildMonitorTab() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final type in HealthMetricType.values)
                _buildMonitorCard(type),
              const SizedBox(height: 8),
              _buildActionLog(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMonitorCard(HealthMetricType type) {
    final isActive = _activeMonitors.contains(type);
    final isLoading = _monitorLoading[type] == true;
    final preview = _todayPreviews[type];
    final cfg = _metricConfig[type];
    final color = cfg?.$2 ?? Colors.grey;
    final icon = cfg?.$1 ?? Icons.monitor_heart;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isActive ? BorderSide(color: color, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.15),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      if (isActive)
                        Text(
                          'Active',
                          style: TextStyle(
                            fontSize: 12,
                            color: color,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      else
                        Text(
                          'Inactive',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[400],
                          ),
                        ),
                    ],
                  ),
                ),
                if (isLoading)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  if (!isActive)
                    TextButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Start'),
                      onPressed: () => _startMonitor(type),
                      style: TextButton.styleFrom(foregroundColor: color),
                    )
                  else
                    TextButton.icon(
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('Stop'),
                      onPressed: () => _stopMonitor(type),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                ],
              ],
            ),
            // Fetch Today preview button + result
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.today, size: 16),
                    label: const Text('Fetch Today'),
                    onPressed: () => _fetchTodayPreview(type),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: color.withValues(alpha: 0.5)),
                      foregroundColor: color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (preview != null)
                    Expanded(
                      child: Text(
                        preview.hasData
                            ? '${preview.sampleCount} samples today'
                                  ' | latest ${_rawValue(preview.latestValue)} ${preview.unit}'
                            : 'No samples today',
                        style: TextStyle(
                          fontSize: 12,
                          color: preview.hasData ? color : Colors.grey[400],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            // Expandable today samples
            if (preview != null && preview.hasData)
              ExpansionTile(
                dense: true,
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${preview.sampleCount} today sample(s)  '
                  '| avg ${_rawValue(preview.statistics.average)} ${preview.unit}',
                  style: const TextStyle(fontSize: 12),
                ),
                children: preview.samples
                    .map((s) => _buildSampleTile(s, type))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionLog() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Action Log',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${_log.length} entries',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const Divider(),
            if (_log.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No actions yet',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              for (final entry in _log)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _formatLogTime(entry.time),
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.message,
                          style: TextStyle(
                            fontSize: 12,
                            color: entry.isError ? Colors.red : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SHARED HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Text(label),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  // ── Formatters ─────────────────────────────────────────────────────────────

  /// Raw value with up to 6 decimal places; trailing zeros stripped.
  /// Verifies no rounding at any layer.
  String _rawValue(double v) {
    final s = v.toStringAsFixed(6);
    final trimmed = s.contains('.')
        ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
        : s;
    return trimmed;
  }

  String _formatDateTimeFull(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${_p(local.month)}-${_p(local.day)} '
        '${_p(local.hour)}:${_p(local.minute)}:${_p(local.second)}';
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60)
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }

  String _formatLogTime(DateTime dt) {
    final local = dt.toLocal();
    return '${_p(local.hour)}:${_p(local.minute)}:${_p(local.second)}';
  }

  String _p(int n) => n.toString().padLeft(2, '0');
}
