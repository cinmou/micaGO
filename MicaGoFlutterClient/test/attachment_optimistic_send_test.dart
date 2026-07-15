import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/store/message_collection.dart';

MessageModel _serverAttachment({
  String guid = 'srv-1',
  String name = 'photo.jpg',
  int bytes = 1234,
  int at = 100000,
  String? text,
}) => MessageModel(
  guid: guid,
  chatGuid: 'chat-a',
  text: text,
  isFromMe: true,
  dateCreated: at,
  attachments: [
    AttachmentModel(
      guid: 'att-$guid',
      downloadUrl: '/api/attachments/att-$guid',
      transferName: name,
      totalBytes: bytes,
      attachmentKind: 'image',
    ),
  ],
);

void main() {
  group('optimistic attachment send (C63)', () {
    test('factory builds a sending image message with a local guid', () {
      final m = MessageModel.optimisticAttachment(
        tempId: 'tmp-att-1',
        filename: 'photo.jpg',
        totalBytes: 1234,
        dateCreated: 100000,
      );
      expect(m.tempId, 'tmp-att-1');
      expect(m.localState, LocalSendState.sending);
      expect(m.isFromMe, isTrue);
      expect(m.attachments, hasLength(1));
      final a = m.attachments.single;
      expect(a.guid, MessageModel.localAttachmentGuid('tmp-att-1'));
      expect(a.canRenderInlineImage, isTrue);
      expect(a.totalBytes, 1234);
    });

    test('non-image files stage as a file card, not a broken image', () {
      final m = MessageModel.optimisticAttachment(
        tempId: 'tmp-att-2',
        filename: 'report.pdf',
        totalBytes: 999,
        dateCreated: 100000,
      );
      expect(m.attachments.single.canRenderInlineImage, isFalse);
      expect(m.attachments.single.attachmentKind, 'file');
    });

    test('reconciles with the confirmed server row by filename', () {
      final local = MessageModel.optimisticAttachment(
        tempId: 'tmp-att-3',
        filename: 'Photo.JPG',
        totalBytes: 1234,
        dateCreated: 100000,
      );
      expect(
        shouldReconcileLocalWithServer(local, _serverAttachment(at: 150000)),
        isTrue,
      );
      // Same size but different name also matches (server may rename).
      expect(
        shouldReconcileLocalWithServer(
          local,
          _serverAttachment(name: 'converted.caf', bytes: 1234),
        ),
        isTrue,
      );
    });

    test('does not reconcile across the window, text rows, or other files', () {
      final local = MessageModel.optimisticAttachment(
        tempId: 'tmp-att-4',
        filename: 'photo.jpg',
        totalBytes: 1234,
        dateCreated: 100000,
      );
      // > 5 minutes apart.
      expect(
        shouldReconcileLocalWithServer(local, _serverAttachment(at: 500000)),
        isFalse,
      );
      // A captioned server row is not a bare attachment send.
      expect(
        shouldReconcileLocalWithServer(local, _serverAttachment(text: 'hey')),
        isFalse,
      );
      // Different name AND different size.
      expect(
        shouldReconcileLocalWithServer(
          local,
          _serverAttachment(name: 'other.png', bytes: 42),
        ),
        isFalse,
      );
    });

    test('pending bubble is removed when the confirming row is upserted', () {
      final col = MessageCollection();
      final local = MessageModel.optimisticAttachment(
        tempId: 'tmp-att-5',
        filename: 'photo.jpg',
        totalBytes: 1234,
        dateCreated: 100000,
      );
      col.addPending(local);
      expect(col.ordered, hasLength(1));
      col.upsertServer(_serverAttachment());
      expect(col.ordered, hasLength(1));
      expect(col.ordered.single.guid, 'srv-1');
      expect(col.pendingByTempId('tmp-att-5'), isNull);
      expect(col.presentationKeyFor(col.ordered.single), local.dedupeKey);
    });
  });

  group('U+FFFC placeholder text reconciliation (C67)', () {
    // chat.db stores attachment messages with the object-replacement char in
    // the text column and the server passes it through. Reconciliation must
    // treat it as "no text" (the renderer already does) — this was the
    // "photo sends show two bubbles until the thread is reopened" bug.
    test('server row whose text is U+FFFC still reconciles by identity', () {
      final local = MessageModel.optimisticAttachment(
        tempId: 'tmp-f1',
        filename: 'photo.jpg',
        totalBytes: 1234,
        dateCreated: 100000,
      );
      expect(
        shouldReconcileLocalWithServer(
          local,
          _serverAttachment(at: 150000, text: '￼'),
        ),
        isTrue,
      );
    });

    test('U+FFFC server row reconciles inside the collection (live path)', () {
      final col = MessageCollection();
      col.addPending(
        MessageModel.optimisticAttachment(
          tempId: 'tmp-f2',
          filename: 'photo.jpg',
          totalBytes: 1234,
          dateCreated: 100000,
        ),
      );
      col.upsertServer(_serverAttachment(guid: 'srv-f2', text: '￼ '));
      expect(col.ordered, hasLength(1));
      expect(col.ordered.single.guid, 'srv-f2');
      expect(col.presentationKeyFor(col.ordered.single), 'tmp-f2');
    });

    test('a real caption still blocks bare-attachment reconciliation', () {
      final local = MessageModel.optimisticAttachment(
        tempId: 'tmp-f3',
        filename: 'photo.jpg',
        totalBytes: 1234,
        dateCreated: 100000,
      );
      expect(
        shouldReconcileLocalWithServer(
          local,
          _serverAttachment(text: '￼ look at this'),
        ),
        isFalse,
      );
    });
  });

  group('converted-file reconciliation (C66)', () {
    MessageModel pendingVoice({String tempId = 'tmp-v1'}) =>
        MessageModel.optimisticAttachment(
          tempId: tempId,
          filename: 'voice.m4a',
          totalBytes: 1000,
          dateCreated: 100000,
        );

    test('same stem with a converted extension matches by identity', () {
      expect(
        shouldReconcileLocalWithServer(
          pendingVoice(),
          _serverAttachment(name: 'voice.caf', bytes: 555),
        ),
        isTrue,
      );
    });

    test(
      'fully renamed conversion loose-reconciles a single in-flight pending',
      () {
        final col = MessageCollection();
        col.addPending(pendingVoice());
        // Name AND size rewritten by the server — identity can't match.
        col.upsertServer(
          _serverAttachment(
            guid: 'srv-c1',
            name: 'converted-abc.caf',
            bytes: 777,
          ),
        );
        expect(col.ordered, hasLength(1));
        expect(col.ordered.single.guid, 'srv-c1');
        expect(col.presentationKeyFor(col.ordered.single), 'tmp-v1');
      },
    );

    test('conversion fallback refuses ambiguous (2+) candidates', () {
      // C70: with several sends in flight, "closest by time" was a coin flip
      // that swapped whole bubbles — an ambiguous conversion must not guess.
      final col = MessageCollection();
      col.addPending(pendingVoice(tempId: 'tmp-v1'));
      col.addPending(
        MessageModel.optimisticAttachment(
          tempId: 'tmp-v2',
          filename: 'clip.m4a',
          totalBytes: 2000,
          dateCreated: 101000,
        ),
      );
      col.upsertServer(
        _serverAttachment(
          guid: 'srv-c2',
          name: 'converted-xyz.caf',
          bytes: 777,
        ),
      );
      expect(col.ordered, hasLength(3));
      expect(col.pendingByTempId('tmp-v1'), isNotNull);
      expect(col.pendingByTempId('tmp-v2'), isNotNull);
    });

    test('same-name server row never consumes two pending sends', () {
      final col = MessageCollection();
      col.addPending(
        MessageModel.optimisticAttachment(
          tempId: 'tmp-a',
          filename: 'photo.jpg',
          totalBytes: 1234,
          dateCreated: 99000,
        ),
      );
      col.addPending(
        MessageModel.optimisticAttachment(
          tempId: 'tmp-b',
          filename: 'photo.jpg',
          totalBytes: 1234,
          dateCreated: 101000,
        ),
      );

      col.upsertServer(_serverAttachment(at: 100500));

      expect(col.ordered, hasLength(2));
      expect(col.pendingByTempId('tmp-a'), isNotNull);
      expect(col.pendingByTempId('tmp-b'), isNull);
    });

    test('loose reconcile only fires for newly inserted rows', () {
      final col = MessageCollection();
      // The converted row is already known (e.g. re-paged history)…
      col.upsertServer(
        _serverAttachment(guid: 'srv-c3', name: 'converted.caf', bytes: 777),
      );
      // …then a pending appears; re-upserting the same guid must not eat it.
      col.addPending(pendingVoice());
      col.upsertServer(
        _serverAttachment(guid: 'srv-c3', name: 'converted.caf', bytes: 777),
      );
      expect(col.ordered, hasLength(2));
    });

    test('failed pendings are never loose-reconciled (kept for retry)', () {
      final col = MessageCollection();
      col.addPending(pendingVoice());
      col.setPendingState('tmp-v1', LocalSendState.failed);
      col.upsertServer(
        _serverAttachment(guid: 'srv-c4', name: 'converted.caf', bytes: 777),
      );
      expect(col.pendingByTempId('tmp-v1'), isNotNull);
    });
  });

  group('pinned pending bytes (C66)', () {
    test('pinLocal hits synchronously and load never fetches', () async {
      final cache = MediaCache.instance;
      final bytes = Uint8List.fromList([1, 2, 3]);
      cache.pinLocal('local-tmp-x', bytes);
      expect(cache.memoryHit('local-tmp-x'), same(bytes));
      var fetched = false;
      final loaded = await cache.load('local-tmp-x', () async {
        fetched = true;
        return Uint8List(0);
      });
      expect(loaded, same(bytes));
      expect(fetched, isFalse);
      cache.unpinLocal('local-tmp-x');
      expect(cache.memoryHit('local-tmp-x'), isNull);
    });
  });

  group('media cache keys (C63)', () {
    test('filenames are filesystem-safe and deterministic', () {
      const key = '/api/attachments/abc/preview?x=1';
      final name = fileNameForMediaKey(key);
      expect(name, fileNameForMediaKey(key));
      expect(name.contains('/'), isFalse);
      expect(name.contains('='), isFalse);
      expect(name, isNot(fileNameForMediaKey('other-key')));
    });

    test('full-media keys do not collide with preview keys', () {
      expect(MediaCache.fullMediaKey('g1'), isNot('g1'));
    });
  });
}
