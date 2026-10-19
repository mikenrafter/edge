// insightsRevision / bumpInsights: the "durable data changed" signal screens
// listen to instead of notifyListeners, and its lifetime.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_app_state_derive_revision.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A real (empty) store: the publish gate's freshness refresh reads it, and
  // without one every pass fails that step and retries, bumping twice.
  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState make() {
    final a = AppState.forTesting();
    addTearDown(a.dispose);
    return a;
  }

  test('bumpInsights adds one to the notifier and ticks nobody else', () {
    final app = make();
    final log = SignalLog(app);
    app.bumpInsights();
    app.bumpInsights();
    expect(app.insightsRevision.value, 2);
    expect(log.events, ['r', 'r']);
  });

  test('starts at zero', () {
    expect(make().insightsRevision.value, 0);
  });

  test('a bump written straight to the notifier (the log-workout sheet, an '
      'import) is the same signal', () {
    final app = make();
    final log = SignalLog(app);
    app.insightsRevision.value++;
    app.bumpInsights();
    expect(log.events, ['r', 'r']);
    expect(app.insightsRevision.value, 2);
  });

  test('it is the same notifier object for the life of the app, through '
      'passes and bumps', () async {
    final app = make();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugDeriveRun = deriveHook(days: ['d1']);
    final first = app.insightsRevision;
    app.bumpInsights();
    await app.debugAfterDrain();
    await app.debugAfterDrain(heavy: true);
    expect(identical(app.insightsRevision, first), isTrue);
    // At least one bump per pass, not exactly one: our publish gate also
    // publishes each day as it lands (derive_publish_each_day_test), so a
    // pass that computes a day bumps for the day and again at its end (D20:
    // our derive coordinator, upstream's features on top).
    expect(first.value, greaterThanOrEqualTo(3));
  });

  test('a listener registered once keeps hearing every bump', () async {
    final app = make();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugDeriveRun = deriveHook();
    final heard = <int>[];
    app.insightsRevision.addListener(() => heard.add(app.insightsRevision.value));
    app.bumpInsights();
    await app.debugAfterDrain();
    app.bumpInsights();
    expect(heard, [1, 2, 3]);
  });

  test('dispose disposes the notifier; a pass that finishes afterwards does '
      'not throw', () async {
    final app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugDeriveRun = deriveHook();
    final notifier = app.insightsRevision;
    app.dispose();
    expect(() => notifier.addListener(() {}), throwsA(isA<FlutterError>()));
    await app.debugAfterDrain();
  });
}
