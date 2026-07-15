import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/platform/incoming_share_service.dart';
import '../contacts/contacts_service.dart';
import '../settings/message_display_controller.dart';
import 'avatar.dart';
import 'chat_list_controller.dart';
import 'chat_service.dart';
import 'message_render.dart' show chatListPreviewText, chatTimestampLabel;
import 'models/chat_summary.dart';
import 'models/merged_chat.dart';

/// The chat list: loads `GET /api/chats` and shows loading/empty/error/loaded
/// states with pull-to-refresh. Material 3 list rows (no iMessage styling).
/// Selection is delegated to [onOpen] so the same widget works single-pane
/// (push a thread) and two-pane (select into the detail pane).
class ChatListScreen extends StatefulWidget {
  final void Function(MergedChat merged) onOpen;
  final String? selectedGuid;
  final ValueListenable<int>? searchRequests;
  final bool compact;
  final bool sidebar;

  const ChatListScreen({
    super.key,
    required this.onOpen,
    this.selectedGuid,
    this.searchRequests,
    this.compact = false,
    this.sidebar = false,
  });

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late final ChatListController _controller;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  bool _searchOpen = false;
  Timer? _autoRefresh;
  String _registeredShareTargetsKey = '';

  @override
  void initState() {
    super.initState();
    _controller = ChatListController(context.read<AppController>());
    _controller.includeDebug = context
        .read<MessageDisplayController>()
        .prefs
        .showDebugChats;
    _controller.startRealtime();
    widget.searchRequests?.addListener(_openSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.load());
    // C45: a once-a-minute heartbeat — keeps the relative timestamps ("now" →
    // "1m" → "2h") current as time passes, and silently re-pulls the chat list
    // so the unread dot stays correct even if a realtime/WS event was missed
    // (the dot is derived from server data + the read watermark). This is the
    // phone safety net: WS can drop on mobile, but a refresh restores the dot.
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _heartbeat(),
    );
  }

  void _heartbeat() {
    if (!mounted) return;
    setState(() {}); // re-render relative timestamps even when offline
    final app = context.read<AppController>();
    if (app.isForeground && app.api != null) {
      unawaited(_controller.load(showSpinner: false));
    }
  }

  @override
  void didUpdateWidget(covariant ChatListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchRequests != widget.searchRequests) {
      oldWidget.searchRequests?.removeListener(_openSearch);
      widget.searchRequests?.addListener(_openSearch);
    }
    if (!oldWidget.compact && widget.compact) {
      _searchCtrl.clear();
      _searchFocus.unfocus();
      _query = '';
      _searchOpen = false;
    }
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    widget.searchRequests?.removeListener(_openSearch);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (!mounted) return;
    if (widget.compact) return;
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchCtrl.clear();
    _searchFocus.unfocus();
    setState(() {
      _query = '';
      _searchOpen = false;
    });
  }

  // C22: if a notification tap requested a chat GUID, open the matching merged
  // conversation once and clear the request. Done after the frame so it doesn't
  // navigate during build.
  void _maybeOpenPendingChat(List<MergedChat> merged) {
    final app = context.read<AppController>();
    final guid = app.pendingOpenChat.value;
    if (guid == null || guid.isEmpty) return;
    MergedChat? match;
    for (final m in merged) {
      if (m.routes.any((r) => r.guid == guid)) {
        match = m;
        break;
      }
    }
    if (match == null) return;
    final target = match;
    app.clearPendingOpenChat();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openMerged(target);
    });
  }

  void _registerShareTargets(
    List<MergedChat> merged,
    ContactsService contacts,
  ) {
    final app = context.read<AppController>();
    final targets = merged
        .take(8)
        .map((m) {
          return (
            guid: m.primary.guid,
            title: m.primary.displayTitle(resolveName: contacts.displayNameFor),
            avatarKey: m.localCustomizationKey,
            customAvatarPath: app.customAvatarPathFor(m.localCustomizationKey),
            handle: m.primary.isGroup ? null : m.primary.chatIdentifier,
          );
        })
        .toList(growable: false);
    final key = targets
        .map(
          (t) => '${t.guid}\u0000${t.title}\u0000${t.customAvatarPath ?? ''}',
        )
        .join('\u0001');
    if (key == _registeredShareTargetsKey) return;
    _registeredShareTargetsKey = key;
    unawaited(() async {
      final enriched = <({String guid, String title, String? avatarPath})>[];
      for (final target in targets) {
        enriched.add((
          guid: target.guid,
          title: target.title,
          avatarPath: await app.shareTargetAvatarPath(
            customizationKey: target.avatarKey,
            handle: target.handle,
            title: target.title,
          ),
        ));
      }
      await IncomingShareService.registerShareTargets(enriched);
    }());
  }

  void _openMerged(MergedChat merged) {
    _controller.markRoutesRead(merged.routes.map((r) => r.guid));
    widget.onOpen(merged);
  }

  // Swipe right (startToEnd) = clear the unread dot; swipe left (endToStart) =
  // pin/unpin the contact. Both are client-only and keep the row in place.
  Future<bool> _onSwipe(
    BuildContext context,
    MergedChat m,
    DismissDirection dir,
  ) async {
    if (dir == DismissDirection.startToEnd) {
      // Swipe right → clear the unread dot; keep the row in place.
      HapticFeedback.selectionClick();
      await _controller.markRoutesRead(m.routes.map((r) => r.guid));
      return false;
    }
    HapticFeedback.selectionClick();
    await _controller.setPinned(
      m.routes.map((r) => r.guid),
      !m.primary.isPinned,
    );
    return false;
  }

  void _showChatMenu(BuildContext context, MergedChat m) async {
    HapticFeedback.selectionClick();
    final strings = MicaLocalizations.of(context);
    final pinned = m.primary.isPinned;
    final guids = m.routes.map((r) => r.guid).toList();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(strings.t(pinned ? 'chat.unpin' : 'chat.pin')),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(strings.t('chat.hide')),
              onTap: () => Navigator.pop(ctx, 'hide'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'pin':
        await _controller.setPinned(guids, !pinned);
        break;
      case 'hide':
        await _controller.hideChats(guids);
        if (context.mounted) _showHiddenBanner(context);
        break;
    }
  }

  void _showHiddenBanner(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(strings.t('chat.hiddenContact'))));
  }

  List<ChatSummary> _filtered(
    List<ChatSummary> chats,
    ContactsService contacts,
  ) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return chats;
    return chats
        .where((c) {
          final name = c.displayTitle(resolveName: contacts.displayNameFor);
          final hay = [
            c.title,
            name,
            for (final participant in c.participants)
              contacts.displayNameFor(participant) ?? participant,
            c.chatIdentifier ?? '',
            c.service.label,
            c.lastMessagePreview ?? '',
          ].join(' ').toLowerCase();
          return hay.contains(q);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    // React to the "show debug chats" preference: reloads with/without noise.
    _controller.setIncludeDebug(
      context.watch<MessageDisplayController>().prefs.showDebugChats,
    );
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        switch (_controller.state) {
          case ChatListState.idle:
          case ChatListState.loading:
            return const Center(child: CircularProgressIndicator());
          case ChatListState.error:
            final strings = MicaLocalizations.of(context);
            return _ErrorState(
              message:
                  _controller.error ?? strings.t('common.failedToLoadChats'),
              onRetry: () => _controller.load(),
            );
          case ChatListState.empty:
            return RefreshIndicator(
              onRefresh: () => _controller.load(showSpinner: false),
              child: const _EmptyState(),
            );
          case ChatListState.loaded:
            final contacts = context.watch<ContactsService>();
            final chats = _filtered(_controller.chats, contacts);
            // C21: merge a contact's multiple chats (iMessage/SMS routes) into
            // one list entry. Client-side view only; real chat GUIDs are intact.
            final merged = mergeChatsByContact(chats, contacts.contactIdFor);
            _registerShareTargets(merged, contacts);
            // C22: a notification tap requested a specific chat — open it once
            // the list is loaded, then clear the request.
            _maybeOpenPendingChat(merged);
            return Column(
              children: [
                _AnimatedSearchSlot(
                  visible: _searchOpen && !widget.compact,
                  child: _SearchField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: (v) => setState(() => _query = v),
                    onClose: _closeSearch,
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _controller.load(showSpinner: false),
                    child: merged.isEmpty
                        ? _NoMatches(query: _query)
                        : ListView.separated(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              12,
                              12,
                              MediaQuery.paddingOf(context).bottom + 8,
                            ),
                            itemCount: merged.length,
                            separatorBuilder: (_, _) => widget.compact
                                ? const SizedBox(height: 4)
                                : const SizedBox(height: 2),
                            itemBuilder: (context, i) {
                              final m = merged[i];
                              final selected = m.routes.any(
                                (r) => r.guid == widget.selectedGuid,
                              );
                              if (widget.compact) {
                                return _ChatRailRow(
                                  merged: m,
                                  selected: selected,
                                  onTap: () => _openMerged(m),
                                  onLongPress: () => _showChatMenu(context, m),
                                );
                              }
                              return Dismissible(
                                key: ValueKey('chat-${m.primary.guid}'),
                                dismissThresholds: const {
                                  DismissDirection.startToEnd: 0.48,
                                  DismissDirection.endToStart: 0.58,
                                },
                                background: _SwipeBg(
                                  alignment: Alignment.centerLeft,
                                  color: Theme.of(context).colorScheme.primary,
                                  icon: Icons.mark_chat_read_outlined,
                                  label: 'Mark read',
                                ),
                                secondaryBackground: _SwipeBg(
                                  alignment: Alignment.centerRight,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                  icon: m.primary.isPinned
                                      ? Icons.push_pin_outlined
                                      : Icons.push_pin,
                                  label: m.primary.isPinned ? 'Unpin' : 'Pin',
                                ),
                                confirmDismiss: (dir) =>
                                    _onSwipe(context, m, dir),
                                child: _ChatRow(
                                  merged: m,
                                  sidebar: widget.sidebar,
                                  selected: selected,
                                  onTap: () => _openMerged(m),
                                  onLongPress: () => _showChatMenu(context, m),
                                  onDismissUnread: () =>
                                      _controller.markRoutesRead(
                                        m.routes.map((r) => r.guid),
                                      ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            );
        }
      },
    );
  }
}

class _AnimatedSearchSlot extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _AnimatedSearchSlot({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return SizeTransition(
            sizeFactor: animation,
            alignment: AlignmentDirectional.topStart,
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.18),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
          );
        },
        child: visible
            ? KeyedSubtree(key: const ValueKey('search-open'), child: child)
            : const SizedBox(key: ValueKey('search-closed'), height: 0),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: SearchBar(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        hintText: strings.t('chat.searchChats'),
        leading: const Icon(Icons.search),
        trailing: [
          IconButton(icon: const Icon(Icons.close), onPressed: onClose),
        ],
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}

class _ChatRailRow extends StatelessWidget {
  final MergedChat merged;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ChatRailRow({
    required this.merged,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chat = merged.primary;
    final contacts = context.watch<ContactsService>();
    final app = context.watch<AppController>();
    final title = chat.displayTitle(resolveName: contacts.displayNameFor);
    final customAvatarPath = app.customAvatarPathFor(
      merged.localCustomizationKey,
    );
    final testAvatarAsset = app.isTestContactChat(chat.guid)
        ? AppController.testContactAvatarAsset
        : null;
    final unreadCount = merged.unreadCount;
    final hasUnread = merged.hasUnread;
    final muted = app.areChatsMuted(merged.routes.map((r) => r.guid));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.65)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            height: 60,
            child: Stack(
              alignment: Alignment.center,
              children: [
                HandleAvatar(
                  title: title,
                  handle: chat.isGroup ? null : chat.chatIdentifier,
                  participantHandles: chat.participants,
                  isGroup: chat.isGroup,
                  radius: 22,
                  localAvatarPath: customAvatarPath,
                  assetAvatarPath: testAvatarAsset,
                ),
                if (hasUnread)
                  Positioned(
                    top: 9,
                    right: 11,
                    child: muted || unreadCount <= 9
                        ? Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.surface,
                                width: 2,
                              ),
                            ),
                          )
                        : _UnreadCountPill(count: unreadCount),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  final String query;
  const _NoMatches({required this.query});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.2),
        const Icon(Icons.search_off, size: 48),
        const SizedBox(height: 12),
        Center(
          child: Text(
            strings.t('chat.noChatMatches').replaceAll('{query}', query),
          ),
        ),
      ],
    );
  }
}

class _ChatRow extends StatelessWidget {
  final MergedChat merged;
  final bool selected;
  final bool sidebar;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDismissUnread;

  const _ChatRow({
    required this.merged,
    required this.onTap,
    this.sidebar = false,
    this.onLongPress,
    this.onDismissUnread,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chat = merged.primary;
    final unreadCount = merged.unreadCount;
    // C43: the dot is the watermark-derived state; the count is just the number.
    final hasUnread = merged.hasUnread;
    // Prefer a local contact name (1:1) when contacts matching is enabled.
    final contacts = context.watch<ContactsService>();
    final app = context.watch<AppController>();
    final title = chat.displayTitle(resolveName: contacts.displayNameFor);
    final customAvatarPath = app.customAvatarPathFor(
      merged.localCustomizationKey,
    );
    final testAvatarAsset = app.isTestContactChat(chat.guid)
        ? AppController.testContactAvatarAsset
        : null;
    final muted = app.areChatsMuted(merged.routes.map((r) => r.guid));
    final loudUnread = hasUnread && !muted;
    final rowColor = hasUnread
        ? loudUnread
              ? scheme.primary
              : selected
              ? scheme.primaryContainer.withValues(alpha: 0.52)
              : Colors.transparent
        : selected
        ? scheme.primaryContainer.withValues(alpha: 0.52)
        : Colors.transparent;
    final onUnread = scheme.onPrimary;
    final primaryTextColor = loudUnread ? onUnread : scheme.onSurface;
    final secondaryTextColor = loudUnread
        ? onUnread.withValues(alpha: 0.78)
        : scheme.onSurfaceVariant;
    final horizontalMargin = 0.0;
    final verticalMargin = sidebar ? 5.0 : 2.0;
    final horizontalPadding = sidebar ? 16.0 : 14.0;
    final verticalPadding = sidebar ? 12.0 : 10.0;
    final minHeight = sidebar ? 84.0 : 72.0;
    final avatarRadius = sidebar ? 24.0 : 25.0;
    // C44: a custom row (not ListTile) — ListTile rejects a trailing wider than
    // the tile, which the draggable badge could trip and white-screen the page.
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalMargin,
        vertical: verticalMargin,
      ),
      child: Material(
        color: rowColor,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Row(
                children: [
                  HandleAvatar(
                    title: title,
                    handle: chat.isGroup ? null : chat.chatIdentifier,
                    participantHandles: chat.participants,
                    isGroup: chat.isGroup,
                    radius: avatarRadius,
                    localAvatarPath: customAvatarPath,
                    assetAvatarPath: testAvatarAsset,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: primaryTextColor,
                                  fontWeight: hasUnread
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            // C21: route count (iMessage + SMS, etc.).
                            if (merged.isMerged) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.merge_type,
                                size: 13,
                                color: secondaryTextColor,
                              ),
                            ],
                            if (muted) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.notifications_off_outlined,
                                size: 14,
                                color: secondaryTextColor,
                              ),
                            ],
                            if (chat.isArchived) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.archive_outlined,
                                size: 14,
                                color: secondaryTextColor,
                              ),
                            ],
                            if (chat.isPinned) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.push_pin,
                                size: 13,
                                color: secondaryTextColor,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: secondaryTextColor),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _trailing(
                    context,
                    hasUnread,
                    unreadCount,
                    unreadForeground: onUnread,
                    muted: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    final preview = chatListPreviewText(
      merged.lastMessagePreview,
      hasMessage: merged.lastMessageAt != null,
    );
    if (preview.isNotEmpty) return preview;
    final chat = merged.primary;
    // For a merged contact, label the available routes (e.g. "iMessage · SMS");
    // otherwise the single service label. Server-authoritative, never guessed.
    final parts = <String>[
      if (merged.isMerged)
        merged.routes
            .map((r) => r.service.label)
            .toSet()
            .where((l) => l != 'Unknown')
            .join(' · ')
      else if (chat.service != ChatService.unknown)
        chat.service.label,
      if (chat.isGroup) 'Group',
    ].where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty && chat.chatIdentifier != null) {
      return chat.chatIdentifier!;
    }
    return parts.join(' · ');
  }

  Widget _trailing(
    BuildContext context,
    bool hasUnread,
    int unreadCount, {
    required Color unreadForeground,
    required bool muted,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final time = merged.lastMessageAt;
    if (time == null && !hasUnread) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    // Badge is draggable: flick it away to mark the chat read (C43).
    final badge = hasUnread
        ? _DraggableUnreadBadge(
            onDismiss: onDismissUnread ?? () {},
            child: muted
                ? const _UnreadDot()
                : unreadCount > 0
                ? _UnreadCountPill(count: unreadCount)
                : const _UnreadDot(),
          )
        : null;
    // C45: time on top, badge below, centered on a single vertical line so the
    // dot sits directly under the timestamp (the badge's transparent hit-padding
    // would otherwise nudge a right-aligned badge off the time's right edge).
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (time != null)
          Text(
            _formatTime(context, time),
            style: textTheme.bodySmall?.copyWith(
              color: hasUnread && !muted
                  ? unreadForeground
                  : scheme.onSurfaceVariant,
              fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        if (badge != null) ...[const SizedBox(height: 4), badge],
      ],
    );
  }

  // C46: the last-message timestamp, the way phones show it:
  //   • under 1 min     → "now"
  //   • under 1 hour    → "5m" (relative)
  //   • same day        → clock time, 12h/24h per the system setting (e.g. 06:06)
  //   • within 7 days   → weekday in the app's language (e.g. Monday / 星期一)
  //   • older           → numeric date in the app's locale (e.g. 12/06/2026)
  String _formatTime(BuildContext context, int unixMs) {
    // C65: pass the full language tag — the relative buckets need the script
    // (分钟 vs 分鐘); intl date symbols resolve from the tag the same way.
    return chatTimestampLabel(
      DateTime.fromMillisecondsSinceEpoch(unixMs),
      now: DateTime.now(),
      use24h: MediaQuery.maybeOf(context)?.alwaysUse24HourFormat ?? false,
      locale: Localizations.localeOf(context).toLanguageTag(),
    );
  }
}

