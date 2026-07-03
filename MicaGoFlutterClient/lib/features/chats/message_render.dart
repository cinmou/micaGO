/// Pure, testable rendering/compatibility logic for messages.
///
/// Centralises what the thread widgets used to do ad-hoc: classify a message
/// into a renderable kind, compute its delivery state once, resolve a sender
/// label that is never blank, and sanitise iMessage control-payload artifacts
/// (e.g. the "+!" leak) so they don't render as normal chat text.
///
/// Reaction/service detection relies on fields the MicaGo server does **not**
/// expose yet (`associatedMessageType`, `itemType`, …); those branches are
/// forward-compatible and inert today. See docs/client-refactor-notes.md.
library;

import 'dart:convert';

import 'package:intl/intl.dart';

import 'models/message_model.dart';

/// The chat-list timestamp label, phone-style (C46). [now] is injected so this
/// stays pure/testable; [use24h] follows the system clock setting; [locale] is
/// the app's language code (en/zh).
///   • < 1 min      → "now"
///   • < 1 hour     → "5m"
///   • same day     → clock time (06:06 or 6:06 AM per use24h)
///   • yesterday     → Yesterday / 昨天
///   • within 7 days → weekday (Monday / 星期一)
///   • older        → numeric date in the locale's order (12/06/2026)
String chatTimestampLabel(
  DateTime dt, {
  required DateTime now,
  required bool use24h,
  required String locale,
}) {
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';

  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfThatDay = DateTime(dt.year, dt.month, dt.day);
  final daysApart = startOfToday.difference(startOfThatDay).inDays;

  try {
    if (daysApart <= 0) {
      return (use24h ? DateFormat.Hm(locale) : DateFormat.jm(locale)).format(
        dt,
      );
    }
    if (daysApart == 1) return _yesterdayLabel(locale);
    if (daysApart < 7) return DateFormat.EEEE(locale).format(dt);
    return DateFormat.yMd(locale).format(dt);
  } catch (_) {
    // Locale date symbols not loaded — locale-independent fallback.
    if (daysApart <= 0) {
      final m = dt.minute.toString().padLeft(2, '0');
      if (use24h) return '${dt.hour.toString().padLeft(2, '0')}:$m';
      final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      return '$h12:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
    }
    if (daysApart == 1) return _yesterdayLabel(locale);
    if (daysApart < 7) {
      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return weekdays[(dt.weekday - 1) % 7];
    }
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}

String _yesterdayLabel(String locale) =>
    locale.toLowerCase().startsWith('zh') ? '昨天' : 'Yesterday';

/// Clock-only label for message timestamp reveal affordances. Unlike
/// [threadTimestampLabel], this intentionally ignores the day bucket.
String timeOnlyTimestampLabel(
  DateTime dt, {
  required bool use24h,
  required String locale,
}) {
  return _timeLabel(dt, use24h: use24h, locale: locale);
}

/// Full timestamp label for in-thread message footers / chat headers. It uses
/// the same day buckets as [chatTimestampLabel], but keeps the concrete time:
/// today -> time, yesterday -> Yesterday 09:30, recent -> Monday 09:30.
String threadTimestampLabel(
  DateTime dt, {
  required DateTime now,
  required bool use24h,
  required String locale,
}) {
  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfThatDay = DateTime(dt.year, dt.month, dt.day);
  final daysApart = startOfToday.difference(startOfThatDay).inDays;

  final time = _timeLabel(dt, use24h: use24h, locale: locale);
  try {
    if (daysApart <= 0) return time;
    if (daysApart == 1) return '${_yesterdayLabel(locale)} $time';
    if (daysApart < 7) return '${DateFormat.EEEE(locale).format(dt)} $time';
    return '${DateFormat.yMd(locale).format(dt)} $time';
  } catch (_) {
    if (daysApart <= 0) return time;
    if (daysApart == 1) return '${_yesterdayLabel(locale)} $time';
    if (daysApart < 7) {
      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      return '${weekdays[(dt.weekday - 1) % 7]} $time';
    }
    return '${dt.month}/${dt.day}/${dt.year} $time';
  }
}

String _timeLabel(DateTime dt, {required bool use24h, required String locale}) {
  try {
    return (use24h ? DateFormat.Hm(locale) : DateFormat.jm(locale))
        .format(dt)
        .replaceAll('\u202f', ' ')
        .replaceAll('\u00a0', ' ');
  } catch (_) {
    final m = dt.minute.toString().padLeft(2, '0');
    if (use24h) return '${dt.hour.toString().padLeft(2, '0')}:$m';
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    return '$h12:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// What kind of row a message should render as.
enum MessageRenderableKind {
  normal, // has displayable text (attachments may also be present)
  attachmentOnly, // no text, but has attachments
  service, // group/system event (rename, join/leave, …)
  reaction, // tapback/reaction to another message
  retracted, // unsent message → subtle system row
  unknown, // nothing renderable (empty/control-only) → subtle system row
}

/// Outgoing/incoming delivery state, computed in one place.
enum MessageDeliveryState {
  incoming,
  sending,
  sent,
  delivered,
  read,
  failed,
  unknown,
}

const String _objectReplacement = '￼';
const String _unicodeReplacement = '�';

/// Strips the invisible attachment-placeholder char and trims. Returns null
/// when nothing meaningful remains.
String? sanitizeMessageText(String? raw) {
  if (raw == null) return null;
  final cleaned = raw
      .replaceAll(_objectReplacement, '')
      .replaceAll(_unicodeReplacement, '')
      .trim();
  return cleaned.isEmpty ? null : cleaned;
}

/// True when [text] is a control-like payload that must NOT render as normal
/// chat text — e.g. the server-side typedstream "+!"/"+$" leak (fixed in the
/// v0.11.5 server) or a string with no letters/digits/CJK at all.
///
/// Conservative on purpose: real messages contain at least one alphanumeric or
/// CJK rune, so this never hides genuine text. The mixed case ("+!Hello") can't
/// be safely repaired client-side and needs the server fix — documented.
bool isControlLikeText(String text) {
  final t = text
      .replaceAll(_objectReplacement, '')
      .replaceAll(_unicodeReplacement, '')
      .trim();
  if (t.isEmpty) return true;
  // Any letter, digit, or CJK ideograph means it's real content.
  final hasAlnum = RegExp(r'[A-Za-z0-9À-ɏЀ-ӿ぀-ヿ一-鿿가-힯]').hasMatch(t);
  if (hasAlnum) return false;
  // Real protocol artifacts ("+!", "+$") are pure ASCII punctuation. Any
  // non-ASCII rune (emoji, symbols, other scripts) is genuine content — never
  // strip a real emoji-only message.
  final hasNonAscii = t.runes.any((r) => r > 0x7F);
  return !hasNonAscii;
}

/// The text to display for a message, or null if there is none to show.
String? displayText(MessageModel m) {
  final clean = sanitizeMessageText(m.text);
  if (clean == null) return null;
  if (isControlLikeText(clean)) return null;
  return clean;
}

MessageRenderableKind renderableKindFor(MessageModel m) {
  if (m.isDebugOnly || m.renderRecommendation == 'debug_only') {
    return MessageRenderableKind.unknown;
  }
  if (m.isRetracted || m.dateRetracted != null) {
    return MessageRenderableKind.retracted;
  }
  final serverKind = _renderableKindFromServerSemantics(m);
  if (serverKind != null) return serverKind;
  if (isReaction(m)) return MessageRenderableKind.reaction;
  if (m.itemType > 0 ||
      m.groupActionType > 0 ||
      (m.groupTitle?.isNotEmpty ?? false)) {
    return MessageRenderableKind.service;
  }
  if (isInteractiveUpdate(m)) return MessageRenderableKind.unknown;
  if (m.isInteractiveApp || m.isEmbeddedMedia) {
    return MessageRenderableKind.normal;
  }
  final hasText = displayText(m) != null;
  if (hasText) return MessageRenderableKind.normal;
  if (m.hasAttachments) return MessageRenderableKind.attachmentOnly;
  return MessageRenderableKind.unknown;
}

MessageRenderableKind? _renderableKindFromServerSemantics(MessageModel m) {
  switch (m.semanticKind) {
    case 'retracted':
      return MessageRenderableKind.retracted;
    case 'tapback':
      return MessageRenderableKind.reaction;
    case 'service_event':
      return MessageRenderableKind.service;
    case 'deleted':
    case 'unavailable':
      return MessageRenderableKind.unknown;
    case 'sticker':
      return m.hasAttachments
          ? MessageRenderableKind.attachmentOnly
          : MessageRenderableKind.unknown;
    // C26: unrecoverable attachment placeholders (the attachment rows are gone,
    // or an edit left empty residue). These can never render a real file card,
    // so present them like an unsent/retracted message instead of a broken card
    // or a cryptic "unsupported" label. Raw details stay in Message Info/Debug.
    case 'missing_attachment_rows':
    case 'empty_edited_residue':
      return MessageRenderableKind.retracted;
    case 'sync_noise':
    case 'unknown':
      return MessageRenderableKind.unknown;
    case 'attachment':
      return m.hasAttachments
          ? MessageRenderableKind.attachmentOnly
          : MessageRenderableKind.unknown;
    case 'normal_text':
    case 'attributed_body_text':
    case 'reply':
    case 'effect':
      if (displayText(m) != null) return MessageRenderableKind.normal;
      if (m.hasAttachments) return MessageRenderableKind.attachmentOnly;
      return MessageRenderableKind.unknown;
  }
  switch (m.renderRecommendation) {
    case 'system':
    case 'unsupported':
      return MessageRenderableKind.unknown;
    case 'merge':
      return MessageRenderableKind.reaction;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Tapbacks / reactions (BlueBubbles-compatible). associatedMessageType is the
// chat.db integer code: 1000 sticker; 2000-2005 add; 3000-3005 remove.
// ---------------------------------------------------------------------------

enum TapbackKind {
  love,
  like,
  dislike,
  laugh,
  emphasize,
  question,
  sticker,
  unknown,
}

class Tapback {
  final TapbackKind kind;
  final bool isRemoval; // true for the 3000-series (reaction removed)
  const Tapback(this.kind, this.isRemoval);
}

/// Parses an `associatedMessageType` code into a [Tapback], or null if the code
/// is not a reaction (0/null/out of range).
Tapback? tapbackFromCode(int? code) {
  if (code == null) return null;
  if (code == 1000) return const Tapback(TapbackKind.sticker, false);
  const kinds = [
    TapbackKind.love,
    TapbackKind.like,
    TapbackKind.dislike,
    TapbackKind.laugh,
    TapbackKind.emphasize,
    TapbackKind.question,
  ];
  if (code >= 2000 && code <= 2005) return Tapback(kinds[code - 2000], false);
  if (code >= 3000 && code <= 3005) return Tapback(kinds[code - 3000], true);
  return null;
}

/// True when the message is a tapback/reaction (has a reaction code + a target).
bool isReaction(MessageModel m) {
  final t = tapbackFromCode(m.associatedMessageType);
  if (t == null || t.kind == TapbackKind.sticker) return false;
  return (m.associatedMessageGuid?.isNotEmpty ?? false);
}

/// BlueBubbles treats associated_message_type 1000 as a sticker attached to a
/// target message, not as a standalone message row.
bool isAssociatedSticker(MessageModel m) =>
    m.associatedMessageType == 1000 &&
    (m.associatedMessageGuid?.trim().isNotEmpty ?? false) &&
    m.hasAttachments;

/// Interactive app update rows, such as an iMessage Poll vote/update, point back
/// at the original app balloon. Until we parse `payload_data`, render the source
/// balloon and suppress the control/update row itself.
bool isInteractiveUpdate(MessageModel m) =>
    (m.associatedMessageType ?? 0) >= 4000 &&
    (m.associatedMessageGuid?.trim().isNotEmpty ?? false) &&
    (m.balloonBundleId?.trim().isNotEmpty ?? false);

/// BlueBubbles hides the "kept an audio message" service row when it carries a
/// subject. The actual voice attachment is the renderable content.
bool isKeptAudioNotice(MessageModel m) =>
    m.itemType == 5 && (m.subject?.trim().isNotEmpty ?? false);

/// The emoji glyph for a tapback (for chips on the target bubble).
String tapbackEmoji(TapbackKind kind) {
  switch (kind) {
    case TapbackKind.love:
      return '❤️'; // ❤️
    case TapbackKind.like:
      return '\u{1F44D}'; // 👍
    case TapbackKind.dislike:
      return '\u{1F44E}'; // 👎
    case TapbackKind.laugh:
      return '\u{1F602}'; // 😂
    case TapbackKind.emphasize:
      return '‼️'; // ‼️
    case TapbackKind.question:
      return '❓'; // ❓
    case TapbackKind.sticker:
    case TapbackKind.unknown:
      return '\u{1F516}'; // 🔖
  }
}

/// Past-tense verb for a tapback ("loved", "liked", …) used in the
/// fallback system row when the target message isn't loaded.
String tapbackVerb(TapbackKind kind) {
  switch (kind) {
    case TapbackKind.love:
      return 'loved';
    case TapbackKind.like:
      return 'liked';
    case TapbackKind.dislike:
      return 'disliked';
    case TapbackKind.laugh:
      return 'laughed at';
    case TapbackKind.emphasize:
      return 'emphasized';
    case TapbackKind.question:
      return 'questioned';
    case TapbackKind.sticker:
      return 'tagged';
    case TapbackKind.unknown:
      return 'reacted to';
  }
}

/// The single canonical helper that resolves a reaction/tapback's target
/// message GUID from its `associatedMessageGuid`. Strips the `p:`/`bp:` scheme,
/// an optional `<part>/` segment, and a leading `+`, so it works for every
/// observed format (`p:0/ABC`, `p:ABC`, `bp:ABC`, `+ABC`, bare `ABC`). C26
/// consolidates the previously-duplicated copies in the realtime + cache paths,
/// which each handled only some of these forms. Returns null when empty.
String? reactionTargetGuid(String? associatedGuid) {
  var raw = associatedGuid?.trim() ?? '';
  if (raw.isEmpty) return null;
  raw = raw.replaceFirst(RegExp(r'^(?:p|bp):'), '');
  final slash = raw.indexOf('/');
  if (slash >= 0) raw = raw.substring(slash + 1);
  raw = raw.replaceFirst(RegExp(r'^\+'), '');
  return raw.isEmpty ? null : raw;
}

// ---------------------------------------------------------------------------
// Replies (threadOriginatorGuid)
// ---------------------------------------------------------------------------

/// True when the message is a reply to an earlier message.
bool isReply(MessageModel m) => (m.threadOriginatorGuid?.isNotEmpty ?? false);

/// Compact reply-preview model built from the (optionally loaded) target.
class ReplyPreview {
  final String sender; // resolved sender label of the quoted message
  final String? text; // sanitized quoted text (null if media/unknown)
  final bool targetLoaded;
  final String? targetGuid;
  const ReplyPreview({
    required this.sender,
    this.text,
    required this.targetLoaded,
    this.targetGuid,
  });
}

// ---------------------------------------------------------------------------
// Message effects (expressiveSendStyleId)
// ---------------------------------------------------------------------------

enum MessageSendEffect {
  none,
  // Bubble effects.
  slam,
  loud,
  gentle,
  invisibleInk,
  // Screen effects.
  confetti,
  fireworks,
  balloons,
  love,
  lasers,
  celebration,
  spotlight,
  echo,
}

/// Whether an effect plays as a full-screen overlay (vs. a per-bubble animation).
bool isScreenSendEffect(MessageSendEffect e) =>
    e == MessageSendEffect.confetti ||
    e == MessageSendEffect.fireworks ||
    e == MessageSendEffect.balloons ||
    e == MessageSendEffect.love ||
    e == MessageSendEffect.lasers ||
    e == MessageSendEffect.celebration ||
    e == MessageSendEffect.spotlight ||
    e == MessageSendEffect.echo;

const Map<String, String> _effectLabels = {
  'com.apple.MobileSMS.expressivesend.impact': 'Sent with Slam',
  'com.apple.MobileSMS.expressivesend.loud': 'Sent with Loud',
  'com.apple.MobileSMS.expressivesend.gentle': 'Sent with Gentle',
  'com.apple.MobileSMS.expressivesend.invisibleink': 'Sent with Invisible Ink',
  'com.apple.messages.effect.CKEchoEffect': 'Sent with Echo',
  'com.apple.messages.effect.CKSpotlightEffect': 'Sent with Spotlight',
  'com.apple.messages.effect.CKHappyBirthdayEffect': 'Sent with Balloons',
  'com.apple.messages.effect.CKConfettiEffect': 'Sent with Confetti',
  'com.apple.messages.effect.CKHeartEffect': 'Sent with Love',
  'com.apple.messages.effect.CKLasersEffect': 'Sent with Lasers',
  'com.apple.messages.effect.CKFireworksEffect': 'Sent with Fireworks',
  'com.apple.messages.effect.CKSparklesEffect': 'Sent with Celebration',
};

MessageSendEffect sendEffectFor(String? expressiveSendStyleId) {
  switch (expressiveSendStyleId?.trim()) {
    case 'com.apple.MobileSMS.expressivesend.impact':
      return MessageSendEffect.slam;
    case 'com.apple.MobileSMS.expressivesend.loud':
      return MessageSendEffect.loud;
    case 'com.apple.MobileSMS.expressivesend.gentle':
      return MessageSendEffect.gentle;
    case 'com.apple.MobileSMS.expressivesend.invisibleink':
      return MessageSendEffect.invisibleInk;
    case 'com.apple.messages.effect.CKConfettiEffect':
      return MessageSendEffect.confetti;
    case 'com.apple.messages.effect.CKFireworksEffect':
      return MessageSendEffect.fireworks;
    case 'com.apple.messages.effect.CKHappyBirthdayEffect':
      return MessageSendEffect.balloons;
    case 'com.apple.messages.effect.CKHeartEffect':
      return MessageSendEffect.love;
    case 'com.apple.messages.effect.CKLasersEffect':
      return MessageSendEffect.lasers;
    case 'com.apple.messages.effect.CKSparklesEffect':
      return MessageSendEffect.celebration;
    case 'com.apple.messages.effect.CKSpotlightEffect':
      return MessageSendEffect.spotlight;
    case 'com.apple.messages.effect.CKEchoEffect':
      return MessageSendEffect.echo;
    default:
      return MessageSendEffect.none;
  }
}

/// Human label for a send effect, or null when there is no effect. Unknown but
/// present effect IDs map to a generic label rather than nothing.
String? effectLabel(String? expressiveSendStyleId) {
  final id = expressiveSendStyleId?.trim() ?? '';
  if (id.isEmpty) return null;
  return _effectLabels[id] ?? 'Sent with an effect';
}

/// Label for a retracted/unsent (or unrecoverable-placeholder) message. Own
/// messages read "You unsent a message"; for others we use the resolved sender
/// name ("Alex unsent a message") when available, falling back to a neutral
/// phrasing when it isn't.
String retractedLabel(MessageModel m, {String? senderName}) {
  if (m.isFromMe) return 'You unsent a message';
  final name = senderName?.trim() ?? '';
  if (name.isNotEmpty) return '$name unsent a message';
  return 'This message was unsent';
}

String? editedMarker(MessageModel m) =>
    (m.isEdited || m.dateEdited != null) && !m.isRetracted ? 'Edited' : null;

MessageDeliveryState deliveryStateFor(MessageModel m) {
  if (!m.isFromMe) return MessageDeliveryState.incoming;
  if (m.localState == LocalSendState.failed || m.errorCode > 0) {
    return MessageDeliveryState.failed;
  }
  if (m.localState == LocalSendState.pending ||
      m.localState == LocalSendState.sending) {
    return MessageDeliveryState.sending;
  }
  if (m.isRead || m.dateRead != null) return MessageDeliveryState.read;
  if (m.isDelivered || m.dateDelivered != null) {
    return MessageDeliveryState.delivered;
  }
  return MessageDeliveryState.sent;
}

String attachmentPreviewLabel(AttachmentModel attachment) {
  return '[附件]';
}

String messagePreviewText(MessageModel message) {
  final text = displayText(message);
  if (text != null && text.isNotEmpty) return text;
  if (message.attachments.isNotEmpty) {
    return attachmentPreviewLabel(message.attachments.first);
  }
  if (message.isRetracted) return 'Message unsent';
  return '[附件]';
}

String chatListPreviewText(String? raw, {bool hasMessage = false}) {
  final clean = sanitizeMessageText(raw);
  if (clean == null || isControlLikeText(clean)) {
    return hasMessage ? '[附件]' : '';
  }
  final normalized = clean.toLowerCase();
  switch (normalized) {
    case 'message':
    case 'attachment':
    case 'file':
    case 'obj':
    case 'object':
    case 'null':
      return '[附件]';
  }
  switch (clean) {
    case '（贴纸）':
    case '（图片）':
      return '[附件]';
    case '（语音）':
    case '（音频）':
      return '[附件]';
    case '（视频）':
      return '[附件]';
    case '（链接）':
      return '[附件]';
    case '（文件）':
      return '[附件]';
  }
  return clean;
}

/// A sender label that is never blank/"null"/raw placeholder.
/// [contactName] is the caller's resolved local-contact name (or null).
String resolveSenderLabel(
  MessageModel m, {
  required bool isGroup,
  String? contactName,
}) {
  if (m.isFromMe) return 'You';
  final name = contactName?.trim() ?? '';
  if (name.isNotEmpty) return name;
  final handle = m.handleId?.trim() ?? '';
  if (handle.isNotEmpty) return handle;
  return 'Unknown';
}

/// Short, user-facing label for a service/group event. The server does not
/// expose enough fields to build the precise text, so this is a generic
/// fallback until it does.
String serviceEventLabel(MessageModel m) {
  final t = sanitizeMessageText(m.text);
  if (t != null && !isControlLikeText(t)) return t;
  return 'Conversation event';
}

// ---------------------------------------------------------------------------
// Classification with reasons + debug (C3R)
// ---------------------------------------------------------------------------

/// Why a message ended up unsupported — for diagnostics, not the user.
enum UnsupportedReason {
  none,
  noContent, // no text, no attachments, no metadata
  controlText, // text was a control/typedstream artifact (e.g. "+!")
  unsupportedAttachment, // has attachment(s) but kind/mime is unknown
  missingServerFields, // cacheHasAttachments but no attachments / likely tapback/event the server didn't tag
  emptyEditedResidue, // edited/dateEdited residue with no displayable content
  parseError,
}

String unsupportedReasonLabel(UnsupportedReason r) {
  switch (r) {
    case UnsupportedReason.none:
      return 'supported';
    case UnsupportedReason.noContent:
      return 'no text / no attachment';
    case UnsupportedReason.controlText:
      return 'control-like text';
    case UnsupportedReason.unsupportedAttachment:
      return 'unsupported attachment type';
    case UnsupportedReason.missingServerFields:
      return 'missing server fields';
    case UnsupportedReason.emptyEditedResidue:
      return 'empty edited residue';
    case UnsupportedReason.parseError:
      return 'parse error';
  }
}

/// Full classification of a message.
class MessageClassification {
  final MessageRenderableKind kind;
  final UnsupportedReason reason;
  const MessageClassification(this.kind, this.reason);

  bool get isUnsupported => kind == MessageRenderableKind.unknown;
}

MessageClassification classifyMessage(MessageModel m) {
  final kind = renderableKindFor(m);
  // C26: unrecoverable placeholders render as an unsent row (kind == retracted)
  // but we still surface the underlying diagnostic reason for Message Info/Debug.
  if (m.semanticKind == 'empty_edited_residue' ||
      m.unsupportedReason == 'empty_edited_residue') {
    return MessageClassification(kind, UnsupportedReason.emptyEditedResidue);
  }
  if (m.semanticKind == 'missing_attachment_rows' ||
      m.unsupportedReason == 'missing_attachment_rows') {
    return MessageClassification(kind, UnsupportedReason.unsupportedAttachment);
  }
  if (kind != MessageRenderableKind.unknown) {
    return MessageClassification(kind, UnsupportedReason.none);
  }
  // Unknown: figure out why.
  final rawText = m.text;
  if (rawText != null &&
      rawText.trim().isNotEmpty &&
      isControlLikeText(rawText)) {
    return const MessageClassification(
      MessageRenderableKind.unknown,
      UnsupportedReason.controlText,
    );
  }
  if (m.cacheHasAttachments && m.attachments.isEmpty) {
    return const MessageClassification(
      MessageRenderableKind.unknown,
      UnsupportedReason.missingServerFields,
    );
  }
  if (m.semanticKind == 'empty_edited_residue' ||
      m.unsupportedReason == 'empty_edited_residue' ||
      ((m.isEdited || m.dateEdited != null) && !m.hasAttachments)) {
    return const MessageClassification(
      MessageRenderableKind.unknown,
      UnsupportedReason.emptyEditedResidue,
    );
  }
  return const MessageClassification(
    MessageRenderableKind.unknown,
    UnsupportedReason.noContent,
  );
}

// ---------------------------------------------------------------------------
// Debug inspector (redacted) — Part A
// ---------------------------------------------------------------------------

const _redacted = '<redacted>';

/// Recursively redacts anything credential-like from a decoded JSON value:
/// keys named token/authorization/password/secret/bearer, and any string value
/// that contains a bearer token or `token=` query param.
Object? redactJson(Object? value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    value.forEach((k, v) {
      final key = '$k';
      if (_isSensitiveKey(key)) {
        out[key] = _redacted;
      } else {
        out[key] = redactJson(v);
      }
    });
    return out;
  }
  if (value is List) return value.map(redactJson).toList();
  if (value is String) return _redactString(value);
  return value;
}

bool _isSensitiveKey(String key) {
  final k = key.toLowerCase();
  return k == 'token' ||
      k == 'authorization' ||
      k == 'password' ||
      k == 'secret' ||
      k.contains('bearer') ||
      k.contains('apikey') ||
      k.contains('api_key');
}

String _redactString(String s) {
  var out = s.replaceAll(
    RegExp(r'[Bb]earer\s+[A-Za-z0-9._\-]+'),
    'Bearer $_redacted',
  );
  out = out.replaceAll(
    RegExp(r'([?&]token=)[^&\s]+'),
    r'$1'
    '$_redacted',
  );
  return out;
}

/// A flat, redacted, copy-friendly view of a message for the debug inspector.
Map<String, dynamic> messageDebugMap(MessageModel m) {
  final cls = classifyMessage(m);
  String? clip(String? t) =>
      t == null ? null : (t.length <= 200 ? t : '${t.substring(0, 200)}…');
  return {
    'guid': m.guid,
    'isFromMe': m.isFromMe,
    'handleId': m.handleId,
    'service': m.service ?? m.handleService,
    'classification': cls.kind.name,
    'classificationReason': unsupportedReasonLabel(cls.reason),
    'textLength': m.text?.length ?? 0,
    'textPreview': clip(sanitizeMessageText(m.text)),
    'hasAttachments': m.hasAttachments,
    'semanticKind': m.semanticKind,
    'renderRecommendation': m.renderRecommendation,
    'isDebugOnly': m.isDebugOnly,
    'unsupportedReason': m.unsupportedReason,
    'attachmentCount': m.attachments.length,
    'attachments': [
      for (final a in m.attachments)
        {
          'guid': a.guid,
          'filename': a.filename,
          'transferName': a.transferName,
          'mimeType': a.mimeType,
          'uti': a.uti,
          'attachmentKind': a.attachmentKind,
          'displayKind': a.displayKind,
          'isPreviewableImage': a.isPreviewableImage,
          'needsPreviewConversion': a.needsPreviewConversion,
          'isVoiceMessage': a.isVoiceMessage,
          'totalBytes': a.totalBytes,
          'hasDownloadUrl': a.downloadUrl.isNotEmpty,
        },
    ],
    'dateCreated': m.dateCreated,
    'dateDelivered': m.dateDelivered,
    'dateRead': m.dateRead,
    'itemType': m.itemType,
    'groupActionType': m.groupActionType,
    'groupTitle': m.groupTitle,
    'associatedMessageType': m.associatedMessageType,
    'associatedMessageGuid': m.associatedMessageGuid,
    'errorCode': m.errorCode,
    'raw': redactJson(m.raw),
  };
}

/// Pretty, redacted JSON for the "Copy debug JSON" action.
String messageDebugJson(MessageModel m) =>
    const JsonEncoder.withIndent('  ').convert(messageDebugMap(m));

/// Pretty-prints any already-sanitised JSON value.
String prettyJson(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

// ---------------------------------------------------------------------------
// Thread compatibility diagnostics — Part J
// ---------------------------------------------------------------------------

class ThreadDiagnostics {
  final int total;
  final int text;
  final int image;
  final int audio;
  final int file;
  final int service;
  final int reaction;
  final int unsupported;
  final Map<UnsupportedReason, int> reasons;
  final MessageModel? lastUnsupported;

  const ThreadDiagnostics({
    required this.total,
    required this.text,
    required this.image,
    required this.audio,
    required this.file,
    required this.service,
    required this.reaction,
    required this.unsupported,
    required this.reasons,
    required this.lastUnsupported,
  });

  static const empty = ThreadDiagnostics(
    total: 0,
    text: 0,
    image: 0,
    audio: 0,
    file: 0,
    service: 0,
    reaction: 0,
    unsupported: 0,
    reasons: {},
    lastUnsupported: null,
  );
}

ThreadDiagnostics computeThreadDiagnostics(List<MessageModel> messages) {
  var text = 0,
      image = 0,
      audio = 0,
      file = 0,
      service = 0,
      reaction = 0,
      unsupported = 0;
  final reasons = <UnsupportedReason, int>{};
  MessageModel? lastUnsupported;
  for (final m in messages) {
    final cls = classifyMessage(m);
    switch (cls.kind) {
      case MessageRenderableKind.normal:
        text++;
        break;
      case MessageRenderableKind.attachmentOnly:
        final a = m.attachments.isNotEmpty ? m.attachments.first : null;
        if (a == null) {
          file++;
        } else if (a.canRenderInlineImage) {
          image++;
        } else if (a.isAudio) {
          audio++;
        } else {
          file++;
        }
        break;
      case MessageRenderableKind.service:
      case MessageRenderableKind.retracted:
        service++;
        break;
      case MessageRenderableKind.reaction:
        reaction++;
        break;
      case MessageRenderableKind.unknown:
        unsupported++;
        reasons[cls.reason] = (reasons[cls.reason] ?? 0) + 1;
        lastUnsupported = m;
        break;
    }
  }
  return ThreadDiagnostics(
    total: messages.length,
    text: text,
    image: image,
    audio: audio,
    file: file,
    service: service,
    reaction: reaction,
    unsupported: unsupported,
    reasons: reasons,
    lastUnsupported: lastUnsupported,
  );
}

String threadDiagnosticsReport(ThreadDiagnostics d) {
  final buf = StringBuffer()
    ..writeln('micaGO message compatibility diagnostics')
    ..writeln('total: ${d.total}')
    ..writeln('text: ${d.text}')
    ..writeln('image: ${d.image}  audio: ${d.audio}  file: ${d.file}')
    ..writeln('service: ${d.service}  reaction: ${d.reaction}')
    ..writeln('unsupported: ${d.unsupported}');
  d.reasons.forEach(
    (r, n) => buf.writeln('  - ${unsupportedReasonLabel(r)}: $n'),
  );
  if (d.lastUnsupported != null) {
    buf
      ..writeln('last unsupported:')
      ..writeln(messageDebugJson(d.lastUnsupported!));
  }
  return buf.toString();
}
