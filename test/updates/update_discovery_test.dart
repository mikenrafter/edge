// WHY: discovery runs on untrusted bytes with a shared, rate-limited server.
// These cases pin what the pilot suites do not: cache completeness behind a 304,
// negative-result caching, historical releases that must not poison a valid
// newer one, the no-APK-request rule, worker parsing, jitter and the typed
// outcomes of a check. Proves CLAIM(release-check-source-order),
// CLAIM(release-check-page-only), CLAIM(release-check-once).
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/data/json_payload_lane.dart';
import 'package:openstrap_edge/sync/update_coordinator.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'update_checker_test.dart' show release;
import 'update_selection_test.dart' show forkRelease, manifest;

class _RecordingLane implements JsonPayloadDecodeLane {
  final bodies = <int>[];
  @override
  Future<JsonPayloadsResult> run(JsonPayloadsInput input) async {
    for (final v in input.values) {
      bodies.add((v as String).length);
    }
    return const IsolateJsonPayloadLane().run(input);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late UpdateStore store;
  late DateTime now;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;
  late _RecordingLane lane;
  late UpdateCoordinator service;
  Duration jitter = Duration.zero;
  bool unmetered = true;

  UpdateCoordinator make() => UpdateCoordinator(
    store: store,
    client: MockClient((r) {
      requests.add(r);
      return respond(r);
    }),
    installed: const InstalledRelease(
      version: '0.11.3-dev',
      build: 78,
      fork: true,
      mode: 'profile',
      abis: ['arm64-v8a'],
    ),
    clock: Clock(() => now),
    unmetered: () async => unmetered,
    schedule: (_) async {},
    jitter: () => jitter,
    lane: lane,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-discovery-');
    store = await UpdateStore.openFile(
      '${directory.path}/u.db',
      factory: databaseFactoryFfi,
    );
    now = DateTime.utc(2026, 11, 15, 12);
    requests = [];
    jitter = Duration.zero;
    unmetered = true;
    lane = _RecordingLane();
    respond = (_) async => http.Response('[]', 200);
    service = make();
  });
  tearDown(() async {
    service.dispose();
    await store.db.close();
    await directory.delete(recursive: true);
  });

  Map<String, Object?> forkListing() => forkRelease('next-2026.11.15', 91);
  http.Response forkOk(http.Request r) {
    if (r.url.path.contains('/assets/')) {
      return http.Response(jsonEncode(manifest('next-2026.11.15', 80)), 200);
    }
    return http.Response(
      jsonEncode(r.url.path.contains('mikenrafter') ? [forkListing()] : []),
      200,
      headers: {'etag': '"fork-1"'},
    );
  }

  group('304 and cache completeness', () {
    // WHY: spec §5.1 - a 304 refreshes freshness only when the cached body,
    // pages and manifests it stands for are complete and valid.
    // catches: stamping an incomplete cache as freshly checked.
    test('304 over a complete cache refreshes the checked time', () async {
      respond = (r) async => forkOk(r);
      await service.check(manual: true);
      final first = service.snapshot.sources[ReleaseSource.fork]!;
      expect(first.candidate?.build, 80);
      now = now.add(const Duration(minutes: 2));
      respond = (_) async => http.Response('', 304);
      await service.check(manual: true);
      final second = service.snapshot.sources[ReleaseSource.fork]!;
      expect(second.checkedAt, now);
      expect(second.candidate?.build, 80);
      expect(second.error, isNull);
    });

    test('304 whose manifest cache is gone is a retryable failure', () async {
      respond = (r) async => forkOk(r);
      await service.check(manual: true);
      final original = service.snapshot.sources[ReleaseSource.fork]!.checkedAt;
      await store.db.delete('update_manifests');
      now = now.add(const Duration(minutes: 2));
      respond = (_) async => http.Response('', 304);
      await service.check(manual: true);
      final after = service.snapshot.sources[ReleaseSource.fork]!;
      expect(after.error, isNotNull);
      expect(after.checkedAt, original, reason: 'not refreshed');
      expect(after.candidate, isNotNull, reason: 'last good stays, dated and stale');
      expect(after.stale, isTrue);
      expect(after.etag, isNull, reason: 'the next request must be unconditional');
    });

    // catches: treating "304, nothing cached" as up to date.
    test('304 with no cache at all is never current', () async {
      respond = (_) async => http.Response('', 304);
      await service.check(manual: true);
      final official = service.snapshot.sources[ReleaseSource.official]!;
      expect(official.candidate, isNull);
      expect(official.current, isFalse);
      expect(official.error, UpdateError.network);
    });
  });

