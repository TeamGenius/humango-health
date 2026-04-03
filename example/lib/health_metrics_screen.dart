import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

class HealthMetricsScreen extends StatefulWidget {
  const HealthMetricsScreen({super.key});
  @override
  State<HealthMetricsScreen> createState() => _HealthMetricsScreenState();
}

class _HealthMetricsScreenState extends State<HealthMetricsScreen>
    with WidgetsBindingObserver {
  final HealthMetricsManager _metricsManager = HealthMetricsManager();

  bool _isLoading = false;
  String? _error;
  AllHealthMetricsResponse? _allMetrics;
  HealthMetricResponse? _selectedDetail;

  String _selectedRange = 'Last 30 days';
  DateTime? _customStartDate;
  DateTime? _customEndDate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchAllMetrics();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetchAllMetrics();
    }
  }

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

  Future<void> _fetchAllMetrics() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _metricsManager.getAllMetrics(
        startDate: _getStartDate(),
        endDate: _getEndDate(),
      );
      setState(() {
        _allMetrics = response;
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

  Future<void> _fetchSingleMetric(HealthMetricType type) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _metricsManager.getMetric(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Metrics'),
        actions: [
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
      ),
      body: Column(
        children: [
          _buildDateRangeSelector(),
          Expanded(child: _buildBody()),
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

  Widget _buildBody() {
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

  // ---------------------------------------------------------------------------
  // Overview – card per metric
  // ---------------------------------------------------------------------------

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
                        'Latest: ${_formatValue(type, response.latestValue)} ${response.unit}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${response.sampleCount} samples  •  '
                        'Avg: ${_formatValue(type, response.statistics.average)} ${response.unit}',
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

  // ---------------------------------------------------------------------------
  // Detail view – single metric with all samples
  // ---------------------------------------------------------------------------

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
              '${_formatValue(type, stats.average)} ${response.unit}',
              Icons.trending_flat,
            ),
            _buildStatRow(
              'Min',
              '${_formatValue(type, stats.min)} ${response.unit}',
              Icons.arrow_downward,
            ),
            _buildStatRow(
              'Max',
              '${_formatValue(type, stats.max)} ${response.unit}',
              Icons.arrow_upward,
            ),
            _buildStatRow('Samples', '${response.sampleCount}', Icons.list),
            _buildStatRow(
              'Date Range',
              '${_formatDate(response.fetchedFrom)} – ${_formatDate(response.fetchedTo)}',
              Icons.date_range,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSampleTile(HealthMetricSample sample, HealthMetricType? type) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: CircleAvatar(
          radius: 16,
          child: Text(
            _formatValue(type, sample.value),
            style: const TextStyle(fontSize: 10),
          ),
        ),
        title: Text(
          '${_formatValue(type, sample.value)} ${sample.unit}',
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          '${_formatDateTime(sample.startDate)} • ${sample.sourceName ?? "Unknown"}',
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow('UUID', sample.uuid),
                _buildDetailRow('Start', _formatDateTime(sample.startDate)),
                _buildDetailRow('End', _formatDateTime(sample.endDate)),
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

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
      padding: const EdgeInsets.symmetric(vertical: 2),
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

  String _formatValue(HealthMetricType? type, double value) {
    if (type == HealthMetricType.bodyFatPercentage) {
      // HealthKit stores as 0-1 fraction, display as %
      return (value * 100).toStringAsFixed(1);
    }
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(1);
  }

  String _formatDate(DateTime dt) {
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
