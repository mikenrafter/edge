// The only way back into a finalized (day, V) row is an explicit user
// override re-derive. API (the one symbol the frozen-row guard adds):
//
//   enum DayResultWrite { derive, userOverride }       // lib/data/db.dart
//   LocalDb.putDayResult(..., DayResultWrite reason = DayResultWrite.derive)
//
// `userOverride` writes exactly as putDayResult does today; `derive` (default)
// is refused on a finalized same-version row (see db_put_day_result_guard_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';

import 'support/frozen_day_result_fixtures.dart';

Future<void> overrideWrite(
  String day, {
  String tag = 'override',
  bool finalized = true,
  bool partial = false,
  double rhr = 61.0,
  Set<String> blankKeys = const {},
}) => LocalDb.putDayResult(
  dayId: day,
  algoVersion: kAlgoVersion,
  payloadJson: payloadOf(tag, day: day, rhr: rhr),
  windowJson: '{"override":true}',
  finalized: finalized,
  partial: partial,
  rhr: rhr,
  rmssd: 33.0,
  readiness: 44.0,
  source: 'band',
  // As the engine does: a blanked key carries null, not a value to write back.
  series: {'rhr': blankKeys.contains('rhr') ? null : rhr, 'readiness': 44.0},
  blankKeys: blankKeys,
  reason: DayResultWrite.userOverride,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async => db = await freshDb('openstrap_override_write_test.db'));
  tearDownAll(dropDb);

  test('an override writes a finalized same-version row', () async {
    await seedRow(db, kDay, finalized: true);

    await overrideWrite(kDay, tag: 'user-window', rhr: 61.0);

    final row = (await rowOf(db, kDay))!;
    expect(row['payload_json'], payloadOf('user-window', rhr: 61.0));
    expect(row['window_json'], '{"override":true}');
    expect(row['computed_at'], isNot(kSeedComputedAt));
    expect(row['finalized'], 1, reason: 'the day stays locked after the edit');
    expect(row['rhr'], 61.0);
    expect(await seriesOf(db, kDay, 'rhr'), 61.0);
    expect(await seriesOf(db, kDay, 'readiness'), 44.0);
  });

  test('an override can blank keys on a finalized row', () async {
    await seedRow(db, kDay, finalized: true);
    await overrideWrite(kDay, blankKeys: {'rhr'});
    expect(await seriesOf(db, kDay, 'rhr'), isNull);
  });

  test('an override may write a day that has no row yet', () async {
    await overrideWrite(kDay, tag: 'fresh');
    expect((await rowOf(db, kDay))!['payload_json'],
        payloadOf('fresh', rhr: 61.0));
  });

  test('after an override the row is frozen again against a plain derive',
      () async {
    await seedRow(db, kDay, finalized: true);
    await overrideWrite(kDay, tag: 'user-window', rhr: 61.0);
    final afterOverride = (await rowOf(db, kDay))!;

    await deriveWrite(kDay, tag: 'late', rhr: 99.0);

    expect(await rowOf(db, kDay), afterOverride);
  });

  test('an override writes over a finalized row of its own version only',
      () async {
    await seedRow(db, kDay, version: kAlgoVersion - 1, finalized: true);
    await seedRow(db, kDay, finalized: true);
    await overrideWrite(kDay, tag: 'user-window');
    expect((await rowOf(db, kDay, version: kAlgoVersion - 1))!['computed_at'],
        kSeedComputedAt);
  });

  test('the default reason is derive: an unmarked write is still refused',
      () async {
    await seedRow(db, kDay, finalized: true);
    await LocalDb.putDayResult(
      dayId: kDay,
      algoVersion: kAlgoVersion,
      payloadJson: payloadOf('plain', rhr: 77.0),
      windowJson: '{}',
      finalized: true,
    );
    expect((await rowOf(db, kDay))!['payload_json'], payloadOf('seed'));
  });
}
