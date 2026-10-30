import '../../core/l10n/app_localizations.dart';

/// The single client-side mapping from the server's service decision to a
/// display/behavior category. The server is authoritative: C21 it computes one
/// message-aware `effectiveService` ("imessage" | "sms" | "rcs" | "unknown")
/// per chat — preferring iMessage — and the client uses ONLY that.
/// `serviceCategory`/`serviceName` are accepted only as a fallback for an older
/// server that doesn't send `effectiveService`.
///
/// Deliberately takes ONLY server service fields — never a chat GUID, handle,
/// phone number, or display name — so the client cannot "guess" SMS from a
/// phone-shaped sender or a `any;-;` GUID. Unknown is the floor, never SMS.
enum ChatService { imessage, sms, rcs, unknown }

ChatService chatServiceFromServer({
  String? effectiveService,
  String? category,
  String? rawService,
}) {
  // The server's resolved effective service wins (C21).
  final eff = _categoryToService(effectiveService);
  if (eff != null) return eff;
  // Fallback for older servers: serviceCategory, then a normalized raw service.
  final cat = _categoryToService(category);
  if (cat != null) return cat;
  switch (rawService?.trim().toLowerCase()) {
    case 'imessage':
    case 'imessagelite':
      return ChatService.imessage;
    case 'sms':
    case 'text':
    case 'plain':
      return ChatService.sms;
    case 'rcs':
      return ChatService.rcs;
  }
  return ChatService.unknown;
}

ChatService? _categoryToService(String? category) {
  switch (category?.trim().toLowerCase()) {
    case 'imessage':
      return ChatService.imessage;
    case 'sms':
      return ChatService.sms;
    case 'rcs':
      return ChatService.rcs;
    default:
      return null;
  }
}

extension ChatServiceDisplay on ChatService {
  String get label => switch (this) {
    ChatService.imessage => 'iMessage',
    ChatService.sms => 'SMS',
    ChatService.rcs => 'RCS',
    ChatService.unknown => MicaLocalizations.current.t('common.unknown'),
  };

  /// iMessage is always sendable. SMS is sendable only when the server's
  /// "Allow SMS sending through Mac" setting is on (C20) — server-authoritative,
  /// never inferred from the GUID/handle. RCS/unknown are always read-only.
  bool canSendWith({required bool allowSmsSend}) {
    switch (this) {
      case ChatService.imessage:
        return true;
      case ChatService.sms:
        return allowSmsSend;
      case ChatService.rcs:
      case ChatService.unknown:
        return false;
    }
  }
}
