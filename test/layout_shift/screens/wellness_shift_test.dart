// Layout shift budget on Wellness: open (loading -> content). Measurement.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show InlineLoading;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';

class _SlowWellnessRepo extends WellnessRepo {
  @override
  Future<Map<String, dynamic>> getDayStress(String date) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return super.getDayStress(date);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Wellness open: loading -> content', (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()..repo = _SlowWellnessRepo();
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const WellnessScreen()));
    run.opened();
    // SQLite replies need the real event loop. The old static spinner could
    // pass without ever publishing the loaded screen.
    await run.frames([0, 16, 50, 100, 200]);
    await settle(t, until: () => find.byType(InlineLoading).evaluate().isEmpty,
      what: 'Wellness stored reads complete');
    await run.frames([0, 100]);
    run.expectNoErrors('wellness open');
  });
}
