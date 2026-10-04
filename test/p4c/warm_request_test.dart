// P4c: a cache miss ENQUEUES the warm instead of computing inline.
//
// ASSUMED API
//
//   ArtifactWarmer.warmKeys(List<String> keys) -> Future<bool>   (artifact_warmer.dart)
//       The on-demand twin of warmAfterPass: warms exactly [keys] (no
//       `candidateKeys` call), through the SAME serial queue, hold rule and
//       per-key rules (`signature` first; null or fresh -> skipped; a throw or
//       null result stores nothing). Completes when those keys have finished,
//       been skipped, dropped (held / disposed) or failed; NEVER throws. The
//       bool is "something new was stored". A key already queued or in flight
//       (from this call, an earlier warmKeys, or a pass) is not computed twice.
//
//   AppState.requestWarm(String key) -> Future<void>             (app_state.dart)
//       Delegates to the one coordinator warmer (the debugArtifactSource /
//       RepoArtifactSource one). When the warm stored a result it then bumps
//       the revision (the same signal the publish uses), so screens that listen
//       re-read and find the stored result FRESH. No warmer (no source, no
//       repo) -> a no-op that does not throw. Nothing stored -> no bump.
//
// Failure mode today: neither method exists.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/artifact_warmer.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import '../fix8ai/support/g1_db.dart';
import '../perf/support/p3_warmer_support.dart';

const _db = 'p4c_warm_request_test.db';

Future<void> _until(bool Function() ok,
    {Duration within = const Duration(seconds: 4)}) async {
  final end = DateTime.now().add(within);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<bool> _warm(ArtifactWarmer w, List<String> keys) async =>
    await (w as dynamic).warmKeys(keys) as bool;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await g1FreshDb(_db);
    await LocalDb.instance;
  });
  tearDownAll(() => g1DropDb(_db));

  group('ArtifactWarmer.warmKeys', () {
    late FakeArtifactSource src;
    late LastResultCache cache;
    late bool held;
    late ArtifactWarmer warmer;

    setUp(() {
      held = false;
      src = FakeArtifactSource()
        ..sigs.addAll({'A': 'a1', 'B': 'b1', 'C': null});
      cache = LastResultCache();
      warmer = ArtifactWarmer(source: src, cache: cache, hold: () => held);
    });
    tearDown(() async {
      warmer.dispose();
      await cache.flush();
    });

    test('warms exactly the keys asked for and stores them under the '
        'signature read BEFORE the compute', () async {
      expect(await _warm(warmer, ['A']), isTrue);
      expect(src.computeStarted, ['A']);
      expect(src.candidateCalls, isEmpty, reason: 'no candidate scan');
      final hit = cache.get<Map>('A')!;
      expect(hit.value, {'k': 'A'});
      expect(hit.sig, 'a1');
    });

    test('a fresh entry and a key with no signature are skipped; nothing is '
        'stored, so the answer is false', () async {
      cache.put<Map<String, dynamic>>('A', {'old': true}, sig: 'a1');
      expect(await _warm(warmer, ['A', 'C']), isFalse);
      expect(src.computeStarted, isEmpty);
      expect(cache.get<Map>('A')!.value, {'old': true});
    });

    test('a failed compute stores nothing, throws nothing, keeps the older '
        'entry', () async {
      cache.put<Map<String, dynamic>>('A', {'old': true}, sig: 'stale');
      src.computeThrows.add('A');
      expect(await _warm(warmer, ['A']), isFalse);
      expect(cache.get<Map>('A')!.value, {'old': true});
    });

    test('a key asked for twice while it is in flight computes once',
        () async {
      src.gates['A'] = Completer<void>();
      final first = _warm(warmer, ['A']);
      await _until(() => src.computeStarted.contains('A'));
      final second = _warm(warmer, ['A']);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      src.gates['A']!.complete();
      await first;
      await second;
      expect(src.computes('A'), 1);
    });

    test('serial: a requested key waits behind a running pass', () async {
      src
        ..keys = ['A']
        ..gates['A'] = Completer<void>();
      final pass = warmer.warmAfterPass(changedDays: const ['2026-10-03']);
      await _until(() => src.computeStarted.contains('A'));
      final req = _warm(warmer, ['B']);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(src.computeStarted, ['A'], reason: 'B has not started');
      src.gates['A']!.complete();
      await pass;
      await req;
      expect(src.computeStarted, ['A', 'B']);
      expect(src.maxRunning, 1);
    });

    test('held: dropped, not queued (skip, don\'t queue)', () async {
      held = true;
      expect(await _warm(warmer, ['A']), isFalse);
      held = false;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(src.computeStarted, isEmpty, reason: 'nothing runs on release');
    });

    test('disposed: nothing runs and nothing throws', () async {
      warmer.dispose();
      expect(await _warm(warmer, ['A']), isFalse);
      expect(src.computeStarted, isEmpty);
    });
  });

  group('AppState.requestWarm', () {
    FakeArtifactSource source() => FakeArtifactSource()
      ..sigs['beats|2026-10-03'] = 's1'
      ..results['beats|2026-10-03'] = {'nn': [900.0], 'raw_beats': 1};

    AppState app(FakeArtifactSource? src) {
      final a = AppState.forTesting();
      if (src != null) a.debugArtifactSource = src;
      addTearDown(a.dispose);
      return a;
    }

    Future<void> request(AppState a, String key) async =>
        await (a as dynamic).requestWarm(key);

    test('computes the key through the one warmer, stores it, and THEN bumps '
        'the revision', () async {
      LastResultCache.instance.clear();
      final src = source();
      final a = app(src);
      final seenAtBump = <Object?>[];
      final start = a.insightsRevision.value;
      a.insightsRevision.addListener(() => seenAtBump
          .add(LastResultCache.instance.get<Map>('beats|2026-10-03')?.value));

      await request(a, 'beats|2026-10-03');
      await _until(() => seenAtBump.isNotEmpty);

      expect(src.computeStarted, ['beats|2026-10-03']);
      expect(a.insightsRevision.value, greaterThan(start));
      expect(seenAtBump.first, isNotNull,
          reason: 'the stored result is already there when screens re-read');
    });

    test('nothing stored (no signature): no compute and no revision bump',
        () async {
      final src = source();
      final a = app(src);
      final start = a.insightsRevision.value;
      await request(a, 'unknown|key');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(src.computeStarted, isEmpty);
      expect(a.insightsRevision.value, start);
    });

    test('no source and no repo: a no-op that does not throw', () async {
      final a = app(null);
      final start = a.insightsRevision.value;
      await request(a, 'beats|2026-10-03');
      expect(a.insightsRevision.value, start);
    });
  });
}
