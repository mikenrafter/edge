// The edge#305 guard decides from COVERAGE, not from the global prune cursor.
//
// Today `_derivePreparedDay` declines to overwrite a day's night-bearing row
// when `windowTruncatedByPrune(day, decoded_pruned_before)` says the night
// window (previous noon -> day end) reaches below the cursor. One global
// cursor cannot describe holes or partial restores:
//   * Sol r4: a backup restoring a night minus its last hour lets
//     `_reconcilePrunedCursor` walk the cursor LOWER, so the guard stops
//     protecting a good row from a derive that sees an incomplete night.
//   * the owner's 10/3 loop: whole raw below a STALE high cursor was declined
//     although nothing was missing.
//
// Contract pinned here:
//   * the existing row's derivation recorded what it read: `derived_fp:<day>`
//     (`profileSig|own|prev`, each `MAX(rec_ts):COUNT:REVSUM`, written through
//     `DerivedFingerprint.compose`). The row COUNTs are the coverage.
//   * a derive declines when the day's own or the previous day's decoded-row
//     COUNT is now LOWER than the recorded one; it proceeds when both are
//     equal or higher, whatever the cursor says;
//   * no recorded fingerprint (imported/legacy row) -> the cursor rule, as
//     today;
//   * a declined forced re-derive is logged with the word "coverage" and its
//     day is listed in `DerivationEngine.snapshot()['declined_days']`.
//
// Assumed seams (new):
//   * `snapshot()['declined_days']` : List<String> of days the last pass
//     declined (the only surfacing path today is a log line; `runDays`
//     returns a count and `rebuildHistoryWithPriority` lists derived days).
//   * the coverage comparison itself reads `compute_freshness` key
//     `derived_fp:<day>` whatever its `v` (an algo bump must still see the
//     old derivation's coverage); no public signature is needed by the tests.

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
const _day = '2026-07-10';
const _prev = '2026-07-09';

int _localSec(String day, int hour) {
  final d = DateTime.parse(day);
  return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch ~/ 1000;
}

