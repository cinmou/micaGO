import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/ui/top_banner.dart';
import '../contacts/contacts_service.dart';
import '../../core/platform/linux_desktop.dart';

/// Local contact matching is one preference, so it stays on the settings page.
class ContactsMatchingTile extends StatefulWidget {
  const ContactsMatchingTile({super.key});

  @override
  State<ContactsMatchingTile> createState() => _ContactsMatchingTileState();
}

class _ContactsMatchingTileState extends State<ContactsMatchingTile> {
  bool _busy = false;

  Future<void> _import(ContactsService contacts) async {
    setState(() => _busy = true);
    try {
      final path = await LinuxDesktop.pickContactFile(
        MicaLocalizations.of(context).t('desktop.importContacts'),
      );
      if (!mounted || path == null) return;
      final result = await contacts.importLinuxVCardFile(path);
      if (mounted) {
        final strings = MicaLocalizations.of(context);
        var message = strings
            .t('desktop.contactsImported')
            .replaceAll('{n}', '${result.imported}')
            .replaceAll('{skipped}', '${result.skipped}');
        if (result.photoErrors > 0) {
          message +=
              ' ${strings.t('desktop.contactPhotosFailed').replaceAll('{n}', '${result.photoErrors}')}';
        }
        TopBanner.show(context, message);
      }
    } catch (_) {
      if (mounted) {
        TopBanner.show(
          context,
          MicaLocalizations.of(context).t('desktop.contactsImportFailed'),
          kind: TopBannerKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(ContactsService contacts, bool enabled) async {
    setState(() => _busy = true);
    try {
      if (enabled) {
        await contacts.enable();
      } else {
        await contacts.disable();
      }
    } catch (_) {
      if (mounted) {
        TopBanner.show(
          context,
          MicaLocalizations.of(context).t('contacts.readFailed'),
          kind: TopBannerKind.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsService>();
    if (isLinuxDesktop) {
      final strings = MicaLocalizations.of(context);
      return Column(
        children: [
          ListTile(
            leading: const Icon(Icons.contacts_outlined),
            title: Text(strings.t('desktop.importContacts')),
            subtitle: Text(
              contacts.status == ContactsStatus.denied
                  ? strings.t('contacts.readFailed')
                  : strings
                        .t('desktop.contactsLocal')
                        .replaceAll('{n}', '${contacts.importedContactCount}'),
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_open_outlined),
            onTap: _busy ? null : () => _import(contacts),
          ),
          if (contacts.importedContactCount > 0)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(strings.t('desktop.clearContacts')),
              onTap: _busy ? null : () => _toggle(contacts, false),
            ),
        ],
      );
    }
    if (!contacts.isSupported) return const SizedBox.shrink();
    final strings = MicaLocalizations.of(context);
    final requesting = _busy || contacts.status == ContactsStatus.requesting;
    final denied = contacts.status == ContactsStatus.denied;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: requesting
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const SizedBox(width: 40, child: Icon(Icons.contacts_outlined)),
          title: Text(strings.t('contacts.matching')),
          subtitle: denied
              ? Text(contacts.error ?? strings.t('contacts.permissionDenied'))
              : null,
          value: contacts.isReady,
          onChanged: requesting ? null : (value) => _toggle(contacts, value),
        ),
        if (denied)
          Padding(
            padding: const EdgeInsets.only(left: 72, right: 16, bottom: 8),
            child: TextButton(
              onPressed: requesting
                  ? null
                  : () async {
                      try {
                        await contacts.openSettings();
                      } catch (_) {
                        if (context.mounted) {
                          TopBanner.show(
                            context,
                            strings.t('contacts.permissionFailed'),
                            kind: TopBannerKind.error,
                          );
                        }
                      }
                    },
              child: Text(strings.t('common.openSettings')),
            ),
          ),
      ],
    );
  }
}
