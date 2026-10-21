// A derive that DECLINES a day is not a derive, and must not loop.
//
// The owner's loop: the first prune on a fresh install raised
// `decoded_pruned_before` to 10-14 00:00; an import then merged whole
// `decoded_onehz` for 10-07..10-13 below it. `windowTruncatedByPrune` called
// those days cut, `_derivePreparedDay` declined them (edge#305: keep the
// existing night-bearing row) and returned true, `run()` counted that as done
// (=> baselines, cross-day, rescan) and recorded the fingerprint, yet the day
// never got a finalized row at this version, so `_deriveScope` picked it again
// on every heavy pass ("day i of 10", then "of 3", forever).
//
// Contract pinned here, all through existing public APIs and DB state:
//   * a declined day is not counted in run()'s result, and does not fire the
//     done-only post-work (onCrossDay);
//   * it is settled for (kAlgoVersion, fingerprint): the next heavy pass does
//     not select it (no onScopeDays entry, no debugDayHook), and rescanRecent
//     does not either;
//   * new raw for it (a fingerprint change) reopens it, and only the days the
//     fingerprint covers;
//   * a settled day no longer counts as pending debt for the quiet level, so
//     later days that were owed a level only because of it become unreachable
//     and finalize with strain still null;
//   * `_quietLevelRepass` retiring an owed marker for truncation settles the
//     day instead of leaving it pending.
//
// Assumed API: none new.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

const _profile = Profile(
  ageYears: 35,
  sex: 'm',
  weightKg: 75,
  heightCm: 178,
  restingHrManual: 55,
);

const _cursor = 'decoded_pruned_before';

int _localSec(String day, int hour) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
}

String _dayAfter(String day, int n) {
  final d = DateTime.parse(day);
  final x = DateTime(d.year, d.month, d.day + n);
  return '${x.year}-${x.month.toString().padLeft(2, '0')}-'
      '${x.day.toString().padLeft(2, '0')}';
}

