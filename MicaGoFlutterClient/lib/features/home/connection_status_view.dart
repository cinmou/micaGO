import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/websocket_client.dart';
import '../debug/debug_log_panel.dart';

/// The Connection tab body: live REST/WebSocket status and the server endpoint
/// summary. No Scaffold — the shell provides the app bar. Pull to refresh.
class ConnectionStatusView extends StatefulWidget {
  const ConnectionStatusView({super.key});

  @override
  State<ConnectionStatusView> createState() => _ConnectionStatusViewState();
}

class _ConnectionStatusViewState extends State<ConnectionStatusView> {
  String? _urlsError;
  bool _loadingUrls = false;

  Future<void> _refreshUrls() async {
    final app = context.read<AppController>();
    setState(() {
      _loadingUrls = true;
      _urlsError = null;
    });
    try {
      await app.refreshServerUrls();
    } on ApiException catch (e) {
      if (mounted) setState(() => _urlsError = '${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _loadingUrls = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return RefreshIndicator(
      onRefresh: _refreshUrls,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DiagnosticsCard(app: app),
          const SizedBox(height: 12),
          _EndpointSummaryCard(
            urlsError: _urlsError,
            loading: _loadingUrls,
            onRefresh: _refreshUrls,
          ),
          const SizedBox(height: 12),
          DebugLogPanel(ws: app.ws, app: app),
        ],
      ),
    );
  }
}

/// Connection diagnostics: server/WS URLs, live REST health + auth, WebSocket
/// status, last error, masked token, and reconnect/check actions. The token is
/// masked by default and never logged.
class _DiagnosticsCard extends StatefulWidget {
  final AppController app;
  const _DiagnosticsCard({required this.app});

  @override
  State<_DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<_DiagnosticsCard> {
  bool? _healthOk;
  bool? _authOk;
  bool _checking = false;
  String? _lastError; // plain-language
  String? _failStep; // 'health' | 'auth'
  int? _failStatus; // HTTP status code
  String? _failUrl; // requested URL (no token)
  bool _revealToken = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    final api = widget.app.api;
    if (api == null) return;
    setState(() {
      _checking = true;
      _lastError = null;
      _failStep = null;
      _failStatus = null;
      _failUrl = null;
    });
    bool? health;
    bool? auth;
    try {
      health = await api.health();
      if (health == true) {
        try {
          await api.authCheck();
          auth = true;
        } on ApiException catch (e) {
          auth = false;
          _failStep = 'auth';
          _failStatus = e.statusCode;
          _failUrl = api.authCheckUrl;
          _lastError = e.friendly;
        }
      } else {
        _failStep = 'health';
        _failUrl = api.healthUrl;
        _lastError = 'Server did not report healthy.';
      }
    } on ApiException catch (e) {
      health = false;
      _failStep = 'health';
      _failStatus = e.statusCode;
      _failUrl = api.healthUrl;
      _lastError = e.friendly;
    }
    if (!mounted) return;
    setState(() {
      _healthOk = health;
      _authOk = auth;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.app.profile;
    final active = widget.app.activeCandidate;
    final candidates = widget.app.connectionCandidates;
    final connectionLog = widget.app.connectionLog;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connection diagnostics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _kv(context, 'Mode', profile?.mode.name ?? '—'),
            const SizedBox(height: 6),
            _kv(context, 'Active', active?.label ?? '—'),
            const SizedBox(height: 6),
            _kv(
              context,
              'Server',
              active?.baseUrl ?? profile?.effectiveBaseUrl ?? '—',
            ),
            const SizedBox(height: 6),
            _kv(
              context,
              'WebSocket',
              active?.wsUrl ?? profile?.effectiveWsUrl ?? '—',
            ),
            const SizedBox(height: 6),
            _tokenRow(context, profile?.token ?? ''),
            if (candidates.isNotEmpty) ...[
              const Divider(height: 20),
              Text(
                'Connection candidates',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              for (final candidate in candidates) ...[
                _candidateRow(
                  context,
                  candidate.label,
                  candidate.baseUrl,
                  active?.baseUrl == candidate.baseUrl,
                ),
                const SizedBox(height: 4),
                _candidateRow(
                  context,
                  '${candidate.label} WS',
                  candidate.wsUrl,
                  active?.wsUrl == candidate.wsUrl,
                ),
              ],
            ],
            const Divider(height: 20),
            _statusRow(context, 'REST health', _checking ? null : _healthOk),
            const SizedBox(height: 4),
            _statusRow(context, 'Auth (token)', _checking ? null : _authOk),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: widget.app.ws,
              builder: (context, _) {
                final ws = widget.app.ws;
                return Row(
                  children: [
                    const SizedBox(
                      width: 88,
                      child: Text('WebSocket', style: TextStyle(fontSize: 13)),
                    ),
                    _WsStatusChip(status: ws.status),
                  ],
                );
              },
            ),
            if (_lastError != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Failed'
                      '${_failStep != null ? ' at ${_failStep == 'auth' ? 'auth check' : 'health check'}' : ''}'
                      '${_failStatus != null ? ' · HTTP $_failStatus' : ''}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_lastError!, style: const TextStyle(fontSize: 12)),
                    if (_failUrl != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Requested: $_failUrl',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _checking ? null : _check,
                  icon: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.health_and_safety_outlined, size: 18),
                  label: Text(
                    MicaLocalizations.of(context).t('connection.checkNow'),
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => widget.app.selectReachableCandidate(
                    reason: 'manual_reconnect',
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    MicaLocalizations.of(context).t('connection.reconnect'),
                  ),
                ),
              ],
            ),
            if (connectionLog.isNotEmpty) ...[
              const Divider(height: 20),
              Text(
                MicaLocalizations.of(context).t('connection.selectionLog'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    connectionLog.reversed
                        .take(20)
                        .toList()
                        .reversed
                        .join('\n'),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusRow(BuildContext context, String label, bool? ok) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String text) = ok == null
        ? (Icons.help_outline, scheme.outline, 'Checking…')
        : ok
        ? (Icons.check_circle, Colors.green, 'OK')
        : (Icons.cancel, scheme.error, 'Failed');
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }

  Widget _tokenRow(BuildContext context, String token) {
    final scheme = Theme.of(context).colorScheme;
    final shown = token.isEmpty
        ? '—'
        : _revealToken
        ? token
        : '${token.length <= 4 ? token : token.substring(0, 4)}••••••••';
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            'Token',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            shown,
            style: const TextStyle(fontFamily: 'monospace'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: _revealToken ? 'Hide' : 'Reveal',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _revealToken
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
          onPressed: token.isEmpty
              ? null
              : () => setState(() => _revealToken = !_revealToken),
        ),
      ],
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            k,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(child: SelectableText(v)),
      ],
    );
  }

