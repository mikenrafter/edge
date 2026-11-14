// WHY: pilot loaders that do not all use InlineLoading still need reserved
// geometry. Catches: a blank wearable page, false zero pending count, or a
// short Explorer loader expanding into a full chart after a slow read.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../backup/backup_support.dart';
import '../../support/as_of_recalc_fakes.dart';
import '../../support/live_guide_harness.dart';
import '../../support/shift_run.dart';
import '../../support/skeleton_fixture.dart' show skLoadAppFonts;

class _ReadRepo extends GuideFakeRepo {
  final gate = Completer<void>();
  @override
  Future<int> pendingActivityCount() async { await gate.future; return 2; }
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    await gate.future;
    return MetricRepo().getChart(metric, from: from, to: to, signals: signals);
  }
}

void check(ShiftRun run, String name) {
  final report = run.score(ShiftPolicy.standard.copyWith(loadWeight: 0, colorWeight: 0));
  debugPrint(formatShiftReport(name, report, run.probe.frames.length));
  for (final finding in report.findings.where((f) => f.rule == 'shift')) {
    expect(finding.score, lessThan(0.002), reason: '$name: ${finding.elementId}');
  }
  expect(report.total, lessThan(0.016), reason: name);
}

Future<void> landed(ShiftRun run) async {
  for (var i = 0; i < 30; i++) {
    await run.t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await run.frames([16]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async {
    await skLoadAppFonts();
    env = await BackupEnv.create('pilot_secondary.db');
    await LocalDb.instance;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(kExploreMetricsPref, 'resting_hr');
  });
  tearDownAll(() => env.dispose());

  for (final screen in <String, Widget>{
    'review doorway': const DetectedActivitiesCard(),
    'Explorer': const ExplorerScreen(),
  }.entries) {
    testWidgets('${screen.key} delayed read reserves its content', (t) async {
      phoneSurface(t);
      final repo = _ReadRepo();
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      final run = ShiftRun(t);
      await t.pumpWidget(perfApp(app, screen.value));
      run.opened();
      await run.frames([0, 150, 2500]);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (screen.key == 'review doorway') {
        final semantics = t.ensureSemantics();
        try {
          await t.pump();
          expect(find.bySemanticsLabel(RegExp('Breakdown of your day')), findsNothing,
            reason: 'an unknown pending count must not announce zero pending items');
        } finally { semantics.dispose(); }
      }
      repo.gate.complete();
      await landed(run);
      check(run, screen.key);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    });
  }

  testWidgets('wearable day has a full pending body before cells arrive', (t) async {
    phoneSurface(t);
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, ValueListenableBuilder<bool>(valueListenable: ready,
      builder: (_, loaded, _) => WearableDayView(device: 'Watch', loaded: loaded,
        hasDay: false))));
    run.opened();
    await run.frames([0, 150, 2500]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    ready.value = true;
    await run.frames([0, 16, 100]);
    check(run, 'wearable day');
  });

  testWidgets('legacy moment review waits for SQLite without an empty-state flash', (t) async {
    phoneSurface(t);
    final gate = Completer<void>(), started = Completer<void>();
    late Future<void> lock;
    await t.runAsync(() async {
      final db = await LocalDb.instance;
      lock = db.transaction((txn) async { started.complete(); await gate.future; });
      await started.future;
    });
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const MomentReviewEditor()));
    run.opened();
    await run.frames([0, 150, 2500]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await t.runAsync(() async { gate.complete(); await lock; });
    await landed(run);
    check(run, 'legacy moment review');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });
}
