// CLAIM load-estimate: one settled size establishes a baseline; recurrence
// wins over noise, while a lone unusual size cannot jerk the next reservation.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/ui2/skeleton/load_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('presentation memory is bounded, isolated by user, durable and excluded from exports', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    var user='a';
    final memory=LoadMemory(userKey:()=>user,limit:4);
    memory.record('section',100);memory.record('other',200);
    user='b';expect(memory.estimate('section'),isNull);memory.record('section',300);
    user='a';expect(memory.estimate('section'),100);
    memory.record('third',400);memory.record('fourth',500);
    expect(memory.estimate('section'),isNull,reason:'the oldest key must be evicted');
    await Future<void>.value();
    await SettingsRepository.instance.appString(LoadMemory.prefKey);
    final restored=LoadMemory(userKey:()=>user,limit:4);
    expect(restored.estimate('third'),400);
    expect(prefsKeyBackedUp(LoadMemory.prefKey),isFalse);
  });
  test(
    'estimate converges, rejects one outlier and remembers the recurring shape',
    () {
      final size = LoadEstimate();
      size.add(100);
      expect(size.value, 100);
      size.add(500);
      expect(size.value, inInclusiveRange(100, 105));
      for (var i = 0; i < 20; i++) {
        size.add(160);
      }
      expect(size.value, 160);
      expect(size.samples.length, 8);
      size.add(900);
      expect(size.value, 160);
      final lines = LoadEstimate(tolerance: .1);
      for (final n in [3.0, 4.0, 4.0, 3.0, 4.0]) {
        lines.add(n);
      }
      expect(lines.value, 4);
    },
  );
}