  Widget _candidateRow(
    BuildContext context,
    String label,
    String value,
    bool active,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: SelectableText(value, style: const TextStyle(fontSize: 12)),
        ),
        if (active) ...[
          const SizedBox(width: 6),
          Chip(
            label: const Text('active'),
            visualDensity: VisualDensity.compact,
            labelStyle: const TextStyle(fontSize: 11),
            padding: EdgeInsets.zero,
          ),
        ],
      ],
    );
  }
}

class _WsStatusChip extends StatelessWidget {
  final WsStatus status;
  const _WsStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strings = MicaLocalizations.of(context);
    final (Color color, String label, IconData icon) = switch (status) {
      WsStatus.connected => (
        Colors.green,
        strings.t('connection.connected'),
        Icons.bolt,
      ),
      WsStatus.connecting => (
        scheme.tertiary,
        strings.t('connection.connecting'),
        Icons.sync,
      ),
      WsStatus.failed => (
        scheme.error,
        strings.t('connection.failed'),
        Icons.error_outline,
      ),
      WsStatus.disconnected => (
        scheme.outline,
        strings.t('connection.disconnected'),
        Icons.power_off,
      ),
      WsStatus.idle => (
        scheme.outline,
        strings.t('connection.idle'),
        Icons.circle_outlined,
      ),
    };
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _EndpointSummaryCard extends StatelessWidget {
  final String? urlsError;
  final bool loading;
  final VoidCallback onRefresh;

  const _EndpointSummaryCard({
    required this.urlsError,
    required this.loading,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final urls = context.watch<AppController>().serverUrls;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Server endpoints',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: onRefresh,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (urlsError != null)
              Text(
                urlsError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (urls == null && !loading)
              const Text('Pull to refresh to load /api/server/urls.')
            else if (urls != null) ...[
              // C25: loopback is not a client-usable endpoint and is no longer
              // listed — only LAN and the optional Public.
              for (final e in urls.lan)
                _row(context, e.label, e.baseUrl, e.reachableLabel),
              if (urls.public?.enabled == true)
                _row(
                  context,
                  'Public',
                  urls.public!.baseUrl,
                  urls.public!.reachableLabel,
                )
              else
                Text(
                  'Public endpoint: not configured',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String url, String badge) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(url)),
          const SizedBox(width: 8),
          Text(badge, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
