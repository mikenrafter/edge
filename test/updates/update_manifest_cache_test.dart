// WHY: a weekly fork must keep checking after its ninth release. Bound new
// manifest fetches while retaining validated progress between checks.
// Proves CLAIM(update-manifest-cache), CLAIM(update-network-consent).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/sync/update_service.dart';
import 'package:openstrap_edge/sync/update_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // catches: repeatedly fetching the same first eight manifests forever.
  test(
    'a cold nine-release catalog completes on the second bounded check',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'manifest-cache-',
      );
      final store = UpdateStore(
        await databaseFactoryFfi.openDatabase('${directory.path}/updates.db'),
      );
      await store.initialize();
      var now = DateTime.utc(2026, 11, 15, 12);
      var manifestRequests = 0;
      final manifests = <int, Map<String, Object?>>{};
      final releases = <Map<String, Object?>>[];
      for (var day = 1; day <= 9; day++) {
        final tag = 'next-2026.11.0$day';
        final name = 'openstrap-edge-$tag-dev-profile.apk';
        releases.add({
          'id': day,
          'tag_name': tag,
          'draft': false,
          'prerelease': true,
          'assets': [
            {'id': 500 + day, 'name': 'edge-release.json'},
            {'id': 600 + day, 'name': name},
          ],
        });
        manifests[500 + day] = {
          'formatVersion': 1,
          'repository': 'mikenrafter/edge',
          'tag': tag,
          'sourceSha': 'a' * 40,
          'versionCode': 70 + day,
          'untrusted': 'https://evil.test/do-not-store',
          'artifacts': [
            {
              'name': name,
              'mode': 'profile',
              'package': 'wtf.openstrap.openstrap_edge.dev',
              'abis': ['arm64-v8a'],
            },
          ],
        };
      }
      final client = MockClient((request) async {
        if (request.url.path.contains('/assets/')) {
          manifestRequests++;
          return http.Response(
            jsonEncode(manifests[int.parse(request.url.pathSegments.last)]),
            200,
          );
        }
        return http.Response(
          jsonEncode(request.url.path.contains('mikenrafter') ? releases : []),
          200,
        );
      });
      final service = UpdateService(
        store: store,
        client: client,
        now: () => now,
        installed: const InstalledRelease(
          version: '0.11.3',
          build: 78,
          fork: true,
          mode: 'profile',
        ),
        unmetered: () async => true,
        schedule: (_) async {},
      );
      try {
        await service.check(manual: true);
        expect(
          service.snapshot.sources[ReleaseSource.fork]!.error,
          UpdateError.incomplete,
        );
        expect(manifestRequests, 8);
        now = now.add(const Duration(minutes: 2));
        await service.check(manual: true);
        expect(
          service.snapshot.sources[ReleaseSource.fork]!.candidate?.tag,
          'next-2026.11.09',
        );
        expect(
          service.snapshot.sources[ReleaseSource.fork]!.candidate?.build,
          79,
        );
        expect(manifestRequests, 9); // eight cached, only the ninth fetched now
        final cached = await store.db.query('update_manifests');
        expect(cached, hasLength(9));
        expect(
          cached.map((r) => r['json']).join(),
          isNot(contains('evil.test')),
        );
        // An API asset modification invalidates just that cached manifest.
        ((releases.first['assets'] as List).first as Map)['updated_at'] =
            '2026-11-15T12:00:00Z';
        now = now.add(const Duration(minutes: 2));
        await service.check(manual: true);
        expect(manifestRequests, 10);
        expect(
          service.snapshot.sources[ReleaseSource.fork]!.candidate?.build,
          79,
        );
        // A late writer from this generation cannot restore cleared metadata.
        now = now.add(const Duration(minutes: 2));
        final lease = await store.claim(now, manual: true);
        expect(lease, isNotNull);
        await service.setEnabled(false);
        expect(
          await store.saveManifest(
            lease!,
            'late',
            jsonDecode(cached.first['json'] as String) as Map<String, dynamic>,
          ),
          isFalse,
        );
        expect(await store.db.query('update_manifests'), isEmpty);
        expect(service.snapshot.phase, UpdatePhase.off);
      } finally {
        service.dispose();
        await store.db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
