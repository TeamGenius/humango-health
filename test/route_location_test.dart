import 'package:flutter_test/flutter_test.dart';
import 'package:humango_health/src/models/workout_data.dart';

void main() {
  test('an altitude-only point keeps no position', () {
    final point = RouteLocation.fromJson({
      'timestamp': '2026-11-02T10:00:00.000Z',
      'altitude': 12.5,
    });

    expect(point.latitude, isNull);
    expect(point.longitude, isNull);
    expect(point.hasPosition, isFalse);
    expect(point.altitude, 12.5);
  });

  test('a GPS point keeps its position', () {
    final point = RouteLocation.fromJson({
      'timestamp': '2026-11-02T10:00:00.000Z',
      'latitude': 40.0,
      'longitude': -105.0,
      'altitude': 1600.0,
    });

    expect(point.hasPosition, isTrue);
    expect(point.latitude, 40.0);
  });
}
