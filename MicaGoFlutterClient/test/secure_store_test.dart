import 'package:micago_credential_storage/micago_credential_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
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
  bool failRsa = false;
  bool corruptReads = false;
  final aesData = <String, String>{};
  bool _aes(Map<String, String> options) =>
      options['storageNamespace'] == 'micago_credentials_aes_v1';
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (corruptReads) return null;
    return (_aes(options) ? aesData : data)[key];
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    (_aes(options) ? aesData : data).remove(key);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (failWrite || (failRsa && !_aes(options))) {
      throw StateError('Keystore unavailable');
    }
    if (_aes(options)) {
      aesData[key] = value;
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await super.write(key: key, value: value, options: options);
  }
}

class _SoftwareStore extends SoftwareCredentialStorage {
  String? value;
  bool fail = false;
  int probes = 0;
  @override
  Future<void> probe() async {
    probes++;
    if (fail) throw StateError('unavailable');
  }

  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String raw) async {
    if (fail) throw StateError('unavailable');
    value = raw;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SlowSecurePlatform secure;
  late SharedPreferencesAsync prefs;
  late SecureStore store;
  late _SoftwareStore software;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
    software = _SoftwareStore();
    store = SecureStore(fallback: prefs, software: software);
  });
  final profile = ConnectionProfile(
    baseUrl: 'https://relay.example',
    token: 'test-secret',
    deviceId: 'test-device',
  );
  test(
    'preflight failure requires consent and cancellation stores no credential',
    () async {
      secure.failWrite = true;
      await expectLater(
        store.prepareCredentialStorage(),
        throwsA(isA<CompatibilityStorageRequired>()),
      );
      await expectLater(
        store.prepareCredentialStorage(confirmCompatibility: () async => false),
        throwsA(isA<CompatibilityStorageRequired>()),
      );
      expect(await store.compatibilityStorageEnabled(), false);
      expect(software.value, isNull);
      expect(software.probes, 0);
    },
  );
  test(
    'explicit software opt-in survives restart and rejection prevents restoration',
    () async {
      secure.failWrite = true;
      var prompts = 0;
      await store.prepareCredentialStorage(
        confirmCompatibility: () async {
          prompts++;
          return true;
        },
      );
      await store.saveProfile(profile);
      expect(await store.compatibilityStorageEnabled(), true);
      expect(secure.data, isEmpty);
      expect(secure.aesData, isEmpty);
      expect(
        await prefs.getString(
          'micago.secure_fallback.micago.connection_profile.v1',
        ),
        isNull,
      );
      final restarted = SecureStore(fallback: prefs, software: software);
      await restarted.prepareCredentialStorage(
        confirmCompatibility: () async {
          prompts++;
          return true;
        },
      );
      expect(prompts, 1);
      expect((await restarted.loadProfile())!.token, profile.token);
      await restarted.writeValue('micago.credential_rejected.v1', '1');
      expect(await restarted.loadProfile(), isNull);
      await restarted.clearProfile();
      expect(software.value, isNull);
    },
  );
  test(
    'selected software mode never resurrects RSA or AES credentials',
    () async {
      await store.saveProfile(profile);
      secure.failWrite = true;
      await store.prepareCredentialStorage(
        confirmCompatibility: () async => true,
      );
      software.value = '{corrupt';
      expect(await store.loadProfile(), isNull);
      software.value = null;
      expect(await store.loadProfile(), isNull);
      await store.clearProfile();
      expect(secure.data, isEmpty);
      expect(secure.aesData, isEmpty);
    },
  );
  test(
    'software storage failure does not select compatibility or activate',
    () async {
      secure.failWrite = true;
      software.fail = true;
      await expectLater(
        store.prepareCredentialStorage(confirmCompatibility: () async => true),
        throwsStateError,
      );
      expect(await store.compatibilityStorageEnabled(), false);
    },
  );

  test(
    'slow Keystore initialization saves securely without the old 900ms failure',
    () async {
      await store.saveProfile(profile);
      expect((await store.loadProfile())!.deviceId, 'test-device');
      expect(await prefs.getKeys(), {'micago.credential_aes_backend.v1'});
    },
  );
  test(
    'persisted rejection marker prevents restoring the old profile',
    () async {
      await store.saveProfile(profile);
      await store.writeValue('micago.credential_rejected.v1', '1');
      expect(await store.loadProfile(), isNull);
    },
  );

  test(
    'RSA provider failure uses isolated AES and restores after restart',
    () async {
      secure.failRsa = true;
      await store.saveProfile(profile);
      expect(secure.data, isEmpty);
      expect(secure.aesData, isNotEmpty);
      expect(await prefs.getBool('micago.credential_aes_backend.v1'), true);
      final restarted = SecureStore(fallback: prefs);
      expect((await restarted.loadProfile())!.token, profile.token);
      await restarted.clearProfile();
      expect(await restarted.loadProfile(), isNull);
      expect(secure.aesData, isEmpty);
    },
  );

  test('selected AES store never resurrects an older RSA credential', () async {
    await store.saveProfile(profile);
    await prefs.setBool('micago.credential_aes_backend.v1', true);
    expect(await store.loadProfile(), isNull);
  });

  test('write must be verified by an exact read before activation', () async {
    secure.corruptReads = true;
    await expectLater(
      store.saveProfile(profile),
      throwsA(isA<CredentialStorageException>()),
    );
    expect(await prefs.getKeys(), isEmpty);
  });

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
