class WorkoutStoreRecord {
  final String deviceActivityId;
  final String dataHash;
  final int dataSize;
  final bool pushed;
  final DateTime? firstSeen;
  final DateTime lastUpdated;

  WorkoutStoreRecord({
    required this.deviceActivityId,
    required this.dataHash,
    required this.dataSize,
    required this.pushed,
    this.firstSeen,
    required this.lastUpdated,
  });

  factory WorkoutStoreRecord.fromMap(Map<String, dynamic> map) {
    return WorkoutStoreRecord(
      deviceActivityId: map['deviceActivityId'] as String,
      dataHash: map['dataHash'] as String,
      dataSize: map['dataSize'] as int,
      pushed: map['pushed'] as bool,
      firstSeen: map['firstSeenISO'] != null
          ? DateTime.parse(map['firstSeenISO'] as String)
          : null,
      lastUpdated: DateTime.parse(map['lastUpdatedISO'] as String),
    );
  }

  Map<String, dynamic> toMap() => {
    'deviceActivityId': deviceActivityId,
    'dataHash': dataHash,
    'dataSize': dataSize,
    'pushed': pushed,
    'firstSeenISO': firstSeen?.toUtc().toIso8601String(),
    'lastUpdatedISO': lastUpdated.toUtc().toIso8601String(),
  };

  @override
  String toString() =>
      'WorkoutStoreRecord(id: $deviceActivityId, pushed: $pushed, size: ${dataSize}B, updated: $lastUpdated)';
}