class _SwipeBg extends StatelessWidget {
  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;
  const _SwipeBg({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final left = alignment == Alignment.centerLeft;
    return Container(
      color: color.withValues(alpha: 0.85),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (left) Icon(icon, color: Colors.white),
          if (left) const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (!left) const SizedBox(width: 8),
          if (!left) Icon(icon, color: Colors.white),
        ],
      ),
    );
  }
}

/// Red number pill (white digits). Shown when hasUnread && unreadCount > 0.
class _UnreadCountPill extends StatelessWidget {
  final int count;

  const _UnreadCountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final label = count > 9999 ? '9999+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 24, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30), // iOS-style red badge
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          height: 1.1,
        ),
      ),
    );
  }
}

/// Plain unread dot (no number) in the theme's accent color. Shown when
/// hasUnread is true but there is no tracked count (notifications were off).
class _UnreadDot extends StatelessWidget {
  const _UnreadDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Makes its [child] badge draggable, iOS-/Telegram-style: long-press to grab,
/// pull it away (it stretches/scales with the pull), and on release past the
/// threshold it plays a pop-and-fade dismiss (marks the chat read); under the
/// threshold it springs back. Dragging never opens the chat.
class _DraggableUnreadBadge extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismiss;
  const _DraggableUnreadBadge({required this.child, required this.onDismiss});

