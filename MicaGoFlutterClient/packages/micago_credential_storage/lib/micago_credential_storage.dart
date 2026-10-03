import 'package:flutter/services.dart';

/// Only used after the user accepts the reduced protection on this device.
/// Android's no-backup directory holds a Tink keyset and encrypted payload.
class SoftwareCredentialStorage {
  static const _channel = MethodChannel('micago/software_credentials');
  Future<void> probe() => _channel.invokeMethod<void>('probe');
  Future<String?> read() => _channel.invokeMethod<String>('read');
  Future<void> write(String value) =>
      _channel.invokeMethod<void>('write', value);
  Future<void> delete() => _channel.invokeMethod<void>('delete');
}
