import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_store.dart';

/// C31/C32 — the single place that defines how a message notification looks and
/// is identified. Every path that shows one (the FCM background isolate and the
/// keep-alive main isolate) goes through here so they are visually identical
/// (Android MessagingStyle, grouped per chat) and dedupe against each other.

/// High-importance channel (heads-up) for new message notifications.
const String messageChannelId = 'micago_messages';
const String messageChannelName = 'Messages';
const String messageChannelDescription = 'New message notifications';
const String androidNotificationSmallIcon = 'ic_stat_micago_notification';

/// All message notifications share this group so the OS bundles them
/// (BlueBubbles parity).
const String messageGroupKey = 'micago.messages';

/// Direct-reply (Android RemoteInput) action + input identifiers. Replying from
/// the notification sends the text straight to the chat via the backend.
const String notificationReplyActionId = 'micago_reply';
const String notificationReplyInputId = 'micago_reply_text';

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
/// once. No reply action this pass (deferred). [chatGuid] is the tap payload.
Future<void> showMessageNotification(
  FlutterLocalNotificationsPlugin plugin, {
  required String? chatGuid,
  required String messageGuid,
  required String senderName,
  required String conversationTitle,
  String? senderKey,
  String? body,
  String? avatarFilePath,
  String? conversationAvatarFilePath,
  bool isGroup = false,
  int? timestampMs,
}) async {
  // For a chat-less message (shouldn't normally happen) fall back to the message
  // guid so it still shows as its own notification.
  final chatKey = (chatGuid == null || chatGuid.isEmpty)
      ? messageGuid
      : chatGuid;
  final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
  final preview = (body == null || body.trim().isEmpty) ? 'New message' : body;

  final buffer = await appendChatNotification(
    chatKey,
    BufferedNotifMessage(
      guid: messageGuid,
      sender: senderName,
      senderKey: (senderKey == null || senderKey.trim().isEmpty)
          ? senderName
          : senderKey.trim(),
      text: preview,
      ts: ts,
    ),
  );

  final BitmapFilePathAndroidIcon? avatar = avatarFilePath != null
      ? BitmapFilePathAndroidIcon(avatarFilePath)
      : null;
  final FilePathAndroidBitmap? largeIcon = conversationAvatarFilePath != null
      ? FilePathAndroidBitmap(conversationAvatarFilePath)
      : null;
  final messages = <Message>[
    for (final m in buffer)
      Message(
        m.text,
        DateTime.fromMillisecondsSinceEpoch(m.ts),
        Person(
          name: m.sender,
          key: m.senderKey.isEmpty ? m.sender : m.senderKey,
          icon: m.senderKey == senderKey || m.sender == senderName
              ? avatar
              : null,
        ),
      ),
  ];

  final style = MessagingStyleInformation(
    const Person(name: 'You'),
    conversationTitle: isGroup ? conversationTitle : null,
    groupConversation: isGroup,
    messages: messages,
  );

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
    largeIcon: largeIcon,
    when: ts,
  );

  await plugin.show(
    notificationIdForChat(chatKey),
    conversationTitle,
    preview,
    NotificationDetails(android: android),
    payload: chatGuid,
  );
}

/// C32: clears a chat's stacked notification + its preview buffer (called when
/// the user opens that chat, so the conversation notification goes away).
Future<void> cancelChatNotification(
  FlutterLocalNotificationsPlugin plugin,
  String chatGuid,
) async {
  if (chatGuid.isEmpty) return;
  await clearChatNotificationBuffer(chatGuid);
  await plugin.cancel(notificationIdForChat(chatGuid));
}
