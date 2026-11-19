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
import 'package:openstrap_edge/sync/update_coordinator.dart';
import 'package:openstrap_edge/sync/update_selection.dart';
import 'package:openstrap_edge/sync/update_store.dart';

Map<String, Object?> release(
  String tag, {
  int id = 1,
  bool prerelease = false,
  bool draft = false,
  List<String>? assets,
  String? url,
}) => {
  'id': id,
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': url ?? 'https://github.com/OpenStrap/edge/releases/tag/$tag',
  'body': '<script>location="https://evil.test"</script>',
  'assets': [
    for (final name in assets ?? ['openstrap-edge-$tag.apk'])
      {'id': name == 'edge-release.json' ? 42 : 10, 'name': name},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late UpdateStore store;
  late DateTime now;
  late List<http.Request> requests;
  late bool unmetered;
  late UpdateCoordinator service;
  late List<ReleaseCandidate> announcements;
  late Future<http.Response> Function(http.Request) respond;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('updates-test-');
    store = UpdateStore(
      await databaseFactoryFfi.openDatabase('${directory.path}/updates.db'),
    );
    await store.initialize();
    now = DateTime.utc(2026, 11, 15, 12);
    requests = [];
    announcements = [];
    unmetered = true;
    respond = (request) async => http.Response(
      jsonEncode(
        request.url.path.contains('OpenStrap') ? [release('v0.11.4')] : [],
      ),
      200,
      headers: {'etag': '"first"'},
    );
    service = UpdateCoordinator(
      store: store,
      client: MockClient((request) {
        requests.add(request);
        return respond(request);
      }),
      now: () => now,
      unmetered: () async => unmetered,
      installed: const InstalledRelease(
        version: '0.11.3',
        build: 78,
        fork: true,
        mode: 'profile',
      ),
      schedule: (_) async {},
      onRelease: (candidate) async {
        announcements.add(candidate);
      },
    );
  });
  tearDown(() async {
    await store.db.close();
    await directory.delete(recursive: true);
  });

  // catches: treating the previous companion preference as consent.
  test(
    'off and metered automatic checks send zero requests; manual is one-time',
    () async {
      await service.check();
      expect(requests, isEmpty);
      await service.setEnabled(true);
      unmetered = false;
      await service.check();
      expect(requests, isEmpty);
      await service.check(manual: true);
      expect(requests.map((r) => r.url.toString()).toList(), [
        'https://api.github.com/repos/OpenStrap/edge/releases?per_page=100',
        'https://api.github.com/repos/mikenrafter/edge/releases?per_page=100',
      ]);
      await service.check(manual: true);
      expect(requests, hasLength(2));
      expect(
        service.snapshot.sources[ReleaseSource.official]!.candidate!.tag,
        'v0.11.4',
      );
    },
  );

  // WHY: a daily worker that runs during quiet hours must not suppress a
  // release forever; a later foreground may present cached metadata.
  // catches: requiring another due network request before a deferred alert.
  test(
    'fresh cached announcements are retried without metered network traffic',
    () async {
      await service.setEnabled(true);
      await service.check();
      expect(announcements.map((c) => c.tag), ['v0.11.4']);
      announcements.clear();
      now = now.add(const Duration(hours: 2));
      unmetered = false;
      await service.check();
      expect(requests, hasLength(2));
      expect(announcements.map((c) => c.tag), ['v0.11.4']);
    },
  );

  // WHY: a Wi-Fi-to-mobile transition can happen between source requests.
  // catches: checking unmetered only once when the batch starts.
  test(
    'automatic checks stop sending when the network becomes metered',
    () async {
      await service.setEnabled(true);
      respond = (_) async {
        unmetered = false;
        return http.Response('[]', 200);
      };
      await service.check();
      expect(requests.map((r) => r.url.path), [
        '/repos/OpenStrap/edge/releases',
      ]);
    },
  );

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
  test(
    'disable invalidates in-flight responses and coalesces requests',
    () async {
      final pending = Completer<http.Response>();
      respond = (_) => pending.future;
      await service.setEnabled(true);
      final first = service.check();
      while (requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final second = service.check();
      await service.setEnabled(false);
      pending.complete(http.Response(jsonEncode([release('v9.0.0')]), 200));
      await Future.wait([first, second]);
      expect(service.snapshot.phase, UpdatePhase.off);
      expect((await store.read()).sources, isEmpty);
    },
  );

  // catches: accidentally including health/version/device headers, or following redirects.
  test(
    'egress contains only static GitHub headers and cache validators',
    () async {
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
      respond = (_) async => http.Response(
        '',
        302,
        headers: {'location': 'https://evil.test/a.apk'},
      );
      await service.check(manual: true);
      expect(requests, hasLength(4));
      expect(
        service.snapshot.sources[ReleaseSource.official]!.error,
        UpdateError.redirect,
      );
    },
  );

  // catches: clearing a usable candidate on a 304, or allowing manual rate-limit bypass.
  test(
    'ETag 304 reuses cache and rate-limit deadline blocks Check now',
    () async {
      await service.check(manual: true);
      now = now.add(const Duration(minutes: 2));
      respond = (_) async => http.Response('', 304);
      await service.check(manual: true);
      expect(requests.last.headers['if-none-match'], '"first"');
      expect(
        service.snapshot.sources[ReleaseSource.official]!.candidate!.tag,
        'v0.11.4',
      );
      now = now.add(const Duration(minutes: 2));
      respond = (_) async =>
          http.Response('', 429, headers: {'retry-after': '172800'});
      await service.check(manual: true);
      now = now.add(const Duration(hours: 1));
      await service.check(manual: true);
      expect(requests, hasLength(6));
      expect(
        service.snapshot.sources[ReleaseSource.official]!.error,
        UpdateError.rateLimited,
      );
    },
  );

  // catches: up-to-date from malformed, empty or truncated metadata, and shared-source failures.
  test(
    'bad JSON, empty fork, incomplete listing are honest independent states',
    () async {
      respond = (r) async => r.url.path.contains('OpenStrap')
          ? http.Response('{bad', 200)
          : http.Response('[]', 200);
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.error,
        UpdateError.badMetadata,
      );
      expect(
        service.snapshot.sources[ReleaseSource.fork]!.error,
        UpdateError.noRelease,
      );
      now = now.add(const Duration(minutes: 2));
      respond = (_) async => http.Response(
        '[]',
        200,
        headers: {'link': '<https://evil.test/?page=2>; rel="next"'},
      );
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.error,
        UpdateError.incomplete,
      );
      expect(requests, hasLength(4));
    },
  );

  // WHY: GitHub returns numeric repository URLs, including after 100 releases.
  // catches: rejecting the real Link form or trusting another repository's id.
  test(
    'real numeric pagination stays scoped to both allowed repositories',
    () async {
      for (final source in ReleaseSource.values) {
        final repositoryId = source == ReleaseSource.official
            ? 1196502414
            : 1403688012;
        final tag = source == ReleaseSource.official
            ? 'v0.11.4'
            : 'next-2026.11.15';
        respond = (r) async {
          if (!r.url.path.contains(source.repository)) {
            return http.Response('[]', 200);
          }
          if (r.url.queryParameters['page'] == '2') {
            return http.Response(jsonEncode([release(tag, id: 101)]), 200);
          }
          return http.Response(
            jsonEncode(
              List.generate(100, (i) => release('unrecognized-$i', id: i + 1)),
            ),
            200,
            headers: {
              'link':
                  '<https://api.github.com/repositories/$repositoryId/releases?per_page=100&page=2>; rel="next", <https://api.github.com/repositories/$repositoryId/releases?per_page=100&page=2>; rel="last"',
            },
          );
        };
        await service.check(manual: true);
        expect(
          requests.where(
            (r) =>
                r.url.path == '/repos/${source.repository}/releases' &&
                r.url.queryParameters['page'] == '2',
          ),
          hasLength(1),
        );
        expect(
          service.snapshot.sources[source]!.error,
          isNot(UpdateError.incomplete),
        );
        now = now.add(const Duration(minutes: 2));
        requests.clear();
        // The other allowed repository's id is still wrong for this source.
        final wrongId = source == ReleaseSource.official
            ? 1403688012
            : 1196502414;
        respond = (r) async => http.Response(
          '[]',
          200,
          headers: r.url.path.contains(source.repository)
              ? {
                  'link':
                      '<https://api.github.com/repositories/$wrongId/releases?per_page=100&page=2>; rel="next"',
                }
              : {},
        );
        await service.check(manual: true);
        expect(service.snapshot.sources[source]!.error, UpdateError.incomplete);
        expect(
          requests.where((r) => r.url.queryParameters.containsKey('page')),
          isEmpty,
        );
        now = now.add(const Duration(minutes: 2));
        requests.clear();
      }
    },
  );

  // WHY: a permission error must not silence checks for a day; server deadlines
  // apply only to rate limits and cannot postpone a check for more than a week.
  // catches: every 403 treated as rateLimited; unbounded HTTP-date Retry-After.
  test(
    'ordinary 403 is retryable and real rate limits have bounded deadlines',
    () async {
      respond = (_) async => http.Response('', 403);
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.error,
        UpdateError.refused,
      );
      expect(service.snapshot.sources[ReleaseSource.official]!.retryAt, isNull);
      now = now.add(const Duration(minutes: 2));
      respond = (_) async => http.Response(
        '',
        403,
        headers: {
          'retry-after': HttpDate.format(now.add(const Duration(days: 365))),
        },
      );
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.error,
        UpdateError.rateLimited,
      );
      expect(
        service.snapshot.sources[ReleaseSource.official]!.retryAt,
        now.add(const Duration(days: 7)),
      );
      now = now.add(const Duration(days: 7, minutes: 1));
      respond = (_) async => http.Response(
        '',
        403,
        headers: {'x-ratelimit-remaining': '0', 'retry-after': '120'},
      );
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.retryAt,
        now.add(const Duration(minutes: 2)),
      );
      now = now.add(const Duration(minutes: 3));
      respond = (_) async =>
          http.Response(jsonEncode([release('v0.11.4')]), 200);
      await service.check(manual: true);
      expect(service.snapshot.sources[ReleaseSource.official]!.error, isNull);
    },
  );

  // catches: API order, lexicographic semver, cross-repo build comparisons, drafts.
  test('official stable semver order is independent of fork build codes', () {
    final candidate = selectRelease(
      ReleaseSource.official,
      [
        release('v0.11.4', id: 4),
        release('v0.12.0-beta.1', id: 5, prerelease: true),
        release('v0.9.99', id: 6),
        release('v0.11.99', id: 7, draft: true),
      ],
      const InstalledRelease(
        version: '0.11.3',
        build: 99999,
        fork: true,
        mode: 'profile',
      ),
    );
    expect(candidate!.tag, 'v0.11.4');
    expect(
      candidate.page.toString(),
      'https://github.com/OpenStrap/edge/releases/tag/v0.11.4',
    );
    expect(
      () => selectRelease(
        ReleaseSource.official,
        [release('v0.11.4'), release('v0.11.4', id: 2)],
        const InstalledRelease(
          version: '0.11.3',
          build: 1,
          fork: true,
          mode: 'profile',
        ),
      ),
      throwsFormatException,
    );
  });

  // WHY: official news must be newer than the fork base, never a permanent false alert.
  // catches: comparing the fork install's counter to an official release ID/code.
  test(
    'official release on a fork is informational at or below its base version',
    () async {
      respond = (r) async => http.Response(
        jsonEncode(
          r.url.path.contains('OpenStrap')
              ? [
                  release(
                    'v0.11.3',
                    assets: ['evil.apk', 'openstrap-edge-v0.11.3.apk'],
                  ),
                ]
              : [],
        ),
        200,
      );
      await service.check(manual: true);
      final official = service.snapshot.sources[ReleaseSource.official]!;
      expect(official.current, isTrue);
      expect(official.candidate!.asset, 'openstrap-edge-v0.11.3.apk');
      expect(announcements, isEmpty);
      await service.load();
      expect(service.snapshot.sources[ReleaseSource.official]!.current, isTrue);
      now = now.add(const Duration(minutes: 2));
      respond = (r) async => http.Response(
        jsonEncode(
          r.url.path.contains('OpenStrap') ? [release('v0.11.2')] : [],
        ),
        200,
      );
      await service.check(manual: true);
      expect(service.snapshot.sources[ReleaseSource.official]!.current, isTrue);
      expect(announcements, isEmpty);
    },
  );

  // WHY: older recognized assets must not hide a newer unrecognized release.
  // catches: silently selecting a previous APK then reporting up to date.
  test(
    'newest official release with unknown assets does not fall back to an older one',
    () {
      expect(
        selectRelease(ReleaseSource.official, [
          release('v0.11.3'),
          release('v0.12.0', id: 2, assets: ['different-v0.12.0.apk']),
        ], service.installed),
        isNull,
      );
    },
  );

  // WHY: an upstream server or proxy cannot expand a small metadata request without bound.
  // catches: reading an unlimited response, or treating a connectivity error as current.
  test('oversize bodies and transport failures are explicit errors', () async {
    respond = (_) async =>
        http.Response(' ' * 2097152 + jsonEncode([release('v0.11.4')]), 200);
    await service.check(manual: true);
    expect(
      service.snapshot.sources[ReleaseSource.official]!.error,
      UpdateError.badMetadata,
    );
    now = now.add(const Duration(minutes: 2));
    respond = (_) async => throw const SocketException('offline');
    await service.check(manual: true);
    expect(
      service.snapshot.sources[ReleaseSource.official]!.error,
      UpdateError.offline,
    );
  });

  // WHY: pagination is bounded and source-scoped; a partial list cannot prove current.
  // catches: following arbitrary Link URLs, or reading a fourth page.
  test('three-page bound never follows a fourth page', () async {
    respond = (r) async {
      final page = int.parse(r.url.queryParameters['page'] ?? '1');
      return http.Response(
        '[]',
        200,
        headers: {
          'link':
              '<https://api.github.com${r.url.path}?per_page=100&page=${page + 1}>; rel="next"',
        },
      );
    };
    await service.check(manual: true);
    expect(requests, hasLength(6));
    expect(
      service.snapshot.sources[ReleaseSource.official]!.error,
      UpdateError.incomplete,
    );
    expect(
      service.snapshot.sources[ReleaseSource.fork]!.error,
      UpdateError.incomplete,
    );
  });

  // WHY: official prereleases are hidden until explicitly selected, unlike fork releases.
  // catches: a global prerelease switch or lexical beta.10/beta.2 ordering.
  test(
    'official prerelease preference persists and uses semantic precedence',
    () async {
      final input = [
        release('v0.12.0-beta.2', id: 10, prerelease: true),
        release('v0.12.0-beta.10', id: 11, prerelease: true),
        release('v0.11.4', id: 12),
      ];
      expect(
        selectRelease(ReleaseSource.official, input, service.installed)!.tag,
        'v0.11.4',
      );
      expect(
        selectRelease(
          ReleaseSource.official,
          input,
          service.installed,
          officialPrereleases: true,
        )!.tag,
        'v0.12.0-beta.10',
      );
      await service.setOfficialPrereleases(true);
      expect((await store.read()).officialPrereleases, isTrue);
      respond = (r) async => http.Response(
        jsonEncode(r.url.path.contains('OpenStrap') ? input : []),
        200,
      );
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.candidate!.tag,
        'v0.12.0-beta.10',
      );
    },
  );

  // catches: accepting a substring APK or selecting release when profile is absent.
  test('exact official portable and ABI names only', () {
    expect(
      matchAsset(
        ReleaseSource.official,
        'v0.11.3',
        'profile',
        ['x86_64', 'arm64-v8a'],
        ['openstrap-edge-v0.11.3.apk'],
      ),
      'openstrap-edge-v0.11.3.apk',
    );
    expect(
      matchAsset(
        ReleaseSource.official,
        'v0.11.3',
        'profile',
        ['x86_64', 'arm64-v8a'],
        [
          'openstrap-edge-v0.11.3-arm64-v8a.apk',
          'openstrap-edge-v0.11.3-x86_64.apk',
        ],
      ),
      'openstrap-edge-v0.11.3-x86_64.apk',
    );
    expect(
      matchAsset(
        ReleaseSource.fork,
        'next-2026.11.15',
        'profile',
        ['arm64-v8a'],
        ['openstrap-edge-next-2026.11.15-dev-release.apk'],
      ),
      isNull,
    );
    expect(
      matchAsset(
        ReleaseSource.official,
        'v0.11.3',
        'release',
        ['arm64-v8a'],
        ['evil-openstrap-edge-v0.11.3.apk', 'openstrap-edge-v0.11.3.zip'],
      ),
      isNull,
    );
    expect(
      () => matchAsset(ReleaseSource.official, 'v0.11.3', 'release', [], [
        'openstrap-edge-v0.11.3.apk',
        'openstrap-edge-v0.11.3.apk',
      ]),
      throwsFormatException,
    );
  });

  // catches: release body/html_url injection, open redirects, path/userinfo tricks.
  test(
    'navigation is reconstructed from two allowlisted repos and supported tags',
    () {
      for (final attack in [
        'https://evil.test/x',
        'javascript:alert(1)',
        'https://github.com@evil.test/OpenStrap/edge/releases/tag/v0.11.4',
      ]) {
        final selected = selectRelease(
          ReleaseSource.official,
          [release('v0.11.4', url: attack)],
          const InstalledRelease(
            version: '0.11.3',
            build: 1,
            fork: true,
            mode: 'profile',
          ),
        );
        expect(selected!.page.uri.host, 'github.com');
      }
      for (final url in [
        'https://github.com/OpenStrap/edge/releases/tag/v0.11.4',
        'https://github.com/mikenrafter/edge/releases/tag/next-2026.11.15',
      ]) {
        expect(ReleasePage.tryParse(url)?.uri.toString(), url);
      }
      for (final url in [
        'http://github.com/OpenStrap/edge/releases/tag/v0.11.4',
        'https://github.com/evil/edge/releases/tag/v0.11.4',
        'https://github.com/OpenStrap/edge/releases/download/v0.11.4/a.apk',
        'https://github.com/OpenStrap/edge/releases/tag/v0.11.4?next=evil',
        'https://github.com:444/OpenStrap/edge/releases/tag/v0.11.4',
        'https://github.com/OpenStrap/edge/releases/tag/%2e%2e',
      ]) {
        expect(ReleasePage.tryParse(url), isNull, reason: url);
      }
    },
  );

  // WHY: names alone cannot establish the fork sequence or build mode.
  // catches: ignoring edge-release.json, cross-mode fallback and code/date sorting.
  test(
    'fork prereleases use the manifest sequence and exact current-mode asset',
    () async {
      final forkRelease = release(
        'next-2026.11.15',
        id: 90,
        prerelease: true,
        assets: [
          'edge-release.json',
          'openstrap-edge-next-2026.11.15-dev-profile-arm64-v8a.apk',
          'openstrap-edge-next-2026.11.15-dev-profile.apk',
        ],
      );
      final manifest = <String, Object?>{
        'formatVersion': 1,
        'repository': 'mikenrafter/edge',
        'tag': 'next-2026.11.15',
        'sourceSha': 'a' * 40,
        'versionCode': 79,
        'artifacts': [
          {
            'name': 'openstrap-edge-next-2026.11.15-dev-profile-arm64-v8a.apk',
            'mode': 'profile',
            'package': 'wtf.openstrap.openstrap_edge.dev',
            'abis': ['arm64-v8a'],
          },
          {
            'name': 'openstrap-edge-next-2026.11.15-dev-profile.apk',
            'mode': 'profile',
            'package': 'wtf.openstrap.openstrap_edge.dev',
            'abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
          },
        ],
      };
      respond = (request) async => http.Response(
        jsonEncode(
          request.url.path.endsWith('/assets/42')
              ? manifest
              : request.url.path.contains('mikenrafter')
              ? [forkRelease]
              : [release('v0.11.3')],
        ),
        200,
      );
      await service.check(manual: true);
      final candidate =
          service.snapshot.sources[ReleaseSource.fork]!.candidate!;
      expect(candidate.build, 79);
      expect(candidate.prerelease, isTrue);
      expect(candidate.identity, 'release:fork:90');
      expect(candidate.asset, 'openstrap-edge-next-2026.11.15-dev-profile.apk');
      final upgraded = UpdateCoordinator(
        store: store,
        client: service.client,
        now: () => now,
        unmetered: () async => true,
        schedule: (_) async {},
        installed: const InstalledRelease(
          version: '0.11.3',
          build: 79,
          fork: true,
          mode: 'profile',
        ),
      );
      await upgraded.load();
      expect(upgraded.snapshot.sources[ReleaseSource.fork]!.current, isTrue);

      expect(service.snapshot.sources[ReleaseSource.fork]!.current, isFalse);
      expect(requests.map((r) => r.url.path).toList(), [
        '/repos/OpenStrap/edge/releases',
        '/repos/mikenrafter/edge/releases',
        '/repos/mikenrafter/edge/releases/assets/42',
      ]);
      for (final package in ['wtf.openstrap.openstrap_edge', 'evil.package']) {
        final bad = jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
        (bad['artifacts'] as List).first['package'] = package;
        expect(
          selectRelease(
            ReleaseSource.fork,
            [forkRelease],
            service.installed,
            manifests: {90: bad},
          ),
          isNull,
        );
      }
      final badName = jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
      (badName['artifacts'] as List).first['name'] = '../evil.apk';
      expect(
        selectRelease(
          ReleaseSource.fork,
          [forkRelease],
          service.installed,
          manifests: {90: badName},
        ),
        isNull,
      );
      expect(
        selectRelease(ReleaseSource.fork, [forkRelease], service.installed),
        isNull,
      );
    },
  );

  // WHY: a date tag cannot order fork builds, and an unmatched newer build
  // must not be hidden by a recognized older one.
  // catches: sorting fork dates or silently falling back across build modes.
  test(
    'fork code orders releases and a newer missing profile never falls back',
    () {
      final input = [
        release(
          'next-2026.11.15',
          id: 91,
          prerelease: true,
          assets: [
            'edge-release.json',
            'openstrap-edge-next-2026.11.15-dev-profile.apk',
          ],
        ),
        release(
          'next-2026.11.08',
          id: 92,
          prerelease: true,
          assets: [
            'edge-release.json',
            'openstrap-edge-next-2026.11.08-dev-profile.apk',
          ],
        ),
      ];
      final manifests = <int, Map<String, dynamic>>{
        91: {
          'formatVersion': 1,
          'repository': 'mikenrafter/edge',
          'tag': 'next-2026.11.15',
          'sourceSha': 'a' * 40,
          'versionCode': 79,
          'artifacts': [
            {
              'name': 'openstrap-edge-next-2026.11.15-dev-profile.apk',
              'mode': 'profile',
              'package': 'wtf.openstrap.openstrap_edge.dev',
              'abis': ['arm64-v8a'],
            },
          ],
        },
        92: {
          'formatVersion': 1,
          'repository': 'mikenrafter/edge',
          'tag': 'next-2026.11.08',
          'sourceSha': 'b' * 40,
          'versionCode': 80,
          'artifacts': [
            {
              'name': 'openstrap-edge-next-2026.11.08-dev-profile.apk',
              'mode': 'profile',
              'package': 'wtf.openstrap.openstrap_edge.dev',
              'abis': ['arm64-v8a'],
            },
          ],
        },
      };
      expect(
        selectRelease(
          ReleaseSource.fork,
          input,
          service.installed,
          manifests: manifests,
        )!.tag,
        'next-2026.11.08',
      );
      input[1] = release(
        'next-2026.11.08',
        id: 92,
        prerelease: true,
        assets: [
          'edge-release.json',
          'openstrap-edge-next-2026.11.08-dev-release.apk',
        ],
      );
      (manifests[92]!['artifacts'] as List).single['name'] =
          'openstrap-edge-next-2026.11.08-dev-release.apk';
      (manifests[92]!['artifacts'] as List).single['mode'] = 'release';
      expect(
        selectRelease(
          ReleaseSource.fork,
          input,
          service.installed,
          manifests: manifests,
        ),
        isNull,
      );
    },
  );

  // WHY: permanent alert claims must be atomic across independent DB handles.
  // catches: using a Dart-only lock or SharedPreferences read-then-write.
  test(
    'notification claim has one winner across independent database connections',
    () async {
      final secondDb = await databaseFactoryFfi.openDatabase(
        store.db.path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final second = UpdateStore(secondDb);
      await second.initialize();
      await store.setEnabled(true);
      try {
        final t = DateTime.utc(2026, 11, 15);
        final claims = await Future.wait([
          store.beginRelease('release:fork:123', t),
          second.beginRelease('release:fork:123', t),
        ]);
        expect(claims.whereType<ReleaseTicket>(), hasLength(1));
        expect(await second.beginRelease('release:fork:123', t), isNull);
        expect(await second.beginRelease('release:fork:124', t), isNotNull);
      } finally {
        await secondDb.close();
      }
    },
  );

  // WHY: a failed request must release its transport without breaking the
  // independent source that follows it.
  // catches: leaking a response stream or reusing a client after closing it.
  test('request-scoped transports close on both failure and success', () async {
    final clients = <_TrackingClient>[];
    final scoped = UpdateCoordinator(
      store: store,
      client: service.client,
      installed: service.installed,
      now: () => now,
      unmetered: () async => true,
      schedule: (_) async {},
      clientFactory: () {
        final client = _TrackingClient(fail: clients.isEmpty);
        clients.add(client);
        return client;
      },
    );
    await scoped.check(manual: true);
    expect(clients, hasLength(2));
    expect(clients.map((c) => c.closes), [1, 1]);
    expect(
      scoped.snapshot.sources[ReleaseSource.official]!.error,
      UpdateError.network,
    );
    expect(
      scoped.snapshot.sources[ReleaseSource.fork]!.error,
      UpdateError.noRelease,
    );
  });

  // catches: two isolates winning a lease, or stale worker saving after disable.
  test('store claims atomically and rejects an obsolete generation', () async {
    await store.setEnabled(true);
    final claims = await Future.wait([
      store.claim(now, manual: true),
      store.claim(now, manual: true),
    ]);
    expect(claims.whereType<UpdateLease>(), hasLength(1));
    final lease = claims.whereType<UpdateLease>().single;
    await store.setEnabled(false);
    expect(
      await store.save(
        lease,
        ReleaseSource.official,
        SourceUpdate(checkedAt: now),
      ),
      isFalse,
    );
    await store.release(lease);
    expect((await store.read()).enabled, isFalse);
  });
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient({required this.fail});
  final bool fail;
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        fail
            ? Stream<List<int>>.error(http.ClientException('offline'))
            : Stream.value(utf8.encode('[]')),
        200,
      );
  @override
  void close() {
    closes++;
  }
}
