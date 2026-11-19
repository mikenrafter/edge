// WHY: review round 1 found false official alerts and a historical manifest
// poisoning the whole catalog. Proves CLAIM(update-source-order),
// CLAIM(update-network-consent), CLAIM(update-release-page).
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/sync/update_background.dart';
import 'package:openstrap_edge/sync/update_claim_ledger.dart';
import 'package:openstrap_edge/sync/update_coordinator.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'update_checker_test.dart' show release;

Map<String, dynamic> manifest(String tag, {int code = 78}) => {
  'formatVersion': 1,
  'repository': 'mikenrafter/edge',
  'tag': tag,
  'sourceSha': 'a' * 40,
  'versionCode': code,
  'artifacts': [
    {
      'name': 'openstrap-edge-$tag-dev-profile.apk',
      'mode': 'profile',
      'package': 'wtf.openstrap.openstrap_edge.dev',
      'abis': ['arm64-v8a'],
    },
  ],
};
Map<String, Object?> forkRelease(
  String tag, {
  int id = 2,
  bool metadata = true,
}) => release(
  tag,
  id: id,
  prerelease: true,
  assets: [
    if (metadata) 'edge-release.json',
    'openstrap-edge-$tag-dev-profile.apk',
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late UpdateStore store;
  late UpdateCoordinator service;
  late DateTime now;
  late Future<http.Response> Function(http.Request) respond;
  late List<http.Request> requests;
  final center = NotificationCenter.instance;
  UpdateCoordinator createService({
    String version = '0.11.3-dev',
    String mode = 'profile',
    bool fork = true,
  }) => UpdateCoordinator(
    store: store,
    client: MockClient((r) {
      requests.add(r);
      return respond(r);
    }),
    installed: InstalledRelease(
      version: version,
      build: 78,
      fork: fork,
      mode: mode,
    ),
    now: () => now,
    unmetered: () async => true,
    schedule: (_) async {},
    onRelease: notifyRelease,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-review-');
    store = UpdateStore(
      await databaseFactoryFfi.openDatabase('${directory.path}/updates.db'),
    );
    await store.initialize();
    now = DateTime.utc(2026, 11, 15, 12);
    requests = [];
    SharedPreferences.setMockInitialValues({'locale_override': 'en'});
    await const NotificationPrefs(quietEnabled: false).save();
    center.registerClaimLedger(NotifCategory.updates, UpdateClaimLedger(() async => store));
    center.claimedPermission = () async => true;
    service = createService();
  });
  tearDown(() async {
    service.dispose();
    center.presentSink = (e, {bool allowPermissionPrompt = true}) async =>
        false;
    await store.db.close();
    await directory.delete(recursive: true);
  });

  // WHY: Android appends -dev for profile and forkDevRelease release builds.
  // The same upstream base must be informational on both, including reload.
  // Proves CLAIM(update-installed-base).
  // catches: treating a platform suffix as a genuine prerelease, dropping the
  // cached separate-app relationship, or spending an alert claim while denied.
  for (final mode in ['profile', 'release']) {
    for (final version in ['0.11.3', '0.11.3-dev']) {
      test(
        'current fork $mode $version announces only a newer official app once',
        () async {
          service.dispose();
          service = createService(version: version, mode: mode);
          var officialTag = 'v0.11.3';
          final shown = <NotificationEvent>[];
          center.presentSink = (e, {bool allowPermissionPrompt = true}) async {
            shown.add(e);
            return true;
          };
          respond = (r) async {
            final metadata = manifest('next-2026.11.15');
            final artifact = (metadata['artifacts'] as List).single as Map;
            artifact['mode'] = mode;
            artifact['name'] = 'openstrap-edge-next-2026.11.15-dev-$mode.apk';
            return http.Response(
              jsonEncode(
                r.url.path.contains('/assets/')
                    ? metadata
                    : r.url.path.contains('OpenStrap')
                    ? [
                        release(
                          officialTag,
                          id: officialTag == 'v0.11.3' ? 1 : 4,
                        ),
                      ]
                    : [
                        release(
                          'next-2026.11.15',
                          id: 2,
                          prerelease: true,
                          assets: [
                            'edge-release.json',
                            'openstrap-edge-next-2026.11.15-dev-$mode.apk',
                          ],
                        ),
                      ],
              ),
              200,
            );
          };
          await service.setEnabled(true);
          await service.check();
          expect(service.snapshot.phase, UpdatePhase.current);
          expect(
            service.snapshot.sources[ReleaseSource.official]!.current,
            isTrue,
          );
          expect(shown, isEmpty);
          await service.load();
          expect(service.snapshot.phase, UpdatePhase.current);
          expect(
            service
                .snapshot
                .sources[ReleaseSource.official]!
                .candidate!
                .separateApp,
            isTrue,
          );
          await service
              .check(); // Fresh cache must not announce the equal release.
          expect(shown, isEmpty);
          now = now.add(const Duration(days: 1, minutes: 1));
          officialTag = 'v0.11.4';
          center.claimedPermission = () async => false;
          await service.check();
          expect(service.snapshot.phase, UpdatePhase.available);
          expect(shown, isEmpty);
          await service.load();
          expect(service.snapshot.phase, UpdatePhase.available);
          expect(
            service
                .snapshot
                .sources[ReleaseSource.official]!
                .candidate!
                .separateApp,
            isTrue,
          );
          final l = await AppLocalizations.delegate.load(const Locale('en'));
          expect(
            updateSummary(l, service.snapshot),
            'New official app release · Official · v0.11.4 · Release · Separate app. Your data stays here.',
          );
          center.claimedPermission = () async => true;
          final requestCount = requests.length;
          await service
              .check(); // Deliver from cache after reload, no new request.
          expect(requests, hasLength(requestCount));
          expect(shown, hasLength(1));
          expect(shown.single.title, 'New official app release');
          expect(shown.single.body, contains('v0.11.4'));
          expect(shown.single.body, contains('Separate app'));
          expect(shown.single.body, isNot(contains('Update available')));
          await service.check();
          expect(shown, hasLength(1));
        },
      );
    }
  }

  // WHY: remove only the fork's final build label; genuine upstream rc/dev
  // versions retain semantic precedence, including on the official package.
  // catches: splitting at the first hyphen or stripping official prereleases.
  for (final identity in [
    (
      version: '0.11.3-rc.1-dev',
      fork: true,
      tag: 'v0.11.3-rc.1',
      current: true,
    ),
    (
      version: '0.11.3-rc.1-dev',
      fork: true,
      tag: 'v0.11.3-rc.2',
      current: false,
    ),
    (version: '0.11.3-rc.1-dev', fork: true, tag: 'v0.11.3', current: false),
    (version: '0.11.3-dev', fork: false, tag: 'v0.11.3', current: false),
    (version: '0.11.3-dev.1', fork: true, tag: 'v0.11.3', current: false),
    (version: '0.11.3-dev', fork: true, tag: 'v0.11.2', current: true),
  ]) {
    test('semantic provenance $identity', () async {
      service.dispose();
      service = createService(version: identity.version, fork: identity.fork);
      await service.setOfficialPrereleases(true);
      respond = (r) async => http.Response(
        jsonEncode(
          r.url.path.contains('OpenStrap')
              ? [release(identity.tag, prerelease: identity.tag.contains('-'))]
              : [],
        ),
        200,
      );
      await service.check(manual: true);
      expect(
        service.snapshot.sources[ReleaseSource.official]!.current,
        identity.current,
      );
      await service.load();
      expect(
        service.snapshot.sources[ReleaseSource.official]!.current,
        identity.current,
      );
    });
  }

  // WHY: the reviewed mutant accepted arbitrary hosts. The valid-host control
  // proves this test exercises redirects, not a blanket redirect rejection.
  // catches: manifest redirect accepts any host (review M1).
  test(
    'manifest redirects allow only GitHub asset host and never request foreign host',
    () async {
      for (final host in [
        'evil.test',
        'release-assets.githubusercontent.com',
      ]) {
        requests.clear();
        respond = (r) async {
          if (r.url.host != 'api.github.com') {
            return http.Response(
              jsonEncode(manifest('next-2026.11.15', code: 79)),
              200,
            );
          }
          if (r.url.path.contains('/assets/')) {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://$host/manifest.json'},
            );
          }
          return http.Response(
            jsonEncode(
              r.url.path.contains('mikenrafter')
                  ? [forkRelease('next-2026.11.15')]
                  : [],
            ),
            200,
          );
        };
        await service.check(manual: true);
        final result = service.snapshot.sources[ReleaseSource.fork]!;
        if (host == 'evil.test') {
          expect(result.error, UpdateError.redirect);
          expect(requests.where((r) => r.url.host == host), isEmpty);
        } else {
          expect(result.error, isNull);
          expect(result.candidate?.build, 79);
          expect(requests.where((r) => r.url.host == host), hasLength(1));
        }
        now = now.add(const Duration(minutes: 2));
      }
    },
  );

  for (final kind in ['missing', 'missing-file', 'json', 'schema']) {
    final malformed = kind != 'missing';
    for (final newer in [false, true]) {
      // WHY: old pre-contract or broken releases must not poison new good ones;
      // an unrecognized newer date cannot justify falling back to an old build.
      // catches: early return/whole-source throw for any missing/bad manifest.
      test(
        '$kind ${newer ? 'newer' : 'older'} manifest ${newer ? 'blocks fallback' : 'does not hide good release'}',
        () async {
          final badTag = newer ? 'next-2026.11.16' : 'next-2026.11.14';
          final bad = forkRelease(badTag, id: 3, metadata: malformed);
          if (malformed) ((bad['assets'] as List).first as Map)['id'] = 43;
          respond = (r) async {
            if (r.url.path.endsWith('/assets/43') && kind == 'missing-file') {
              return http.Response('', 404);
            }
            if (r.url.path.endsWith('/assets/43')) {
              return http.Response(
                kind == 'json'
                    ? '{malformed'
                    : jsonEncode({
                        ...manifest(badTag),
                        'repository': 'evil/edge',
                      }),
                200,
              );
            }
            if (r.url.path.endsWith('/assets/42')) {
              return http.Response(
                jsonEncode(manifest('next-2026.11.15', code: 79)),
                200,
              );
            }
            return http.Response(
              jsonEncode(
                r.url.path.contains('mikenrafter')
                    ? [bad, forkRelease('next-2026.11.15')]
                    : [],
              ),
              200,
            );
          };
          await service.check(manual: true);
          final result = service.snapshot.sources[ReleaseSource.fork]!;
          if (newer) {
            expect(result.candidate, isNull);
            expect(result.error, isNotNull);
          } else {
            expect(result.error, isNull);
            expect(result.candidate?.tag, 'next-2026.11.15');
            expect(result.candidate?.build, 79);
          }
        },
      );
    }
  }
}
