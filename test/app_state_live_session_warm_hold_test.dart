// 8AJ seam 2 characterization: AppState's live-session predicate (workout,
// breathing session or window, ECG capture) is the derive coordinator's
// "warm held" input. Observed through the artifact warmer: while a live
// session is active a productive pass warms nothing; once it ends, the next
// pass warms. Must pass before and after the LiveStreamController move
// (`_liveSessionActive` stays a callback into the coordinator).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';

import 'support/scripted_artifact_source.dart';
import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_split8aj_seam2_warm_hold.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // A key per test: a stored result with a matching signature is "fresh" and
  // would make a later test's pass warm nothing for the wrong reason.
  Future<(AppState, FakeArtifactSource)> rig(String key) async {
    final src = FakeArtifactSource()
      ..keys = [key]
      ..sigs[key] = 's';
    final app = AppState.forTesting();
    app.debugArtifactSource = src;
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugDeriveRun = deriveHook(days: ['d1']);
    return (app, src);
  }

  test('no live session: a productive pass warms', () async {
    final (app, src) = await rig('a');
    addTearDown(app.dispose);
    await app.debugAfterDrain();
    await until(() => src.computeStarted.isNotEmpty);
    expect(src.computeStarted, ['a']);
  });

  test('a workout holds the warmer; ending it releases the next pass',
      () async {
    final (app, src) = await rig('b');
    addTearDown(app.dispose);
    app.activeWorkout = LiveWorkoutState(
        startTime: DateTime.now(), targetKcal: 0, type: 'running');
    await app.debugAfterDrain();
    await settleMs(200);
    expect(src.computeStarted, isEmpty);
    app.activeWorkout = null;
    await app.debugAfterDrain();
    await until(() => src.computeStarted.isNotEmpty);
    expect(src.computeStarted, ['b']);
  });

  test('a breathing session and a breathing window each hold it', () async {
    final (app, src) = await rig('c');
    addTearDown(app.dispose);
    app.breathingActive = true;
    await app.debugAfterDrain();
    await settleMs(200);
    expect(src.computeStarted, isEmpty, reason: 'session');
    app.breathingActive = false;
    app.breathingWindowOpen = true;
    await app.debugAfterDrain();
    await settleMs(200);
    expect(src.computeStarted, isEmpty, reason: 'window');
    app.breathingWindowOpen = false;
    await app.debugAfterDrain();
    await until(() => src.computeStarted.isNotEmpty);
    expect(src.computeStarted, ['c']);
  });

  test('the developer live feed and live-HR viewers are not live sessions: '
      'they do not hold the warmer', () async {
    final (app, src) = await rig('d');
    addTearDown(app.dispose);
    await app.startLiveFeed('');
    app.retainLiveHrView();
    await app.debugAfterDrain();
    await until(() => src.computeStarted.isNotEmpty);
    expect(src.computeStarted, ['d']);
  });
}
