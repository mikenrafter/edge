// A typed sleep window that reaches past the recorded data (D27 revised).
//
// The wearer types a window starting 2 h before the band's first sample. The
// night is staged inside the typed bounds, but only the recorded part has
// stage minutes: nothing is invented for the 2 h nobody watched. That time
// shows up as width instead: every stage's {lo, hi} range
// (`sleep.stage_ranges.value`) widens by it, since an uncovered epoch could be
// any stage (analytics `stageMinuteRanges`).
//
// RED until typed windows are staged and the ranges are stored.

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

/// The band's first sample: sleep onset. Everything before it is unrecorded.
final int _firstSec = SyntheticDay.sec(_truth.sleepOnset);
final int _onset = _firstSec - 2 * 3600;
final int _offset = SyntheticDay.sec(_truth.sleepOffset);
final double _coveredMin = (_offset - _firstSec) / 60;
final double _windowMin = (_offset - _onset) / 60;

Future<Map<String, dynamic>> _payload() async => (jsonDecode(
        (await LocalDb.dayResult(_dayId))!['payload_json'] as String) as Map)
    .cast<String, dynamic>();

void main() {
  late Map<String, dynamic> b;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'sleep_typed_window_thin_coverage_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final (raws, samples) in _truth.primaryBatches()) {
      final r = raws.where((x) => (x.recTs ?? 0) >= _firstSec).toList();
      final s = samples.where((x) => x.tsEpoch >= _firstSec).toList();
      if (s.isNotEmpty) await LocalDb.commitSyncBatch(r, s);
    }
    await LocalDb.putSleepOverride(
        dayId: _dayId, onsetTs: _onset, offsetTs: _offset, source: 'manual');
    expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true), 1);
    b = await _payload();
  });

  tearDownAll(() async => LocalDb.close());

  test('the window is the typed one, start included', () {
    final w = ((b['sleep'] as Map?)?['window'] as Map?)?['value'];
    expect(w, isA<Map>(), reason: 'a typed window is staged, not blanked');
    expect(((w as Map)['onset_ms'] as num) ~/ 1000, _onset);
    expect((w['offset_ms'] as num) ~/ 1000, _offset);
    expect(b['sleep_source'], 'manual');
  });

  test('stage minutes cover only the recorded part of the window', () {
    final sc = (b['scalars'] as Map).cast<String, dynamic>();
    for (final k in ['tst_min', 'light_min', 'deep_min', 'rem_min']) {
      expect(sc[k], isA<num>(), reason: '$k: the recorded part is staged');
    }
    final acc = ((b['sleep'] as Map)['accounting'] as Map)['value'] as Map;
    final light = sc['light_min'] as num;
    final deep = sc['deep_min'] as num;
    final rem = sc['rem_min'] as num;
    final wake = (acc['wake_sec'] as num) / 60;
    expect(light + deep + rem + wake, lessThanOrEqualTo(_coveredMin + 2),
        reason: 'staged minutes past the $_coveredMin recorded');
    expect(sc['tst_min'] as num, lessThanOrEqualTo(_coveredMin + 1));
    expect(sc['tst_min'] as num, greaterThan(0));
  });

  test('every stage range widens by the unrecorded 2 h', () {
    final r = (((b['sleep'] as Map)['stage_ranges'] as Map?)?['value'] as Map?)
        ?.cast<String, dynamic>();
    expect(r, isNotNull, reason: 'sleep.stage_ranges.value');
    expect(r!.keys.toSet(), {'wake', 'light', 'deep', 'rem'});
    var sumLo = 0.0, sumHi = 0.0;
    for (final k in r.keys) {
      final lo = ((r[k] as Map)['lo'] as num).toDouble();
      final hi = ((r[k] as Map)['hi'] as num).toDouble();
      expect(hi - lo, greaterThanOrEqualTo(120 - 1),
          reason: '$k: [$lo, $hi] does not carry the 2 h nobody watched');
      expect(hi, lessThanOrEqualTo(_windowMin + 1), reason: k);
      sumLo += lo;
      sumHi += hi;
    }
    expect(sumLo, lessThanOrEqualTo(_coveredMin + 1),
        reason: 'certain minutes come only from recorded time');
    expect(sumHi, greaterThanOrEqualTo(_windowMin - 1));
  });
}
