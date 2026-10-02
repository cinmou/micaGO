import 'message_preference_status.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'chat_preference_status.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/network/notification_display.dart';
import '../../core/network/update_check.dart';
import '../../core/network/websocket_client.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/connection_candidate.dart';
import '../../core/network/device_identity.dart';
import '../../core/storage/local_cache_store.dart';
import '../../core/theme_controller.dart';
import '../../core/ui/glass_theme_widgets.dart';
import '../../core/ui/top_banner.dart';
import '../chats/chat_service.dart';
import '../chats/message_render.dart';
import '../chats/models/chat_summary.dart';
import '../chats/models/message_model.dart';
import '../contacts/people_screen.dart';
import '../debug/debug_log_panel.dart';
import 'backup_restore_ui.dart';
import 'message_display_page.dart';
import '../../core/ui/app_dialog.dart';

/// Settings tab: shows the current connection (token masked), and lets the user
/// edit the connection or disconnect. Kept minimal for C1.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<bool>? _compatibilityStatus;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    _compatibilityStatus ??= app.store.compatibilityStorageEnabled();
    // C61: persisted on the controller (SecureStore-backed) so the entry no
    // longer vanishes when this screen is rebuilt or the app restarts.
    final testingAndDebugUnlocked = app.developerModeEnabled;
    final profile = app.profile;
    final theme = context.watch<ThemeController>();
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final glassBg = liquidGlassPageColor(context);
    final headerBg = theme.useLiquidGlass
        ? glassBg
        : _settingsAccent1_100(scheme);
    final pageBg = theme.useLiquidGlass ? glassBg : _settingsAccent1_50(scheme);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.t('nav.settings')),
        backgroundColor: headerBg,
        surfaceTintColor: Colors.transparent,
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(color: headerBg),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: DecoratedBox(
            decoration: BoxDecoration(color: pageBg),
            child: SafeArea(
              top: false,
              bottom: false,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  16 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  Text(
                    strings.t('settings.connection'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (profile != null)
                    _RouteSwitcher(
                      app: app,
                      onEdit: () => context.push(Routes.connection),
                    )
                  else
                    Card(
                      child: ListTile(
                        leading: _leadingIcon(Icons.link_off_outlined),
                        title: Text(strings.t('settings.connection')),
                        subtitle: Text(
                          strings.t('settings.testContactUnreachable'),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push(Routes.connection),
                      ),
                    ),
                  if (profile != null)
                    FutureBuilder<bool>(
                      future: _compatibilityStatus,
                      builder: (context, snapshot) => snapshot.data == true
                          ? Card(
                              child: ListTile(
                                leading: _leadingIcon(Icons.security_outlined),
                                title: Text(
                                  strings.t('settings.credentialCompatibility'),
                                ),
                                subtitle: Text(
                                  strings.t(
                                    'settings.credentialCompatibilityDetail',
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  const SizedBox(height: 20),
                  Text(
                    strings.t('settings.general'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _GeneralSettingsCard(app: app, push: _push),
                  const SizedBox(height: 20),
                  Text(
                    strings.t('settings.notifications'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _NotificationsCard(app: app),
                  const SizedBox(height: 20),
                  Text(
                    strings.t('settings.backupRestore'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  const _BackupRestoreCard(),
                  const SizedBox(height: 20),
                  Text(
                    strings.t('settings.hiddenItems'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _HiddenItemsCard(app: app),
                  const SizedBox(height: 20),
                  Text(
                    strings.t('settings.more'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: [
                        if (testingAndDebugUnlocked) ...[
                          ListTile(
                            leading: _leadingIcon(Icons.developer_mode),
                            title: Text(strings.t('settings.developerMode')),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _push(
                              context,
                              strings.t('settings.developerMode'),
                              _DeveloperModeBody(app: app),
                            ),
                          ),
                          const Divider(height: 1),
                        ],
                        ListTile(
                          leading: _leadingIcon(Icons.info_outline),
                          title: Text(strings.t('settings.about')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _push(
                            context,
                            strings.t('settings.about'),
                            const _AboutBody(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // C76: one destructive action, styled as such. "Edit
                  // connection" was removed — it opened the same page as the
                  // connection card above, so two equal-looking buttons led to
                  // very different places (one reversible, one wiping the
                  // pairing + local cache).
                  if (profile != null) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _confirmDisconnect(context, app),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error,
                          side: BorderSide(
                            color: scheme.error.withValues(alpha: 0.5),
                          ),
                        ),
                        icon: const Icon(Icons.link_off),
                        label: Text(strings.t('settings.unpair')),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Center(
                    child: Column(
                      children: [
                        Text(
                          strings
                              .t('settings.versionFooter')
                              .replaceAll('{version}', kAppVersion),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Built with ♥️ for everyone.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Pushes a Settings sub-page wrapped in its own Scaffold (title + back).
  void _push(BuildContext context, String title, Widget body) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SettingsSubPage(title: title, child: body),
      ),
    );
  }

  Future<void> _confirmDisconnect(
    BuildContext context,
    AppController app,
  ) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        icon: Icon(Icons.link_off, color: scheme.error),
        title: Text(MicaLocalizations.of(ctx).t('settings.unpairTitle')),
        content: Text(MicaLocalizations.of(ctx).t('settings.unpairBody')),

        cancelLabel: MicaLocalizations.of(ctx).t('settings.cancel'),
        onCancel: () => Navigator.pop(ctx, false),
        confirmLabel: MicaLocalizations.of(ctx).t('settings.unpairConfirm'),
        onConfirm: () => Navigator.pop(ctx, true),
        destructive: true,
      ),
    );
    if (confirmed == true) {
      await app.signOut();
      if (context.mounted) context.go(Routes.connection);
    }
  }
}

Widget _leadingIcon(IconData icon, {Color? color}) => SizedBox(
  width: 40,
  child: Center(child: Icon(icon, color: color)),
);

class _TwoActionRow extends StatelessWidget {
  final Widget primary;
  final Widget secondary;

  const _TwoActionRow({required this.primary, required this.secondary});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: primary),
        const SizedBox(width: 8),
        Expanded(child: secondary),
      ],
    );
  }
}

/// C85: every advertised route with its full address and live status. The
/// radio marks the route in use; tapping an available route switches to it
/// now and keeps it until it drops, after which selection is automatic again.
/// Rows that are still being checked or are unavailable can't be tapped — the
/// check only decides that, it never switches or disconnects.
class _RouteSwitcher extends StatefulWidget {
  final AppController app;

  /// C76: the connection card is the single entry point for editing the
  /// pairing (the old duplicate "Edit connection" button is gone).
  final VoidCallback onEdit;
  const _RouteSwitcher({required this.app, required this.onEdit});

  @override
  State<_RouteSwitcher> createState() => _RouteSwitcherState();
}

class _RouteSwitcherState extends State<_RouteSwitcher> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.app.probeAllRoutes());
  }

  Future<void> _switchTo(String baseUrl) async {
    final strings = MicaLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.app.selectRoute(baseUrl);
    final key = switch (result) {
      RouteSwitchResult.switched => 'settings.routeSwitchedToast',
      RouteSwitchResult.fellBack => 'settings.routeFellBackToast',
      RouteSwitchResult.unreachable => 'settings.routeSwitchFailedToast',
      RouteSwitchResult.superseded => null,
    };
    if (key == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.t(key))));
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final strings = MicaLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([app, app.ws]),
      builder: (context, _) {
        final routes = app.routeOptions;
        final active = app.activeCandidate?.baseUrl;
        final switching = app.switchingRoute;
        final statuses = {
          for (final c in routes)
            c.baseUrl: routeRowStatus(
              baseUrl: c.baseUrl,
              switchingTo: switching,
              activeBaseUrl: active,
              realtimeConnected: app.ws.status == WsStatus.connected,
              probing: app.isProbingRoute(c.baseUrl),
              probe: app.routeProbes[c.baseUrl],
            ),
        };
        final activeStatus = statuses[active];
        final inUse = switching != null && statuses.containsKey(switching)
            ? switching
            : activeStatus == RouteRowStatus.connected ||
                  activeStatus == RouteRowStatus.connecting
            ? active
            : null;
        final muted = scheme.onSurface.withValues(alpha: 0.38);

        Widget statusText(String baseUrl, RouteRowStatus status) {
          final ms = app.routeProbes[baseUrl]?.latency?.inMilliseconds;
          String withMs(String label) => ms == null ? label : '$label · $ms ms';
          return switch (status) {
            RouteRowStatus.switching => Text(
              strings.t('settings.routeSwitching'),
              style: TextStyle(color: scheme.primary),
            ),
            RouteRowStatus.connected => Text(
              withMs(strings.t('settings.routeConnected')),
              style: TextStyle(color: scheme.primary),
            ),
            RouteRowStatus.connecting => Text(
              strings.t('settings.routeConnecting'),
            ),
            RouteRowStatus.checking => Text(
              strings.t('settings.routeChecking'),
              style: TextStyle(color: muted),
            ),
            RouteRowStatus.available => Text(
              withMs(strings.t('settings.routeReachable')),
            ),
            RouteRowStatus.unavailable => Text(
              strings.t('settings.routeUnreachable'),
              style: TextStyle(color: muted),
            ),
          };
        }

        return Card(
          child: RadioGroup<String>(
            groupValue: inUse,
            onChanged: (value) {
              if (value == null || value == inUse) return;
              if (statuses[value] != RouteRowStatus.available) return;
              unawaited(_switchTo(value));
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    strings.t('settings.route'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final c in routes)
                  RadioListTile<String>(
                    value: c.baseUrl,
                    enabled:
                        c.baseUrl == inUse ||
                        statuses[c.baseUrl] == RouteRowStatus.available,
                    title: Text(c.baseUrl),
                    subtitle: statusText(c.baseUrl, statuses[c.baseUrl]!),
                    dense: true,
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: _leadingIcon(Icons.edit_outlined),
                  title: Text(strings.t('settings.editConnection')),
                  subtitle: Text(strings.t('settings.editConnectionBody')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onEdit,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// C27: push notification status + a "Send test notification" action. Push is
/// optional (BlueBubbles user-owned Firebase): when it isn't configured the card
/// explains that the app stays on its live socket + catch-up sync, which still
/// delivers messages while open.
/// C29c: device-registration diagnostics + a "Register device now" button so a
/// failing registration can be debugged on-device instead of guessed.
class _DeviceRegisterDebug extends StatefulWidget {
  const _DeviceRegisterDebug();

  @override
  State<_DeviceRegisterDebug> createState() => _DeviceRegisterDebugState();
}

class _DeviceRegisterDebugState extends State<_DeviceRegisterDebug> {
  String _diagnostics = MicaLocalizations.current.t('common.loading');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final text = await context.read<AppController>().connectionDiagnostics();
    if (mounted) setState(() => _diagnostics = text);
  }

  Future<void> _registerNow() async {
    setState(() => _busy = true);
    final result = await context.read<AppController>().registerDeviceNow();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(result)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _TwoActionRow(
          primary: FilledButton.icon(
            onPressed: _busy ? null : _registerNow,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            label: Text(
              MicaLocalizations.of(context).t('settings.registerDeviceNow'),
            ),
          ),
          secondary: OutlinedButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: Text(MicaLocalizations.of(context).t('common.refresh')),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _diagnostics,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap "Register device now", then check the Mac server log and '
          'curl <baseUrl>/api/devices. The result line above shows the exact '
          'HTTP status / error (401 = token, 0 = unreachable, 400 = rejected).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _DeveloperModeBody extends StatelessWidget {
  final AppController app;

  const _DeveloperModeBody({required this.app});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _TestContactCard(app: app),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: _leadingIcon(Icons.terminal),
                title: Text(strings.t('settings.realtimeEvents')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(
                        title: Text(strings.t('settings.realtimeEvents')),
                      ),
                      body: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: DebugLogPanel(ws: app.ws, app: app),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: _leadingIcon(Icons.devices_other_outlined),
                title: Text(strings.t('settings.deviceRegistration')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(
                        title: Text(strings.t('settings.deviceRegistration')),
                      ),
                      body: const SafeArea(child: _DeviceRegisterDebug()),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              _NotificationDiagnosticsTile(app: app),
            ],
          ),
        ),
      ],
    );
  }
}

class _NotificationsCard extends StatefulWidget {
  final AppController app;
  const _NotificationsCard({required this.app});

  @override
  State<_NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<_NotificationsCard> {
  Future<void> _enableNotifications() async {
    final granted = await requestSystemNotificationPermission();
    widget.app.noteNotificationPermission(granted);
    if (!mounted) return;
    if (granted == false) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(MicaLocalizations.of(context).t('notif.permBlocked')),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final strings = MicaLocalizations.of(context);
    final configured = app.pushConfigured;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: _leadingIcon(
              configured
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              color: configured ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Text(strings.t('notif.fcmBeta')),
            subtitle: Text(
              configured
                  ? strings.t('notif.registered')
                  : strings.t('notif.notConfiguredBody'),
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: _leadingIcon(Icons.subject_outlined),
            title: Text(strings.t('notif.showMessageText')),
            value: app.notificationShowsMessageText,
            onChanged: app.api == null
                ? null
                : (v) => app.setNotificationShowsMessageText(v),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: _leadingIcon(Icons.web_asset_outlined),
            title: Text(strings.t('notif.inApp')),
            value: app.inAppNotificationsEnabled,
            onChanged: (v) => app.setInAppNotificationsEnabled(v),
          ),
          // Android 13+ permission warning — a denied POST_NOTIFICATIONS means
          // no pushes OR keep-alive notifications can appear, however configured.
          if (defaultTargetPlatform == TargetPlatform.android &&
              !kIsWeb &&
              app.notificationPermission == 'denied') ...[
            const Divider(height: 1),
            ListTile(
              leading: _leadingIcon(
                Icons.warning_amber_outlined,
                color: scheme.error,
              ),
              title: Text(strings.t('notif.permOff')),
              trailing: TextButton(
                onPressed: _enableNotifications,
                child: Text(strings.t('notif.turnOn')),
              ),
            ),
          ],
          // C29: advanced opt-in keep-alive (Android only). Default off. Works
          // even without Firebase — a foreground service holds the connection.
          if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) ...[
            const Divider(height: 1),
            SwitchListTile(
              secondary: _leadingIcon(Icons.bolt_outlined),
              title: Text(strings.t('notif.keepAlive')),
              value: app.keepAliveEnabled,
              onChanged: (v) => app.setKeepAliveEnabled(v),
            ),
          ],
        ],
      ),
    );
  }
}

/// C31: read-only notification diagnostics — FCM configured/registered,
/// keep-alive, permission, last notification source, last direct-reply result.
/// "Copy" exports the same (no token, no message text).
class _NotificationDiagnosticsTile extends StatelessWidget {
  final AppController app;
  const _NotificationDiagnosticsTile({required this.app});

  List<MapEntry<String, String>> _rows() {
    String perm = switch (app.notificationPermission) {
      'granted' => 'granted',
      'denied' => 'denied',
      _ => 'unknown',
    };
    return [
      MapEntry('Firebase push', app.pushConfigured ? 'configured' : 'off'),
      MapEntry(
        'Token registered',
        app.pushConfigured ? 'yes (${app.pushProvider})' : 'no',
      ),
      MapEntry('Keep-alive', app.keepAliveEnabled ? 'enabled' : 'off'),
      MapEntry('Notification permission', perm),
      MapEntry('Last notification', app.lastNotificationSource ?? '—'),
      MapEntry('Last direct reply', app.lastReplyResult ?? '—'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    final strings = MicaLocalizations.of(context);
    return ExpansionTile(
      leading: const SizedBox(width: 40, child: Icon(Icons.info_outline)),
      title: Text(strings.t('notif.diagnostics')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: Text(r.key)),
                Expanded(
                  flex: 6,
                  child: Text(
                    r.value,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(strings.t('notif.copyDiagnostics')),
            onPressed: () {
              final text = [
                'micaGO notification diagnostics',
                for (final r in rows) '${r.key}: ${r.value}',
              ].join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(
                  SnackBar(content: Text(strings.t('notif.diagnosticsCopied'))),
                );
            },
          ),
        ),
      ],
    );
  }
}

/// Theme mode, color, and language controls.
/// C20: server-authoritative "Allow SMS sending through Mac" toggle. Reads and
/// writes the server's sync settings — the client never guesses. Default off:
/// SMS chats stay read-only until the user turns this on (and the server's
/// Messages can actually send SMS).
class _GeneralSettingsCard extends StatelessWidget {
  final AppController app;
  final void Function(BuildContext context, String title, Widget body) push;

  const _GeneralSettingsCard({required this.app, required this.push});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: _leadingIcon(Icons.palette_outlined),
            title: Text(strings.t('settings.appearance')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => push(
              context,
              strings.t('settings.appearance'),
              const _AppearanceSettingsBody(),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: _leadingIcon(Icons.contacts_outlined),
            title: Text(strings.t('settings.contacts')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => push(
              context,
              strings.t('settings.contacts'),
              const PeopleScreen(),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: _leadingIcon(Icons.chat_bubble_outline),
            title: Text(strings.t('settings.messageDisplay')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => push(
              context,
              strings.t('settings.messageDisplay'),
              const MessageDisplayPage(),
            ),
          ),
          const Divider(height: 1),
          _SmsSendingTile(app: app),
        ],
      ),
    );
  }
}

class _SmsSendingTile extends StatefulWidget {
  final AppController app;
  const _SmsSendingTile({required this.app});

  @override
  State<_SmsSendingTile> createState() => _SmsSendingTileState();
}

class _SmsSendingTileState extends State<_SmsSendingTile> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Pull the current server value when the screen opens (it is also fetched
    // on connect). Best-effort.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.app.syncSettings == null) {
        widget.app.refreshSyncSettings();
      }
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    final ok = await widget.app.setAllowSmsSend(value);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      TopBanner.show(
        context,
        MicaLocalizations.of(context).t('settings.smsUpdateFailed'),
        kind: TopBannerKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final strings = MicaLocalizations.of(context);
    final unreachable = app.syncSettings == null;
    return SwitchListTile(
      secondary: _leadingIcon(Icons.sms_outlined),
      title: Text(strings.t('settings.allowSms')),
      subtitle: Text(
        unreachable
            ? strings.t('settings.smsUnavailable')
            : strings.t('settings.smsBody'),
      ),
      value: app.allowSmsSend,
      onChanged: (_busy || unreachable) ? null : _toggle,
    );
  }
}

class _TestContactCard extends StatefulWidget {
  final AppController app;
  const _TestContactCard({required this.app});

  @override
  State<_TestContactCard> createState() => _TestContactCardState();
}

class _TestContactCardState extends State<_TestContactCard> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Pull the current server value when the screen opens. Best-effort.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.app.testContactEnabled == null) {
        widget.app.refreshTestContact();
      }
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    final ok = await widget.app.setTestContactEnabled(value);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      TopBanner.show(
        context,
        MicaLocalizations.of(context).t('settings.testContactUpdateFailed'),
        kind: TopBannerKind.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final strings = MicaLocalizations.of(context);
    final unreachable = app.api == null;
    final enabled = app.testContactEnabled ?? false;
    return Card(
      child: SwitchListTile(
        secondary: _leadingIcon(Icons.science_outlined),
        title: Text(strings.t('settings.testContactTitle')),
        subtitle: Text(
          unreachable
              ? strings.t('settings.testContactUnreachable')
              : strings.t('settings.testContactDesc'),
        ),
        value: enabled,
        onChanged: (_busy || unreachable) ? null : _toggle,
      ),
    );
  }
}

class _SettingsSubPage extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget>? actions;

  const _SettingsSubPage({
    required this.title,
    required this.child,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glass = context.watch<ThemeController>().useLiquidGlass;
    final glassBg = liquidGlassPageColor(context);
    final headerBg = glass ? glassBg : _settingsAccent1_100(scheme);
    final pageBg = glass ? glassBg : _settingsAccent1_50(scheme);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: headerBg,
        surfaceTintColor: Colors.transparent,
        actions: actions,
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(color: headerBg),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: DecoratedBox(
            decoration: BoxDecoration(color: pageBg),
            child: SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _settingsAccent1_50(ColorScheme scheme) =>
    Color.alphaBlend(scheme.primary.withValues(alpha: 0.10), scheme.surface);

Color _settingsAccent1_100(ColorScheme scheme) => Color.alphaBlend(
  scheme.primary.withValues(alpha: 0.18),
  scheme.surfaceContainerLowest,
);

/// Hidden messages and synced chat visibility.
class _HiddenItemsCard extends StatefulWidget {
  final AppController app;
  const _HiddenItemsCard({required this.app});

  @override
  State<_HiddenItemsCard> createState() => _HiddenItemsCardState();
}

class _HiddenItemsCardState extends State<_HiddenItemsCard> {
  int _hiddenMessages = 0;
  int _hiddenContacts = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    widget.app.chatPreferences.addListener(_refreshCounts);
  }

  @override
  void dispose() {
    widget.app.chatPreferences.removeListener(_refreshCounts);
    super.dispose();
  }

  Future<void> _refresh() async {
    await widget.app.chatPreferences.sync();
    await _refreshCounts();
  }

  Future<void> _refreshCounts() async {
    final m = await widget.app.hiddenMessageCount();
    final c = await widget.app.hiddenChatCount();
    if (!mounted) return;
    setState(() {
      _hiddenMessages = m;
      _hiddenContacts = c;
    });
  }

  Future<void> _openMessages() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HiddenMessagesPage(app: widget.app),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openContacts() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HiddenContactsPage(app: widget.app),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: _leadingIcon(Icons.chat_bubble_outline),
            title: Text(strings.t('settings.hiddenMessages')),
            subtitle: Text(
              strings
                  .t('settings.hiddenMessagesCount')
                  .replaceAll('{n}', '$_hiddenMessages'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openMessages,
          ),
          const Divider(height: 1),
          ListTile(
            leading: _leadingIcon(Icons.contacts_outlined),
            title: Text(strings.t('settings.hiddenContacts')),
            subtitle: Text(
              strings
                  .t('settings.hiddenContactsCount')
                  .replaceAll('{n}', '$_hiddenContacts'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openContacts,
          ),
          ChatPreferenceStatus(
            preferences: widget.app.chatPreferences,
            showDescription: false,
          ),
        ],
      ),
    );
  }
}

/// One row of a hidden-items list, already resolved for display.
class _HiddenRow {
  final String guid;
  final IconData icon;
  final String title;
  final String subtitle;

  const _HiddenRow({
    required this.guid,
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}

class HiddenMessagesPage extends StatelessWidget {
  final AppController app;
  const HiddenMessagesPage({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return _HiddenItemsPage<HiddenMessageRecord>(
      title: strings.t('settings.hiddenMessages'),
      countKey: 'settings.hiddenMessagesCount',
      emptyIcon: Icons.chat_bubble_outline,
      emptyKey: 'settings.noHiddenMessages',
      restoredKey: 'settings.releasedMessages',
      changes: app.messagePreferences,
      footer: MessagePreferenceStatus(preferences: app.messagePreferences),
      load: app.hiddenMessages,
      restore: app.releaseHiddenMessages,
      rowOf: (context, item) {
        final chat = item.chat;
        final subtitle = [
          if (chat != null) chat.title,
          _hiddenMessageTime(context, item.message),
        ].where((s) => s.isNotEmpty).join(' · ');
        return _HiddenRow(
          guid: item.guid,
          icon: Icons.chat_bubble_outline,
          title: _hiddenMessageTitle(item.message),
          subtitle: subtitle.isEmpty ? item.guid : subtitle,
        );
      },
    );
  }
}

class HiddenContactsPage extends StatelessWidget {
  final AppController app;
  const HiddenContactsPage({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return _HiddenItemsPage<ChatSummary>(
      title: strings.t('settings.hiddenContacts'),
      countKey: 'settings.hiddenContactsCount',
      emptyIcon: Icons.contacts_outlined,
      emptyKey: 'settings.noHiddenContacts',
      restoredKey: 'settings.releasedContacts',
      changes: app.chatPreferences,
      footer: ChatPreferenceStatus(
        preferences: app.chatPreferences,
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
      ),
      load: app.hiddenChats,
      restore: app.releaseHiddenChats,
      rowOf: (context, chat) => _HiddenRow(
        guid: chat.guid,
        icon: chat.isGroup ? Icons.groups_outlined : Icons.person_outline,
        title: chat.title,
        subtitle: chat.service.label,
      ),
    );
  }
}

class _HiddenItemsPage<T> extends StatefulWidget {
  final Listenable? changes;
  final Widget? footer;
  final String title;
  final String countKey;
  final IconData emptyIcon;
  final String emptyKey;
  final String restoredKey;
  final Future<List<T>> Function() load;
  final Future<int> Function(Set<String>) restore;
  final _HiddenRow Function(BuildContext, T) rowOf;

  const _HiddenItemsPage({
    super.key,
    this.changes,
    this.footer,
    required this.title,
    required this.countKey,
    required this.emptyIcon,
    required this.emptyKey,
    required this.restoredKey,
    required this.load,
    required this.restore,
    required this.rowOf,
  });

  @override
  State<_HiddenItemsPage<T>> createState() => _HiddenItemsPageState<T>();
}

class _HiddenItemsPageState<T> extends State<_HiddenItemsPage<T>> {
  var _items = const <_HiddenRow>[];
  final _selected = <String>{};
  bool _loading = true;
  bool _busy = false;
  bool _selectMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    widget.changes?.addListener(_load);
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final items = await widget.load();
    if (!mounted) return;
    setState(() {
      _items = [for (final item in items) widget.rowOf(context, item)];
      _selected.removeWhere((guid) => !_items.any((e) => e.guid == guid));
      _loading = false;
      if (_items.isEmpty) _selectMode = false;
    });
  }

  Future<void> _restore(Iterable<String> guids) async {
    final ids = guids.where((g) => g.isNotEmpty).toSet();
    if (ids.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final n = await widget.restore(ids);
      if (!mounted) return;
      _selected.clear();
      await _load();
      if (mounted) _toastRestore(context, n, widget.restoredKey);
    } catch (_) {
      if (mounted) {
        TopBanner.show(
          context,
          MicaLocalizations.of(context).t('prefs.connect'),
          kind: TopBannerKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(String guid) {
    setState(() {
      if (!_selected.add(guid)) _selected.remove(guid);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _items.length) {
        _selected.clear();
      } else {
        _selected.addAll(_items.map((e) => e.guid));
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return _SettingsSubPage(
      title: widget.title,
      actions: [
        if (!_loading && _items.isNotEmpty)
          if (_selectMode) ...[
            IconButton(
              tooltip: strings.t('settings.selectAll'),
              icon: const Icon(Icons.select_all),
              onPressed: _busy ? null : _toggleSelectAll,
            ),
            IconButton(
              tooltip: strings.t('settings.cancel'),
              icon: const Icon(Icons.close),
              onPressed: _busy ? null : _exitSelectMode,
            ),
          ] else
            IconButton(
              tooltip: strings.t('settings.select'),
              icon: const Icon(Icons.checklist),
              onPressed: () => setState(() => _selectMode = true),
            ),
      ],
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? Column(
              children: [
                Expanded(
                  child: _HiddenEmptyState(
                    icon: widget.emptyIcon,
                    label: strings.t(widget.emptyKey),
                  ),
                ),
                if (widget.footer != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: widget.footer,
                  ),
              ],
            )
          : Column(
              children: [
                Expanded(child: _list(strings)),
                if (_selectMode) _restoreBar(strings),
              ],
            ),
    );
  }

  Widget _list(MicaLocalizations strings) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          strings.t(widget.countKey).replaceAll('{n}', '${_items.length}'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _tile(_items[i]),
              ],
            ],
          ),
        ),
        ?widget.footer,
      ],
    );
  }

  Widget _tile(_HiddenRow row) {
    final strings = MicaLocalizations.of(context);
    final selected = _selected.contains(row.guid);
    return ListTile(
      leading: _leadingIcon(row.icon),
      title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        row.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _selectMode
          ? Checkbox(
              value: selected,
              onChanged: _busy ? null : (_) => _toggle(row.guid),
            )
          : IconButton(
              tooltip: strings.t('settings.restoreSelected'),
              icon: const Icon(Icons.visibility_outlined),
              onPressed: _busy ? null : () => _restore([row.guid]),
            ),
      onTap: _busy
          ? null
          : () {
              if (_selectMode) {
                _toggle(row.guid);
              } else {
                // Tapping a row outside select mode starts a selection with it.
                setState(() {
                  _selectMode = true;
                  _selected.add(row.guid);
                });
              }
            },
    );
  }

  Widget _restoreBar(MicaLocalizations strings) {
    final label = _selected.isEmpty
        ? strings.t('settings.restoreSelected')
        : '${strings.t('settings.restoreSelected')} (${_selected.length})';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy || _selected.isEmpty
                ? null
                : () => _restore(_selected),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.restore),
            label: Text(label),
          ),
        ),
      ),
    );
  }
}

class _HiddenEmptyState extends StatelessWidget {
  final IconData icon;
  final String label;

  const _HiddenEmptyState({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

String _hiddenMessageTitle(MessageModel? message) {
  if (message == null) return MicaLocalizations.current.t('common.message');
  return displayText(message) ?? messagePreviewText(message);
}

String _hiddenMessageTime(BuildContext context, MessageModel? message) {
  final ts = message?.dateCreated;
  if (ts == null) return '';
  return threadTimestampLabel(
    DateTime.fromMillisecondsSinceEpoch(ts),
    now: DateTime.now(),
    use24h: MediaQuery.alwaysUse24HourFormatOf(context),
    locale: Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en',
  );
}

void _toastRestore(BuildContext context, int n, String key) {
  final strings = MicaLocalizations.of(context);
  final msg = n == 0
      ? strings.t('settings.nothingHidden')
      : strings.t(key).replaceAll('{n}', '$n');
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// C54: export/import a `.micagobak` settings backup.
class _BackupRestoreCard extends StatelessWidget {
  const _BackupRestoreCard();

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: _leadingIcon(Icons.ios_share),
            title: Text(strings.t('settings.exportBackup')),
            subtitle: Text(strings.t('settings.exportBackupBody')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => exportSettingsBackup(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: _leadingIcon(Icons.restore),
            title: Text(strings.t('settings.importBackup')),
            subtitle: Text(strings.t('settings.importBackupBody')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => importSettingsBackup(context),
          ),
        ],
      ),
    );
  }
}

class _ChatBackgroundPicker extends StatelessWidget {
  final ThemeController theme;
  const _ChatBackgroundPicker({required this.theme});

  @override
  Widget build(BuildContext context) {
    final path = theme.chatBackgroundPath;
    final file = path == null ? null : File(path);
    final exists = file != null && file.existsSync();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: exists
                  ? Image.file(file, fit: BoxFit.cover)
                  : Icon(
                      Icons.wallpaper_outlined,
                      color: scheme.onSurfaceVariant,
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    MicaLocalizations.of(context).t(
                      exists
                          ? 'settings.customBackground'
                          : 'settings.defaultBackground',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    exists
                        ? MicaLocalizations.of(
                            context,
                          ).t('settings.backgroundShown')
                        : MicaLocalizations.of(
                            context,
                          ).t('settings.backgroundPick'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (exists)
          _TwoActionRow(
            primary: FilledButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(
                MicaLocalizations.of(context).t('settings.changeImage'),
              ),
            ),
            secondary: OutlinedButton.icon(
              onPressed: () => theme.clearChatBackground(),
              icon: const Icon(Icons.delete_outline),
              label: Text(MicaLocalizations.of(context).t('common.remove')),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(
                MicaLocalizations.of(context).t('settings.chooseImage'),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 95,
    );
    if (image == null) return;
    try {
      await theme.setChatBackgroundFromFile(image.path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              MicaLocalizations.of(context).t('settings.backgroundUpdated'),
            ),
          ),
        );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              MicaLocalizations.of(context).t('chat.imageUnusable'),
            ),
          ),
        );
    }
  }
}

class _AppearanceSettingsBody extends StatelessWidget {
  const _AppearanceSettingsBody();

  @override
  Widget build(BuildContext context) {
    final activeTheme = context.watch<ThemeController>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [_AppearanceCard(theme: activeTheme)],
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  final ThemeController theme;
  const _AppearanceCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final useGlass = theme.useLiquidGlass;
    final selectedBg = useGlass ? scheme.primary : null;
    final selectedFg = useGlass ? scheme.onPrimary : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Theme mode ---
            Text(
              strings.t('settings.theme'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text(strings.t('settings.system')),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text(strings.t('settings.light')),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text(strings.t('settings.dark')),
                ),
              ],
              selected: {theme.themeMode},
              style: useGlass
                  ? ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? selectedBg
                            : null,
                      ),
                      foregroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? selectedFg
                            : null,
                      ),
                      iconColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? selectedFg
                            : null,
                      ),
                    )
                  : null,
              onSelectionChanged: (s) => theme.setThemeMode(s.first),
            ),
            const Divider(height: 28),

            // --- Color ---
            Text(
              strings.t('settings.color'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in theme.availableColorChoices)
                  ChoiceChip(
                    selected: theme.colorChoice == c,
                    onSelected: (_) => theme.setColorChoice(c),
                    selectedColor: useGlass ? selectedBg : null,
                    checkmarkColor: selectedFg,
                    labelStyle: theme.colorChoice == c && useGlass
                        ? TextStyle(color: selectedFg)
                        : null,
                    avatar: c == ThemeColorChoice.system
                        ? const Icon(Icons.auto_awesome, size: 16)
                        : CircleAvatar(radius: 8, backgroundColor: _seedFor(c)),
                    label: Text(_colorLabel(c, strings)),
                  ),
              ],
            ),
            const Divider(height: 28),

            Text(
              MicaLocalizations.of(context).t('settings.chatBackground'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _ChatBackgroundPicker(theme: theme),
            const Divider(height: 28),

            // --- Language ---
            Text(
              strings.t('settings.language'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            DropdownButton<LanguageChoice>(
              value: theme.language,
              isExpanded: true,
              onChanged: (l) {
                if (l != null) theme.setLanguage(l);
              },
              items: [
                DropdownMenuItem(
                  value: LanguageChoice.system,
                  child: Text(strings.t('settings.systemLanguage')),
                ),
                DropdownMenuItem(
                  value: LanguageChoice.english,
                  child: Text(strings.t('settings.english')),
                ),
                DropdownMenuItem(
                  value: LanguageChoice.simplifiedChinese,
                  child: Text(strings.t('settings.zhHans')),
                ),
                DropdownMenuItem(
                  value: LanguageChoice.traditionalChinese,
                  child: Text(strings.t('settings.zhHant')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _seedFor(ThemeColorChoice c) {
    switch (c) {
      case ThemeColorChoice.system:
      case ThemeColorChoice.micago:
        return MicaGoThemeSeed.value;
      case ThemeColorChoice.bicao:
        return const Color(0xFF2E7D32);
      case ThemeColorChoice.wisteria:
        return const Color(0xFF7E6BAE);
      case ThemeColorChoice.citrus:
        return const Color(0xFFE65100);
      case ThemeColorChoice.blackWhite:
        return const Color(0xFF2E2E2E);
      case ThemeColorChoice.paleGold:
        return const Color(0xFFB89B5E);
      case ThemeColorChoice.wineRed:
        return const Color(0xFF8B1E3F);
      case ThemeColorChoice.blueGreen:
        return const Color(0xFF1F6F6A);
      case ThemeColorChoice.indigo:
        return const Color(0xFF2F3A73);
      case ThemeColorChoice.dianthus:
        return const Color(0xFFE889A8);
      case ThemeColorChoice.witheredGrass:
        return const Color(0xFF9C8A4F);
      case ThemeColorChoice.amber:
        return const Color(0xFFB8792B);
      case ThemeColorChoice.liquidGlass:
        return const Color(0xFF007AFF);
    }
  }

  String _colorLabel(ThemeColorChoice c, MicaLocalizations strings) {
    switch (c) {
      case ThemeColorChoice.system:
        return strings.t('themeColor.system');
      case ThemeColorChoice.micago:
        return strings.t('themeColor.micago');
      case ThemeColorChoice.bicao:
        return strings.t('themeColor.bicao');
      case ThemeColorChoice.wisteria:
        return strings.t('themeColor.wisteria');
      case ThemeColorChoice.citrus:
        return strings.t('themeColor.citrus');
      case ThemeColorChoice.blackWhite:
        return strings.t('themeColor.blackWhite');
      case ThemeColorChoice.paleGold:
        return strings.t('themeColor.paleGold');
      case ThemeColorChoice.wineRed:
        return strings.t('themeColor.wineRed');
      case ThemeColorChoice.blueGreen:
        return strings.t('themeColor.blueGreen');
      case ThemeColorChoice.indigo:
        return strings.t('themeColor.indigo');
      case ThemeColorChoice.dianthus:
        return strings.t('themeColor.dianthus');
      case ThemeColorChoice.witheredGrass:
        return strings.t('themeColor.witheredGrass');
      case ThemeColorChoice.amber:
        return strings.t('themeColor.amber');
      case ThemeColorChoice.liquidGlass:
        return strings.t('themeColor.liquidGlass');
    }
  }
}

/// Tiny indirection so the settings swatch can reference the brand seed without
/// importing the app theme here.
class MicaGoThemeSeed {
  static const Color value = Color(0xFF007AFF);
}

class _AboutBody extends StatefulWidget {
  const _AboutBody();

  @override
  State<_AboutBody> createState() => _AboutBodyState();
}

class _AboutBodyState extends State<_AboutBody> {
  static const int _debugUnlockTaps = 7;

  int _versionTapCount = 0;
  bool _checkingUpdate = false;
  UpdateCheckResult? _updateResult;

  /// Shows the outcome of the last check; tapping runs a new one.
  String _updateValueLabel(MicaLocalizations strings) {
    if (_checkingUpdate) return strings.t('settings.updateChecking');
    final result = _updateResult;
    if (result == null) return strings.t('settings.updateCheckNow');
    switch (result.status) {
      case UpdateCheckStatus.updateAvailable:
        return strings
            .t('settings.updateAvailable')
            .replaceAll('{version}', result.latestVersion ?? '');
      case UpdateCheckStatus.upToDate:
        return strings.t('settings.updateUpToDate');
      case UpdateCheckStatus.unknown:
        return strings.t('settings.updateUnknown');
    }
  }

  Future<void> _runUpdateCheck() async {
    setState(() => _checkingUpdate = true);
    final result = await checkForUpdate(kAppVersion);
    if (!mounted) return;
    setState(() {
      _checkingUpdate = false;
      _updateResult = result;
    });
    // A newer build is the only outcome worth interrupting for.
    if (result.status == UpdateCheckStatus.updateAvailable) {
      await _openExternal(result.releaseUrl);
    }
  }

  // C61: developer mode lives on (and is persisted by) the AppController, so
  // it survives leaving Settings and app restarts.
  bool get _debugUnlocked => context.read<AppController>().developerModeEnabled;

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    // Rebuild when developer mode flips (the status tile reflects it).
    context.watch<AppController>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
            child: Column(
              children: [
                const _FloatingMicaGoLogo(),
                const SizedBox(height: 22),
                Text(
                  'micaGO',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          strings.t('settings.about'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              _AboutInfoTile(
                icon: Icons.auto_awesome_rounded,
                title: strings.t('settings.version'),
                value: 'Muscovite v$kAppVersion',
                onTap: _handleVersionTap,
              ),
              const Divider(height: 1),
              _AboutInfoTile(
                icon: Icons.code_outlined,
                title: strings.t('settings.openSource'),
                value: 'GitHub',
                onTap: () => _openExternal('https://github.com/cinmou/MicaGo'),
              ),
              const Divider(height: 1),
              _AboutInfoTile(
                icon: Icons.science_outlined,
                title: strings.t('settings.status'),
                value: _debugUnlocked
                    ? strings.t('settings.debugEnabled')
                    : strings.t('settings.betaStatus'),
                onTap: _debugUnlocked ? _confirmDisableDebugMode : null,
              ),
              const Divider(height: 1),
              // C74: actually checks GitHub for a newer release instead of just
              // opening the releases page.
              _AboutInfoTile(
                icon: Icons.system_update_alt_outlined,
                title: strings.t('settings.checkUpdates'),
                value: _updateValueLabel(strings),
                onTap: _checkingUpdate ? null : _runUpdateCheck,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('made with ♥️ for everyone', textAlign: TextAlign.center),
        ),
      ],
    );
  }

  void _handleVersionTap() {
    if (_debugUnlocked) return;
    setState(() => _versionTapCount++);
    final remaining = _debugUnlockTaps - _versionTapCount;
    if (remaining <= 0) {
      unawaited(context.read<AppController>().setDeveloperModeEnabled(true));
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              MicaLocalizations.of(context).t('settings.debugUnlocked'),
            ),
          ),
        );
      return;
    }
    if (remaining <= 3) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              MicaLocalizations.of(
                context,
              ).t('settings.debugUnlockHint').replaceAll('{n}', '$remaining'),
            ),
          ),
        );
    }
  }

  Future<void> _confirmDisableDebugMode() async {
    final strings = MicaLocalizations.of(context);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: Text(strings.t('settings.disableDebugTitle')),
        content: Text(strings.t('settings.disableDebugBody')),

        cancelLabel: strings.t('settings.cancel'),
        onCancel: () => Navigator.pop(ctx, false),
        confirmLabel: strings.t('settings.disableDebugConfirm'),
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _versionTapCount = 0);
    await context.read<AppController>().setDeveloperModeEnabled(false);
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      TopBanner.show(
        context,
        MicaLocalizations.of(context).t('settings.openLinkFailed'),
        kind: TopBannerKind.error,
      );
    }
  }
}

class _FloatingMicaGoLogo extends StatefulWidget {
  const _FloatingMicaGoLogo();

  @override
  State<_FloatingMicaGoLogo> createState() => _FloatingMicaGoLogoState();
}

class _FloatingMicaGoLogoState extends State<_FloatingMicaGoLogo>
    with SingleTickerProviderStateMixin {
  static const double _logoSize = 104;

  late final AnimationController _tiltController;
  bool _pressed = false;
  double _rawTiltX = 0;
  double _rawTiltY = 0;

  @override
  void initState() {
    super.initState();
    _tiltController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _tiltController.dispose();
    super.dispose();
  }

  void _onPanDown(DragDownDetails details) {
    _updateTiltValues(details.localPosition);
    _tiltController.forward();
    setState(() => _pressed = true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _updateTiltValues(details.localPosition);
  }

  void _updateTiltValues(Offset localPosition) {
    setState(() {
      final dx = (localPosition.dx - (_logoSize / 2)) / (_logoSize / 2);
      final dy = (localPosition.dy - (_logoSize / 2)) / (_logoSize / 2);
      _rawTiltX = dy.clamp(-1.2, 1.2) * 0.18;
      _rawTiltY = -dx.clamp(-1.2, 1.2) * 0.18;
    });
  }

  void _deactivate() {
    if (!_pressed) return;
    _tiltController.reverse().then((_) {
      if (mounted && !_pressed) {
        setState(() {
          _rawTiltX = 0;
          _rawTiltY = 0;
        });
      }
    });
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onPanDown: _onPanDown,
      onPanUpdate: _onPanUpdate,
      onPanEnd: (_) => _deactivate(),
      onPanCancel: _deactivate,
      child: AnimatedBuilder(
        animation: _tiltController,
        builder: (context, child) {
          return TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(
              begin: Offset.zero,
              end: Offset(_rawTiltX, _rawTiltY),
            ),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            builder: (context, smoothedTilt, child) {
              final tiltX = smoothedTilt.dx * _tiltController.value;
              final tiltY = smoothedTilt.dy * _tiltController.value;
              final scale = 1.0 + (0.05 * _tiltController.value);
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateX(tiltX)
                  ..rotateY(tiltY)
                  ..scaleByDouble(scale, scale, scale, 1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(
                          alpha: _pressed ? 0.24 : 0.14,
                        ),
                        blurRadius: _pressed ? 28 : 18,
                        offset: Offset(0, _pressed ? 14 : 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'lib/Assets/MicaGo.png',
                      width: _logoSize,
                      height: _logoSize,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AboutInfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;

  const _AboutInfoTile({
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _leadingIcon(icon),
      title: Text(title),
      subtitle: Text(value),
      onTap: onTap,
    );
  }
}
