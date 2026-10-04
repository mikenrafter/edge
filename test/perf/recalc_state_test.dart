// 8AG-perf P1b: RecalcState — which days a running pass has not finished.
//
// ASSUMED API
//
//   lib/state/recalc_state.dart (new, pure Dart):
//     class RecalcState {
//       const RecalcState({
//         this.days = const <String>{},   // local day labels still being recalculated
//         this.passStartedAt,             // DateTime?, set when the scope is known
//         this.crossDay = false,          // cross-day / baseline step is running
//       });
//       static const RecalcState idle = RecalcState();
//     }
//
//   AppState (lib/state/app_state.dart):
//     ValueListenable<RecalcState> get recalc;      // backed by a ValueNotifier,
//                                                   // NOT notifyListeners-driven
//     // test seams (@visibleForTesting), the engine is not injectable today:
//     DeriveRunHook? debugDeriveRun;                // replaces `_derive.run`
//     RescanHook?   debugRescanRecent;              // replaces `_derive.rescanRecent`
//     void debugSetRecalc(RecalcState s);          // sets the notifier directly
//     Future<void> debugAfterDrain({bool heavy = false, bool changedOnly = false});
//                                                   // == _afterDrain(...)
//
//     typedef DeriveRunHook = Future<int> Function({
//       required bool heavy,
//       required bool changedOnly,
//       void Function(int total)? onScope,
//       void Function(List<String> days)? onScopeDays,   // NEW engine callback
//       void Function(String day, int index, int total)? onDayDone,
//       void Function(bool active)? onCrossDay,          // NEW engine callback
//     });
//     typedef RescanHook = Future<int> Function({
//       void Function(List<String> days)? onScopeDays,
//       void Function(String day, int index, int total)? onDayDone,
//     });
//
//   DerivationEngine.run()/runDays()/rescanRecent() gain the optional
//   `onScopeDays` (and run() `onCrossDay`) parameters; `onScope` is kept.
//
// Behaviour: scope reported -> days = that list, passStartedAt = now; each
// onDayDone removes its day; cross-day step toggles crossDay; in `finally`
// (success, failure) everything is cleared. Rescan of recent finalized days
// covers its own days the same way.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/recalc_state.dart';

Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_recalc_state_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() => LocalDb.close());

  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState.forTesting();
  });
  tearDown(() => app.dispose());

  test('starts idle', () {
    expect(app.recalc.value.days, isEmpty);
    expect(app.recalc.value.passStartedAt, isNull);
    expect(app.recalc.value.crossDay, isFalse);
  });

  test('scope -> per-day removal -> cleared', () async {
    final gate1 = Completer<void>();
    final gate2 = Completer<void>();
    final seen = <Set<String>>[];
    app.recalc.addListener(() => seen.add({...app.recalc.value.days}));
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(3);
      onScopeDays?.call(['2026-10-03', '2026-10-02', '2026-10-01']);
      await gate1.future;
      onDayDone?.call('2026-10-03', 1, 3);
      await gate2.future;
      onDayDone?.call('2026-10-02', 2, 3);
      onDayDone?.call('2026-10-01', 3, 3);
      return 3;
    };

    final before = DateTime.now();
    final pass = app.debugAfterDrain();
    await _until(() => app.recalc.value.days.isNotEmpty);
    expect(app.recalc.value.days, {'2026-10-03', '2026-10-02', '2026-10-01'});
    expect(app.recalc.value.passStartedAt, isNotNull);
    expect(app.recalc.value.passStartedAt!.isBefore(before), isFalse);

    gate1.complete();
    await _until(() => app.recalc.value.days.length == 2);
    expect(app.recalc.value.days, {'2026-10-02', '2026-10-01'},
        reason: 'a finished day leaves the set at once, mid-pass');

    gate2.complete();
    await pass;
    expect(app.recalc.value.days, isEmpty);
    expect(app.recalc.value.passStartedAt, isNull);
    expect(seen.first, {'2026-10-03', '2026-10-02', '2026-10-01'});
    expect(seen.last, isEmpty);
  });

  test('cleared when the pass throws (finally, not the happy path)', () async {
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScopeDays?.call(['a', 'b']);
      onDayDone?.call('a', 1, 2);
      onCrossDay?.call(true);
      throw StateError('boom');
    };
    await app.debugAfterDrain();
    expect(app.recalc.value.days, isEmpty);
    expect(app.recalc.value.crossDay, isFalse);
    expect(app.recalc.value.passStartedAt, isNull);
  });

  test('a pass that has nothing to do leaves it idle', () async {
    var notified = 0;
    app.recalc.addListener(() => notified++);
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(0);
      onScopeDays?.call(const []);
      return 0;
    };
    await app.debugAfterDrain();
    expect(app.recalc.value.days, isEmpty);
    expect(app.recalc.value.passStartedAt, isNull,
        reason: 'no scope, no pass in progress');
    expect(notified, lessThanOrEqualTo(1));
  });

  test('crossDay is true exactly while the cross-day / baseline step runs',
      () async {
    final gate = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScopeDays?.call(['d']);
      onDayDone?.call('d', 1, 1);
      onCrossDay?.call(true);
      await gate.future;
      onCrossDay?.call(false);
      return 1;
    };
    final pass = app.debugAfterDrain();
    await _until(() => app.recalc.value.crossDay);
    expect(app.recalc.value.crossDay, isTrue);
    expect(app.recalc.value.days, isEmpty,
        reason: 'the per-day work is done; only the roll-up is left');
    gate.complete();
    await pass;
    expect(app.recalc.value.crossDay, isFalse);
  });

  test('rescanRecent (baseline rescan of finalized days) is covered too',
      () async {
    final gate = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async =>
        0;
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async {
      onScopeDays?.call(['2026-09-30', '2026-09-29']);
      await gate.future;
      onDayDone?.call('2026-09-30', 1, 2);
      onDayDone?.call('2026-09-29', 2, 2);
      return 2;
    };
    await app.debugAfterDrain(heavy: true);
    await _until(() => app.recalc.value.days.isNotEmpty);
    expect(app.recalc.value.days, {'2026-09-30', '2026-09-29'});
    gate.complete();
    await _until(() => app.recalc.value.days.isEmpty);
    expect(app.recalc.value.days, isEmpty);
  });

  test('a throwing rescan also clears', () async {
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async =>
        0;
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async {
      onScopeDays?.call(['x']);
      throw StateError('rescan failed');
    };
    await app.debugAfterDrain(heavy: true);
    await _until(() => app.recalc.value.days.isEmpty);
    expect(app.recalc.value.days, isEmpty);
  });

  test('recalc changes do not ride AppState.notifyListeners', () {
    var ticks = 0;
    app.addListener(() => ticks++);
    app.debugSetRecalc(RecalcState(days: {'d'}, passStartedAt: DateTime.now()));
    app.debugSetRecalc(RecalcState.idle);
    expect(ticks, 0,
        reason: 'AppState ticks at ~1 Hz while a workout is live; the label '
            'must listen to its own notifier');
  });
}
