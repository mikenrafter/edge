// A sleep correction has to reach the stored day. End to end on the synthetic
// day: the band night is detected, then a typed window replaces it with
// exactly the typed times, then "Not sleep" removes the night. Each step goes
// through the real `DerivationEngine.runDays` the edit's own re-derive uses.

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

Map<String, dynamic>? _window(Map<String, dynamic> b) =>
    ((b['sleep'] as Map?)?['window'] as Map?)?['value'] as Map<String, dynamic>?;

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

  // Our rule (5e205cfe, merge log D27): "Set the times myself" means absence,
  // not a number the app worked out. The typed bounds are kept exactly on the
  // override row and the night's metrics stay blank, as for "Not sleep".
  // Upstream staged the typed window instead.
  test('a typed window over a detected night is stored as typed, metrics blank',
      () async {
    expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true), 1);
    expect(_window(await _payload()), isNotNull, reason: 'detected first');

    final onset = SyntheticDay.sec(_truth.sleepOnset) - 40 * 60;
    final offset = SyntheticDay.sec(_truth.sleepOffset) + 25 * 60;
    await LocalDb.putSleepOverride(
        dayId: _dayId, onsetTs: onset, offsetTs: offset, source: 'manual');
    expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true), 1);

    final b = await _payload();
    expect(b['sleep_source'], 'manual');
    expect(((b['sleep'] as Map?)?['window'] as Map?)?['value'], isNot(isA<Map>()),
        reason: 'no staged night for a typed window');
    expect((b['scalars'] as Map)['tst_min'], isNull);
    final ov = (await LocalDb.getSleepOverride(_dayId))!;
    expect(ov['onset_ts'], onset);
    expect(ov['offset_ts'], offset);
    expect(ov['source'], 'manual');
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
