// Home cold open on an install with an active wearable: the wearable card is
// part of the day read, so it is in its final place when the day lands and
// neither it nor the rings under it move. Fake-async pumps only.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';

class _WearableHomeRepo extends HomeRepo {
  _WearableHomeRepo(super.today);
  @override
  Future<Map<String, dynamic>> getToday() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return super.getToday();
  }

  @override
  Future<WearableDay?> wearableDay(String date) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return (
      adapterId: 'garmin',
      cells: {
        'resting_hr': {'class': 'ours', 'value': 52, 'method': 'hr_1min'},
        'steps': {'class': 'device', 'value': 4200, 'method': 'device'},
      }
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Home cold open with an active wearable: the card does not land late',
      (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = _WearableHomeRepo(homeBundle(
          readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    run.opened();
    await run.frames();
    await t.pump(const Duration(seconds: 5));
    expect(find.byType(WearableCellsCard), findsOneWidget);
    final r = run.score();
    run.expectNoErrors('home cold open, wearable');
    // Plain Home cold open scores 0.018; a card landing late was 0.26.
    expect(r.warnings, isEmpty);
    expect(r.total, lessThan(0.05), reason: 'the card starts in its place');
  });
}
