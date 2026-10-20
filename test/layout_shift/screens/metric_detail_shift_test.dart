// Layout shift budget on MetricDetail: open (loading -> chart) then switching a
// range chip (an Interaction on the chip). Measurement test.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';

/// Chart reads answer after a fixed fake-clock delay, like a database read.
class _SlowMetricRepo extends MetricRepo {
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return super.getChart(metric, from: from, to: to, signals: signals);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('MetricDetail open, then switch to 7 days', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowMetricRepo();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
    run.opened();
    await run.frames(); // open: loading -> data
    await t.pump(const Duration(seconds: 3));
    await run.tap(find.text('7 days')); // range chip
    await t.pump(const Duration(seconds: 3));
    run.expectNoErrors('metric detail open + range chip');
  });

  // Opening alone: the first read lands above the "What moves it" loader and
  // must not carry it down the page (it is a different element, not the first
  // loader moving).
  testWidgets('MetricDetail open: nothing already drawn moves', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowMetricRepo();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
    run.opened();
    await run.frames();
    final r = run.score();
    printOnFailure(formatShiftReport('metric detail open', r, run.probe.frames.length));
    for (final f in r.findings.where((f) => f.rule == 'shift')) {
      expect(f.score, lessThan(0.002), reason: '${f.elementId} @${f.atMs}');
    }
    expect(r.total, lessThan(0.016));
  });
}
