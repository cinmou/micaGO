import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/websocket_client.dart';

Future<void> waitForStatus(WebSocketClient client, WsStatus status) async {
  if (client.status == status) return;
  final ready = Completer<void>();
  void changed() {
    if (client.status == status && !ready.isCompleted) ready.complete();
  }

  client.addListener(changed);
  try {
    await ready.future.timeout(const Duration(seconds: 3));
  } finally {
    client.removeListener(changed);
  }
}

void main() {
  late Directory directory;
  late HttpServer server;
  late String pin;
  final sockets = <WebSocket>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('micago-ws-test-');
    final certPath = '${directory.path}/test.crt';
    final keyPath = '${directory.path}/test.key';
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-days',
      '2',
      '-subj',
      '/CN=micago-test',
    ]);
    expect(generated.exitCode, 0);
    final pem = await File(certPath).readAsString();
    pin = sha256
        .convert(
          base64Decode(
            pem
                .split('\n')
                .where((line) => line.isNotEmpty && !line.startsWith('-----'))
                .join(),
          ),
        )
        .toString();
    final context = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
  });

  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'a stalled secure handshake fails within the configured deadline',
    () async {
      server.listen((request) {}); // Deliberately leave the upgrade unanswered.
      final client = WebSocketClient(
        handshakeTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(client.dispose);
      client.connect(
        'wss://127.0.0.1:${server.port}/ws',
        'test-only',
        tlsFingerprint: pin,
      );
      await waitForStatus(client, WsStatus.failed);
      expect(client.lastError, contains('TimeoutException'));
    },
  );

  test(
    'late handshake from a replaced socket cannot restore its state',
    () async {
      final firstRequest = Completer<HttpRequest>();
      final secondSocket = Completer<WebSocket>();
      var requests = 0;
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer test-only');
        requests++;
        if (requests == 1) {
          firstRequest.complete(request);
        } else {
          final socket = await WebSocketTransformer.upgrade(request);
          sockets.add(socket);
          secondSocket.complete(socket);
        }
      });
      final client = WebSocketClient();
      addTearDown(client.dispose);
      final uri = 'wss://127.0.0.1:${server.port}/ws';
      client.connect(uri, 'test-only', tlsFingerprint: pin);
      final request = await firstRequest.future.timeout(
        const Duration(seconds: 3),
      );
      client.connect(uri, 'test-only', tlsFingerprint: pin);
      final socket = await secondSocket.future.timeout(
        const Duration(seconds: 3),
      );
      await waitForStatus(client, WsStatus.connected);
      final old = await WebSocketTransformer.upgrade(request);
      sockets.add(old);
      await old.close();
      // A frame on the active socket proves its listener survived the old close.
      final received = client.events.first;
      socket.add(jsonEncode({'type': 'test:new', 'data': {}}));
      expect(
        (await received.timeout(const Duration(seconds: 3))).type,
        'test:new',
      );
      expect(client.status, WsStatus.connected);
      await socket.close();
      await waitForStatus(client, WsStatus.disconnected);
    },
  );
}
