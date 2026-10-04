// 8AG-perf P3-B: the artifact warmer. After a derive pass that computed days,
// ONE bounded serial warmer recomputes the artifacts whose signature changed and
// stores them in `last_result` (the rows the screens read), so the next open
// finds them fresh.
//
// ASSUMED API (new file lib/state/artifact_warmer.dart):
//
//   abstract class ArtifactSource {
//     /// The artifact keys that may need warming after a pass that changed
//     /// [changedDays] (local day labels), in the order they should be warmed.
//     Future<List<String>> candidateKeys(List<String> changedDays);
//     /// The CURRENT signature of [key]; null = none can be given.
//     Future<String?> signature(String key);
//     /// The value to store for [key] (the same map the matching reader
//     /// returns); null = nothing to store. Heavy math runs off the UI isolate
//     /// inside this call. A throw is a failed warm.
//     Future<Map<String, dynamic>?> compute(String key);
//   }
//
//   class ArtifactWarmer {
//     ArtifactWarmer({
//       required ArtifactSource source,
//       LastResultCache? cache,          // default LastResultCache.instance
//       bool Function()? hold,           // true => a workout / ECG capture /
//                                        // scheduler hold is in force
//       void Function(String message)? log,
//     });
//
//     /// Completes when this warm has finished, been dropped (hold) or been
//     /// cancelled. NEVER throws.
//     Future<void> warmAfterPass({required List<String> changedDays});
//
//     /// Cancels: no further key is started, an in-flight compute's result is
//     /// DISCARDED (not stored), later warmAfterPass calls return at once.
//     void dispose();
//   }
//
// SEMANTICS pinned here:
//   * [changedDays] empty => nothing happens (candidateKeys is not even asked).
//   * [hold] true when called => return at once: nothing asked, nothing
//     computed ("skip, don't queue"). [hold] is re-checked before EVERY key;
//     once true the remaining keys are dropped, not queued. A compute that was
//     already running when the hold began finishes and is stored.
//   * Keys are processed strictly one after another, in candidateKeys order.
//     Overlapping warmAfterPass calls never run two computes at once and never
//     compute a key twice for an unchanged signature.
//   * Per key: signature (a throw is logged and skips the key; null skips it:
//     there is nothing to key freshness on) -> stored entry (cache.read) ->
//     equal signature => skip; otherwise compute -> null => store nothing;
//     else cache.put(key, map, sig: signature) and flush, so the row the
//     screen reads is written.
//   * A compute that throws is logged (the message names the key), stores
//     NOTHING (never cache an error; an older entry stays), does not stop the
//     other keys and is not retried within the pass.
//
// Failure mode today: the library does not exist (the file fails to load).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/artifact_warmer.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import '../fix8ai/support/g1_db.dart';
import 'support/p3_warmer_support.dart';

const _db = 'openstrap_p3_warmer_test.db';

Future<Map<String, Object?>?> _row(String key) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
      'SELECT key, input_sig, payload_json FROM last_result WHERE key = ?',
      [key]);
  return rows.isEmpty ? null : rows.single;
}

Future<void> _spin() => Future<void>.delayed(const Duration(milliseconds: 40));

