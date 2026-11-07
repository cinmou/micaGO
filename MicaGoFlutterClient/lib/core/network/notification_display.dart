import 'dart:io';
import 'dart:convert';
import 'package:micago_conversations/micago_conversations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_store.dart';
import 'linux_notification_avatar.dart';
import 'push_logic.dart';
import '../platform/linux_desktop.dart';
import '../l10n/app_localizations.dart';

final _linuxPosted =
    <
      String,
      ({String guid, int timestamp, FlutterLocalNotificationsPlugin plugin})
    >{};
final _linuxSeen = <String>{};
Future<void> _linuxWork = Future<void>.value();

Future<void> _serializeLinux(Future<void> Function() action) {
  final next = _linuxWork.then((_) => action());
  _linuxWork = next.catchError((Object _) {});
  return next;
}

Future<void> clearSuppressedLinuxNotifications(
  bool Function(String chatGuid, String messageGuid) suppressed,
) async {
  if (!isLinuxDesktop) return;
  await _serializeLinux(() async {
    for (final chat in _linuxPosted.keys.toList()) {
      if (!suppressed(chat, _linuxPosted[chat]!.guid)) continue;
      await _linuxPosted[chat]!.plugin.cancel(notificationIdForChat(chat));
      _linuxPosted.remove(chat);
    }
  });
}

Future<void> cancelLinuxNotificationThrough(String chat, int through) =>
    _serializeLinux(() async {
      final latest = _linuxPosted[chat];
      if (latest == null ||
          latest.timestamp <= 0 ||
          latest.timestamp > through) {
        return;
      }
      await _linuxPosted[chat]!.plugin.cancel(notificationIdForChat(chat));
      _linuxPosted.remove(chat);
    });

/// C31/C32 — the single place that defines how a message notification looks and
/// is identified. Every path that shows one (the FCM background isolate and the
/// keep-alive main isolate) goes through here so they are visually identical
/// (Android MessagingStyle, grouped per chat) and dedupe against each other.

/// High-importance channel (heads-up) for new message notifications.
const String messageChannelId = 'micago_messages';
const String messageChannelName = 'Messages';
const String messageChannelDescription = 'New message notifications';
const String androidNotificationSmallIcon = 'ic_stat_micago_notification';
const String androidTestContactAvatar = 'micago_test_contact_avatar';

/// All message notifications share this group so the OS bundles them
/// (BlueBubbles parity).
const String messageGroupKey = 'micago.messages';

/// Direct-reply (Android RemoteInput) action + input identifiers. Replying from
/// the notification sends the text straight to the chat via the backend.
const String notificationReplyActionId = 'micago_reply';
const String notificationReadActionId = 'micago_mark_read';

/// The Android channel created at init time. High importance so messages can
/// surface as heads-up notifications.
const AndroidNotificationChannel messageNotificationChannel =
    AndroidNotificationChannel(
      messageChannelId,
      messageChannelName,
      description: messageChannelDescription,
      importance: Importance.high,
    );

/// Deterministic FNV-1a 32-bit hash (masked positive). MUST be stable across
/// isolates/processes — the FCM notification is shown from a separate background
/// isolate while the keep-alive one is shown from the main isolate, and
/// `String.hashCode` is seeded per-isolate. A shared, stable id is what lets the
/// two paths collapse into ONE notification (C31).
int _stableId(String s) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    hash ^= s.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Stable id for a single message GUID (kept for the cross-isolate dedup test).
int notificationIdForMessage(String? messageGuid) =>
    _stableId(messageGuid ?? '');

/// C32: stable id keyed by **chat** — every message in a chat updates the same
/// notification, so new messages stack into one MessagingStyle conversation
/// instead of creating a separate notification each time.
int notificationIdForChat(String chatKey) => _stableId(chatKey);

/// Whether the OS currently allows notifications (Android 13+ POST_NOTIFICATIONS).
/// Returns null on platforms without the concept. Cheap — does not require the
/// plugin to be initialized first.
Future<bool?> systemNotificationsEnabled() async {
  return FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.areNotificationsEnabled();
}

/// Prompts for the Android 13+ POST_NOTIFICATIONS permission (no-op below 13 or
/// when already granted). Returns the resulting grant state, or null off-Android.
Future<bool?> requestSystemNotificationPermission() async {
  return FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
}

