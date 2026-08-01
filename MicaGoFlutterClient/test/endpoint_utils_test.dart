import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/connection_candidate.dart';
import 'package:mica_go/core/network/endpoint_utils.dart';

void main() {
  _lanRoutePersistenceTests();
  group('normalizeBaseUrl', () {
    test('adds http scheme when missing', () {
      expect(normalizeBaseUrl('192.168.1.5:3000'), 'http://192.168.1.5:3000');
    });

    test('trims whitespace and trailing slashes', () {
      expect(
        normalizeBaseUrl('  https://mica.example.com//  '),
        'https://mica.example.com',
      );
    });

    test('empty stays empty', () {
      expect(normalizeBaseUrl('   '), '');
    });

    test('drops a pasted path to the bare origin', () {
      expect(
        normalizeBaseUrl('https://micago.cinmou.uk/api/health'),
        'https://micago.cinmou.uk',
      );
      expect(
        normalizeBaseUrl('https://micago.cinmou.uk/api'),
        'https://micago.cinmou.uk',
      );
    });

    test('drops query and fragment', () {
      expect(
        normalizeBaseUrl('https://micago.cinmou.uk/?x=1#frag'),
        'https://micago.cinmou.uk',
      );
    });

    test('keeps a custom port', () {
      expect(
        normalizeBaseUrl('http://192.168.1.5:3000/api/chats'),
        'http://192.168.1.5:3000',
      );
    });
  });

  group('deriveWebSocketUrl', () {
    test('https -> wss and appends /ws', () {
      expect(
        deriveWebSocketUrl('https://mica.example.com'),
        'wss://mica.example.com/ws',
      );
    });

    test('http -> ws with port', () {
      expect(
        deriveWebSocketUrl('http://127.0.0.1:3000'),
        'ws://127.0.0.1:3000/ws',
      );
    });

    test('does not double-append /ws', () {
      expect(
        deriveWebSocketUrl('https://mica.example.com/ws'),
        'wss://mica.example.com/ws',
      );
    });

    test('empty stays empty', () {
      expect(deriveWebSocketUrl(''), '');
    });
  });

  group('isValidHttpUrl', () {
    test('accepts host without scheme (normalized)', () {
      expect(isValidHttpUrl('mica.example.com'), isTrue);
    });

    test('accepts https url', () {
      expect(isValidHttpUrl('https://mica.example.com'), isTrue);
    });

    test('rejects empty', () {
      expect(isValidHttpUrl(''), isFalse);
    });
  });
}

// C75: LAN routes vanished from Settings because an empty `/api/server/urls`
// LAN list was written straight through to the stored profile.
void _lanRoutePersistenceTests() {
  group('LAN route persistence (C75)', () {
    const stored = [
      EndpointRef(baseUrl: 'http://192.168.1.9:3000', wsUrl: ''),
      EndpointRef(baseUrl: 'http://10.0.0.5:3000', wsUrl: ''),
    ];

    test('a reported list replaces the stored routes', () {
      const reported = [EndpointRef(baseUrl: 'http://192.168.1.20:3000', wsUrl: '')];
      expect(
        resolvePersistedLanRoutes(
          reported: reported,
          previous: stored,
          serverUsesVisibilityFlags: false,
        ),
        reported,
      );
    });

    test('an empty report keeps the stored routes (transient gap)', () {
      expect(
        resolvePersistedLanRoutes(
          reported: const [],
          previous: stored,
          serverUsesVisibilityFlags: false,
        ),
        stored,
      );
    });

    test('a visibility-flag server may legitimately report none', () {
      expect(
        resolvePersistedLanRoutes(
          reported: const [],
          previous: stored,
          serverUsesVisibilityFlags: true,
        ),
        isEmpty,
      );
    });
  });
}
