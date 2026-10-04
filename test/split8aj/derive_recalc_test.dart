// 8AJ seam 1 characterization: the RecalcState notifier and its owner
// bookkeeping, observed through AppState.recalc. Must pass before and after the
// DeriveCoordinator move.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/recalc_state.dart';

import 'support/derive_harness.dart';

const _db = 'openstrap_split8aj_derive_recalc.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState make() {
    final a = AppState.forTesting();
    addTearDown(a.dispose);
    a.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    return a;
  }

  group('identity', () {
    test('recalc is one ValueListenable for the whole app lifetime', () async {
      final app = make();
      final first = app.recalc;
      expect(first, isA<ValueListenable<RecalcState>>());
      expect(identical(app.recalc, first), isTrue);
      app.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
      await app.debugAfterDrain();
      expect(identical(app.recalc, first), isTrue);
      app.debugDeriveRun = deriveHook(throws: StateError('x'));
      await app.debugAfterDrain();
      expect(identical(app.recalc, first), isTrue);
    });

    test('insightsRevision is one ValueNotifier<int> for the whole app '
        'lifetime, starting at 0', () async {
      final app = make();
      final first = app.insightsRevision;
      expect(first, isA<ValueNotifier<int>>());
      expect(first.value, 0);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      expect(identical(app.insightsRevision, first), isTrue);
      expect(first.value, greaterThan(0));
    });

    test('recalc starts idle', () {
      final app = make();
      expect(app.recalc.value, RecalcState.idle);
      expect(app.recalc.value.days, isEmpty);
      expect(app.recalc.value.passStartedAt, isNull);
      expect(app.recalc.value.crossDay, isFalse);
    });
  });

  group('set and cleared', () {
    test('scope sets the days and a start time; each done day leaves; the end '
        'puts back idle', () async {
      final app = make();
      final gate = Completer<void>();
      final snaps = <(Set<String>, bool, bool)>[];
      app.recalc.addListener(() {
        final v = app.recalc.value;
        snaps.add(({...v.days}, v.passStartedAt != null, v.crossDay));
      });
      app.debugDeriveRun = deriveHook(
          days: ['d3', 'd2', 'd1'], gate: gate, holdAfter: 1);
      final before = DateTime.now();
      final pass = app.debugAfterDrain();
      await until(() => app.recalc.value.days.length == 2);
      expect(app.recalc.value.days, {'d2', 'd1'},
          reason: 'the first day is done, the others are still pending');
      expect(app.recalc.value.passStartedAt, isNotNull);
      expect(app.recalc.value.passStartedAt!.isBefore(before), isFalse);
      gate.complete();
      await pass;
      expect(app.recalc.value, RecalcState.idle);
      // scope, d3 done, d2 done, d1 done, idle.
      expect(snaps.map((s) => s.$1.length).toList(), [3, 2, 1, 0, 0]);
      expect(snaps.last.$1, isEmpty);
      expect(snaps.last.$2, isFalse);
      expect(snaps.last.$3, isFalse);
    });

    test('an empty scope sets nothing', () async {
      final app = make();
      var notified = 0;
      app.recalc.addListener(() => notified++);
      app.debugDeriveRun = deriveHook(days: const []);
      await app.debugAfterDrain();
      expect(notified, 0);
      expect(app.recalc.value, RecalcState.idle);
    });

    test('a pass that throws mid-pass puts back idle', () async {
      final app = make();
      app.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        onScopeDays?.call(['d2', 'd1']);
        onDayDone?.call('d2', 1, 2);
        throw StateError('boom');
      };
      await app.debugAfterDrain();
      expect(app.recalc.value, RecalcState.idle);
    });

    test('the cross-day flag follows the engine and is cleared at the end',
        () async {
      final app = make();
      final gate = Completer<void>();
      app.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        onScopeDays?.call(['d1']);
        onDayDone?.call('d1', 1, 1);
        onCrossDay?.call(true);
        await gate.future;
        onCrossDay?.call(false);
        return 1;
      };
      final pass = app.debugAfterDrain();
      await until(() => app.recalc.value.crossDay);
      expect(app.recalc.value.crossDay, isTrue);
      gate.complete();
      await pass;
      expect(app.recalc.value, RecalcState.idle);
    });

    test('a failed pass that left days pending gives one extra revision so '
        'the labels can drop; a clean pass does not', () async {
      final failing = make();
      failing.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        onScopeDays?.call(['d2', 'd1']);
        throw StateError('boom');
      };
      final failedRevs = RevisionLog(failing);
      await failing.debugAfterDrain();
      await settleMs();
      expect(failedRevs.bumps, 1, reason: 'only the end-of-pass clear bump');

      final clean = make();
      clean.debugDeriveRun = deriveHook(days: ['d1']);
      final cleanRevs = RevisionLog(clean);
      await clean.debugAfterDrain();
      await settleMs();
      expect(cleanRevs.bumps, 2,
          reason: 'day publish + end-of-pass publish, no clear bump');
    });

    test('recalc updates never tick AppState itself', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final ticks = TickCounter(app);
      var recalcTicks = 0;
      app.recalc.addListener(() => recalcTicks++);
      await app.debugAfterDrain();
      expect(recalcTicks, greaterThan(0));
      expect(ticks.ticks, 2, reason: 'day 1 + publish only');
    });

    test('debugSetRecalc writes the notifier directly and is ignored after '
        'dispose', () {
      final app = AppState.forTesting();
      final s = RecalcState(days: {'d1'}, passStartedAt: DateTime(2026));
      app.debugSetRecalc(s);
      expect(app.recalc.value, s);
      app.dispose();
      expect(() => app.debugSetRecalc(RecalcState.idle), returnsNormally);
    });
  });

  group('owner bookkeeping', () {
    test('a refused pass that returns early cannot wipe a running pass\'s '
        'days', () async {
      final app = make();
      final gate = Completer<void>();
      app.debugDeriveRun = deriveHook(
          days: ['d2', 'd1'], gate: gate, holdAfter: 0);
      final running = app.debugAfterDrain();
      await until(() => app.recalc.value.days.length == 2);

      // The engine's lock refuses the second pass: it reports no scope.
      app.debugDeriveRun = deriveHook(reportScope: false, returns: 0);
      await app.debugAfterDrain();
      expect(app.recalc.value.days, {'d2', 'd1'},
          reason: 'the refused pass set nothing, so it clears nothing');

      gate.complete();
      await running;
      expect(app.recalc.value, RecalcState.idle);
    });

    test('a later scope takes ownership: the earlier pass\'s day-done calls '
        'stop touching the set', () async {
      final app = make();
      final gate = Completer<void>();
      void Function(String day, int index, int total)? firstDayDone;
      app.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        firstDayDone = onDayDone;
        onScopeDays?.call(['old']);
        await gate.future;
        return 0;
      };
      final first = app.debugAfterDrain();
      await until(() => app.recalc.value.days.contains('old'));

      final second = Completer<void>();
      app.debugDeriveRun = deriveHook(
          days: ['new1', 'new2'], gate: second, holdAfter: 0);
      final secondPass = app.debugAfterDrain();
      await until(() => app.recalc.value.days.contains('new1'));
      expect(app.recalc.value.days, {'new1', 'new2'});

      firstDayDone!('new1', 1, 1); // the stale pass reports a day
      expect(app.recalc.value.days, {'new1', 'new2'},
          reason: 'only the owner may remove days');

      second.complete();
      await secondPass;
      gate.complete();
      await first;
      expect(app.recalc.value, RecalcState.idle);
    });
  });

  group('baseline-dirty rescan', () {
    test('a heavy pass\'s rescan reports its own days and clears them',
        () async {
      final app = make();
      final gate = Completer<void>();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async {
        onScopeDays?.call(['r2', 'r1']);
        await gate.future;
        onDayDone?.call('r2', 1, 2);
        onDayDone?.call('r1', 2, 2);
        return 2;
      };
      await app.debugAfterDrain(heavy: true);
      await until(() => app.recalc.value.days.length == 2);
      expect(app.recalc.value.days, {'r2', 'r1'},
          reason: 'the pass has returned; the rescan still owns the set');
      gate.complete();
      await until(() => app.recalc.value == RecalcState.idle);
      expect(app.recalc.value, RecalcState.idle);
    });

    test('a throwing rescan still puts back idle', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async {
        onScopeDays?.call(['r1']);
        throw StateError('rescan boom');
      };
      await app.debugAfterDrain(heavy: true);
      await until(() => app.recalc.value == RecalcState.idle);
      expect(app.recalc.value, RecalcState.idle);
    });
  });
}
