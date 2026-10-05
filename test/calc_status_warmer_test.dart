// P4b: the artifact warmer and a compute-on-open read report what they are
// doing, then clear.
//
// ASSUMED API: lib/compute/calc_status.dart (see calc_status_test.dart).
//
//   * ArtifactWarmer opens ONE step on CalcStatus.instance around each key's
//     `source.compute(key)`, labelled "Preparing <screen>" (the label starts
//     with "Preparing "; the screen wording is the implementation's). It is
//     closed in `finally`: a compute that throws, a disposed warmer and a
//     discarded result all leave nothing open. A key that is skipped (fresh,
//     no signature) opens nothing.
//   * LocalRepositoryImpl.getNightBeats(date) (the Beats screen's corrected RR,
//     which runs under Isolate.run) opens a step around that call, with a
//     non-empty plain label, and closes it. A night with nothing to correct
//     (no beats) opens nothing.
//
// Failure mode today: the library does not exist (the file fails to load).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_status.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/artifact_warmer.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/last_result_db.dart';
import 'support/scripted_artifact_source.dart';

const _db = 'p4b_calc_status_warmer_test.db';

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeArtifactSource src;
  late LastResultCache cache;
  late ArtifactWarmer warmer;
  late List<String?> seen;
  late void Function() listener;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await g1FreshDb(_db);
    await LocalDb.instance;
    src = FakeArtifactSource()..keys = ['A', 'B'];
    cache = LastResultCache();
    warmer = ArtifactWarmer(source: src, cache: cache);
    seen = [];
    listener = () => seen.add(CalcStatus.instance.value?.label);
    CalcStatus.instance.addListener(listener);
  });
  tearDown(() async {
    CalcStatus.instance.removeListener(listener);
    warmer.dispose();
    await cache.flush();
  });
  tearDownAll(() => g1DropDb(_db));

  group('warmer', () {
    test('a step is open while a key computes and closed when the pass ends',
        () async {
      src.sigs.addAll({'A': 'a', 'B': 'b'});
      src.gates['A'] = Completer<void>();
      String? during;
      src.onCompute = (k) {
        if (k == 'A') during = CalcStatus.instance.value?.label;
      };
      final f = warmer.warmAfterPass(changedDays: ['2026-10-03']);
      await _until(() => src.computeStarted.contains('A'));
      expect(CalcStatus.instance.value, isNotNull,
          reason: 'A is computing: say so');
      expect(CalcStatus.instance.value!.label, startsWith('Preparing '));
      src.gates['A']!.complete();
      await f;

      expect(during, startsWith('Preparing '));
      expect(CalcStatus.instance.value, isNull);
      expect(seen.where((l) => l != null), hasLength(greaterThanOrEqualTo(2)),
          reason: 'one step per computed key (A and B)');
      expect(seen.last, isNull);
    });

    test('keys that are fresh or have no signature open nothing', () async {
      src.sigs['A'] = 'a'; // B: no signature
      (cache as dynamic).put<Map<String, dynamic>>('A', {'old': 1}, sig: 'a');
      await cache.flush();
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.computeStarted, isEmpty);
      expect(seen, isEmpty, reason: 'nothing was calculated, nothing was shown');
      expect(CalcStatus.instance.value, isNull);
    });

    test('a compute that throws still closes its step, and the next key '
        'reports normally', () async {
      src.sigs.addAll({'A': 'a', 'B': 'b'});
      src.computeThrows.add('A');
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.computeStarted, ['A', 'B']);
      expect(CalcStatus.instance.value, isNull);
      expect(seen.where((l) => l != null && l.startsWith('Preparing ')),
          hasLength(2));
    });

    test('dispose mid-compute: the discarded result leaves nothing open',
        () async {
      src.sigs.addAll({'A': 'a', 'B': 'b'});
      src.gates['A'] = Completer<void>();
      final f = warmer.warmAfterPass(changedDays: ['d']);
      await _until(() => src.computeStarted.contains('A'));
      warmer.dispose();
      src.gates['A']!.complete();
      await f;
      expect(CalcStatus.instance.value, isNull);
      expect(src.computeStarted, ['A'], reason: 'B was never started');
    });

    test('a hold drops the pass and opens nothing', () async {
      src.sigs.addAll({'A': 'a', 'B': 'b'});
      final held = ArtifactWarmer(source: src, cache: cache, hold: () => true);
      await held.warmAfterPass(changedDays: ['d']);
      expect(seen, isEmpty);
      held.dispose();
    });
  });

  group('compute-on-open read', () {
    Future<void> seedNight(Database db, String day, int onset, int seconds) async {
      await db.insert('day_result', {
        'day_id': day,
        'algo_version': 61,
        'payload_json': '{}',
        'window_json':
            jsonEncode({'onset_ms': onset * 1000, 'offset_ms': (onset + seconds) * 1000}),
        'computed_at': 1,
        'finalized': 1,
      });
      final b = db.batch();
      for (var t = onset; t <= onset + seconds; t++) {
        b.insert('decoded_rr', {
          'ts_ms': t * 1000,
          'rec_ts': t,
          'beat_index': 0,
          'rr_ts_ms': t * 1000,
          'rr_ms': 900 + (t % 7) * 4,
        });
      }
      await b.commit(noResult: true);
    }

    test('getNightBeats reports while it corrects the beats, then clears',
        () async {
      final db = await LocalDb.instance;
      await seedNight(db, '2026-08-15', 1786735958, 600);
      final repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final got = await repo.getNightBeats('2026-08-15');
      expect(got.nn, isNotEmpty, reason: 'the fixture really corrected beats');

      final opened = seen.where((l) => l != null).toList();
      expect(opened, isNotEmpty, reason: 'the correction was reported');
      expect(opened.first, isNotEmpty);
      expect(CalcStatus.instance.value, isNull);
      expect(seen.last, isNull);
    });

    test('a night with no beats opens nothing', () async {
      final db = await LocalDb.instance;
      await db.insert('day_result', {
        'day_id': '2026-08-01',
        'algo_version': 61,
        'payload_json': '{}',
        'window_json': jsonEncode(
            {'onset_ms': 1786000000 * 1000, 'offset_ms': 1786003600 * 1000}),
        'computed_at': 1,
        'finalized': 1,
      });
      final repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final got = await repo.getNightBeats('2026-08-01');
      expect(got.nn, isEmpty);
      expect(seen, isEmpty);
      expect(CalcStatus.instance.value, isNull);
    });
  });
}
