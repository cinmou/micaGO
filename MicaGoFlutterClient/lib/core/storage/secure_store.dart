import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:micago_credential_storage/micago_credential_storage.dart';

import '../models/connection_profile.dart';

/// Persists the connection profile. The bearer token is stored with
/// [FlutterSecureStorage], or explicitly opted-in Android software encryption.
/// Profiles are never written to plain SharedPreferences or logged.
class CredentialStorageException implements Exception {
  const CredentialStorageException();
  @override
  String toString() => 'Could not save the device credential securely.';
}

class CompatibilityStorageRequired extends CredentialStorageException {
  const CompatibilityStorageRequired();
}

class SecureStore {
  static const _profileKey = 'micago.connection_profile.v1';
  static const _credentialBackendKey = 'micago.credential_aes_backend.v1';
  static const _softwareBackendKey = 'micago.credential_software_backend.v1';
  bool _prepared = false;
  final SoftwareCredentialStorage _software;
  static const _contactsKey = 'micago.contacts_matching_enabled.v1';
  static const _fallbackMarkerKey = 'micago.secure_store_fallback.v1';
  static const _fallbackPrefix = 'micago.secure_fallback.';
  // First Android Keystore initialization can take seconds on older devices.
  // A Future timeout cannot cancel the underlying platform write.
  static const _secureTimeout = Duration(seconds: 30);

