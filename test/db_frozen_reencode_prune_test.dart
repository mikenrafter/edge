// The two things the freeze must NOT disturb.
//
//   * `reencodeLegacyDayResults` (payload re-encoding that keeps every value
//     bit-identical) still rewrites FINALIZED rows. It is encoding, not a
//     publish, so it bypasses the guard: payload_json is the only column that
//     moves, every decoded value is identical, and the row stays frozen against
//     a derive write afterwards.
//   * The AGENTS.md section 3.9 prune guard. "Derived" for pruning is
//     `dayResultIds(kAlgoVersion)` (complete, non-skipped rows) feeding
//     `rawPruneCutoffSec`. A refused write must neither promote a partial
//     finalized row to "derived" nor demote a complete finalized one.
//

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

import 'support/frozen_day_result_fixtures.dart';

const _t0 = 1783572180;

Map<String, dynamic> _bundle(int n) => {
  'scalars': {'rhr': 55.0, 'readiness': 71.0},
  'series': {
    'hr_curve': [
      for (var i = 0; i < n; i++) {'t': _t0 + i * 60, 'v': 60 + (i % 17)},
    ],
    'hrv_day': [
      for (var i = 0; i < n; i++) {'t': _t0 + i * 61 + (i % 5), 'v': 30.0 + i},
    ],
  },
};

int _dayStart(String label) {
  final d = DateTime.parse(label);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async => db = await freshDb('openstrap_reencode_prune_test.db'));
  tearDownAll(dropDb);

  group('re-encode of a finalized legacy row', () {
    Future<void> seedLegacyFinal() => seedRow(
      db,
      kDay,
      finalized: true,
      payload: jsonEncode(_bundle(30)),
    );

    test('still rewrites a finalized row, value-identical', () async {
      await seedLegacyFinal();
      final before = (await rowOf(db, kDay))!;

      expect(await LocalDb.reencodeLegacyDayResults(), 1);

      final after = (await rowOf(db, kDay))!;
      expect(SeriesCodec.needsReencode(after['payload_json'] as String),
          isFalse);
      expect(after['payload_json'], isNot(before['payload_json']),
          reason: 'the spelling changed');
      expect(
        jsonEncode(SeriesCodec.decodePayloadJson(after['payload_json'])),
        jsonEncode(_bundle(30)),
        reason: 'every value survives bit-for-bit',
      );
    });

    test('moves nothing but payload_json: computed_at, finalized, scalars stay',
        () async {
      await seedLegacyFinal();
      final before = (await rowOf(db, kDay))!;
      await LocalDb.reencodeLegacyDayResults();
      final after = (await rowOf(db, kDay))!;
      for (final k in before.keys) {
        if (k == 'payload_json') continue;
        expect(after[k], before[k], reason: 'column $k changed');
      }
      expect(after['computed_at'], kSeedComputedAt);
    });

    test('the re-encoded row is still frozen against a derive write', () async {
      await seedLegacyFinal();
      await LocalDb.reencodeLegacyDayResults();
      final encoded = (await rowOf(db, kDay))!;

      await deriveWrite(kDay, tag: 'late', finalized: true, rhr: 99.0);

      expect(await rowOf(db, kDay), encoded);
    });

    test('a re-encode does not move dayResultRev', () async {
      await seedLegacyFinal();
      final rev = await LocalDb.dayResultRev();
      await LocalDb.reencodeLegacyDayResults();
      expect(await LocalDb.dayResultRev(), rev,
          reason: 'encoding is not a publish');
    });
  });

  group('section 3.9 prune guard is unaffected', () {
    final dataNow = _dayStart('2026-03-20');
    const rawDays = ['2026-03-10', '2026-03-11'];

    Future<int?> cutoff() async => DerivationEngine.rawPruneCutoffSec(
      dataNowSec: dataNow,
      rawDayIds: rawDays,
      derivedDayIds: await LocalDb.dayResultIds(kAlgoVersion),
    );

    test('a finalized complete row counts as derived and does not hold raw',
        () async {
      await seedRow(db, '2026-03-10', finalized: true);
      await seedRow(db, '2026-03-11', finalized: true);
      expect(await LocalDb.dayResultIds(kAlgoVersion), rawDays.toSet());
      expect(await cutoff(), dataNow - rawRetentionDays * 86400);
    });

    test('a refused thin write cannot demote a finalized complete day',
        () async {
      await seedRow(db, '2026-03-10', finalized: true);
      await seedRow(db, '2026-03-11', finalized: true);

      await deriveWrite('2026-03-10', partial: true, finalized: false);
      await deriveWrite('2026-03-11', skipped: true, finalized: false);

      expect(await LocalDb.dayResultIds(kAlgoVersion), rawDays.toSet(),
          reason: 'still complete, so still not holding raw back');
      expect(await cutoff(), dataNow - rawRetentionDays * 86400);
    });

    test('a finalized PARTIAL row stays "not derived": raw is held', () async {
      await seedRow(db, '2026-03-10', finalized: true, partial: true);
      await seedRow(db, '2026-03-11', finalized: true);
      expect(await LocalDb.dayResultIds(kAlgoVersion), {'2026-03-11'});
      expect(await cutoff(), _dayStart('2026-03-10'));
    });

    test('a refused write cannot smuggle a finalized partial row to derived',
        () async {
      await seedRow(db, '2026-03-10', finalized: true, partial: true);
      await seedRow(db, '2026-03-11', finalized: true);

      await deriveWrite('2026-03-10', partial: false, finalized: true);

      expect((await rowOf(db, '2026-03-10'))!['partial'], 1);
      expect(await LocalDb.dayResultIds(kAlgoVersion), {'2026-03-11'});
      expect(await cutoff(), _dayStart('2026-03-10'));
    });

    test('a provisional partial day completed by a later write releases raw',
        () async {
      await seedRow(db, '2026-03-10', partial: true);
      await seedRow(db, '2026-03-11', finalized: true);
      expect(await cutoff(), _dayStart('2026-03-10'));

      await deriveWrite('2026-03-10', partial: false);

      expect(await LocalDb.dayResultIds(kAlgoVersion), rawDays.toSet());
      expect(await cutoff(), dataNow - rawRetentionDays * 86400);
    });

    test('finalizedDayIds is untouched by a refused write', () async {
      await seedRow(db, '2026-03-10', finalized: true);
      await seedRow(db, '2026-03-11', finalized: false);
      await deriveWrite('2026-03-10', finalized: false);
      await deriveWrite('2026-03-11', finalized: false);
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), {'2026-03-10'});
    });
  });
}