Future<void> _until(bool Function() ok,
    {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeArtifactSource src;
  late LastResultCache cache;
  late List<String> logs;
  late bool held;
  late ArtifactWarmer warmer;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await g1FreshDb(_db);
    await LocalDb.instance; // the first open builds the schema: keep it out of the timings
    src = FakeArtifactSource()..keys = ['A', 'B', 'C'];
    cache = LastResultCache();
    logs = [];
    held = false;
    warmer = ArtifactWarmer(
        source: src, cache: cache, hold: () => held, log: logs.add);
  });
  tearDown(() async {
    warmer.dispose();
    await cache.flush();
  });
  tearDownAll(() => g1DropDb(_db));

  void sign(Map<String, String?> m) => src.sigs.addAll(m);

  test('no changed days: nothing is asked, nothing computed', () async {
    sign({'A': 's', 'B': 's', 'C': 's'});
    await warmer.warmAfterPass(changedDays: const []);
    expect(src.candidateCalls, isEmpty);
    expect(src.computeStarted, isEmpty);
  });

  test('only keys whose stored signature differs are computed, and they are '
      'stored with the signature the screens will compare', () async {
    sign({'A': 'a1', 'B': 'b2', 'C': 'c1'});
    (cache as dynamic).put<Map<String, dynamic>>('A', {'old': 'a'}, sig: 'a1');
    (cache as dynamic).put<Map<String, dynamic>>('B', {'old': 'b'}, sig: 'b1');
    // C: nothing stored at all.
    await cache.flush();

    await warmer.warmAfterPass(changedDays: ['2026-10-03']);
    expect(src.candidateCalls, [
      ['2026-10-03']
    ]);
    expect(src.computeStarted, ['B', 'C'], reason: 'A is fresh: not recomputed');

    final a = await _row('A');
    expect(a!['input_sig'], 'a1');
    expect(jsonDecode(a['payload_json'] as String), {'old': 'a'},
        reason: 'a fresh entry is not rewritten');
    final b = await _row('B');
    expect(b!['input_sig'], 'b2');
    expect(jsonDecode(b['payload_json'] as String), {'k': 'B'});
    final c = await _row('C');
    expect(c!['input_sig'], 'c1');
    expect(cache.get<Map<String, dynamic>>('C')!.value, {'k': 'C'},
        reason: 'and the memory layer the screens read has it too');
  });

  test('a second pass with unchanged signatures warms nothing; a key whose '
      'signature moved is recomputed exactly once', () async {
    sign({'A': 'a1', 'B': 'b1', 'C': 'c1'});
    await warmer.warmAfterPass(changedDays: ['d']);
    expect(src.computeStarted, ['A', 'B', 'C']);
    src.computeStarted.clear();

    await warmer.warmAfterPass(changedDays: ['d']);
    expect(src.computeStarted, isEmpty);

    src.sigs['B'] = 'b2';
    await warmer.warmAfterPass(changedDays: ['d']);
    expect(src.computeStarted, ['B']);
    expect((await _row('B'))!['input_sig'], 'b2');
  });

  test('serial: never two computes at once, in candidate order', () async {
    sign({'A': 'a', 'B': 'b', 'C': 'c'});
    src.gates.addAll({
      'A': Completer<void>(),
      'B': Completer<void>(),
      'C': Completer<void>(),
    });
    final f = warmer.warmAfterPass(changedDays: ['d']);
    await _until(() => src.computeStarted.isNotEmpty);
    await _spin();
    expect(src.computeStarted, ['A'], reason: 'B waits for A');
    src.gates['A']!.complete();
    await _until(() => src.computeStarted.length >= 2);
    await _spin();
    expect(src.computeStarted, ['A', 'B']);
    src.gates['B']!.complete();
    await _until(() => src.computeStarted.length >= 3);
    src.gates['C']!.complete();
    await f;
    expect(src.computeStarted, ['A', 'B', 'C']);
    expect(src.maxRunning, 1);
  });

  test('overlapping passes never run two computes at once nor compute a key '
      'twice for an unchanged signature', () async {
    sign({'A': 'a', 'B': 'b', 'C': 'c'});
    src.gates['A'] = Completer<void>();
    final first = warmer.warmAfterPass(changedDays: ['d1']);
    await _until(() => src.computeStarted.isNotEmpty);
    final second = warmer.warmAfterPass(changedDays: ['d2']);
    await _spin();
    expect(src.computeStarted, ['A']);
    src.gates['A']!.complete();
    await Future.wait([first, second]);
    expect(src.maxRunning, 1);
    for (final k in ['A', 'B', 'C']) {
      expect(src.computes(k), 1, reason: '$k computed once');
    }
  });

  test('a null signature is skipped (nothing to key freshness on); a null '
      'result stores nothing', () async {
    sign({'A': null, 'B': 'b', 'C': 'c'});
    src.nullResult.add('B');
    await warmer.warmAfterPass(changedDays: ['d']);
    expect(src.computes('A'), 0);
    expect(src.computes('B'), 1);
    expect(await _row('B'), isNull, reason: 'no raw => no artifact, never made up');
    expect(await _row('A'), isNull);
    expect(await _row('C'), isNotNull);
  });

  group('errors', () {
    test('a failing compute stores nothing (an older entry stays), is logged '
        'with its key, does not stop the others and is not retried in the '
        'pass', () async {
      sign({'A': 'a2', 'B': 'b', 'C': 'c'});
      (cache as dynamic).put<Map<String, dynamic>>('A', {'old': 1}, sig: 'a1');
      await cache.flush();
      src.computeThrows.add('A');
      await warmer.warmAfterPass(changedDays: ['d']); // must not throw
      expect(src.computes('A'), 1, reason: 'no retry storm');
      final a = await _row('A');
      expect(a!['input_sig'], 'a1');
      expect(jsonDecode(a['payload_json'] as String), {'old': 1});
      expect(logs.any((l) => l.contains('A')), isTrue,
          reason: 'logged, naming the key: $logs');
      expect(await _row('B'), isNotNull);
      expect(await _row('C'), isNotNull);
    });

    test('a failing compute with nothing stored leaves no row', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      src.computeThrows.add('B');
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(await _row('B'), isNull);
      expect(cache.get<Map<String, dynamic>>('B'), isNull);
    });

    test('a signature that throws skips that key only', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      src.sigThrows.add('A');
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.computes('A'), 0);
      expect(logs.any((l) => l.contains('A')), isTrue);
      expect(await _row('B'), isNotNull);
      expect(await _row('C'), isNotNull);
    });

    test('a failure is not sticky: the next pass tries the key again',
        () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      src.computeThrows.add('A');
      await warmer.warmAfterPass(changedDays: ['d']);
      src.computeThrows.clear();
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.computes('A'), 2);
      expect(await _row('A'), isNotNull);
    });
  });

  group('holds', () {
    test('held when the pass ends: nothing is asked or computed', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      held = true;
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.candidateCalls, isEmpty);
      expect(src.computeStarted, isEmpty);
    });

    test('skip, don\'t queue: releasing the hold later does not start the '
        'dropped work by itself', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      held = true;
      await warmer.warmAfterPass(changedDays: ['d']);
      held = false;
      await _spin();
      expect(src.computeStarted, isEmpty);
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.computeStarted, ['A', 'B', 'C'], reason: 'the next pass warms');
    });

    test('a workout starting mid-warm stops it before the next key', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      src.onCompute = (k) {
        if (k == 'A') held = true;
      };
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.computeStarted, ['A'], reason: 'B and C are never started');
      expect(await _row('A'), isNotNull,
          reason: 'the compute that was already running still lands');
      expect(await _row('B'), isNull);
    });
  });

  group('dispose', () {
    test('cancels: the in-flight result is discarded, no further key '
        'starts, and the pass still completes', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      src.gates['A'] = Completer<void>();
      final f = warmer.warmAfterPass(changedDays: ['d']);
      await _spin();
      expect(src.computeStarted, ['A']);
      warmer.dispose();
      src.gates['A']!.complete();
      await f.timeout(const Duration(seconds: 2));
      await cache.flush();
      expect(src.computeStarted, ['A'], reason: 'B and C never start');
      expect(await _row('A'), isNull, reason: 'a cancelled warm stores nothing');
      expect(cache.get<Map<String, dynamic>>('A'), isNull);
    });

    test('after dispose a pass is a no-op', () async {
      sign({'A': 'a', 'B': 'b', 'C': 'c'});
      warmer.dispose();
      await warmer.warmAfterPass(changedDays: ['d']);
      expect(src.candidateCalls, isEmpty);
      expect(src.computeStarted, isEmpty);
    });

    test('dispose is idempotent', () {
      warmer.dispose();
      warmer.dispose();
    });
  });
}