/// C32: shows a native-style **MessagingStyle** notification for an incoming
/// message. Messages for the same chat stack into a single conversation
/// notification (keyed by chat), titled with the contact/chat name and showing
/// the sender's avatar when [avatarFilePath] is provided (a default monogram
/// otherwise). [senderName]/[conversationTitle]/[body] must already be resolved
/// (contact name, preview mode applied). The chat's preview buffer accumulates
/// across pushes so prior unread lines remain visible, and dedupes by
/// [messageGuid] so an FCM + keep-alive delivery of the same message is shown
/// once. Inline reply sends an ordinary new message on the notified route.
Future<void> showMessageNotification(
  FlutterLocalNotificationsPlugin plugin, {
  required String? chatGuid,
  required String messageGuid,
  String? deviceId,
  String replyLabel = 'Reply',
  String replyHint = 'Message',
  String readLabel = 'Mark as read',
  required String senderName,
  required String conversationTitle,
  String? senderKey,
  String? body,
  String? avatarFilePath,
  String? conversationAvatarFilePath,
  String? avatarDrawableResource,
  String? conversationAvatarDrawableResource,
  bool isGroup = false,
  int? timestampMs,
}) async {
  // For a chat-less message (shouldn't normally happen) fall back to the message
  // guid so it still shows as its own notification.
  final chatKey = (chatGuid == null || chatGuid.isEmpty)
      ? messageGuid
      : chatGuid;
  final ts = timestampMs != null && timestampMs > 0
      ? timestampMs
      : DateTime.now().millisecondsSinceEpoch;
  final preview = (body == null || body.trim().isEmpty) ? 'New message' : body;

  if (isLinuxDesktop) {
    await _serializeLinux(() async {
      final identity = '$chatKey\u001f$messageGuid';
      final latest = _linuxPosted[chatKey];
      if (_linuxSeen.contains(identity) ||
          latest?.guid == messageGuid ||
          (latest != null && latest.timestamp > ts)) {
        return;
      }
      String? avatarPath;
      for (final path in [avatarFilePath, conversationAvatarFilePath]) {
        if (path == null) continue;
        avatarPath = await circularLinuxNotificationAvatar(path);
        if (avatarPath != null) break;
      }
      await plugin.show(
        notificationIdForChat(chatKey),
        conversationTitle,
        const HtmlEscape(HtmlEscapeMode.element).convert(
          body == null || body.trim().isEmpty
              ? MicaLocalizations.current.t('chat.newMessage')
              : preview,
        ),
        NotificationDetails(
          linux: LinuxNotificationDetails(
            icon: avatarPath == null ? null : FilePathLinuxIcon(avatarPath),
            category: LinuxNotificationCategory.imReceived,
            urgency: LinuxNotificationUrgency.normal,
          ),
        ),
        payload: chatGuid == null
            ? null
            : notificationPayload(
                chatGuid,
                deviceId ?? '',
                readThrough: timestampMs ?? 0,
              ),
      );
      _linuxSeen.add(identity);
      if (_linuxSeen.length > 512) _linuxSeen.remove(_linuxSeen.first);
      _linuxPosted[chatKey] = (
        guid: messageGuid,
        timestamp: timestampMs ?? 0,
        plugin: plugin,
      );
    });
    return;
  }

  final buffered = BufferedNotifMessage(
    guid: messageGuid,
    sender: senderName,
    senderKey: (senderKey == null || senderKey.trim().isEmpty)
        ? senderName
        : senderKey.trim(),
    text: preview,
    ts: ts,
    readThrough: timestampMs,
    avatarPath: avatarFilePath,
    avatarResource: avatarDrawableResource,
  );
  // Only chat notifications stack. A chat-less push (e.g. the server test
  // notification) has no open/read/reply path that could ever clear a buffer,
  // so buffering it would re-show every earlier copy forever; it replaces its
  // previous notification instead.
  final buffer = chatGuid?.isNotEmpty == true
      ? await appendChatNotification(chatKey, buffered, deviceId: deviceId)
      : [buffered];

  if (avatarFilePath != null && !await File(avatarFilePath).exists()) {
    avatarFilePath = null;
  }
  if (conversationAvatarFilePath != null &&
      !await File(conversationAvatarFilePath).exists()) {
    conversationAvatarFilePath = null;
  }
  final effectiveSenderKey = senderKey?.trim().isNotEmpty == true
      ? senderKey!.trim()
      : senderName;
  final avatar = avatarDrawableResource != null
      ? DrawableResourceAndroidIcon(avatarDrawableResource)
      : avatarFilePath != null
      ? BitmapFilePathAndroidIcon(avatarFilePath)
      : null;
  final largeIcon = conversationAvatarDrawableResource != null
      ? DrawableResourceAndroidBitmap(conversationAvatarDrawableResource)
      : conversationAvatarFilePath != null
      ? FilePathAndroidBitmap(conversationAvatarFilePath)
      : null;
  Person notificationSender(BufferedNotifMessage m) {
    final icon = m.senderKey == effectiveSenderKey
        ? avatar
        : m.avatarResource != null
        ? DrawableResourceAndroidIcon(m.avatarResource!)
        : m.avatarPath != null && File(m.avatarPath!).existsSync()
        ? BitmapFilePathAndroidIcon(m.avatarPath!)
        : null;
    return Person(
      name: m.sender,
      key: m.senderKey.isEmpty ? m.sender : m.senderKey,
      icon: icon,
    );
  }

  final messages = <Message>[
    for (final m in buffer)
      Message(
        m.text,
        DateTime.fromMillisecondsSinceEpoch(m.ts),
        notificationSender(m),
      ),
  ];

  final style = MessagingStyleInformation(
    const Person(name: 'You'),
    conversationTitle: isGroup ? conversationTitle : null,
    groupConversation: isGroup,
    messages: messages,
  );

  final through = buffer.every((m) => (m.readThrough ?? 0) > 0)
      ? buffer.fold<int>(
          0,
          (at, m) => m.readThrough! > at ? m.readThrough! : at,
        )
      : 0;
  final payload = chatGuid == null
      ? null
      : deviceId?.isNotEmpty == true
      ? notificationPayload(chatGuid, deviceId!, readThrough: through)
      : chatGuid;
  String? shortcutId;
  if (Platform.isAndroid &&
      chatGuid?.isNotEmpty == true &&
      deviceId?.isNotEmpty == true) {
    try {
      shortcutId = await AndroidConversations.publish(
        chatGuid: chatGuid!,
        deviceId: deviceId!,
        title: conversationTitle,
        payload: payload!,
        personName: senderName,
        personKey: effectiveSenderKey,
        personAvatarPath: avatarFilePath,
        avatarPath:
            conversationAvatarFilePath ?? (isGroup ? null : avatarFilePath),
      );
    } catch (_) {
      /* System limits must not suppress message delivery. */
    }
  }
  final android = AndroidNotificationDetails(
    messageChannelId,
    messageChannelName,
    channelDescription: messageChannelDescription,
    icon: androidNotificationSmallIcon,
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.message,
    groupKey: messageGroupKey,
    styleInformation: style,
    shortcutId: shortcutId,
    largeIcon: largeIcon,
    when: ts,
    actions: chatGuid?.isNotEmpty == true && deviceId?.isNotEmpty == true
        ? [
            AndroidNotificationAction(
              notificationReplyActionId,
              replyLabel,
              inputs: [AndroidNotificationActionInput(label: replyHint)],
              cancelNotification: false,
              showsUserInterface: false,
            ),
            if (through > 0)
              AndroidNotificationAction(
                notificationReadActionId,
                readLabel,
                cancelNotification: false,
                showsUserInterface: false,
              ),
          ]
        : null,
  );

  await plugin.show(
    notificationIdForChat(chatKey),
    conversationTitle,
    preview,
    NotificationDetails(android: android),
    payload: payload,
  );
}

