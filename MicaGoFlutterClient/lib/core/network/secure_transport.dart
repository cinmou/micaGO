import 'dart:io';
import 'endpoint_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Pinning is scoped to one server origin. Public routes use system CA trust;
/// LAN routes use the exact certificate fingerprint received during pairing.
HttpClient secureIoClient(String baseUrl, {String? fingerprint}) {
  final origin = Uri.parse(baseUrl);
  if (origin.scheme != 'https' && origin.scheme != 'wss') {
    throw StateError(
      'This connection requires HTTPS. Create a new pairing code on the Mac.',
    );
  }
  final pin = fingerprint?.toLowerCase() ?? '';
  final client = HttpClient(
    context: pin.isEmpty ? null : SecurityContext(withTrustedRoots: false),
  );
  if (pin.isNotEmpty) {
    client.badCertificateCallback = (cert, host, port) {
      final now = DateTime.now();
      return host == origin.host &&
          port == transportPort(origin) &&
          now.isAfter(cert.startValidity) &&
          now.isBefore(cert.endValidity) &&
          sha256.convert(cert.der).toString() == pin;
    };
  }
  return client;
}

http.Client secureHttpClient(String baseUrl, {String? fingerprint}) =>
    _OriginClient(
      IOClient(secureIoClient(baseUrl, fingerprint: fingerprint)),
      Uri.parse(baseUrl),
    );

class _OriginClient extends http.BaseClient {
  final http.Client inner;
  final Uri origin;
  _OriginClient(this.inner, this.origin);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.origin != origin.origin) {
      throw StateError(
        'Authenticated requests must stay on the paired origin.',
      );
    }
    request.followRedirects = false;
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}
