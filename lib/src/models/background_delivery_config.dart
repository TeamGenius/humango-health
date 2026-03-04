enum BackgroundDeliveryMode { api, localStorage }

class BackgroundDeliveryConfig {
  final BackgroundDeliveryMode mode;
  final String? apiURL;
  final Map<String, String>? headers;

  BackgroundDeliveryConfig({
    required this.mode,
    this.apiURL,
    this.headers,
  });

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'apiURL': apiURL,
      'headers': headers ?? {},
    };
  }

  factory BackgroundDeliveryConfig.fromJson(Map<String, dynamic> json) {
    return BackgroundDeliveryConfig(
      mode: BackgroundDeliveryMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => BackgroundDeliveryMode.localStorage,
      ),
      apiURL: json['apiURL'],
      headers: (json['headers'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, v.toString()),
      ),
    );
  }
}
