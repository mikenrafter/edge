// Review fixes, job 2 (workout). A stop-pending workout is already over: it
// must not keep the artifact warmer held, and an unreadable held-stop marker
// must not stop the live-row reconcile from resuming a genuinely live session.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';

import '../perf/support/p3_warmer_support.dart';
import '../split8aj/support/derive_harness.dart';
import '../split8aj/support/workout_harness.dart';

const _db = 'review_fixes_job2_stop_pending.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    await deriveDbSetUp(_db);
    await Prefs.ensureLoaded();
    Prefs.setString(Prefs.workoutStopPending, '');
    spies = PlatformSpies();
  });
  tearDown(() async {
    spies.dispose();
    await deriveDbTearDown(_db);
  });

  test('a workout whose stop failed no longer holds the artifact warmer',
      () async {
    final src = FakeArtifactSource()
      ..keys = ['stop-pending']
      ..sigs['stop-pending'] = 's';
    final app = AppState.forTesting();
    app.debugArtifactSource = src;
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugDeriveRun = deriveHook(days: ['d1']);
    app.startWorkout(workoutId: 'j2-warm', type: 'strength');
    await sessionLanded('j2-warm');
    await app.debugAfterDrain();
    await settleMs(200);
    expect(src.computeStarted, isEmpty, reason: 'a live workout holds it');

    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    await expectLater(app.stopWorkout(), throwsA(anything));
    expect(app.workoutStopPending, isTrue);
    await app.debugAfterDrain();
    await until(() => src.computeStarted.isNotEmpty);
    expect(src.computeStarted, ['stop-pending']);

    await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
    await app.stopWorkout();
    await finish(app);
  });

  test('an unreadable held-stop marker does not stop a live session from '
      'resuming', () async {
    final first = AppState.forTesting();
    first.startWorkout(workoutId: 'j2-corrupt', type: 'strength');
    await sessionLanded('j2-corrupt');
    first.dispose();

    Prefs.setString(Prefs.workoutStopPending, '{not json');
    final relaunch = AppState.forTesting();
    await relaunch.debugReconcileOrphanedLiveWorkout();
    expect(relaunch.activeWorkout?.workoutId, 'j2-corrupt');
    expect(relaunch.workoutStopPending, isFalse);
    Prefs.setString(Prefs.workoutStopPending, '');
    await finish(relaunch);
  });
}
