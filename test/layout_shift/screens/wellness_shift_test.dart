// Layout shift budget on Wellness: open (loading -> content). Measurement.
import 'package:flutter_test/flutter_test.dart';
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
    await run.frames();
    await t.pump(const Duration(seconds: 3));
    run.expectNoErrors('wellness open');
  });
}
