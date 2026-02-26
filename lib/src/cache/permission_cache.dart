//
//  permission_cache.dart
//  humango_health
//

import '../models/health_data_type.dart';
import '../models/health_kit_authorization_result.dart';

/// Dart-layer authorization cache to prevent spamming Native HealthKit `getRequestStatusForAuthorization` calls.
/// iOS specifically warns against calling this frequently as it blocks slightly internally.
class PermissionCache {
  static final PermissionCache _instance = PermissionCache._internal();
  factory PermissionCache() => _instance;
  PermissionCache._internal();

  HealthKitAuthorizationResult? _lastKnownResult;
  DateTime? _lastFetchTime;
  static const Duration _cacheTtl = Duration(minutes: 5);

  /// Caches the given authorization result.
  void captureResult(HealthKitAuthorizationResult result) {
    _lastKnownResult = result;
    _lastFetchTime = DateTime.now();
  }

  /// Returns the cached result if still valid (under 5 minutes old), otherwise null.
  HealthKitAuthorizationResult? get validCache {
    if (_lastKnownResult == null || _lastFetchTime == null) return null;
    
    if (DateTime.now().difference(_lastFetchTime!) > _cacheTtl) {
      // Cache expired
      return null;
    }

    return _lastKnownResult;
  }

  /// Invalidates the cache immediately.
  void invalidate() {
    _lastKnownResult = null;
    _lastFetchTime = null;
  }
}
