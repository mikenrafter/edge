// AGENTS.md invariant 3.9: a day whose derive FAILED
// transiently must never look derived to the prune or to `changedOnly`.
//
// The pure-selector regression guard lives in raw_prune_pending_guard_test.dart.
// This file is the INTEGRATION layer: a real
// heavy pass where an old day times out leaves NO recorded fingerprint and no
// complete result for it, so the next `changedOnly` pass derives it again.
//
// ASSUMED API (see p2_engine_outcome_test.dart): `DerivationEngine.debugDayHook`
// (`Future<void> Function(String dayId)?`, awaited at the top of processDay's
// try block; a throw is handled exactly like a failed prepare) and
// `DerivationEngine.lastOutcome` (see p2_engine_outcome_test.dart).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

int _counter = 1;

Future<void> _record(int ts) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'co$c',
      capturedAt: ts * 1000,
      recTs: ts,
    ),
    Sample(
      tsEpoch: ts,
      counter: c,
      hr: 62 + (c % 5),
      rrIntervalsMs: const [950],
      ax: 0,
      ay: 0,
      az: 1,
      spo2RedRaw: 1,
      spo2IrRaw: 1,
      skinTempRaw: 3000,
    ),
  );
}

Future<void> _seedDay(int daysAgo) async {
  final n = DateTime.now();
  final base =
      DateTime(n.year, n.month, n.day - daysAgo, 1).millisecondsSinceEpoch ~/ 1000;
  for (var i = 0; i < 120; i++) {
    await _record(base + i);
  }
}

String _day(int daysAgo) {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day - daysAgo));
}

void main() {
  group('integration: a real transient failure', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_p2_transient_prune_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await _seedDay(9);
      await _seedDay(0);
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    test('the timed-out old day keeps no fingerprint and no complete result, '
        'and the next changedOnly pass derives it again', () async {
      final old = _day(9);
      final failing = DerivationEngine()
        ..debugDayHook = (day) async {
          if (day == old) throw TimeoutException('prepare took too long');
        };
      await failing.run(const Profile(), heavy: true, changedOnly: true);
      expect(failing.lastOutcome!.transientFailures, 1);
      expect(failing.lastOutcome!.complete, isFalse);

      expect((await LocalDb.derivedFingerprints(kAlgoVersion)).containsKey(old),
          isFalse,
          reason: 'recording one would make an unchanged-input retry skip it');
      // A transient skip leaves either no row or a skip marker (skipped = 1,
      // never finalized); a partial row would be just as harmless. What the
      // prune reads is `dayResultIds`, which must not list the day.
      final row = await LocalDb.dayResult(old);
      expect(
          row == null ||
              row['skipped'] == 1 ||
              row['partial'] == 1,
          isTrue,
          reason: 'never a complete result, or the prune would drop its raw');
      expect(await LocalDb.dayResultIds(kAlgoVersion), isNot(contains(old)),
          reason: 'prune-pending: its raw must survive');
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), isNot(contains(old)));

      // The input did not change at all, and the day still gets its turn.
      final days = <String>[];
      final retry = DerivationEngine();
      await retry.run(
        const Profile(),
        heavy: true,
        changedOnly: true,
        onDayDone: (day, i, n) => days.add(day),
      );
      expect(days, contains(old));
      expect(retry.lastOutcome!.complete, isTrue);
    });
  });
}