  group('historical releases', () {
    // catches: a historical release with a bad assets array failing the source.
    test('an older release with a bad assets shape and a duplicate name is ignored', () async {
      respond = (r) async {
        if (!r.url.path.contains('OpenStrap')) return http.Response('[]', 200);
        final bad = release('v0.9.0', id: 1)..['assets'] = 'oops';
        final dup = release('v0.9.1', id: 2, assets: ['a.apk', 'a.apk']);
        return http.Response(jsonEncode([release('v0.11.4', id: 4), dup, bad]), 200);
      };
      await service.check(manual: true);
      final official = service.snapshot.sources[ReleaseSource.official]!;
      expect(official.error, isNull);
      expect(official.candidate?.tag, 'v0.11.4');
    });

    // WHY: a malformed NEWER release must not become "current".
    test('a newer malformed release blocks, keeps a page link and the last good', () async {
      respond = (r) async => http.Response(
        jsonEncode(r.url.path.contains('OpenStrap') ? [release('v0.11.4', id: 4)] : []),
        200,
      );
      await service.check(manual: true);
      now = now.add(const Duration(minutes: 2));
      respond = (r) async {
        final newer = release('v0.12.0', id: 5)..['assets'] = null;
        return http.Response(
          jsonEncode(r.url.path.contains('OpenStrap') ? [newer, release('v0.11.4', id: 4)] : []),
          200,
        );
      };
      await service.check(manual: true);
      final official = service.snapshot.sources[ReleaseSource.official]!;
      expect(official.error, isNotNull);
      expect(official.current, isFalse);
      expect(official.releasePage?.toString(), 'https://github.com/OpenStrap/edge/releases/tag/v0.12.0');
      expect(official.candidate?.tag, 'v0.11.4', reason: 'dated last good metadata');
    });

    // WHY: negative results are cached by release/asset id and modification time
    // so one broken historical manifest is not refetched on every check.
    // catches: refetching a 404 manifest daily, or caching it past a change.
    test('an unavailable older manifest is fetched once per modification time', () async {
      var updatedAt = '2026-11-01T00:00:00Z';
      respond = (r) async {
        if (r.url.path.endsWith('/assets/43')) return http.Response('', 404);
        if (r.url.path.contains('/assets/')) {
          return http.Response(jsonEncode(manifest('next-2026.11.15', 80)), 200);
        }
        if (!r.url.path.contains('mikenrafter')) return http.Response('[]', 200);
        final old = forkRelease('next-2026.11.01', 92);
        ((old['assets'] as List).first as Map)['id'] = 43;
        ((old['assets'] as List).first as Map)['updated_at'] = updatedAt;
        return http.Response(jsonEncode([forkListing(), old]), 200);
      };
      await service.check(manual: true);
      expect(service.snapshot.sources[ReleaseSource.fork]!.candidate?.build, 80);
      int old404() => requests.where((r) => r.url.path.endsWith('/assets/43')).length;
      expect(old404(), 1);
      now = now.add(const Duration(minutes: 2));
      await service.check(manual: true);
      expect(old404(), 1, reason: 'negative result reused');
      updatedAt = '2026-11-14T00:00:00Z';
      now = now.add(const Duration(minutes: 2));
      await service.check(manual: true);
      expect(old404(), 2, reason: 'asset changed, so ask again');
    });
  });

