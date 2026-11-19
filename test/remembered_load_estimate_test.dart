// CLAIM load-estimate: one settled size establishes a baseline; recurrence
// wins over noise, while a lone unusual size cannot jerk the next reservation.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/ui2/skeleton/load_memory.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'support/failing_preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Why: a best-effort layout cache must not leak an asynchronous platform
  // error into the UI. Catches: using the fire-and-forget preference setter.
  for (final throws in [false, true]) {
    testWidgets('a failed cache write keeps usable memory, throws=$throws', (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.reload();
      final original = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = FailingPreferencesStore(
        original, key: LoadMemory.prefKey, throws: throws);
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final memory = LoadMemory(userKey: () => 'failure-profile');
      memory.record('section', 100);
      await t.pump();
      expect(memory.estimate('section'), 100);
      expect(t.takeException(), isNull);
      memory.record('next-section', 200);
      await t.pump();
      await Prefs.reload();
      final restored = LoadMemory(userKey: () => 'failure-profile');
      expect(restored.estimate('next-section'), 200,
        reason: 'a later write recovers through the real preferences backend');
    });
  }
  test(
    'presentation memory is bounded, isolated by user, durable and excluded from exports',
    () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      var user = 'a';
      final memory = LoadMemory(userKey: () => user, limit: 4);
      memory.record('section', 100);
      memory.record('other', 200);
      user = 'b';
      expect(memory.estimate('section'), isNull);
      memory.record('section', 300);
      user = 'a';
      expect(memory.estimate('section'), 100);
      memory.record('third', 400);
      memory.record('fourth', 500);
      expect(
        memory.estimate('section'),
        isNull,
        reason: 'the oldest key must be evicted',
      );
      await Future<void>.value();
      await Prefs.reload();
      final restored = LoadMemory(userKey: () => user, limit: 4);
      expect(restored.estimate('third'), 400);
      expect(kPrefsNotBackedUp.containsKey(LoadMemory.prefKey), isTrue);
    },
  );
  // CLAIM known-shape-first: an estimate must not clip labels/rows whose new
  // size is already known. Memory only fills the genuinely unknown tail.
  testWidgets('remembered height never clips a larger known loading shape', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Widget show(bool pending, double height) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          child: RememberedLayout(
            id: 'known-loading-shape',
            pending: pending,
            child: SizedBox(height: height, child: const Text('Known label')),
          ),
        ),
      ),
    );
    await t.pumpWidget(show(false, 40));
    await t.pump();
    await t.pumpWidget(show(true, 100));
    expect(t.getSize(find.byType(RememberedLayout)).height, 100);
    await t.pumpWidget(show(false, 55));
    await t.pump();
    expect(
      t.getSize(find.byType(RememberedLayout)).height,
      55,
      reason: 'settled content always fits naturally',
    );
    await t.pumpWidget(const SizedBox());
  });
  test(
    'estimate converges, rejects one outlier and remembers the recurring shape',
    () {
      final size = LoadEstimate();
      size.add(100);
      expect(size.value, 100);
      size.add(500);
      expect(size.value, inInclusiveRange(100, 105));
      for (var i = 0; i < 20; i++) {
        size.add(160);
      }
      expect(size.value, 160);
      expect(size.samples.length, 8);
      size.add(900);
      expect(size.value, 160);
      final lines = LoadEstimate(tolerance: .1);
      for (final n in [3.0, 4.0, 4.0, 3.0, 4.0]) {
        lines.add(n);
      }
      expect(lines.value, 4);
    },
  );
}
