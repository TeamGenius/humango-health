/// Delivery mode for sleep background data.
///
/// - [api]: Sleep session data is POSTed directly to a remote API.
///   Both foreground (`HKAnchoredObjectQueryDescriptor`) and background (`HKObserverQuery`)
///   still run — samples are accumulated into session state and delivered via API
///   when the session ends. Individual samples are NOT pushed to EventChannel.
/// - [localStorage]: Default behavior — foreground uses EventChannel streaming,
///   background stores to UserDefaults for later retrieval.
enum SleepBackgroundDeliveryMode {
  /// API mode: finalized sleep sessions are POSTed to the configured endpoint.
  /// Foreground and background queries both run normally —
  /// samples accumulate into session state instead of being pushed to EventChannel.
  api,

  /// Local storage mode (default): normal foreground streaming + background storage.
  localStorage,
}

/// Configuration for sleep background delivery.
///
/// Use with [SleepDataManager.configureSleepBackgroundDelivery] to control
/// how finalized sleep session data is delivered.
///
/// Example:
/// ```dart
/// await sleepManager.configureSleepBackgroundDelivery(
///   SleepBackgroundDeliveryConfig(
///     mode: SleepBackgroundDeliveryMode.api,
///     apiURL: 'https://api.example.com/sleep-sessions',
///     headers: {'Authorization': 'Bearer token123'},
///   ),
/// );
/// ```
class SleepBackgroundDeliveryConfig {
  /// The delivery mode: `.api` or `.localStorage`.
  final SleepBackgroundDeliveryMode mode;

  /// The API endpoint URL for sleep session delivery (required for `.api` mode).
  final String? apiURL;

  /// Custom HTTP headers for API requests (e.g., authorization tokens).
  final Map<String, String>? headers;

  SleepBackgroundDeliveryConfig({
    required this.mode,
    this.apiURL,
    this.headers,
  });

  /// Converts to a JSON map for method channel communication.
  Map<String, dynamic> toJson() {
    return {'mode': mode.name, 'apiURL': apiURL, 'headers': headers ?? {}};
  }

  /// Creates from a JSON map.
  factory SleepBackgroundDeliveryConfig.fromJson(Map<String, dynamic> json) {
    return SleepBackgroundDeliveryConfig(
      mode: SleepBackgroundDeliveryMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => SleepBackgroundDeliveryMode.localStorage,
      ),
      apiURL: json['apiURL'],
      headers: (json['headers'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v.toString()),
      ),
    );
  }
}
