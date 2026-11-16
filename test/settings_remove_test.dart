// why: Home invalidation must delete its durable key through the settings queue,
// preserving rollback and change metadata. CLAIM(home-cache-reset).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The platform seam makes a refused deletion observable.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';

class _RefusedDelete extends InMemorySharedPreferencesStore {
  _RefusedDelete() : super.empty();
  bool refuse = false;
  @override
  Future<bool> remove(String key) async => refuse ? false : super.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'remove deletes the durable key and announces removal without adding a value',
    () async {
      final repo = SettingsRepository.instance;
      await repo.update(
        (d) => d.setString('snapshot', 'private'),
        sections: const {},
      );
      final change = await repo.update(
        (d) => d.remove('snapshot'),
        sections: const {},
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.containsKey('snapshot'), isFalse);
      expect(change.appPrefs, isEmpty);
      expect(change.removedAppPrefs, {'snapshot'});
      expect(change.isEmpty, isFalse);
    },
  );
  test(
    'refused removal restores the previous value and reports failure',
    () async {
      final store = _RefusedDelete();
      SharedPreferencesStorePlatform.instance = store;
      final repo = SettingsRepository.instance;
      await repo.update(
        (d) => d.setString('snapshot', 'private'),
        sections: const {},
      );
      store.refuse = true;
      await expectLater(
        repo.update((d) => d.remove('snapshot'), sections: const {}),
        throwsStateError,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString('snapshot'), 'private');
    },
  );
}
