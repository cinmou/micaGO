import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router.dart';
import '../../core/app_controller.dart';
import '../../core/network/notification_display.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/models/connection_profile.dart';
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

/// Settings tab: shows the current connection (token masked), and lets the user
/// edit the connection or disconnect. Kept minimal for C1.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _testingAndDebugUnlocked = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
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
                    _RouteSwitcher(app: app, profile: profile)
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
                        if (_testingAndDebugUnlocked) ...[
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
                            _AboutBody(
                              debugUnlocked: _testingAndDebugUnlocked,
                              onDebugModeChanged: (enabled) => setState(
                                () => _testingAndDebugUnlocked = enabled,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (profile != null) ...[
                    const SizedBox(height: 20),
                    _TwoActionRow(
                      primary: OutlinedButton.icon(
                        onPressed: () => context.push(Routes.connection),
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(strings.t('settings.editConnection')),
                      ),
                      secondary: OutlinedButton.icon(
                        onPressed: () => _confirmDisconnect(context, app),
                        icon: const Icon(Icons.logout),
                        label: Text(strings.t('settings.disconnect')),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          MicaLocalizations.of(context).t('settings.disconnectTitle'),
        ),
        content: Text(
          MicaLocalizations.of(context).t('settings.disconnectBody'),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(
                    MicaLocalizations.of(context).t('settings.cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    MicaLocalizations.of(context).t('settings.disconnect'),
                  ),
                ),
              ),
            ],
          ),
        ],
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

/// C26: when the server advertises more than one route (multiple LAN interfaces,
/// or LAN + Public), let the user pick which one to use. "Automatic" keeps the
/// LAN-first behaviour; picking a specific route pins it (persisted) and the app
/// reconnects through it.
class _RouteSwitcher extends StatelessWidget {
  final AppController app;
  final ConnectionProfile profile;
  const _RouteSwitcher({required this.app, required this.profile});

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final candidates = app.connectionCandidates;
    final activeBase = app.activeCandidate?.baseUrl;
    final pinned = profile.selectedBaseUrl;
    final scheme = Theme.of(context).colorScheme;

    String labelFor(ConnectionCandidate c) {
      final host = Uri.tryParse(c.baseUrl)?.host ?? c.baseUrl;
      return '${c.label} · $host';
    }

    return Card(
      child: RadioGroup<String?>(
        groupValue: pinned,
        onChanged: (v) => app.selectRoute(v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                strings.t('settings.route'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            RadioListTile<String?>(
              value: null,
              title: Text(strings.t('settings.autoRoute')),
              subtitle: Text(strings.t('settings.autoRouteBody')),
              dense: true,
            ),
            for (final c in candidates)
              RadioListTile<String?>(
                value: c.baseUrl,
                title: Text(labelFor(c)),
                subtitle: c.baseUrl == activeBase
                    ? Text(
                        strings.t('settings.connected'),
                        style: TextStyle(color: scheme.primary),
                      )
                    : Text(c.baseUrl),
                secondary: c.baseUrl == activeBase
                    ? Icon(Icons.check_circle, color: scheme.primary, size: 20)
                    : null,
                dense: true,
              ),
          ],
        ),
      ),
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
  String _diagnostics = 'Loading…';
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
            label: const Text('Register device now'),
          ),
          secondary: OutlinedButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
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
  bool _busy = false;

  Future<void> _sendTest() async {
    setState(() => _busy = true);
    final error = await widget.app.sendTestPush();
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = error ?? MicaLocalizations.of(context).t('notif.testSent');
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

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
            subtitle: configured
                ? null
                : Text(strings.t('notif.notConfiguredBody')),
          ),
          if (configured) ...[
            const Divider(height: 1),
            ListTile(
              leading: _leadingIcon(Icons.send_outlined),
              title: Text(strings.t('notif.sendTest')),
              trailing: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _busy ? null : _sendTest,
            ),
          ],
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
        'Could not update the test contact',
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

  const _SettingsSubPage({required this.title, required this.child});

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

/// Entry points for client-hidden messages and contacts. The actual restore
/// actions live in native-feeling list subpages so users can review items first.
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
  }

  Future<void> _refresh() async {
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
        builder: (_) => _SettingsSubPage(
          title: MicaLocalizations.of(context).t('settings.hiddenMessages'),
          child: HiddenMessagesPage(app: widget.app),
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openContacts() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SettingsSubPage(
          title: MicaLocalizations.of(context).t('settings.hiddenContacts'),
          child: HiddenContactsPage(app: widget.app),
        ),
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
        ],
      ),
    );
  }
}

class HiddenMessagesPage extends StatefulWidget {
  final AppController app;
  const HiddenMessagesPage({super.key, required this.app});

  @override
  State<HiddenMessagesPage> createState() => _HiddenMessagesPageState();
}

