import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/chats/avatar.dart';
import 'package:mica_go/features/contacts/contacts_service.dart';

class _MemoryStore implements SecureStore {
  bool enabled = false;
  @override
  Future<bool> contactsMatchingEnabled() async => enabled;
  @override
  Future<void> setContactsMatchingEnabled(bool value) async {
    enabled = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _card({String? photo, String name = 'Alice', String uid = 'person-1'}) =>
    'BEGIN:VCARD\nVERSION:3.0\nUID:$uid\nFN:$name\n'
    'TEL:+19995550123\nEMAIL:alice@example.test\n'
    '${photo == null ? '' : 'PHOTO;ENCODING=b;TYPE=PNG:$photo\n'}END:VCARD\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('micago-contact-photos-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getApplicationSupportDirectory');
          return directory.path;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  testWidgets(
    'photos survive restart and appear through the chat avatar entry',
    (tester) async {
      late ContactsService contacts;
      late Uint8List photo;
      await tester.runAsync(() async {
        final store = _MemoryStore();
        final imported = ContactsService(store: store);
        final file = await File(
          '${directory.path}/photo.vcf',
        ).writeAsString(_card(photo: _redPhoto));
        final result = await imported.importLinuxVCardFile(file.path);
        expect(result.photoErrors, 0);
        expect(result.imported, 1);
        contacts = ContactsService(store: store);
        await contacts.bootstrap();
        photo = (await contacts.thumbnailForHandle('+19995550123'))!;
        expect(
          await contacts.thumbnailForHandle('alice@example.test'),
          orderedEquals(photo),
        );
        final buffer = await ui.ImmutableBuffer.fromUint8List(photo);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        expect(descriptor.width, 256);
        expect(descriptor.height, 128);
        descriptor.dispose();
        buffer.dispose();
        expect(
          await Directory(
            '${directory.path}/linux-contact-avatars',
          ).list().length,
          1,
        );
        imported.dispose();
      });
      addTearDown(contacts.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ContactsService>.value(
          value: contacts,
          child: const MaterialApp(
            home: Scaffold(
              body: HandleAvatar(title: 'Alice', handle: '+19995550123'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isA<MemoryImage>());
      expect(
        (avatar.backgroundImage! as MemoryImage).bytes,
        orderedEquals(photo),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'updates replace avatars, keep good photos on errors, and clear images',
    (tester) async {
      await tester.runAsync(() async {
        final contacts = ContactsService(store: _MemoryStore());
        try {
          final file = File('${directory.path}/photo.vcf');
          await file.writeAsString(_card(photo: _redPhoto));
          await contacts.importLinuxVCardFile(file.path);
          final red = (await contacts.thumbnailForHandle('+19995550123'))!;
          await file.writeAsString(_card(photo: _bluePhoto));
          await contacts.importLinuxVCardFile(file.path);
          final blue = (await contacts.thumbnailForHandle('+19995550123'))!;
          expect(blue, isNot(orderedEquals(red)));
          expect(
            await Directory(
              '${directory.path}/linux-contact-avatars',
            ).list().length,
            1,
          );
          await file.writeAsString(_card(name: 'Renamed'));
          await contacts.importLinuxVCardFile(file.path);
          expect(
            await contacts.thumbnailForHandle('+19995550123'),
            orderedEquals(blue),
          );
          for (final invalid in [
            'invalid-base64',
            base64Encode(utf8.encode('not an image')),
          ]) {
            await file.writeAsString(_card(photo: invalid));
            final result = await contacts.importLinuxVCardFile(file.path);
            expect(result.imported, 1);
            expect(result.photoErrors, 1);
            expect(
              await contacts.thumbnailForHandle('+19995550123'),
              orderedEquals(blue),
            );
          }
          await file.writeAsString(_card(uid: 'upgraded-person'));
          await contacts.importLinuxVCardFile(file.path);
          expect(
            await contacts.thumbnailForHandle('alice@example.test'),
            orderedEquals(blue),
          );
          await contacts.disable();
          expect(
            await Directory('${directory.path}/linux-contact-avatars').exists(),
            isFalse,
          );
          expect(await contacts.thumbnailForHandle('+19995550123'), isNull);
          expect(contacts.importedContactCount, 0);
        } finally {
          contacts.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('embedded data URIs and unindented vCard 2.1 photos import', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final contacts = ContactsService(store: _MemoryStore());
      final file = File('${directory.path}/photo.vcf');
      try {
        final wrapped = [
          for (var i = 0; i < _redPhoto.length; i += 76)
            _redPhoto.substring(
              i,
              i + 76 > _redPhoto.length ? _redPhoto.length : i + 76,
            ),
        ].join('\n');
        final exports = [
          _card(photo: _redPhoto)
              .replaceFirst('VERSION:3.0', 'VERSION:4.0')
              .replaceFirst(
                'PHOTO;ENCODING=b;TYPE=PNG:',
                'PHOTO:data:image/png;base64,',
              ),
          _card(photo: wrapped).replaceFirst('VERSION:3.0', 'VERSION:2.1'),
        ];
        for (final text in exports) {
          await file.writeAsString(text);
          final result = await contacts.importLinuxVCardFile(file.path);
          expect(result.photoErrors, 0);
          expect(await contacts.thumbnailForHandle('+19995550123'), isNotNull);
        }
      } finally {
        contacts.dispose();
      }
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('large exports retain embedded avatars', (tester) async {
    await tester.runAsync(() async {
      final contacts = ContactsService(store: _MemoryStore());
      final file = File('${directory.path}/large.vcf');
      final output = file.openWrite();
      output.write(_card(photo: _redPhoto).replaceFirst('END:VCARD\n', ''));
      final foldedPhoto = ' ${' ' * 65536}\n';
      for (var i = 0; i < 176; i++) {
        output.write(foldedPhoto);
      }
      output.write('END:VCARD\n');
      await output.close();
      try {
        expect(await file.length(), greaterThan(10 * 1024 * 1024));
        final result = await contacts.importLinuxVCardFile(file.path);
        expect(result.imported, 1);
        expect(result.photoErrors, 0);
        expect(await contacts.thumbnailForHandle('+19995550123'), isNotNull);
      } finally {
        contacts.dispose();
      }
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'a damaged duplicate photo keeps a valid photo from the same export',
    (tester) async {
      await tester.runAsync(() async {
        final contacts = ContactsService(store: _MemoryStore());
        final file = await File('${directory.path}/duplicates.vcf')
            .writeAsString(
              _card(photo: _redPhoto) +
                  _card(photo: base64Encode(utf8.encode('not an image'))),
            );
        try {
          final result = await contacts.importLinuxVCardFile(file.path);
          expect(result.photoErrors, 1);
          expect(contacts.importedContactCount, 1);
          expect(await contacts.thumbnailForHandle('+19995550123'), isNotNull);
        } finally {
          contacts.dispose();
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('legacy imports without avatar fields remain readable', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final store = _MemoryStore()..enabled = true;
      await File('${directory.path}/linux-contacts.json').writeAsString(
        jsonEncode([
          {
            'id': 'legacy',
            'name': 'Alice',
            'phones': ['+19995550123'],
            'emails': [],
          },
        ]),
      );
      final contacts = ContactsService(store: store);
      try {
        await contacts.bootstrap();
        expect(contacts.displayNameFor('+19995550123'), 'Alice');
        expect(await contacts.thumbnailForHandle('+19995550123'), isNull);
      } finally {
        contacts.dispose();
      }
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}

const _redPhoto =
    'iVBORw0KGgoAAAANSUhEUgAAAoAAAAFACAIAAACjr1pdAAAE9ElEQVR4nO3VMQEAIAzAMMC/5+GCHiQK+nXPAgBeO3'
    'UAAPzIgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCA'
    'ASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAAB'
    'AwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgY'
    'MAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGA'
    'ACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAAB'
    'AwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQ'
    'NAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEg'
    'YMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMG'
    'AACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAA'
    'BAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAg'
    'YMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMG'
    'gIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQM'
    'CAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDA'
    'ABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAA'
    'gYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQM'
    'GAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCAAQNAwIABIGDAABAwYAAIGDAABAwYAAIGDA'
    'ABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgAEgYMAAEDBgAAgYMAAEDBgAAgYMAAEDBoCA'
    'AQNAwIABIGDAABAwYAAIGDAABAwYAAIGDAABAwaAgAEDQMCAASBgwAAQMGAACBgwAAQMGAACBgwAAQMGgIABA0DAgA'
    'EgYMAAEDBgAAgYMAAEDBgAAgYMAIELC6UDf7MtZyAAAAAASUVORK5CYII=';

const _bluePhoto =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKUlEQVR4nO3NMQEAAAjDsIF/z2ACvlRAU8nks369Aw'
    'AAAAAAAAAAgMMWocYBP7wfsd0AAAAASUVORK5CYII=';
