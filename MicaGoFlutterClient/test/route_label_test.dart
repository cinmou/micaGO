import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/features/chats/models/chat_summary.dart';
import 'package:mica_go/features/chats/route_label.dart';

ChatSummary _route(
  String guid,
  String handle,
  String effective, {
  bool? canSendText,
}) => ChatSummary.fromJson({
  'guid': guid,
  'chatIdentifier': handle,
  'effectiveService': effective,
  'canSendText': ?canSendText,
});

void main() {
  group('route details', () {
    test('each route keeps its concrete handle', () {
      expect(
        routeHandle(_route('phone', '+447700900123', 'imessage')),
        '+447700900123',
      );
      expect(
        routeHandle(_route('email', 'a@icloud.com', 'imessage')),
        'a@icloud.com',
      );
      expect(
        routeHandle(ChatSummary.fromJson({'guid': 'group', 'isGroup': true})),
        isEmpty,
      );
    });
    test('sendability label uses the server-provided capability', () {
      expect(
        routeSendabilityLabel(
          _route('g', '+1', 'imessage', canSendText: true),
          allowSmsSend: false,
        ),
        'Can send',
      );
      // SMS with the server setting off → read only (no local inference).
      expect(
        routeSendabilityLabel(
          _route('g', '+1', 'sms', canSendText: false),
          allowSmsSend: false,
        ),
        'Read only',
      );
    });
  });
}