  final FlutterSecureStorage _storage;
  final SharedPreferencesAsync _fallback;
  final FlutterSecureStorage _androidCompatibility;
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // Preserve legacy credentials; an isolated AES Keystore store handles ROMs
  // whose RSA provider rejects their public keys. Apple platforms use Keychain.
  SecureStore({
    FlutterSecureStorage? storage,
    SharedPreferencesAsync? fallback,
    SoftwareCredentialStorage? software,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(
               resetOnError: false,
               migrateWithBackup: true,
             ),
           ),
       _androidCompatibility = const FlutterSecureStorage(
         aOptions: AndroidOptions(
           storageNamespace: 'micago_credentials_aes_v1',
           keyCipherAlgorithm: KeyCipherAlgorithm.AES_GCM_NoPadding,
           storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
           resetOnError: false,
           migrateOnAlgorithmChange: false,
         ),
       ),
       _fallback = fallback ?? SharedPreferencesAsync(),
       _software = software ?? SoftwareCredentialStorage();

  Future<bool> compatibilityStorageEnabled() async =>
      _isAndroid && (await _fallback.getBool(_softwareBackendKey) ?? false);

  /// Probe before redeeming an invitation. Existing credential slots are untouched.
  Future<void> prepareCredentialStorage({
    Future<bool> Function()? confirmCompatibility,
  }) async {
    if (!_isAndroid || _prepared) return;
    if (await compatibilityStorageEnabled()) {
      await _software.probe().timeout(_secureTimeout);
      _prepared = true;
      return;
    }
    final useAes = await _fallback.getBool(_credentialBackendKey);
    final candidates = useAes == true
        ? [_androidCompatibility]
        : [_storage, _androidCompatibility];
    for (final candidate in candidates) {
      final nonce = List.generate(16, (_) => Random.secure().nextInt(256));
      final key = 'micago.credential_probe.${base64UrlEncode(nonce)}';
      final value = base64UrlEncode(nonce);
      try {
        await candidate.write(key: key, value: value).timeout(_secureTimeout);
        if (await candidate.read(key: key).timeout(_secureTimeout) != value) {
          throw const CredentialStorageException();
        }
        await _fallback.setBool(
          _credentialBackendKey,
          identical(candidate, _androidCompatibility),
        );
        _prepared = true;
        return;
      } on TimeoutException {
        throw const CredentialStorageException();
      } catch (_) {
        // A separate AES Keystore namespace can recover from RSA-only failures.
      } finally {
        unawaited(candidate.delete(key: key).catchError((_) {}));
      }
    }
    if (confirmCompatibility == null || !await confirmCompatibility()) {
      throw const CompatibilityStorageRequired();
    }
    await _software.probe().timeout(_secureTimeout);
    await _fallback.setBool(_softwareBackendKey, true);
    _prepared = true;
  }

  /// Loads the saved profile, or null if none / unreadable.
  Future<ConnectionProfile?> loadProfile() async {
    try {
      if (await readValue('micago.credential_rejected.v1') == '1') return null;
      if (await compatibilityStorageEnabled()) {
        final raw = await _software.read().timeout(_secureTimeout);
        if (raw == null) return null;
        return ConnectionProfile.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
      final mode = _isAndroid
          ? await _fallback.getBool(_credentialBackendKey)
          : false;
      String? raw;
      try {
        raw = await (mode == true ? _androidCompatibility : _storage)
            .read(key: _profileKey)
            .timeout(_secureTimeout);
      } on TimeoutException {
        rethrow;
      } catch (_) {
        if (!_isAndroid || mode != null) rethrow;
      }
      // Recover a verified AES write interrupted before its non-secret selector
      // was saved. An explicit selector never falls through to an older store.
      if (_isAndroid && mode == null && raw == null) {
        raw = await _androidCompatibility
            .read(key: _profileKey)
            .timeout(_secureTimeout);
        if (raw != null) await _fallback.setBool(_credentialBackendKey, true);
      }
      await _cleanupLegacyProfile();
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ConnectionProfile.fromJson(decoded);
      }
      return null;
    } catch (_) {
      // Corrupt/unreadable storage should not crash the app.
      return null;
    }
  }

  Future<void> saveProfile(ConnectionProfile profile) async {
    final encoded = jsonEncode(profile.toJson());
    if (await compatibilityStorageEnabled()) {
      try {
        await _software.write(encoded).timeout(_secureTimeout);
        if (await _software.read().timeout(_secureTimeout) != encoded) {
          throw const CredentialStorageException();
        }
        await _cleanupLegacyProfile();
        return;
      } catch (_) {
        _prepared = false;
        throw const CredentialStorageException();
      }
    }
    final useCompatibility =
        _isAndroid && (await _fallback.getBool(_credentialBackendKey) ?? false);
    final candidates = useCompatibility
        ? [_androidCompatibility]
        : [_storage, if (_isAndroid) _androidCompatibility];
    for (final candidate in candidates) {
      try {
        await candidate
            .write(key: _profileKey, value: encoded)
            .timeout(_secureTimeout);
        final saved = await candidate
            .read(key: _profileKey)
            .timeout(_secureTimeout);
        if (saved != encoded) throw const CredentialStorageException();
        if (_isAndroid) {
          await _fallback.setBool(
            _credentialBackendKey,
            identical(candidate, _androidCompatibility),
          );
        }
        await _cleanupLegacyProfile();
        return;
      } on TimeoutException {
        // A timed-out platform write is still running; do not race it with
        // another backend on the same plugin worker thread.
        throw const CredentialStorageException();
      } catch (_) {
        // Try the plugin's independent AES Keystore implementation on Android.
      }
    }
    _prepared = false;
    throw const CredentialStorageException();
  }

  Future<void> clearProfile() async {
    final softwareActive = await compatibilityStorageEnabled();
    // Clear software credentials even if the broken platform store throws.
    Object? activeError;
    if (_isAndroid) {
      try {
        await _software.delete().timeout(_secureTimeout);
      } catch (error) {
        if (softwareActive) activeError = error;
      }
    }
    final useAes =
        _isAndroid && (await _fallback.getBool(_credentialBackendKey) ?? false);
    for (final candidate in [_storage, if (_isAndroid) _androidCompatibility]) {
      try {
        await candidate.delete(key: _profileKey).timeout(_secureTimeout);
      } catch (error) {
        if (!softwareActive &&
            identical(candidate, useAes ? _androidCompatibility : _storage)) {
          activeError = error;
        }
      }
    }
    await _cleanupLegacyProfile();
    _prepared = false;
    if (activeError != null) throw activeError;
  }

  Future<void> _cleanupLegacyProfile() async {
    try {
      await _deleteFallback(_profileKey);
    } catch (_) {}
  }

  /// Whether the user has opted into local contacts matching (a simple flag —
  /// the contact book itself is never persisted).
  Future<bool> contactsMatchingEnabled() async {
    try {
      return (await _read(_contactsKey)) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setContactsMatchingEnabled(bool enabled) async {
    await _write(_contactsKey, enabled ? '1' : '0');
  }

  /// Generic small-value storage for non-secret preferences (theme, language).
  Future<String?> readValue(String key) async {
    try {
      return await _read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeValue(String key, String value) async {
    if (key == _profileKey) {
      throw ArgumentError('Use saveProfile for credentials.');
    }
    await _write(key, value);
  }

  Future<void> deleteValue(String key) async {
    await _delete(key);
  }

  Future<String?> _read(String key) async {
    if (await _fallbackEnabled()) {
      return _readFallback(key);
    }
    try {
      final secureValue = await _storage.read(key: key).timeout(_secureTimeout);
      if (secureValue != null) return secureValue;
      return _readFallback(key);
    } catch (error) {
      await _enableFallback(error);
      return _readFallback(key);
    }
  }

  Future<void> _write(String key, String value) async {
    if (await _fallbackEnabled()) {
      await _writeFallback(key, value);
      return;
    }
    try {
      await _storage.write(key: key, value: value).timeout(_secureTimeout);
      // Only non-secret preferences use this fallback mirror. Device
      // credentials are handled exclusively by saveProfile above.
      await _writeFallback(key, value);
    } catch (error) {
      await _enableFallback(error);
      await _writeFallback(key, value);
    }
  }

  Future<void> _delete(String key) async {
    await _deleteFallback(key);
    if (await _fallbackEnabled()) return;
    try {
      await _storage.delete(key: key).timeout(_secureTimeout);
    } catch (error) {
      await _enableFallback(error);
    }
  }

  Future<bool> _fallbackEnabled() async =>
      (await _fallback.getBool(_fallbackMarkerKey)) ?? false;

  Future<void> _enableFallback(Object error) async {
    if (kDebugMode) {
      debugPrint('[SecureStore] Using non-secret preference fallback.');
    }
    await _fallback.setBool(_fallbackMarkerKey, true);
  }

  Future<String?> _readFallback(String key) =>
      _fallback.getString(_fallbackPrefix + key);

  Future<void> _writeFallback(String key, String value) =>
      _fallback.setString(_fallbackPrefix + key, value);

  Future<void> _deleteFallback(String key) =>
      _fallback.remove(_fallbackPrefix + key);
}
