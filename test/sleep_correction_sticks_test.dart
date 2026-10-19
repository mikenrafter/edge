// A sleep correction has to reach the stored day. End to end on the synthetic
// day: the band night is detected, then a typed window replaces it with
// exactly the typed times and is staged inside them, then "Not sleep" removes
// the night. Each step goes through the real `DerivationEngine.runDays` the
// edit's own re-derive uses.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final SyntheticDay _truth = SyntheticDay(DateTime(2026, 10, 4));
const String _dayId = '2026-10-04';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

Future<Map<String, dynamic>> _payload() async => (jsonDecode(
        (await LocalDb.dayResult(_dayId))!['payload_json'] as String) as Map)
    .cast<String, dynamic>();

/// The staged window, or null (a blanked night stores a '—' placeholder).
Map<String, dynamic>? _window(Map<String, dynamic> b) {
  final v = ((b['sleep'] as Map?)?['window'] as Map?)?['value'];
  return v is Map ? v.cast<String, dynamic>() : null;
}

/// `sleep.stage_ranges.value`: stage -> {lo, hi} minutes.
Map<String, Map<String, dynamic>>? _ranges(Map<String, dynamic> b) =>
    (((b['sleep'] as Map?)?['stage_ranges'] as Map?)?['value'] as Map?)
        ?.map((k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()));

/// The stored point minutes per stage (wake from the sleep accounting).
Map<String, double> _points(Map<String, dynamic> b) {
  final sc = (b['scalars'] as Map).cast<String, dynamic>();
  final acc = (((b['sleep'] as Map)['accounting'] as Map)['value'] as Map);
  return {
    'wake': (acc['wake_sec'] as num) / 60,
    'light': (sc['light_min'] as num).toDouble(),
    'deep': (sc['deep_min'] as num).toDouble(),
    'rem': (sc['rem_min'] as num).toDouble(),
  };
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'sleep_correction_sticks_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final (raws, samples) in _truth.primaryBatches()) {
      await LocalDb.commitSyncBatch(raws, samples);
    }
  });

  tearDownAll(() async => LocalDb.close());

  // D27 revised (owner 2026-10-19): a typed window is staged inside exactly the
  // typed bounds, as upstream does, and each stage carries a {lo, hi} minute
  // range from the data available for the night (analytics
  // `stageMinuteRanges`). The synthetic day records every second of the
  // window, so nothing is uncovered: wake (decided by HR/motion, never by a
  // score near a cutoff) is exact, and every point sits inside its range.
  // Replaces 5e205cfe's "a typed window blanks the night" (and 09df3470).
  test('a typed window over a detected night is stored as typed, staged, '
      'with per-stage ranges', () async {
    expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true), 1);
    expect(_window(await _payload()), isNotNull, reason: 'detected first');

    final onset = SyntheticDay.sec(_truth.sleepOnset) - 40 * 60;
    final offset = SyntheticDay.sec(_truth.sleepOffset) + 25 * 60;
    await LocalDb.putSleepOverride(
        dayId: _dayId, onsetTs: onset, offsetTs: offset, source: 'manual');
    expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true), 1);

    final b = await _payload();
    expect(b['sleep_source'], 'manual');
    final w = _window(b);
    expect(w, isNotNull, reason: 'a typed window is staged, not blanked');
    expect((w!['onset_ms'] as num) ~/ 1000, onset);
    expect((w['offset_ms'] as num) ~/ 1000, offset);

    final sc = (b['scalars'] as Map).cast<String, dynamic>();
    for (final k in ['tst_min', 'light_min', 'deep_min', 'rem_min']) {
      expect(sc[k], isA<num>(), reason: '$k: the typed night is staged');
    }
    final ov = (await LocalDb.getSleepOverride(_dayId))!;
    expect(ov['onset_ts'], onset);
    expect(ov['offset_ts'], offset);
    expect(ov['source'], 'manual');

    final r = _ranges(b);
    expect(r, isNotNull, reason: 'sleep.stage_ranges.value');
    expect(r!.keys.toSet(), {'wake', 'light', 'deep', 'rem'});
    final points = _points(b);
    for (final k in r.keys) {
      final lo = (r[k]!['lo'] as num).toDouble();
      final hi = (r[k]!['hi'] as num).toDouble();
      expect(lo, lessThanOrEqualTo(hi), reason: k);
      // Points are rounded to whole minutes.
      expect(points[k]!, inInclusiveRange(lo - 1, hi + 1),
          reason: '$k point ${points[k]} outside [$lo, $hi]');
    }
    expect(r['wake']!['lo'], r['wake']!['hi'],
        reason: 'full coverage: no epoch could be wake without being labelled '
            'so');
    final windowMin = (offset - onset) / 60;
    final sumLo = r.values.fold<double>(0, (a, v) => a + (v['lo'] as num));
    final sumHi = r.values.fold<double>(0, (a, v) => a + (v['hi'] as num));
    expect(sumLo, lessThanOrEqualTo(windowMin + 1));
    expect(sumHi, greaterThanOrEqualTo(windowMin - 1));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('"Not sleep" over a stored night leaves the day with no night',
      () async {
    await LocalDb.putSleepOverride(
      dayId: _dayId,
      onsetTs: SyntheticDay.sec(_truth.sleepOnset),
      offsetTs: SyntheticDay.sec(_truth.sleepOffset),
      source: 'rejected',
    );
    expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true), 1);
    final b = await _payload();
    expect(b['sleep_source'], 'rejected');
    expect((b['scalars'] as Map)['tst_min'], isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
