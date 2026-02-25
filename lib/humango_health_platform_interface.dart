import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'humango_health_method_channel.dart';

abstract class HumangoHealthPlatform extends PlatformInterface {
  /// Constructs a HumangoHealthPlatform.
  HumangoHealthPlatform() : super(token: _token);

  static final Object _token = Object();

  static HumangoHealthPlatform _instance = MethodChannelHumangoHealth();

  /// The default instance of [HumangoHealthPlatform] to use.
  ///
  /// Defaults to [MethodChannelHumangoHealth].
  static HumangoHealthPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [HumangoHealthPlatform] when
  /// they register themselves.
  static set instance(HumangoHealthPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
