import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/l10n/app_localizations.dart';

/// Live connection diagnostics and the bounded realtime event log.
class DebugLogPanel extends StatelessWidget {
  final AppController app;
  const DebugLogPanel({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final strings = MicaLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([ws, app]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('WebSocket: ${ws.status.name}'),
                  const SizedBox(height: 8),
                  _RealtimeDiagnostics(app: app),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: ws.log.isEmpty ? null : ws.clearLog,
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: Text(strings.t('settings.clearSelection')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (ws.log.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(strings.t('debug.noEvents')),
            ),
          for (final entry in ws.log.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
              child: SelectableText(
                '${_timestamp(entry.at)}  ${entry.text}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }
}

class _RealtimeDiagnostics extends StatelessWidget {
  final AppController app;
  const _RealtimeDiagnostics({required this.app});

  @override
  Widget build(BuildContext context) {
    final d = app.realtimeDiagnostics;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DefaultTextStyle(
        style:
            Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace') ??
            const TextStyle(fontFamily: 'monospace', fontSize: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('cursor: ${d.lastAppliedEventCursor ?? '—'}'),
            Text('last event: ${_timestamp(d.lastEventAt)}'),
            Text('last reconnect: ${_timestamp(d.lastReconnectAt)}'),
            Text('catch-up cursor: ${d.lastCatchUpCursor ?? '—'}'),
            Text('catch-up count: ${d.lastCatchUpResultCount}'),
            Text(
              'patched/reload: ${d.eventsPatchedDirectly}/${d.eventsForcedReload}',
            ),
            Text('chat reloads: ${d.chatListEventReloads}'),
            Text(
              'dropped missing chat/malformed: '
              '${d.droppedMissingChatGuid}/${d.droppedMalformedEvents}',
            ),
            Text('DB writes from realtime: ${d.localDbWrites}'),
            Text(
              'reconnects: ${d.reconnectCount}'
              '${app.realtimeCatchingUp ? ' (catching up)' : ''}',
            ),
          ],
        ),
      ),
    );
  }
}

String _timestamp(DateTime? time) {
  if (time == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
