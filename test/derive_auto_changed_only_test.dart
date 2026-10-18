// What the scheduler's pass asks of the engine, and what
// it reports back.
//
// Light passes: the scheduler-driven LIGHT pass used to call
// `_afterDrain(heavy: false)` with `changedOnly` defaulting to false, so every
// 8 s stored-data tick re-derived today even when nothing it reads had moved.
// A light pass now passes `changedOnly: true`. Heavy passes keep
// `changedOnly: false` (they carry the finalize extras and the force paths).
//
// Outcome: `_afterDrain` returns a `DeriveOutcome` to the scheduler.
//
// API (lib/state/app_state.dart):
//
//   @visibleForTesting
//   Future<DeriveOutcome> debugRunScheduled({required DeriveJobKind kind})
//     == the exact callback the DeriveScheduler is constructed with:
//        `({required DeriveJobKind kind}) =>
//             _afterDrain(heavy: kind == heavy, changedOnly: kind == light)`
//     returning the pass's outcome:
//       * debugDeriveRun hook returned n          -> DeriveOutcome(computed: n)
//         (with the real engine: its `lastOutcome` for this pass)
//       * the pass threw (the `_afterDrain` catch fires) -> DeriveOutcome(
//         failed: true, error: contains the message)
//
//   `_afterDrain`'s existing early return (`changedOnly && scopeTotal == 0 &&
//   no engine last_error` => log "nothing changed" and return before the
//   post-derive work, in particular without bumping insightsRevision) keeps
//   its meaning, and now applies to the automatic light path.
//
// The `debugDeriveRun` seam is unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

class _Call {
  _Call(this.heavy, this.changedOnly);
  final bool heavy;
  final bool changedOnly;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_auto_changed_only_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() => LocalDb.close());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  late AppState app;
  late List<_Call> calls;

  void install({int returns = 1, int? scope, Object? throws}) {
    calls = [];
    app = AppState.forTesting();
    addTearDown(app.dispose);
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      calls.add(_Call(heavy, changedOnly));
      if (throws != null) throw throws;
      if (scope != null) onScope?.call(scope);
      return returns;
    };
  }

  group('light passes: which passes may skip unchanged days', () {
    test('the scheduler\'s LIGHT pass runs the engine with changedOnly: true',
        () async {
      install();
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(calls, hasLength(1));
      expect(calls.single.heavy, isFalse);
      expect(calls.single.changedOnly, isTrue);
    });

    test('the scheduler\'s HEAVY pass keeps changedOnly: false', () async {
      install();
      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(calls, hasLength(1));
      expect(calls.single.heavy, isTrue);
      expect(calls.single.changedOnly, isFalse,
          reason: 'heavy carries the finalize extras / force paths');
    });

    test('a light pass that found nothing changed stops before the '
        'post-derive work (no revision bump)', () async {
      install(returns: 0, scope: 0);
      final start = app.insightsRevision.value;
      final outcome = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(app.insightsRevision.value, start,
          reason: 'nothing was recomputed, so nothing to re-read');
      expect(outcome.complete, isTrue,
          reason: '"nothing changed" is a finished pass, not a failure');
      expect(outcome.computed, 0);
    });

    test('guard: a heavy pass with scope 0 still finishes the full '
        'post-derive path (changedOnly false => no early return)', () async {
      install(returns: 0, scope: 0);
      final start = app.insightsRevision.value;
      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(app.insightsRevision.value, greaterThan(start));
    });

    test('a light pass that computed days still publishes', () async {
      install(returns: 1, scope: 1);
      final start = app.insightsRevision.value;
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(app.insightsRevision.value, greaterThan(start));
    });
  });

  group('outcome: what the scheduler gets back', () {
    test('a pass that ran returns a complete outcome with the day count',
        () async {
      install(returns: 2, scope: 2);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(o.complete, isTrue);
      expect(o.computed, 2);
    });

    test('a pass that throws returns failed, with the error, and does not '
        'rethrow', () async {
      install(throws: StateError('engine exploded'));
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.failed, isTrue);
      expect(o.complete, isFalse);
      expect(o.error, contains('engine exploded'));
    });

    test('the throw path leaves the app usable for the next pass', () async {
      install(throws: StateError('first one fails'));
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      app.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        onScope?.call(1);
        return 1;
      };
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.complete, isTrue);
    });
  });
}