  @override
  State<_DraggableUnreadBadge> createState() => _DraggableUnreadBadgeState();
}

class _DraggableUnreadBadgeState extends State<_DraggableUnreadBadge>
    with TickerProviderStateMixin {
  // Release past this distance to dismiss; under it, spring back.
  static const double _threshold = 44;
  // Transparent padding around the visible badge that enlarges the grab area.
  static const double _hitPadding = 9;

  Offset _drag = Offset.zero;
  bool _dragging = false;
  bool _dismissing = false;
  bool _pastThreshold = false;

  // Eager (not lazy `late = …`): a lazy field first built inside dispose()
  // touches an inherited widget on a deactivated element and crashes (C44).
  late final AnimationController _spring;
  late final AnimationController _pop;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _pop = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _spring.dispose();
    _pop.dispose();
    super.dispose();
  }

  /// Grows the badge as it is pulled — ~1.0 at rest up to ~1.35 at the threshold.
  double get _dragScale {
    final t = (_drag.distance / _threshold).clamp(0.0, 1.0);
    return 1.0 + 0.35 * Curves.easeOut.transform(t);
  }

  void _springBack() {
    final from = _drag;
    final anim = Tween<Offset>(
      begin: from,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _spring, curve: Curves.elasticOut));
    void tick() => setState(() => _drag = anim.value);
    anim.addListener(tick);
    _spring.forward(from: 0).whenComplete(() => anim.removeListener(tick));
  }

  void _beginDismiss() {
    HapticFeedback.mediumImpact();
    setState(() => _dismissing = true);
    _pop.forward(from: 0).whenComplete(() {
      if (mounted) widget.onDismiss(); // parent rebuild then drops the badge
    });
  }

  @override
  Widget build(BuildContext context) {
    final badge = Padding(
      padding: const EdgeInsets.all(_hitPadding),
      child: widget.child,
    );

    // Pop-and-fade: keep flinging in the drag direction, scale up, fade out.
    if (_dismissing) {
      return AnimatedBuilder(
        animation: _pop,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_pop.value);
          final dir = _drag.distance == 0
              ? Offset.zero
              : _drag / _drag.distance;
          final offset = _drag + dir * (30 * t);
          final scale = (_dragScale + 0.25) - 0.1 * t;
          return Opacity(
            opacity: 1 - t,
            child: Transform.translate(
              offset: offset,
              child: Transform.scale(scale: scale, child: badge),
            ),
          );
        },
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) {
        _spring.stop();
        HapticFeedback.selectionClick();
        setState(() => _dragging = true);
      },
      onLongPressMoveUpdate: (d) {
        final past = d.localOffsetFromOrigin.distance > _threshold;
        if (past != _pastThreshold) {
          _pastThreshold = past;
          HapticFeedback.lightImpact(); // tick when crossing the dismiss line
        }
        setState(() => _drag = d.localOffsetFromOrigin);
      },
      onLongPressEnd: (_) {
        setState(() => _dragging = false);
        if (_drag.distance > _threshold) {
          _beginDismiss();
        } else {
          _springBack();
        }
        _pastThreshold = false;
      },
      child: Transform.translate(
        offset: _drag,
        child: Transform.scale(
          scale: _dragging ? _dragScale : 1.0,
          child: badge,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.25),
        const Icon(Icons.chat_bubble_outline, size: 56),
        const SizedBox(height: 12),
        const Center(child: Text('No chats yet')),
        const SizedBox(height: 4),
        Center(
          child: Text(
            'Pull down to refresh.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(MicaLocalizations.of(context).t('common.retry')),
            ),
          ],
        ),
      ),
    );
  }
}
