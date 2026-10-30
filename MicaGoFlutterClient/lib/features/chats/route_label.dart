import 'models/chat_summary.dart';
import '../../core/l10n/app_localizations.dart';

/// Concrete phone/email for an individual route; groups have no single handle.
String routeHandle(ChatSummary route) =>
    route.isGroup ? '' : route.chatIdentifier?.trim() ?? '';

/// Short sendability hint for the route detail row. Server-authoritative — never
/// inferred from the handle/GUID shape.
String routeSendabilityLabel(ChatSummary route, {required bool allowSmsSend}) {
  return MicaLocalizations.current.t(
    route.canSendText(allowSmsSend: allowSmsSend)
        ? 'chat.canSend'
        : 'chat.readOnly',
  );
}