/// [wakeMin] minutes of daytime 1 Hz rows from [hour] local.
Future<void> _insertDay(String day, {int wakeMin = 400, int hour = 9}) async {
  final db = await LocalDb.instance;
  final start = _localSec(day, hour);
  final batch = db.batch();
  for (var i = 0; i < wakeMin * 60; i++) {
    final ts = start + i;
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': i < 45 * 60 ? 130 : 62 + (i % 3) - 1,
      'ax': 0.05 * ((i % 60) / 60.0),
      'ay': 0.05 * ((i % 30) / 30.0),
      'az': 0.98,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

/// A finalized row from an EARLIER algo version that already has night scalars:
/// what the edge#305 guard exists to protect.
Future<void> _oldRow(String day) => LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion - 1,
      payloadJson: jsonEncode({
        'scalars': {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
      }),
      windowJson: '{"onset_ms": 1, "offset_ms": 2}',
      finalized: true,
      rhr: 52,
      rmssd: 61,
      readiness: 74,
      series: {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
    );

Future<void> _clear() async {
  final db = await LocalDb.instance;
  for (final t in const [
    'decoded_onehz',
    'decoded_rr',
    'day_result',
    'metric_series',
    'metric_series_version',
    'compute_freshness',
  ]) {
    await db.delete(t);
  }
  await db.delete('sync_cursor', where: 'name = ?', whereArgs: [_cursor]);
  await db.delete('sync_cursor', where: 'name = ?', whereArgs: ['baseline_sig']);
}

Future<Set<String>> _owed() async => {
      for (final k in await LocalDb.computeFreshnessKeys(
          DerivationEngine.kQuietRepassKeyPrefix))
        k.substring(DerivationEngine.kQuietRepassKeyPrefix.length),
    };

/// What one pass did.
class _Pass {
  _Pass(this.done, this.hooked, this.scope, this.crossDay);
  final int done;
  final List<String> hooked;
  final List<String> scope;
  final int crossDay;
}

Future<_Pass> _heavy() async {
  final e = DerivationEngine();
  final hooked = <String>[];
  var scope = <String>[];
  var crossDay = 0;
  e.debugDayHook = (d) async => hooked.add(d);
  final done = await e.run(
    _profile,
    heavy: true,
    onScopeDays: (days) => scope = [...days],
    onCrossDay: (active) {
      if (active) crossDay++;
    },
  );
  return _Pass(done, hooked, scope, crossDay);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_declined_day_settles_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  const slow = Timeout(Duration(minutes: 8));

  // Whole raw for [days], a stale cursor at the midnight after the last one,
  // and an older-version night-bearing row on each.
  Future<void> seedStale(List<String> days) async {
    await _clear();
    for (final d in days) {
      await _insertDay(d);
      await _oldRow(d);
    }
    await LocalDb.setCursor(
        _cursor, '${_localSec(_dayAfter(days.last, 1), 0)}');
  }

  test('a declined day is not counted as derived, and is not selected again',
      () async {
    const days = ['2026-07-01', '2026-07-02', '2026-07-03'];
    await seedStale(days);

    final first = await _heavy();
    expect(first.hooked, containsAll(days), reason: 'precondition: attempted');
    expect(first.done, 0,
        reason: 'every day was declined (kept the existing row); none derived');
    expect(first.crossDay, 0,
        reason: 'nothing derived, so no baselines / cross-day follow-up');
    final fps = await LocalDb.derivedFingerprints(kAlgoVersion);
    for (final d in days) {
      expect(fps, contains(d), reason: '$d is settled for its fingerprint');
    }

    final second = await _heavy();
    expect(second.scope, isEmpty,
        reason: 'settled days are not in the next heavy pass\'s scope');
    expect(second.hooked, isEmpty,
        reason: 'and are not prepared or derived again: ${second.hooked}');
    expect(second.done, 0);
  }, timeout: slow);

  test('new raw for a settled day reopens it, and only the days its '
      'fingerprint covers', () async {
    const days = ['2026-07-01', '2026-07-02', '2026-07-03'];
    await seedStale(days);
    await _heavy();
    expect((await _heavy()).hooked, isEmpty, reason: 'precondition: settled');

    // Evening rows land on 07-02: its own fingerprint moves, and 07-03's
    // (which folds in the day before).
    await _insertDay('2026-07-02', wakeMin: 60, hour: 20);

    final third = await _heavy();
    expect(third.hooked, contains('2026-07-02'));
    expect(third.hooked, isNot(contains('2026-07-01')),
        reason: 'untouched, still settled');
  }, timeout: slow);

  test('a marker retired for truncation settles the day', () async {
    const day = '2026-07-01';
    await seedStale([day]);
    await LocalDb.putComputeFreshness(
        '${DerivationEngine.kQuietRepassKeyPrefix}$day', '{}');

    await _heavy();
    expect(await _owed(), isNot(contains(day)),
        reason: 'the truncated day\'s abstention is final');
    final again = await _heavy();
    expect(again.hooked, isEmpty,
        reason: 'retired and settled, not left pending: ${again.hooked}');
  }, timeout: slow);

  group('quiet-level debt', () {
    const settled = ['2026-07-01', '2026-07-02', '2026-07-03'];
    const later = '2026-07-05'; // not cut by a cursor at 07-04 00:00
    const edge = '2026-07-12'; // moves the data edge >48 h past [later]

    test('a day owed a level only because settled days precede it finalizes '
        'with strain still null', () async {
      await seedStale(settled);
      await _insertDay(later);
      await _insertDay(edge);

      for (var i = 0; i < 3; i++) {
        await _heavy();
      }

      expect(await _owed(), isNot(contains(later)),
          reason: 'three settled days can never give it a level');
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(later));
      final db = await LocalDb.instance;
      final rows = await db.query('metric_series',
          where: 'date = ? AND key = ?', whereArgs: [later, 'strain']);
      expect(rows.isEmpty || rows.single['value'] == null, isTrue,
          reason: 'abstains: no level, no strain, nothing substituted');
    }, timeout: slow);

    test('the unreachable proof ignores settled days', () async {
      await seedStale(settled);
      await _heavy();
      await _insertDay(later);
      expect(await DerivationEngine().debugQuietLevelUnreachable(later), isTrue,
          reason: 'valid 0 + pending 0 < 3; settled days are not pending');
    }, timeout: slow);

    test('control: with no earlier days at all it finalizes (harness check)',
        () async {
      await _clear();
      await _insertDay(later);
      await _insertDay(edge);
      for (var i = 0; i < 2; i++) {
        await _heavy();
      }
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(later));
    }, timeout: slow);
  });

  test('end to end: a second heavy pass with no new data derives nothing, '
      'fires no follow-up work and the rescan selects nothing', () async {
    final days = [for (var d = 7; d <= 13; d++) '2026-07-${d.toString().padLeft(2, '0')}'];
    await seedStale(days);

    final first = await _heavy();
    expect(first.done, 0);
    expect(first.crossDay, 0);

    final second = await _heavy();
    expect(second.done, 0);
    expect(second.hooked, isEmpty);
    expect(second.crossDay, 0);

    var rescanScope = <String>[];
    await DerivationEngine().rescanRecent(
      _profile,
      onScopeDays: (d) => rescanScope = [...d],
    );
    expect(rescanScope, isEmpty,
        reason: 'the rescan re-derives none of the settled days');
  }, timeout: slow);
}