/// C32: clears a chat's stacked notification + its preview buffer (called when
/// the user opens that chat, so the conversation notification goes away).
Future<void> cancelChatNotification(
  FlutterLocalNotificationsPlugin plugin,
  String chatGuid,
) async {
  if (chatGuid.isEmpty) return;
  if (isLinuxDesktop) {
    await _serializeLinux(() async {
      await plugin.cancel(notificationIdForChat(chatGuid));
      _linuxPosted.remove(chatGuid);
    });
    return;
  }
  await clearChatNotificationBuffer(chatGuid);
  await plugin.cancel(notificationIdForChat(chatGuid));
}

/// Native check-and-cancel stays on Android's main thread alongside posting.
Future<void> cancelNotificationThrough(String payload) async {
  final target = NotificationTarget.parse(payload);
  final chat = target?.chatGuid;
  final through = target?.readThrough;
  if (chat == null || through == null) return;
  await clearChatNotificationBuffer(
    chat,
    through: through,
    deviceId: target?.deviceId,
  );
  if (!Platform.isAndroid) return;
  await AndroidConversations.cancelThrough(
    notificationIdForChat(chat),
    through,
  );
}

Future<void> clearSystemNotificationState() async {
  if (isLinuxDesktop) {
    await _serializeLinux(() async {
      try {
        await FlutterLocalNotificationsPlugin().cancelAll();
        await clearLinuxNotificationAvatars();
      } finally {
        _linuxPosted.clear();
        _linuxSeen.clear();
      }
    }).catchError((Object _) {});
    return;
  }
  if (!Platform.isAndroid) return;
  try {
    await FlutterLocalNotificationsPlugin().cancelAll();
  } catch (_) {}
  try {
    await AndroidConversations.clear();
  } catch (_) {}
}
