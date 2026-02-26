enum PermissionStatus {
  notDetermined,  // Never asked
  authorized,     // Permission granted
  denied,         // Permission explicitly denied
  restricted      // OS restriction
}

extension PermissionStatusExtension on PermissionStatus {
  String get name {
    switch (this) {
      case PermissionStatus.notDetermined: return 'notDetermined';
      case PermissionStatus.authorized: return 'authorized';
      case PermissionStatus.denied: return 'denied';
      case PermissionStatus.restricted: return 'restricted';
    }
  }

  static PermissionStatus fromString(String status) {
    switch (status) {
      case 'authorized': return PermissionStatus.authorized;
      case 'denied': return PermissionStatus.denied;
      case 'restricted': return PermissionStatus.restricted;
      case 'notDetermined':
      case 'unknown':
      default:
        return PermissionStatus.notDetermined;
    }
  }
}
