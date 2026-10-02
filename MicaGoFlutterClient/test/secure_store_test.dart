import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/storage/secure_store.dart';

class _SlowSecurePlatform extends TestFlutterSecureStoragePlatform {
  _SlowSecurePlatform() : super({});
  bool failWrite = false;
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (failWrite) throw StateError('Keystore unavailable');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await super.write(key: key, value: value, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SlowSecurePlatform secure;
  late SharedPreferencesAsync prefs;
  late SecureStore store;
  setUp(() {
    final oldSecure = FlutterSecureStoragePlatform.instance;
    final oldPrefs = SharedPreferencesAsyncPlatform.instance;
    addTearDown(() {
      FlutterSecureStoragePlatform.instance = oldSecure;
      SharedPreferencesAsyncPlatform.instance = oldPrefs;
    });
    secure = _SlowSecurePlatform();
    FlutterSecureStoragePlatform.instance = secure;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    prefs = SharedPreferencesAsync();
    store = SecureStore(fallback: prefs);
  });
  final profile = ConnectionProfile(
    baseUrl: 'https://relay.example',
    token: 'test-secret',
    deviceId: 'test-device',
  );
  test(
    'slow Keystore initialization saves securely without the old 900ms failure',
    () async {
      await store.saveProfile(profile);
      expect((await store.loadProfile())!.deviceId, 'test-device');
      expect(await prefs.getKeys(), isEmpty);
    },
  );
  test('Keystore failure never persists a plaintext credential', () async {
    secure.failWrite = true;
    await expectLater(
      store.saveProfile(profile),
      throwsA(isA<CredentialStorageException>()),
    );
    expect(secure.data, isEmpty);
    expect(await prefs.getKeys(), isEmpty);
  });
}
