// WHY: discovery must finish across bounded batches without depending on API
// order, manifest-cache retention or a live coordinator surviving the batch.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/sync/update_coordinator.dart';
import 'package:openstrap_edge/sync/update_http.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'update_checker_test.dart' show release;
import 'update_selection_test.dart' show forkRelease, manifest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late UpdateStore store;
  late DateTime now;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;

  Future<SourceUpdate> batch(ReleaseSource source) async {
    requests.clear();
    final service = UpdateCoordinator(
      store: store,
      client: MockClient((r) { requests.add(r); return respond(r); }),
      clock: Clock(() => now),
      installed: const InstalledRelease(version: '0.11.3-dev', build: 78, fork: true, mode: 'profile'),
      unmetered: () async => true,
      schedule: (_) async {},
    );
    await service.check(manual: true);
    final answer = service.snapshot.sources[source]!;
    service.dispose();
    for (final s in ReleaseSource.values) {
      expect(requests.where((r) => r.url.path == '/repos/${s.repository}/releases').length,
          lessThanOrEqualTo(maxListingPages));
    }
    expect(requests.where((r) => r.url.path.contains('/assets/')).length,
        lessThanOrEqualTo(maxNewManifests));
    await store.db.close();
    store = await UpdateStore.openFile('${directory.path}/u.db', factory: databaseFactoryFfi);
    now = now.add(const Duration(minutes: 2));
    return answer;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-progress-');
    store = await UpdateStore.openFile('${directory.path}/u.db', factory: databaseFactoryFfi);
    now = DateTime.utc(2026, 11, 15, 12);
    requests = [];
  });
  tearDown(() async {
    await store.db.close();
    await directory.delete(recursive: true);
  });

  for (final (count, counters) in [(65, false), (73, false), (73, true)]) {
    // catches: restarting manifest traversal with only 64 retained entries.
    // N1: downloads and reactions must not erase traversal across restarts.
    // catches: hashing GitHub counters instead of normalized release facts.
    test('$count manifests finish with negative entries and an out-of-order maximum, counters=$counters', () async {
      final catalog = <Map<String, Object?>>[];
      final manifests = <int, Map<String, dynamic>>{};
      final fetched = <int>[];
      for (var i = 1; i <= count; i++) {
        final tag = 'next-${DateTime.utc(2026, 1, i).toIso8601String().substring(0, 10).replaceAll('-', '.')}';
        final entry = forkRelease(tag, i);
        ((entry['assets'] as List).first as Map)['id'] = 1000 + i;
        catalog.add(entry);
        manifests[1000 + i] = manifest(tag, i == 10 ? 10000 : 100 + i);
      }
      catalog.shuffle(Random(42)); // selection must follow checked builds, never API order
      respond = (r) async {
        if (r.url.path.contains('/assets/')) {
          final id = int.parse(r.url.pathSegments.last);
          fetched.add(id);
          // Five older entries are negatively cached. They cannot poison #10.
          return id <= 1005 ? http.Response('', 404)
              : http.Response(jsonEncode(manifests[id]), 200);
        }
        if (counters) {
          for (final row in catalog) {
            row['reactions'] = {'total_count': now.millisecondsSinceEpoch};
            for (final asset in row['assets'] as List) {
              (asset as Map)['download_count'] = now.millisecondsSinceEpoch;
            }
          }
        }
        return http.Response(jsonEncode(r.url.path.contains('mikenrafter') ? catalog : []), 200);
      };
      SourceUpdate? result;
      for (var i = 0; i < 20; i++) {
        result = await batch(ReleaseSource.fork);
        if (result.error != UpdateError.incomplete) break;
        expect(result.candidate, isNull, reason: 'no maximum established yet');
      }
      expect(result!.error, isNull);
      expect(result.candidate?.build, 10000);
      expect(result.candidate?.id, 10);
      expect(fetched.toSet(), {for (var i = 1; i <= count; i++) 1000 + i});
      expect(fetched, hasLength(count), reason: 'progress survives cache eviction and reopen');
      expect((await store.db.query('update_manifests')).length, lessThanOrEqualTo(64));
      final again = await batch(ReleaseSource.fork);
      expect(again.error, isNull, reason: 'a completed catalog stays complete');
      expect(again.candidate?.build, 10000);
      expect(fetched, hasLength(count), reason: 'completed progress avoids historical refetches');
      expect(await store.db.query('sqlite_master', where: 'name=?',
          whereArgs: ['update_progress']), hasLength(1));
      final summaries = await store.db.query('update_progress');
      expect(summaries.length, lessThanOrEqualTo(2));
      expect(jsonEncode(summaries).length, lessThan(64 * 1024));
    });
  }

  for (final change in ['none', 'head', 'later', 'counters']) {
    // WHY/N1: changing counters must not restart pagination or revalidation.
    // catches: restarting at page one forever, or trusting stale continuation.
    test('page four completes across restarts, catalog change=$change', () async {
      var changed = false;
      final pagesSeen = <int>[];
      respond = (r) async {
        if (!r.url.path.contains('OpenStrap')) return http.Response('[]', 200);
        final page = int.parse(r.url.queryParameters['page'] ?? '1');
        pagesSeen.add(page);
        final rows = page == 1
            ? [release(changed && change == 'head' ? 'v9.0.0' : 'v0.12.0', id: changed && change == 'head' ? 99 : 1)]
            : page == 2 && changed && change == 'later' ? [release('v9.0.0', id: 99)]
            : page == 4 ? [release('v1.0.0', id: 4)]
            : [release('unsupported-$page', id: page, draft: true)];
        if (change == 'counters') {
          for (final row in rows) {
            row['reactions'] = {'total_count': pagesSeen.length};
            for (final asset in row['assets'] as List) {
              (asset as Map)['download_count'] = pagesSeen.length;
            }
          }
        }
        return http.Response(jsonEncode(rows), 200, headers: {
          'etag': changed ? '"changed"' : '"original"',
          if (page < 4) 'link': '<${listingUri(ReleaseSource.official, page + 1)}>; rel="next"',
        });
      };
      var result = await batch(ReleaseSource.official);
      expect(result.error, UpdateError.incomplete);
      expect(result.candidate, isNull);
      if (change != 'none') changed = true;
      for (var i = 0; i < 12 && result.error == UpdateError.incomplete; i++) {
        result = await batch(ReleaseSource.official);
      }
      expect(result.error, isNull);
      expect(result.candidate?.tag, ['head', 'later'].contains(change) ? 'v9.0.0' : 'v1.0.0');
      expect(pagesSeen, contains(4));
      if (change == 'counters') {
        result = await batch(ReleaseSource.official);
        for (var i = 0; i < 12 && result.error == UpdateError.incomplete; i++) {
          result = await batch(ReleaseSource.official);
        }
        expect(result.error, isNull, reason: 'revalidation also ignores counter churn');
        expect(result.candidate?.tag, 'v1.0.0');
      }
    });
  }
}