class _HiddenMessagesPageState extends State<HiddenMessagesPage> {
  var _items = const <HiddenMessageRecord>[];
  final _selected = <String>{};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final items = await widget.app.hiddenMessages();
    if (!mounted) return;
    setState(() {
      _items = items;
      _selected.removeWhere((guid) => !items.any((e) => e.guid == guid));
      _loading = false;
    });
  }

  Future<void> _restore(Iterable<String> guids) async {
    final ids = guids.where((g) => g.isNotEmpty).toSet();
    if (ids.isEmpty || _busy) return;
    setState(() => _busy = true);
    final n = await widget.app.releaseHiddenMessages(ids);
    await _load();
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _busy = false;
    });
    _toastRestore(context, n, 'settings.releasedMessages');
  }

  void _toggle(String guid, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(guid);
      } else {
        _selected.remove(guid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return _HiddenEmptyState(
        icon: Icons.chat_bubble_outline,
        label: strings.t('settings.noHiddenMessages'),
      );
    }
    return Column(
      children: [
        _HiddenSelectionBar(
          selectedCount: _selected.length,
          busy: _busy,
          onRestore: _selected.isEmpty ? null : () => _restore(_selected),
          onClear: _selected.isEmpty ? null : () => setState(_selected.clear),
        ),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.only(
              bottom: 12 + MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: _items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final item = _items[i];
              final selected = _selected.contains(item.guid);
              final message = item.message;
              final chat = item.chat;
              final title = _hiddenMessageTitle(message);
              final subtitle = [
                if (chat != null) chat.title,
                _hiddenMessageTime(context, message),
              ].where((s) => s.isNotEmpty).join(' · ');
              return CheckboxListTile(
                value: selected,
                onChanged: _busy ? null : (v) => _toggle(item.guid, v ?? false),
                secondary: _leadingIcon(Icons.chat_bubble_outline),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: subtitle.isEmpty
                    ? Text(
                        item.guid,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                controlAffinity: ListTileControlAffinity.trailing,
              );
            },
          ),
        ),
      ],
    );
  }
}

class HiddenContactsPage extends StatefulWidget {
  final AppController app;
  const HiddenContactsPage({super.key, required this.app});

  @override
  State<HiddenContactsPage> createState() => _HiddenContactsPageState();
}

class _HiddenContactsPageState extends State<HiddenContactsPage> {
  var _items = const <ChatSummary>[];
  final _selected = <String>{};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final items = await widget.app.hiddenChats();
    if (!mounted) return;
    setState(() {
      _items = items;
      _selected.removeWhere((guid) => !items.any((e) => e.guid == guid));
      _loading = false;
    });
  }

  Future<void> _restore(Iterable<String> guids) async {
    final ids = guids.where((g) => g.isNotEmpty).toSet();
    if (ids.isEmpty || _busy) return;
    setState(() => _busy = true);
    final n = await widget.app.releaseHiddenChats(ids);
    await _load();
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _busy = false;
    });
    _toastRestore(context, n, 'settings.releasedContacts');
  }

  void _toggle(String guid, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(guid);
      } else {
        _selected.remove(guid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return _HiddenEmptyState(
        icon: Icons.contacts_outlined,
        label: strings.t('settings.noHiddenContacts'),
      );
    }
    return Column(
      children: [
        _HiddenSelectionBar(
          selectedCount: _selected.length,
          busy: _busy,
          onRestore: _selected.isEmpty ? null : () => _restore(_selected),
          onClear: _selected.isEmpty ? null : () => setState(_selected.clear),
        ),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.only(
              bottom: 12 + MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: _items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final chat = _items[i];
              final selected = _selected.contains(chat.guid);
              return CheckboxListTile(
                value: selected,
                onChanged: _busy ? null : (v) => _toggle(chat.guid, v ?? false),
                secondary: _leadingIcon(
                  chat.isGroup ? Icons.groups_outlined : Icons.person_outline,
                ),
                title: Text(
                  chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  chat.service.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                controlAffinity: ListTileControlAffinity.trailing,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HiddenSelectionBar extends StatelessWidget {
  final int selectedCount;
  final bool busy;
  final VoidCallback? onRestore;
  final VoidCallback? onClear;

  const _HiddenSelectionBar({
    required this.selectedCount,
    required this.busy,
    required this.onRestore,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                strings
                    .t('settings.selectedCount')
                    .replaceAll('{n}', '$selectedCount'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            TextButton(
              onPressed: busy ? null : onClear,
              child: Text(strings.t('settings.clearSelection')),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy ? null : onRestore,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restore),
              label: Text(strings.t('settings.restoreSelected')),
            ),
          ],
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
  if (message == null) return 'Message';
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
                  Text(exists ? 'Custom image selected' : 'Default background'),
                  const SizedBox(height: 4),
                  Text(
                    exists
                        ? 'Shown behind message history and the input area.'
                        : 'Choose any local image for your chat screen.',
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
              label: const Text('Change image'),
            ),
            secondary: OutlinedButton.icon(
              onPressed: () => theme.clearChatBackground(),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove'),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose image'),
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
          const SnackBar(content: Text('Chat background updated')),
        );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('Could not use that image')),
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
              'Chat background',
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
  final bool debugUnlocked;
  final ValueChanged<bool> onDebugModeChanged;

  const _AboutBody({
    required this.debugUnlocked,
    required this.onDebugModeChanged,
  });

  @override
  State<_AboutBody> createState() => _AboutBodyState();
}

class _AboutBodyState extends State<_AboutBody> {
  static const int _debugUnlockTaps = 7;

  late bool _debugUnlocked;
  int _versionTapCount = 0;

  @override
  void initState() {
    super.initState();
    _debugUnlocked = widget.debugUnlocked;
  }

  @override
  Widget build(BuildContext context) {
    final strings = MicaLocalizations.of(context);
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
                value: 'Rhodolite v$kAppVersion',
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
              _AboutInfoTile(
                icon: Icons.system_update_alt_outlined,
                title: strings.t('settings.checkUpdates'),
                value: 'GitHub Releases',
                onTap: () =>
                    _openExternal('https://github.com/cinmou/MicaGo/releases'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _handleVersionTap() {
    if (_debugUnlocked) return;
    setState(() => _versionTapCount++);
    final remaining = _debugUnlockTaps - _versionTapCount;
    if (remaining <= 0) {
      setState(() => _debugUnlocked = true);
      widget.onDebugModeChanged(true);
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.t('settings.disableDebugTitle')),
        content: Text(strings.t('settings.disableDebugBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.t('settings.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(strings.t('settings.disableDebugConfirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _debugUnlocked = false;
      _versionTapCount = 0;
    });
    widget.onDebugModeChanged(false);
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