/// 1 Hz rows over [lo, hi): [hr] bpm, wrist still when [still].
Future<void> _rows(int lo, int hi, {required int hr, bool still = true}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var ts = lo; ts < hi; ts++) {
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': hr + (ts % 3) - 1,
      'ax': still ? 0.01 : 0.05 * ((ts % 60) / 60.0),
      'ay': still ? 0.01 : 0.05 * ((ts % 30) / 30.0),
      'az': 0.98,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

/// A whole 07-09 / 07-10 night: evening, sleep 22:00-06:00, a morning, and
/// the 07-10 daytime.
Future<void> _wholeNight() async {
  await _rows(_localSec(_prev, 9), _localSec(_prev, 22), hr: 85, still: false);
  await _rows(_localSec(_prev, 22), _localSec(_day, 6), hr: 50);
  await _rows(_localSec(_day, 6), _localSec(_day, 15), hr: 80, still: false);
}

/// The last hour of 07-09 (23:00-24:00): inside the night, inside 07-09.
Future<void> _dropLastHourOfPrev() async {
  final db = await LocalDb.instance;
  await db.delete('decoded_onehz',
      where: 'rec_ts >= ? AND rec_ts < ?',
      whereArgs: [_localSec(_prev, 23), _localSec(_day, 0)]);
}

Future<int> _count() async {
  final db = await LocalDb.instance;
  return (await db.rawQuery('SELECT COUNT(*) AS n FROM decoded_onehz'))
      .first['n'] as int;
}

/// A stored row with real night scalars (what the guard protects).
Future<void> _row(int version, {bool finalized = false}) =>
    LocalDb.putDayResult(
      dayId: _day,
      algoVersion: version,
      payloadJson: jsonEncode({
        'scalars': {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
      }),
      windowJson: '{"onset_ms": 1, "offset_ms": 2}',
      finalized: finalized,
      rhr: 52,
      rmssd: 61,
      readiness: 74,
      series: {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
    );

/// What the derive that produced the row above recorded: the fingerprint of
/// the raw as it is NOW, under [version].
Future<String> _recordFingerprintFromCurrentRaw(int version) async {
  final fps = await LocalDb.decodedDayFingerprints({_day, _prev});
  final fp = DerivedFingerprint.compose(
      profileSig: 'old-profile', own: fps[_day]!, previous: fps[_prev]);
  await LocalDb.putDerivedFingerprint(_day, version, fp);
  return fp;
}

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

Future<List<Map<String, Object?>>> _rowsAt(int version) async {
  final db = await LocalDb.instance;
  return db.query('day_result',
      where: 'day_id = ? AND algo_version = ?', whereArgs: [_day, version]);
}

/// The row at [version] is byte-for-byte what [_row] stored.
Future<void> _expectUntouched(int version) async {
  final rows = await _rowsAt(version);
  expect(rows, hasLength(1));
  final scalars = jsonDecode(rows.single['payload_json'] as String)['scalars'];
  expect(scalars, {'rhr': 52.0, 'rmssd': 61.0, 'readiness': 74.0},
      reason: 'the stored night was not overwritten');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_night_coverage_guard_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(_clear);

  const slow = Timeout(Duration(minutes: 5));

  Future<({int done, List<String> log, Map<String, dynamic> snap})> forced() async {
    final log = <String>[];
    final e = DerivationEngine(log: log.add);
    final done = await e.runDays(_profile, {_day}, force: true);
    return (done: done, log: log, snap: e.snapshot());
  }

  test('precondition: a whole synthetic night derives and replaces the row '
      '(harness check, no stale cursor)', () async {
    await _wholeNight();
    await _row(kAlgoVersion - 1);
    await _recordFingerprintFromCurrentRaw(kAlgoVersion - 1);
    final r = await forced();
    expect(r.done, 1, reason: 'derived: ${r.log}');
    expect(await _rowsAt(kAlgoVersion), hasLength(1));
  }, timeout: slow);

  test('1. Sol r4: raw lost the last hour of the night the row was derived '
      'from, the cursor says whole: a forced re-derive declines, row '
      'unchanged', () async {
    await _wholeNight();
    await _row(kAlgoVersion - 1);
    await _recordFingerprintFromCurrentRaw(kAlgoVersion - 1);
    // The reconcile walk lowered the cursor: it claims nothing is cut.
    await LocalDb.setCursor(_cursor, '${_localSec('2026-07-08', 0)}');
    await _dropLastHourOfPrev();

    final r = await forced();

    expect(r.done, 0, reason: 'declined, not derived: ${r.log}');
    expect(await _rowsAt(kAlgoVersion), isEmpty,
        reason: 'no new-version row written from an incomplete night');
    await _expectUntouched(kAlgoVersion - 1);
  }, timeout: slow);

  test('1b. a declined derive does not lower the coverage it is judged by: '
      'the next forced derive declines too', () async {
    await _wholeNight();
    await _row(kAlgoVersion - 1);
    await _recordFingerprintFromCurrentRaw(kAlgoVersion - 1);
    await _dropLastHourOfPrev();

    // run() records a declined day's fingerprint (so the day settles); that
    // must not become the new "what the row was derived from".
    final e = DerivationEngine();
    await e.run(_profile, heavy: true, force: true);
    final again = await forced();

    expect(again.done, 0, reason: 'still declined: ${again.log}');
    expect(await _rowsAt(kAlgoVersion), isEmpty);
    await _expectUntouched(kAlgoVersion - 1);
  }, timeout: slow);

  test('2. equal coverage below a stale high cursor: proceeds and writes',
      () async {
    await _wholeNight();
    await _row(kAlgoVersion - 1);
    await _recordFingerprintFromCurrentRaw(kAlgoVersion - 1);
    // Stale: midnight after the day, yet every row of the night is present.
    await LocalDb.setCursor(_cursor, '${_localSec('2026-07-11', 0)}');

    final r = await forced();

    expect(r.done, 1, reason: 'equal coverage must derive: ${r.log}');
    expect(await _rowsAt(kAlgoVersion), hasLength(1),
        reason: 'the cursor no longer decides');
  }, timeout: slow);

  test('3. more coverage than the row was derived from (raw arrived later): '
      'proceeds, even under a high cursor', () async {
    await _rows(_localSec(_prev, 9), _localSec(_prev, 22), hr: 85, still: false);
    await _rows(_localSec(_prev, 22), _localSec(_day, 2), hr: 50);
    await _row(kAlgoVersion - 1);
    await _recordFingerprintFromCurrentRaw(kAlgoVersion - 1);
    // The rest of the night lands afterwards.
    await _rows(_localSec(_day, 2), _localSec(_day, 6), hr: 50);
    await _rows(_localSec(_day, 6), _localSec(_day, 15), hr: 80, still: false);
    await LocalDb.setCursor(_cursor, '${_localSec('2026-07-11', 0)}');

    final r = await forced();

    expect(r.done, 1, reason: 'more coverage must derive: ${r.log}');
    expect(await _rowsAt(kAlgoVersion), hasLength(1));
  }, timeout: slow);

  group('4. no fingerprint for the existing row: the cursor rule, as today', () {
    test('cursor above the window: declines', () async {
      await _wholeNight();
      await _row(kAlgoVersion - 1);
      await LocalDb.setCursor(_cursor, '${_localSec('2026-07-11', 0)}');
      expect(await LocalDb.derivedFingerprints(kAlgoVersion - 1), isEmpty,
          reason: 'precondition: imported/legacy row, no fingerprint');

      final r = await forced();

      expect(r.done, 0, reason: 'conservative: ${r.log}');
      expect(await _rowsAt(kAlgoVersion), isEmpty);
      await _expectUntouched(kAlgoVersion - 1);
    }, timeout: slow);

    test('cursor below the window: proceeds', () async {
      await _wholeNight();
      await _row(kAlgoVersion - 1);
      await LocalDb.setCursor(_cursor, '${_localSec('2026-07-08', 0)}');

      final r = await forced();

      expect(r.done, 1, reason: '${r.log}');
      expect(await _rowsAt(kAlgoVersion), hasLength(1));
    }, timeout: slow);
  });

  test('5. a user-forced re-derive of a FROZEN row with less coverage still '
      'declines, and says so (log + snapshot)', () async {
    await _wholeNight();
    await _row(kAlgoVersion, finalized: true);
    await _recordFingerprintFromCurrentRaw(kAlgoVersion);
    await _dropLastHourOfPrev();

    final r = await forced();

    expect(r.done, 0, reason: '${r.log}');
    await _expectUntouched(kAlgoVersion);
    expect(
        r.log.any((l) => l.contains(_day) && l.contains('coverage')), isTrue,
        reason: 'the decline names the day and the lost coverage: ${r.log}');
    expect(r.snap['declined_days'], contains(_day),
        reason: 'surfaced to the caller, not only the log');
  }, timeout: slow);

  test('harness sanity: the dropped hour is gone', () async {
    await _wholeNight();
    final whole = await _count();
    await _dropLastHourOfPrev();
    expect(await _count(), whole - 3600);
  });
}
