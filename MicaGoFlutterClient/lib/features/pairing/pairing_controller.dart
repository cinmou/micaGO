import 'package:flutter/foundation.dart';
import '../../core/storage/secure_store.dart';

import '../../core/app_controller.dart';
import 'pairing_payload.dart';
import '../../core/l10n/app_localizations.dart';

enum PairingStage { scanning, preview, testing, success, failure }

/// Parse a scanned invitation and activate the shared connection flow.
class PairingController extends ChangeNotifier {
  final AppController app;

  PairingController(this.app);

  PairingStage stage = PairingStage.scanning;
  PairingPayload? payload;
  String? message;

  void onScan(String raw) {
    if (stage != PairingStage.scanning) return;
    try {
      payload = parsePairingPayload(raw);
      if (payload!.version < 4) {
        throw PairingParseException(
          MicaLocalizations.current.t('pair.secureUpgrade'),
        );
      }
      message = null;
      stage = PairingStage.preview;
    } on PairingParseException catch (e) {
      payload = null;
      message = e.message;
    }
    notifyListeners();
  }

  void scanAgain() {
    stage = PairingStage.scanning;
    payload = null;
    message = null;
    notifyListeners();
  }

  /// Tests endpoints, activates the connection, and warms the local cache.
  Future<bool> useScanned({
    Future<bool> Function()? confirmCompatibility,
  }) async {
    final p = payload;
    if (p == null || stage == PairingStage.testing) return false;

    stage = PairingStage.testing;
    message = MicaLocalizations.current.t('pair.testing');
    notifyListeners();

    if (p.version >= 4) {
      try {
        await app.saveAndActivate(
          p.toProfile(),
          confirmCompatibility: confirmCompatibility,
        );
        message = MicaLocalizations.current.t('pair.connected');
        stage = PairingStage.success;
        notifyListeners();
        return true;
      } catch (error) {
        stage = PairingStage.failure;
        message = error is CompatibilityStorageRequired
            ? MicaLocalizations.current.t('pair.compatibilityRequired')
            : error is CredentialStorageException
            ? MicaLocalizations.current.t('pair.secureStorageFailed')
            : error.toString();
        notifyListeners();
        return false;
      }
    }

    stage = PairingStage.failure;
    message = MicaLocalizations.current.t('pair.secureUpgrade');
    notifyListeners();
    return false;
  }
}
