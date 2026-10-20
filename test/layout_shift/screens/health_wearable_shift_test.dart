// Health cold open on an install with an active wearable: the wearable card is
// part of the overview read, so it is in its final place when the overview
// lands and nothing around it moves. Fake-async pumps only.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/as_of_recalc_fakes.dart';
import '../../support/shift_run.dart';
import '../../support/tabs_consistency_fakes.dart';

class _Repo extends TabsRepo {
  _Repo(super.today);
  @override
  Future<Map<String, dynamic>> getTodayStored() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return super.getTodayStored();
  }

  @override
  Future<WearableDay?> wearableDay(String date) async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    return (
      adapterId: 'garmin',
      cells: {
        'resting_hr': {'class': 'ours', 'value': 52, 'method': 'hr_1min'},
        'hrv': {'class': 'device', 'value': 48, 'method': 'device'},
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

  testWidgets('Health cold open with an active wearable: the card does not land late',
      (t) async {
    phoneSurface(t);
    final app = AppState.forTesting()
      ..repo = _Repo(homeBundle(
          readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    addTearDown(app.dispose);
    final run = ShiftRun(t);
    await t.pumpWidget(perfApp(app, const HealthScreen()));
    run.opened();
    await run.frames();
    await t.pump(const Duration(seconds: 5));
    expect(find.byType(WearableCellsCard), findsOneWidget);
    final r = run.score();
    run.expectNoErrors('health cold open, wearable');
    expect(r.warnings, isEmpty);
    expect(r.total, lessThan(0.05), reason: 'the card starts in its place');
  });
}
