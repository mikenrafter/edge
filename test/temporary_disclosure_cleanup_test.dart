// CLAIM temporary-disclosure: old per-event/subactivity preferences are removed
// on launch while a real section's saved collapsed choice survives.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'startup cleans temporary identities and preserves saved sections',
    () async {
      SharedPreferences.setMockInitialValues({
        'accordion_moment-group:123:wake': true,
        'accordion_track-sub:track:tea': true,
        'accordion_sleep_night': false,
      });
      await Prefs.ensureLoaded();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'accordion_sleep_night'});
      expect(Prefs.getBool('accordion_sleep_night', true), isFalse);
    },
  );
}
