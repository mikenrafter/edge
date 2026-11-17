// WHY: these loaders are reached by navigation or OS/database replies rather
// than the main metric repository. Measure their real routes and late replies.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/snooze_settings_rows.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import '../../backup/backup_support.dart';
import '../../support/as_of_recalc_fakes.dart';
import '../../support/fake_alarm_engine.dart';
import '../../support/live_guide_harness.dart';
import '../../support/shift_run.dart';
import '../../support/pilot_shots.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;
import 'pilot_secondary_shift_test.dart' show check, landed;

class _PrivateRepo extends GuideFakeRepo {
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String day) =>
      LocalDb.journalMetricsForDay(day);
  final workout = Completer<Map<String, dynamic>>();
  int workoutReads = 0;
  @override
  Future<Map<String, dynamic>> getRecords() async => const {
    'workouts_tracked': 1,
  };
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => kJournalFields;
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];
  @override
  Future<Map<String, dynamic>> getWorkout(String id) {
    workoutReads++;
    return workout.future;
  }
}

Widget _app(AppState app, Widget child) => pilotShot(
  ChangeNotifierProvider<UnitsController>(
    create: (_) => UnitsController.seed(UnitSystem.metric),
    child: perfApp(app, child, brightness: Brightness.dark),
  ),
);

Finder _scroll() => find
    .descendant(
      of: find.byType(ListView).first,
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    await skLoadAppFonts();
    env = await BackupEnv.create('pilot_private_routes.db');
    await LocalDb.instance;
  });
  setUp(() async {
    await Prefs.ensureLoaded();
  });
  tearDownAll(() => env.dispose());

  testWidgets(
    'historical summary reserves its archetype while its bundle waits',
    (t) async {
      phoneSurface(t);
      final repo = _PrivateRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(_app(app, const WorkoutScreen()));
      final setup = ShiftRun(t);
      await landed(setup);
      await t.tap(find.text('History'));
      await landed(setup);
      final running = find.text('Running').last;
      expect(running, findsOneWidget);
      await t.ensureVisible(running);
      await t.tap(running);
      await t.pump(const Duration(milliseconds: 350));
      await settle(
        t,
        until: () => repo.workoutReads == 1,
        what: 'the historical bundle query has started',
      );
      final run = ShiftRun(t, skipCoveredRoutes: true)..opened();
      await run.frames([0, 150, 200, 216, 466, 2500]);
      final spinners = find.byType(CircularProgressIndicator).evaluate().length;
      expect(repo.workoutReads, 1);
      await takePilotShot(t, 'historical-workout');
      repo.workout.complete({});
      await landed(run);
      expect(spinners, 0);
      check(run, 'historical summary');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('weight trend opens with a full chart placeholder', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _PrivateRepo();
    addTearDown(app.dispose);
    await t.runAsync(() async {
      await LocalDb.putJournalMetrics(yesterdayId, {
        'weight_kg': const JournalMetricValue(71),
      });
      await LocalDb.putJournalMetrics(todayId, {
        'weight_kg': const JournalMetricValue(72),
      });
    });
    await t.pumpWidget(_app(app, const JournalCompose()));
    final setup = ShiftRun(t);
    await landed(setup);
    final trend = find.byWidgetPredicate(
      (w) => w is Pressable && w.semanticLabel == 'See the weight trend',
    );
    expect(trend, findsOneWidget);
    await t.ensureVisible(trend);
    await t.tap(trend);
    await t.pump(const Duration(milliseconds: 350));
    final run = ShiftRun(t, skipCoveredRoutes: true)..opened();
    await run.frames([0, 150, 200, 216, 466, 2500]);
    final spinners = find.byType(CircularProgressIndicator).evaluate().length;
    await takePilotShot(t, 'weight-trend');
    await landed(run);
    check(run, 'weight trend');
    expect(spinners, 0);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('alarm exact-timing reply keeps the snooze rows in place', (
    t,
  ) async {
    phoneSurface(t);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final answer = Completer<bool>();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'canScheduleExactNotifications'
                ? answer.future
                : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final app = AppState.forTesting(engine: FakeAlarmEngine());
      addTearDown(app.dispose);
      await t.runAsync(
        () => app.setSnoozeSettings(const SnoozeSettings(enabled: true)),
      );
      // Android's elastic drag is a user gesture, outside the OS-reply phase.
      await t.pumpWidget(_app(app, ScrollConfiguration(
        behavior: const MaterialScrollBehavior().copyWith(overscroll: false,
          physics: const ClampingScrollPhysics()),
        child: const AlarmScreen())));
      // Drain unrelated preference/trace reads; the OS permission reply above
      // remains held, so this phase measures that reply alone.
      await landed(ShiftRun(t));
      await t.scrollUntilVisible(
        find.byType(SnoozeSettingsRows),
        300,
        scrollable: _scroll(),
      );
      // Stop the setup scroll before measuring the delayed OS reply.
      final position = t.state<ScrollableState>(_scroll()).position;
      position.jumpTo(position.pixels.clamp(position.minScrollExtent, position.maxScrollExtent));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      final run = ShiftRun(t, skipCoveredRoutes: true)..opened();
      await run.frames([0, 150, 200, 216, 466, 2500]);
      await takePilotShot(t, 'alarm-capability');
      answer.complete(false);
      await landed(run);
      expect(find.byKey(const ValueKey('snooze-exact-note')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      check(run, 'alarm exact timing');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('alarm trace read reserves several decision lines', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting(engine: FakeAlarmEngine());
    addTearDown(app.dispose);
    final epoch = DateTime(2026, 11, 14, 7).millisecondsSinceEpoch ~/ 1000;
    app.device.alarmEpoch = epoch;
    await t.pumpWidget(_app(app, const AlarmScreen()));
    final setup = ShiftRun(t);
    await landed(setup);
    final timeline = find.text('Timeline and status');
    await t.scrollUntilVisible(timeline, 300, scrollable: _scroll());
    final decision = find.text('Last wake decision').first;
    if (decision.evaluate().isEmpty) {
      await t.tap(timeline);
      await landed(setup);
    }
    await t.scrollUntilVisible(decision, 200, scrollable: _scroll());
    // The expanded trace appends unknown decision lines at its end.
    await landed(setup);
    await t.pumpAndSettle(); // finish the setup scroll and initial trace read
    final beforeHeader = t.getTopLeft(decision);
    final run = ShiftRun(t, trackUnkeyed: false)..opened();
    await run.frames([0, 150, 200, 216, 466, 2500]);
    await takePilotShot(t, 'alarm-trace');
    await t.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        await LocalDb.appendWakeTrace(
          wakeEpochSec: epoch,
          atMs: i,
          kind: 'fallback',
          dataJson: jsonEncode({
            'armed': true,
            'confirmed': true,
            'rearmed': false,
          }),
        );
      }
      app.wake.noteTraceChanged();
    });
    await landed(run);
    expect(find.textContaining('armed and confirmed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(t.getTopLeft(decision), beforeHeader);
    debugPrint(formatShiftReport('alarm trace end growth', run.score(), run.probe.frames.length));
    expect(find.descendant(of: find.byKey(const ValueKey('alarm-trace-slot')),
      matching: find.byType(Scrollable)), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });
}
