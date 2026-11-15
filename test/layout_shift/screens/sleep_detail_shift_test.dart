// Layout shift budget on SleepDetail: open, loading -> night data. Measurement.
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';

class _SlowSleepRepo extends SleepRepo {
  final daysRead = <String>[];
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    daysRead.add(date);
    return super.getDaySleepV2(date);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    // Day navigation does not depend on the optional rough-night SQL read.
    Prefs.setString('rough_night.dismissed', todayId);
  });

  testWidgets('SleepDetail open: loading -> night', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowSleepRepo();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, SleepDetail(day: yesterdayId)));
    run.opened();
    await run.frames();
    await t.pump(const Duration(seconds: 3));
    run.expectNoErrors('sleep detail open');
  });

  testWidgets('SleepDetail open on today (no day given)', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowSleepRepo();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const SleepDetail()));
    run.opened();
    await run.frames();
    await t.pump(const Duration(seconds: 3));
    run.expectNoErrors('sleep detail open on today');
  });

  testWidgets('SleepDetail: step to the previous day', (t) async {
    phoneSurface(t);
    final repo = _SlowSleepRepo();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const SleepDetail()));
    await run.frames();
    await settle(t, until: () => find.byWidgetPredicate(
      (w) => w is PendingContent && w.pending).evaluate().isEmpty,
      what: 'the initial night has settled');
    expect(repo.daysRead.last, todayId);
    run.probe.frames.clear(); // the tap phase starts after the cold read
    run.now = 0;
    final prev = find.descendant(of: find.byType(DayNav),
      matching: find.byIcon(LucideIcons.chevronLeft));
    expect(prev, findsOneWidget, reason: 'the day stepper must be on screen');
    await run.tap(prev);
    await t.pump(const Duration(seconds: 3));
    await settle(t, until: () => repo.daysRead.last == yesterdayId,
      what: 'previous night was read');
    run.now += 16;
    run.snap();
    expect(repo.daysRead.last, yesterdayId);
    run.expectNoErrors('sleep detail step to previous day');
  });
}
