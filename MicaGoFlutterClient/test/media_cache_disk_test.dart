import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/core/network/api_client.dart';

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('micago-cache-test-'),
  );
  tearDown(() async => directory.delete(recursive: true));
  File file(String key) =>
      File('${directory.path}/${fileNameForMediaKey(key)}');
  Future<void> seed(String key, int length, Duration age) async {
    await file(key).writeAsBytes(List.filled(length, 1));
    await file(key).setLastModified(DateTime.now().subtract(age));
  }

  test(
    'startup removes expired entries and evicts oldest until within budget',
    () async {
      await seed('expired', 4, const Duration(days: 31));
      await seed('old', 4, const Duration(days: 2));
      await seed('recent', 4, const Duration(days: 1));
      final cache = MediaCache(maxDiskBytes: 4);
      await cache.init(directory: directory);
      expect(await file('expired').exists(), isFalse);
      expect(await file('old').exists(), isFalse);
      expect(await file('recent').exists(), isTrue);
    },
  );

  test(
    'disk read refreshes recency and survives subsequent capacity eviction',
    () async {
      final cache = MediaCache(maxDiskBytes: 8, maxMemoryBytes: 0);
      await cache.init(directory: directory);
      await seed('keep', 4, const Duration(days: 3));
      await seed('evict', 4, const Duration(days: 2));
      var requests = 0;
      await cache.load('keep', () async {
        requests++;
        return Uint8List(4);
      });
      expect(requests, 0);
      await cache.load('new', () async => Uint8List(4));
      await cache.prune();
      expect(await file('keep').exists(), isTrue);
      expect(await file('evict').exists(), isFalse);
      expect(await file('new').exists(), isTrue);
      expect(
        await file('keep').lastModified(),
        isA<DateTime>().having(
          (date) =>
              date.isAfter(DateTime.now().subtract(const Duration(minutes: 1))),
          'recent read',
          isTrue,
        ),
      );
    },
  );

  test('expired disk hit refetches and publishes a complete file', () async {
    final cache = MediaCache(maxMemoryBytes: 0);
    await cache.init(directory: directory);
    await seed('image', 3, const Duration(days: 31));
    final result = await cache.load(
      'image',
      () async => Uint8List.fromList([7, 8]),
    );
    await cache.prune();
    expect(result, [7, 8]);
    expect(await file('image').readAsBytes(), [7, 8]);
    expect(await File('${file('image').path}.part').exists(), isFalse);
  });

  test(
    'oversized downloads and pending local originals stay outside disk eviction',
    () async {
      final cache = MediaCache(maxDiskBytes: 1, maxMemoryBytes: 0);
      await cache.init(directory: directory);
      final preview = Uint8List.fromList([1, 2]);
      final original = Uint8List.fromList([3, 4, 5]);
      cache.registerLocal(
        'local-pending',
        preview: preview,
        loadPreview: () async => preview,
        loadOriginal: () async => original,
      );
      await cache.load('large', () async => Uint8List(2));
      await cache.prune();
      expect(await file('large').exists(), isFalse);
      expect(await directory.list().toList(), isEmpty);
      expect(cache.memoryHit('local-pending'), same(preview));
      final api = ApiClient(
        baseUrl: 'https://test',
        token: 'test',
        httpClient: MockClient(
          (_) async => throw StateError('unexpected fetch'),
        ),
      );
      addTearDown(api.close);
      expect(await cache.attachmentFull(api, 'local-pending'), same(original));
      expect(
        await cache.load(
          'local-pending',
          () async => throw StateError('unexpected fetch'),
        ),
        same(preview),
      );
    },
  );

  test('only abandoned partial files are reclaimed', () async {
    final stale = File('${directory.path}/old.part');
    final active = File('${directory.path}/new.part');
    await stale.writeAsString('partial');
    await stale.setLastModified(
      DateTime.now().subtract(const Duration(hours: 2)),
    );
    await active.writeAsString('partial');
    await MediaCache().init(directory: directory);
    expect(await stale.exists(), isFalse);
    expect(await active.exists(), isTrue);
  });
}
