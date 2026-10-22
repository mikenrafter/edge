// DeriveCoordinator.deriveProgress has ONE owner (the coordinator). Several
// publishers (a coordinator pass, a direct import) hold a claim on it. The
// screen shows the most recent publication of any live claim; when a claim is
// released the screen falls back to the newest claim still live, and to null
// only when none is. A release never wipes work that is still running, and a
// publish never makes an older claim vanish for good.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/derive_progress.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_derive_progress_owner.db';

DeriveCoordinator _make() {
  final logs = <String>[];
  DerivationEngine? engine;
  final c = DeriveCoordinator(
    engine: () => engine ??= DerivationEngine(log: logs.add),
    profile: () => Profile.fromMap(const <String, dynamic>{}),
    log: logs.add,
    notify: () {},
    isDisposed: () => false,
    repo: () => null,
    warmHeld: () => false,
    refreshPhoneStepsToday: () async {},
    maybeNotifyRecoveryReady: () async {},
    runHealthExport: () async => 0,
    healthSyncEnabled: () => false,
    telemetryConsent: () => false,
    healthShareConsent: () => false,
    maybeReclaimDiskSpace: () async {},
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const pass = DeriveProgress(dayIndex: 3, dayTotal: 10, day: '2026-10-03');
  const import = DeriveProgress(dayIndex: 1);

  test('an import releasing while a pass runs gives the pass back', () {
    final c = _make();
    final a = c.beginPublishedProgress();
    c.publishProgress(a, pass);
    final b = c.beginPublishedProgress();
    c.publishProgress(b, import);
    expect(c.deriveProgress.value, same(import), reason: 'newest publication');

    c.clearPublishedProgress(b);
    expect(c.deriveProgress.value, same(pass),
        reason: 'the pass is still running; it must not go invisible');

    c.clearPublishedProgress(a);
    expect(c.deriveProgress.value, isNull);
  });

  test('a pass releasing first leaves the import visible', () {
    final c = _make();
    final a = c.beginPublishedProgress();
    c.publishProgress(a, pass);
    final b = c.beginPublishedProgress();
    c.publishProgress(b, import);

    c.clearPublishedProgress(a);
    expect(c.deriveProgress.value, same(import));
    c.clearPublishedProgress(b);
    expect(c.deriveProgress.value, isNull);
  });

  test('the owner that publishes last is the one shown', () {
    final c = _make();
    final a = c.beginPublishedProgress();
    final b = c.beginPublishedProgress();
    c.publishProgress(b, import);
    c.publishProgress(a, pass);
    expect(c.deriveProgress.value, same(pass));
    c.clearPublishedProgress(a);
    expect(c.deriveProgress.value, same(import));
    c.clearPublishedProgress(b);
  });

  test('releasing twice, or a claim that never published, wipes nothing', () {
    final c = _make();
    final a = c.beginPublishedProgress();
    c.publishProgress(a, pass);
    final never = c.beginPublishedProgress();
    c.clearPublishedProgress(never);
    c.clearPublishedProgress(never);
    expect(c.deriveProgress.value, same(pass));
    c.clearPublishedProgress(a);
    c.clearPublishedProgress(a);
    expect(c.deriveProgress.value, isNull);
  });
}
