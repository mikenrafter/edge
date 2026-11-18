import 'dart:async';

import 'support/test_callable.dart';
// A day old enough to finalize, whose next day has not stored its window yet
// in the same pass, is held: not finalized and not recorded as unchanged, so
// the next pass reads tonight's window and locks the day then. The hold is
// forced through the test seam rather than by racing two workers.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const _profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

// Three days of data: the day before the first is old enough to finalize on
// the first pass.
final _days = [
  for (var i = 0; i < 3; i++) SyntheticDay(DateTime(2026, 7, 13 + i)),
];
const _held = '2026-07-12';

Future<void> _seed(String name) async {
  SharedPreferences.setMockInitialValues({});
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(
    p.join(await databaseFactory.getDatabasesPath(), name),
  );
  var committed = 0;
  for (final d in _days) {
    for (final (raws, samples) in d.primaryBatches()) {
      final keep = [
        for (var j = 0; j < raws.length; j++)
          if (raws[j].recTs! > committed) j,
      ];
      if (keep.isEmpty) continue;
      await LocalDb.commitSyncBatch(
        [for (final j in keep) raws[j]],
        [for (final j in keep) samples[j]],
        deviceFamily: 'gen4',
      );
      committed = raws[keep.last].recTs!;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DerivationEngine.debugHoldTonight = {};
    DerivationEngine.debugSecondHalfHook = null;
    await LocalDb.close();
  });

  // WHY: rescans and quiet re-passes must populate the same pending pool as
  // run/runDays. Hold the next worker before its window commits. The earlier
  // day must retain that prepare-time hold when the next worker later fails.
  // Proves CLAIM(tonight-pool-membership), without debugHoldTonight.
  for (final path in ['rescan', 'quiet']) {
    test('$path keeps a day provisional while its next worker is pending', () async {
      await _seed('tonight_pool_$path.db');
      const next = '2026-07-13';
      final prepared = Completer<void>();
      final nextEntered = Completer<void>();
      var inQuiet = false;
      for (final day in ['2026-07-09', '2026-07-10', '2026-07-11']) {
        await LocalDb.putMetricSeriesValue(day, 'quiet_hrr', 0.2);
      }
      Future<void> holdNext(String day) async {
        if (day != next) return;
        if (!nextEntered.isCompleted) nextEntered.complete();
        await prepared.future;
        throw StateError('next day failed before its window committed');
      }
      final engine = DerivationEngine();
      engine.debugDayHook = (day) async {
        if (path == 'quiet') throw StateError('leave first pool for quiet retry');
      };
      DerivationEngine.debugSecondHalfHook = TestCall1((day) async {
        if (path == 'rescan' && day == next) await holdNext(day);
        if (day == _held && (path == 'rescan' || inQuiet)) {
          await nextEntered.future;
          if (!prepared.isCompleted) prepared.complete();
        }
      });
      DerivationEngine.debugQuietRepassHook = (day) async {
        if (day == null) inQuiet = true;
        if (day != null) await holdNext(day);
      };
      addTearDown(() {
        if (!prepared.isCompleted) prepared.complete();
        DerivationEngine.debugQuietRepassHook = null;
      });
      if (path == 'rescan') {
        expect(await engine.rescanRecent(_profile), greaterThan(0));
      } else {
        for (final day in [_held, next]) {
          await LocalDb.putComputeFreshness(
              '${DerivationEngine.kQuietRepassKeyPrefix}$day', 'owed');
        }
        await engine.run(_profile, heavy: true);
        expect(inQuiet, isTrue);
      }
      expect(prepared.isCompleted, isTrue, reason: 'earlier day really computed');
      final row = await LocalDb.dayResult(_held);
      expect(row, isNotNull);
      expect(row!['partial'], 0, reason: 'a successful second half is held');
      expect(row['finalized'], 0, reason: 'next day had no committed window when this day prepared');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test(
    'a held day never finalizes or receives a skip key, then settles',
    () async {
      await _seed('derive_tonight_pending.db');

      // Two held passes: the second derives from unchanged inputs, which is
      // where a fingerprint would be recorded and the day skipped for good.
      DerivationEngine.debugHoldTonight = {_held};
      for (var i = 0; i < 2; i++) {
        await DerivationEngine().run(_profile, heavy: true);
        expect(await LocalDb.dayResult(_held), isNotNull);
        expect(
          await LocalDb.finalizedDayIds(kAlgoVersion),
          isNot(contains(_held)),
          reason: 'held pass $i',
        );
        expect(
          await LocalDb.deriveFingerprint(_held),
          isNull,
          reason: 'held pass $i',
        );
      }

      DerivationEngine.debugHoldTonight = {};
      await DerivationEngine().run(_profile, heavy: true);
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(_held));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a failed second half does not carry a finalized row past the hold',
    () async {
      await _seed('derive_tonight_pending_recovery.db');
      // A cold first pass may legitimately hold the day (the next day's
      // window can land after it in the same pass), so a second pass is what
      // guarantees the finalized row this test starts from.
      await DerivationEngine().run(_profile, heavy: true);
      await DerivationEngine().run(_profile, heavy: true);
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(_held));

      // Re-derived (forced) while held, with its second half failing: the
      // recovery path carries the complete finalized row forward, and must not
      // carry the lock with it.
      DerivationEngine.debugHoldTonight = {_held};
      DerivationEngine.debugSecondHalfHook = TestCall1((day) async {
        if (day == _held) throw StateError('second half down');
      });
      await DerivationEngine().runDays(_profile, {_held}, force: true);
      expect(
        await LocalDb.finalizedDayIds(kAlgoVersion),
        isNot(contains(_held)),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