  group('requests', () {
    // WHY: owner rule, absolute: no binary URL fetch, ever (CLAIM release-check-page-only).
    // catches: following browser_download_url, an .apk asset URL or html_url.
    test('no request names an APK, a download URL or a foreign host', () async {
      final forkAssets = (forkListing()['assets'] as List).cast<Map>();
      for (final a in forkAssets) {
        a['browser_download_url'] = 'https://github.com/mikenrafter/edge/releases/download/x/${a['name']}';
        a['url'] = 'https://api.github.com/repos/mikenrafter/edge/releases/assets/${a['id']}';
      }
      respond = (r) async {
        if (r.url.path.contains('/assets/')) {
          return http.Response(jsonEncode(manifest('next-2026.11.15', 80)), 200);
        }
        return http.Response(
          jsonEncode(r.url.path.contains('mikenrafter')
              ? [forkListing()]
              : [release('v0.11.4', id: 4, url: 'https://evil.test/x.apk')]),
          200,
        );
      };
      await service.check(manual: true);
      expect(requests, isNotEmpty);
      for (final r in requests) {
        expect(r.url.host, 'api.github.com');
        expect(r.url.path.endsWith('.apk'), isFalse, reason: '${r.url}');
        expect(r.url.toString().contains('download'), isFalse, reason: '${r.url}');
      }
      // The only asset endpoint ever read is the manifest's (id 42).
      expect(
        requests.where((r) => r.url.path.contains('/assets/')).map((r) => r.url.path),
        everyElement(endsWith('/assets/42')),
      );
    });

    // WHY: spec §5.1 "Metadata parsing is bounded registered-worker work".
    // catches: jsonDecode of a multi-megabyte page on the UI isolate.
    test('every metadata body is parsed through the worker lane', () async {
      respond = (r) async => forkOk(r);
      await service.check(manual: true);
      // 2 listings + 1 manifest.
      expect(lane.bodies, hasLength(3));
      expect(lane.bodies.every((n) => n > 0 && n < 2 * 1024 * 1024), isTrue);
    });
  });

  group('outcomes and jitter', () {
    test('typed outcomes distinguish deferral, refusal and completion', () async {
      expect(await service.check(), isA<CheckDeferred>());
      expect((await service.check() as CheckDeferred).reason, DeferReason.disabled);
      await service.setEnabled(true);
      unmetered = false;
      expect((await service.check() as CheckDeferred).reason, DeferReason.metered);
      expect(await service.check(manual: true), isA<CheckCompleted>());
      expect((await service.check(manual: true) as CheckDeferred).reason, DeferReason.throttled);
      expect(requests, hasLength(2), reason: 'the deferrals sent nothing');
    });

    test('storage failure is a failed outcome, not a throw', () async {
      await store.db.close();
      final outcome = await service.check(manual: true);
      expect(outcome, isA<CheckFailed>());
      expect((outcome as CheckFailed).error, UpdateError.storage);
    });

    // CLAIM(release-check-once) catches: every device checking at the same minute.
    test('the next automatic slot moves by the injected jitter', () async {
      jitter = const Duration(hours: 5);
      await service.setEnabled(true);
      await service.check();
      expect(requests, hasLength(2));
      now = now.add(const Duration(hours: 28, minutes: 59));
      await service.check();
      expect(requests, hasLength(2), reason: 'inside 24 h + 5 h');
      now = now.add(const Duration(minutes: 2));
      await service.check();
      expect(requests, hasLength(4));
    });

    // WHY: the server's deadline and our own due slot are separate facts.
    test('a server backoff keeps its own deadline beside the due slot', () async {
      await service.setEnabled(true);
      respond = (_) async => http.Response('', 429, headers: {'retry-after': '7200'});
      await service.check();
      final retry = service.snapshot.sources[ReleaseSource.official]!.retryAt;
      expect(retry, now.add(const Duration(hours: 2)));
      now = now.add(const Duration(hours: 1));
      expect((await service.check(manual: true)), isA<CheckCompleted>());
      expect(requests, hasLength(2), reason: 'both sources honored their deadline');
      now = now.add(const Duration(hours: 1, minutes: 2));
      respond = (_) async => http.Response('[]', 200);
      await service.check(manual: true);
      expect(requests, hasLength(4));
    });
  });
}
