// 8AG-perf P2-B: the engine records HOW a pass ended.
//
// The bug: `DerivationEngine.run` caught everything and returned 0, so the
// scheduler could not tell "nothing to do" from "the pass blew up", and
// deleted the job either way.
//
// ASSUMED API (lib/compute/derivation_engine.dart + lib/compute/derive_outcome.dart):
//
//   DeriveOutcome? get lastOutcome;           // null before any run() call
//   snapshot()['last_outcome']                // == lastOutcome?.toMap()
//
//   run() keeps returning Future<int> (days computed). Besides, per call:
//     * ran to the end, no transient skip      -> DeriveOutcome(computed: n)
//     * a day skipped for a TRANSIENT reason   -> transientFailures++ for each
//       ('timeout' / 'error', i.e. `_transientSkipReasons`)
//     * a day skipped for a STRUCTURAL reason  -> NOT a failure (its
//       fingerprint is recorded on purpose)
//     * the pass-level `catch` fired           -> failed: true, error: '$e'
//     * refused because a pass is already in flight (the process-wide
//       `_running` lock) -> failed: true, error: 'busy'; the refused call's
//       outcome is what `lastOutcome` shows right after it returns. When the
//       in-flight pass finishes, `lastOutcome` shows ITS outcome.
//
// New test seams on DerivationEngine (instance fields, both
// `@visibleForTesting`, both null by default):
//
//   Future<void> Function(String dayId)? debugDayHook;
//       awaited at the top of `processDay`'s try block, before the day is
//       prepared. A throw takes the same path as a failed prepare: the day is
//       skipped with `_skipReasonForError(e)`.
//   Future<void> Function()? debugScopeHook;
//       awaited inside run()'s outer try, right after `_deriveScope`. A throw
//       is a pass-level failure.

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

Future<void> _seedToday() async {
  final n = DateTime.now();
  final base = DateTime(n.year, n.month, n.day, 1).millisecondsSinceEpoch ~/ 1000;
  for (var i = 0; i < 120; i++) {
    await _record(base + i);
  }
}

String get _today => todayLabel();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_p2_engine_outcome_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await _seedToday();
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('no outcome before the first pass', () {
    expect(DerivationEngine().lastOutcome, isNull);
  });

  test('a clean pass is complete and counts what it computed', () async {
    final e = DerivationEngine();
    final n = await e.run(const Profile(), heavy: true);
    expect(n, 1);
    final o = e.lastOutcome!;
    expect(o.complete, isTrue);
    expect(o.failed, isFalse);
    expect(o.transientFailures, 0);
    expect(o.computed, 1);
    expect(e.snapshot()['last_outcome'], o.toMap());
  });

  test('a pass-level throw is failed, with the error, and run() still '
      'returns 0', () async {
    final e = DerivationEngine()
      ..debugScopeHook = () async => throw StateError('boom');
    final n = await e.run(const Profile(), heavy: true);
    expect(n, 0);
    final o = e.lastOutcome!;
    expect(o.failed, isTrue);
    expect(o.complete, isFalse);
    expect(o.error, contains('boom'));
    expect(e.snapshot()['last_outcome'], o.toMap());
  });

  test('the next clean pass replaces a failed outcome', () async {
    final e = DerivationEngine()
      ..debugScopeHook = () async => throw StateError('boom');
    await e.run(const Profile(), heavy: true);
    expect(e.lastOutcome!.failed, isTrue);

    e.debugScopeHook = null;
    await e.run(const Profile(), heavy: true);
    expect(e.lastOutcome!.complete, isTrue);
    expect(e.lastOutcome!.error, isNull);
  });

  test('a TimeoutException on a day is a transient failure: not complete, '
      'the pass itself did not fail', () async {
    final e = DerivationEngine()
      ..debugDayHook = (day) async {
        if (day == _today) throw TimeoutException('prepare took too long');
      };
    final n = await e.run(const Profile(), heavy: true);
    expect(n, 0);
    final o = e.lastOutcome!;
    expect(o.transientFailures, 1);
    expect(o.failed, isFalse);
    expect(o.complete, isFalse);
    expect(o.computed, 0);
  });

  test('any other thrown error on a day is transient too (reason "error")',
      () async {
    final e = DerivationEngine()
      ..debugDayHook = (day) async {
        if (day == _today) throw StateError('worker died');
      };
    await e.run(const Profile(), heavy: true);
    final o = e.lastOutcome!;
    expect(o.transientFailures, 1);
    expect(o.complete, isFalse);
  });

  test('a STRUCTURAL skip is not a failure', () async {
    final e = DerivationEngine()
      ..debugDayHook = (day) async {
        if (day == _today) {
          throw Exception('day_prepare_budget_exceeded day=$day rows=9 pages=9');
        }
      };
    await e.run(const Profile(), heavy: true);
    final o = e.lastOutcome!;
    expect(o.transientFailures, 0,
        reason: 'the same input will fail the same way; retrying is pointless');
    expect(o.failed, isFalse);
    expect(o.complete, isTrue);
  });

  test('a call refused because a pass is in flight is failed "busy"',
      () async {
    final gate = Completer<void>();
    final inFlight = DerivationEngine()..debugScopeHook = () => gate.future;
    final first = inFlight.run(const Profile(), heavy: true);
    // Let the first call take the process-wide lock.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(inFlight.running, isTrue);

    final other = DerivationEngine();
    final refused = await other.run(const Profile(), heavy: true);
    expect(refused, 0);
    final o = other.lastOutcome!;
    expect(o.failed, isTrue);
    expect(o.error, 'busy');
    expect(o.complete, isFalse, reason: 'it did not do the requested work');

    gate.complete();
    await first;
    expect(inFlight.lastOutcome!.complete, isTrue,
        reason: 'the in-flight pass reports its own outcome');
  });

  test('the same engine asked twice at once: the refusal is "busy" too',
      () async {
    final gate = Completer<void>();
    final e = DerivationEngine()..debugScopeHook = () => gate.future;
    final first = e.run(const Profile(), heavy: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await e.run(const Profile(), heavy: true);
    expect(e.lastOutcome!.failed, isTrue);
    expect(e.lastOutcome!.error, 'busy');

    gate.complete();
    await first;
    expect(e.lastOutcome!.complete, isTrue);
  });
}
