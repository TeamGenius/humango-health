import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humango_health/humango_health.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.humango.workouts/read');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('fetchPushedWorkoutIds returns the native IDs', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'fetchPushedWorkoutIds');
      return ['A', 'B'];
    });

    expect(await WorkoutReadManager().fetchPushedWorkoutIds(), ['A', 'B']);
  });

  test(
    'fetchPushedWorkoutIds returns empty when native returns null',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);

      expect(await WorkoutReadManager().fetchPushedWorkoutIds(), isEmpty);
    },
  );
}
