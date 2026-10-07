import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the key is the documented one', () {
    expect(Prefs.exploreWakeOutcomes, 'explore.wake_outcomes');
  });

  test('default off, on only when set', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    expect(Prefs.exploreWakeOutcomesOn, isFalse);
    Prefs.setBool(Prefs.exploreWakeOutcomes, true);
    expect(Prefs.exploreWakeOutcomesOn, isTrue);
  });
}
