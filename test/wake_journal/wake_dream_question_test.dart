import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/natural_wake_card.dart';
import 'package:openstrap_edge/ui2/screens/snooze_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_journal.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_settings.dart' show WakeUpgradeState;
import 'package:openstrap_edge/wake/wake_stores.dart';
import '../backup/backup_support.dart';
import '../support/as_of_recalc_fakes.dart' show perfApp;
import '../support/fake_alarm_engine.dart';
import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    env = await BackupEnv.create('p2_wake_dream_ui.db');
  });
  setUp(() async {
    await env.wipe();
  });
  tearDownAll(() async => env.dispose());

  Future<WakeController> pump(WidgetTester t, WakePath path) async {
    final w = WakeController(
      schedule: () => [],
      saveEntry: (_) async {},
      loadUpgradeState: () async => WakeUpgradeState.none,
      saveUpgradeState: (_) async {},
      acknowledgeWake: (_) async => const WakeAckOutcome(
        nativeCancelRequested: false,
        nativeCancelled: false,
        fallbackArmed: true,
      ),
      traceFor: (_) async => const [],
      journal: const DbWakeJournal(),
      journalNow: () => atMinute(9),
    );
    addTearDown(w.dispose);
    w.noteWakeAwaitingAck(epoch, path);
    if (path == WakePath.natural) w.noteNaturalRepeat(true);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: NaturalWakeBuzzingCard(wake: w)),
      ),
    );
    return w;
  }

  // I'm up keeps stopping the wake and saving in real I/O after the tap; let
  // that finish before teardown closes the database.
  Future<void> drain(WidgetTester t) =>
      t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));

  Future<void> tapImUp(WidgetTester t) async {
    expect(find.byKey(const ValueKey('natural-wake-im-up')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('natural-wake-im-up')));
    await t.pumpAndSettle();
    expect(find.text('How did you wake up?'), findsOneWidget);
    for (final option in ['From a dream', 'Normally', 'Skip']) {
      expect(find.text(option), findsOneWidget);
    }
  }

  for (final path in WakePath.values) {
    testWidgets('I\'m up asks the dream question for $path wakes', (t) async {
      await pump(t, path);
      await tapImUp(t);
    });
  }

  for (final answer in [DreamAnswer.dream, DreamAnswer.normal]) {
    testWidgets('selecting $answer writes the answer on this wake ack', (
      t,
    ) async {
      await t.runAsync(() async {
        await const DbWakeTraceStore().append(
          row('natural', -20, {'reason': 'fire'}),
        );
        await const DbWakeTraceStore().append(row('ack', 8));
      });
      await pump(t, WakePath.natural);
      await tapImUp(t);
      await t.runAsync(() async {
        await t.tap(
          find.text(answer == DreamAnswer.dream ? 'From a dream' : 'Normally'),
        );
      });
      await t.pumpAndSettle();
      final night = await t.runAsync(
        () => const DbWakeJournal().forEpoch(epoch),
      );
      expect(night?.dream?.answer, answer);
      expect(night?.dream?.path, WakePath.natural);
      expect(night?.dream?.at, atMinute(9));
    });
  }

  testWidgets('Skip closes the question without writing an answer', (t) async {
    await t.runAsync(() => const DbWakeTraceStore().append(row('ack', 8)));
    await pump(t, WakePath.natural);
    await tapImUp(t);
    await t.tap(find.text('Skip'));
    await t.pumpAndSettle();
    expect(find.text('How did you wake up?'), findsNothing);
    final ack = await t.runAsync(() => const DbWakeTraceStore().forWake(epoch));
    expect(ack?.single.data, {});
  });

  testWidgets('a later wake asks again after the previous wake was answered', (
    t,
  ) async {
    await t.runAsync(() async {
      await const DbWakeTraceStore().append(
        row('natural', -20, {'reason': 'fire'}),
      );
      await const DbWakeTraceStore().append(row('ack', 8));
    });
    final w = await pump(t, WakePath.natural);
    await tapImUp(t);
    await t.runAsync(() async {
      await t.tap(find.text('Normally'));
      await pumpEventQueue();
    });
    await t.pumpAndSettle();
    w.noteNaturalRepeat(false);
    w.noteWakeAwaitingAck(epoch + 86400, WakePath.natural);
    w.noteNaturalRepeat(true);
    await t.pump();
    await tapImUp(t);
    await drain(t);
  });

  testWidgets(
    'the real alarm event exposes an I\'m up question even with Natural off',
    (t) async {
      final app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      app.debugWakeClock = () => atMinute(1);
      app.debugHandleAlarmEvent(57, ts: epoch);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: NaturalWakeBuzzingCard(wake: app.wake)),
        ),
      );
      await tapImUp(t);
      await drain(t);
    },
  );

  testWidgets('the real Home snooze I\'m up path asks too', (t) async {
    final app = AppState.forTesting(engine: FakeAlarmEngine());
    addTearDown(app.dispose);
    app.debugWakeClock = () => atMinute(1);
    app.debugSnoozeConfirmedWake = () async => false;
    app.debugSnoozeEvidence = (_, _) async {};
    app.debugSnoozePlay = (_, {notes, onFirstWrite}) async => true;
    await t.runAsync(() async {
      await app.setSnoozeSettings(const SnoozeSettings(enabled: true));
      app.debugHandleAlarmEvent(57, ts: epoch);
      await app.debugOnHapticsTerminated(
        'expired',
        at: atMinute(1),
        bandAt: atMinute(1),
      );
    });
    await t.pumpWidget(
      perfApp(
        app,
        Builder(builder: (c) => snoozeCardFor(c) ?? const SizedBox.shrink()),
      ),
    );
    expect(find.byKey(const ValueKey('snooze-im-up')), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('snooze-im-up')));
    });
    await t.pumpAndSettle();
    expect(find.text('How did you wake up?'), findsOneWidget);
    await drain(t);
  });
}
