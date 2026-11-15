// WHY: untrusted release metadata must never authorize installs or arbitrary
// navigation; automatic GitHub traffic requires this install's consent.
// Proves CLAIM(update-network-consent), CLAIM(update-release-page),
// CLAIM(update-source-order), CLAIM(update-asset-match), CLAIM(update-lease).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/sync/update_service.dart';
import 'package:openstrap_edge/sync/update_store.dart';

Map<String, Object?> release(String tag, {int id = 1, bool prerelease = false,
    bool draft = false, List<String>? assets, String? url}) => {
  'id': id, 'tag_name': tag, 'draft': draft, 'prerelease': prerelease,
  'html_url': url ?? 'https://github.com/OpenStrap/edge/releases/tag/$tag',
  'body': '<script>location="https://evil.test"</script>',
  'assets': [for (final name in assets ?? ['openstrap-edge-$tag.apk'])
    {'id': name == 'edge-release.json' ? 42 : 10, 'name': name}],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late UpdateStore store;
  late DateTime now;
  late List<http.Request> requests;
  late bool unmetered;
  late UpdateService service;
  late Future<http.Response> Function(http.Request) respond;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('updates-test-');
    store = UpdateStore(await databaseFactoryFfi.openDatabase('${directory.path}/updates.db'));
    await store.initialize();
    now = DateTime.utc(2026, 11, 15, 12);
    requests = [];
    unmetered = true;
    respond = (request) async => http.Response(jsonEncode(request.url.path.contains('OpenStrap')
      ? [release('v0.11.4')] : []), 200, headers: {'etag': '"first"'});
    service = UpdateService(store: store, client: MockClient((request) {
      requests.add(request);
      return respond(request);
    }), now: () => now, unmetered: () async => unmetered,
      installed: const InstalledRelease(version: '0.11.3', build: 78, fork: true, mode: 'profile'),
      schedule: (_) async {});
  });
  tearDown(() async { await store.db.close(); await directory.delete(recursive: true); });

  // catches: treating the previous companion preference as consent.
  test('off and metered automatic checks send zero requests; manual is one-time', () async {
    await service.check();
    expect(requests, isEmpty);
    await service.setEnabled(true);
    unmetered = false;
    await service.check();
    expect(requests, isEmpty);
    await service.check(manual: true);
    expect(requests.map((r) => r.url.toString()).toList(), [
      'https://api.github.com/repos/OpenStrap/edge/releases?per_page=100',
      'https://api.github.com/repos/mikenrafter/edge/releases?per_page=100']);
    await service.check(manual: true);
    expect(requests, hasLength(2));
    expect(service.snapshot.sources[ReleaseSource.official]!.candidate!.tag, 'v0.11.4');
  });

  // catches: rescheduling on every foreground, no persisted throttle, clock rollback loops.
  test('daily deadline survives restart and backwards clock', () async {
    await service.setEnabled(true);
    await service.check();
    now = now.add(const Duration(hours: 23));
    await service.check();
    expect(requests, hasLength(2));
    now = now.subtract(const Duration(days: 7));
    await service.check();
    await service.check();
    expect(requests, hasLength(2));
    now = DateTime.utc(2026, 11, 16, 18, 1);
    await service.check();
    expect(requests, hasLength(4));
  });

  // catches: a late response restoring state after opt-out, and check-then-write races.
  test('disable invalidates in-flight responses and coalesces requests', () async {
    final pending = Completer<http.Response>();
    respond = (_) => pending.future;
    await service.setEnabled(true);
    final first = service.check();
    while (requests.isEmpty) { await Future<void>.delayed(Duration.zero); }
    final second = service.check();
    await service.setEnabled(false);
    pending.complete(http.Response(jsonEncode([release('v9.0.0')]), 200));
    await Future.wait([first, second]);
    expect(service.snapshot.phase, UpdatePhase.off);
    expect((await store.read()).sources, isEmpty);
  });

  // catches: accidentally including health/version/device headers, or following redirects.
  test('egress contains only static GitHub headers and cache validators', () async {
    await service.check(manual: true);
    for (final r in requests) {
      expect(r.method, 'GET');
      expect(r.bodyBytes, isEmpty);
      expect(r.headers, {
        'accept': 'application/vnd.github+json',
        'user-agent': 'Edge-release-checker',
        'x-github-api-version': '2022-11-28',
      });
      expect(r.followRedirects, isFalse);
    }
    now = now.add(const Duration(minutes: 2));
    respond = (_) async => http.Response('', 302, headers: {'location': 'https://evil.test/a.apk'});
    await service.check(manual: true);
    expect(requests, hasLength(4));
    expect(service.snapshot.sources[ReleaseSource.official]!.error, UpdateError.redirect);
  });

  // catches: clearing a usable candidate on a 304, or allowing manual rate-limit bypass.
  test('ETag 304 reuses cache and rate-limit deadline blocks Check now', () async {
    await service.check(manual: true);
    now = now.add(const Duration(minutes: 2));
    respond = (_) async => http.Response('', 304);
    await service.check(manual: true);
    expect(requests.last.headers['if-none-match'], '"first"');
    expect(service.snapshot.sources[ReleaseSource.official]!.candidate!.tag, 'v0.11.4');
    now = now.add(const Duration(minutes: 2));
    respond = (_) async => http.Response('', 429, headers: {'retry-after': '172800'});
    await service.check(manual: true);
    now = now.add(const Duration(hours: 1));
    await service.check(manual: true);
    expect(requests, hasLength(6));
    expect(service.snapshot.sources[ReleaseSource.official]!.error, UpdateError.rateLimited);
  });

  // catches: up-to-date from malformed, empty or truncated metadata, and shared-source failures.
  test('bad JSON, empty fork, incomplete listing are honest independent states', () async {
    respond = (r) async => r.url.path.contains('OpenStrap')
      ? http.Response('{bad', 200) : http.Response('[]', 200);
    await service.check(manual: true);
    expect(service.snapshot.sources[ReleaseSource.official]!.error, UpdateError.badMetadata);
    expect(service.snapshot.sources[ReleaseSource.fork]!.error, UpdateError.noRelease);
    now = now.add(const Duration(minutes: 2));
    respond = (_) async => http.Response('[]', 200, headers: {
      'link': '<https://evil.test/?page=2>; rel="next"'});
    await service.check(manual: true);
    expect(service.snapshot.sources[ReleaseSource.official]!.error, UpdateError.incomplete);
    expect(requests, hasLength(4));
  });

  // catches: API order, lexicographic semver, cross-repo build comparisons, drafts.
  test('official stable semver order is independent of fork build codes', () {
    final candidate = selectRelease(ReleaseSource.official, [
      release('v0.11.4', id: 4), release('v0.12.0-beta.1', id: 5, prerelease: true),
      release('v0.9.99', id: 6), release('v0.11.99', id: 7, draft: true),
    ], const InstalledRelease(version: '0.11.3', build: 99999, fork: true, mode: 'profile'));
    expect(candidate!.tag, 'v0.11.4');
    expect(candidate.page.toString(), 'https://github.com/OpenStrap/edge/releases/tag/v0.11.4');
    expect(() => selectRelease(ReleaseSource.official,
      [release('v0.11.4'), release('v0.11.4', id: 2)],
      const InstalledRelease(version: '0.11.3', build: 1, fork: true, mode: 'profile')),
      throwsFormatException);
  });

  // catches: accepting a substring APK or selecting release when profile is absent.
  test('exact official portable and ABI names only', () {
    expect(matchAsset(ReleaseSource.official, 'v0.11.3', 'profile', ['x86_64', 'arm64-v8a'],
      ['openstrap-edge-v0.11.3.apk']), 'openstrap-edge-v0.11.3.apk');
    expect(matchAsset(ReleaseSource.official, 'v0.11.3', 'profile', ['x86_64', 'arm64-v8a'],
      ['openstrap-edge-v0.11.3-arm64-v8a.apk', 'openstrap-edge-v0.11.3-x86_64.apk']),
      'openstrap-edge-v0.11.3-x86_64.apk');
    expect(matchAsset(ReleaseSource.fork, 'next-2026.11.15', 'profile', ['arm64-v8a'],
      ['openstrap-edge-next-2026.11.15-dev-release.apk']), isNull);
    expect(matchAsset(ReleaseSource.official, 'v0.11.3', 'release', ['arm64-v8a'],
      ['evil-openstrap-edge-v0.11.3.apk', 'openstrap-edge-v0.11.3.zip']), isNull);
    expect(() => matchAsset(ReleaseSource.official, 'v0.11.3', 'release', [],
      ['openstrap-edge-v0.11.3.apk', 'openstrap-edge-v0.11.3.apk']), throwsFormatException);
  });

  // catches: release body/html_url injection, open redirects, path/userinfo tricks.
  test('navigation is reconstructed from two allowlisted repos and supported tags', () {
    for (final attack in ['https://evil.test/x', 'javascript:alert(1)',
      'https://github.com@evil.test/OpenStrap/edge/releases/tag/v0.11.4']) {
      final selected = selectRelease(ReleaseSource.official, [release('v0.11.4', url: attack)],
        const InstalledRelease(version: '0.11.3', build: 1, fork: true, mode: 'profile'));
      expect(selected!.page.host, 'github.com');
    }
    for (final url in ['https://github.com/OpenStrap/edge/releases/tag/v0.11.4',
      'https://github.com/mikenrafter/edge/releases/tag/next-2026.11.15']) {
      expect(ReleasePage.tryParse(url)?.uri.toString(), url);
    }
    for (final url in ['http://github.com/OpenStrap/edge/releases/tag/v0.11.4',
      'https://github.com/evil/edge/releases/tag/v0.11.4',
      'https://github.com/OpenStrap/edge/releases/download/v0.11.4/a.apk',
      'https://github.com/OpenStrap/edge/releases/tag/v0.11.4?next=evil',
      'https://github.com:444/OpenStrap/edge/releases/tag/v0.11.4',
      'https://github.com/OpenStrap/edge/releases/tag/%2e%2e']) {
      expect(ReleasePage.tryParse(url), isNull, reason: url);
    }
  });

  // catches: two isolates winning a lease, or stale worker saving after disable.
  test('store claims atomically and rejects an obsolete generation', () async {
    await store.setEnabled(true);
    final claims = await Future.wait([store.claim(now, manual: true), store.claim(now, manual: true)]);
    expect(claims.whereType<UpdateLease>(), hasLength(1));
    final lease = claims.whereType<UpdateLease>().single;
    await store.setEnabled(false);
    expect(await store.save(lease, ReleaseSource.official,
      SourceUpdate(checkedAt: now)), isFalse);
    await store.release(lease);
    expect((await store.read()).enabled, isFalse);
  });
}
