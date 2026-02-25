import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'humango_health_platform_interface.dart';

/// An implementation of [HumangoHealthPlatform] that uses method channels.
class MethodChannelHumangoHealth extends HumangoHealthPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('humango_health');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
