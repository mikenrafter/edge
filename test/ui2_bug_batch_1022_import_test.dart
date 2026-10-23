// RED (owner UI feedback 2026-10-22, B9; Sol r2 P2 on welcome.dart runImport).
//
// Scenario: an earlier import's coach-key warning was dismissed (its ack is
// stored) and nothing is unfinished. A new import starts; clearing that ack
// FAILS (runImport swallows the error). The new backup also needs the coach
// key, but `add()` excludes it because of the stale ack, so the warning shows
// in the immediate report and is gone after leaving the page or restarting.
//
// Expected: a fresh import whose reset failed bypasses acks for its own add(),
// so its warning is stored durably. (The fix may live in ImportReentryStore
// or AppState; this test drives the same calls runImport makes.)
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/import_reentry_store.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _prefKey = 'import_reentry_pending';
const _name = 'import_bug_batch_1022.db';

class _FlakyStore extends SharedPreferencesStorePlatform {
  _FlakyStore(Map<String, Object> data)
      : _inner = InMemorySharedPreferencesStore.withData(data);
  final InMemorySharedPreferencesStore _inner;
  bool refuse = false;
  @override
  Future<bool> clear() => _inner.clear();
  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();
  @override
  Future<bool> remove(String key) async =>
      refuse && key.endsWith(_prefKey) ? false : _inner.remove(key);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      refuse && key.endsWith(_prefKey)
          ? false
          : _inner.setValue(valueType, key, value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_name));
  tearDown(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferences.resetStatic();
    await deriveDbTearDown(_name);
  });

  Future<_FlakyStore> armStore() async {
    final store =
        _FlakyStore({'flutter.$_prefKey': ';$kNeedsReentryCoachKey'});
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    return store;
  }

  test('store: a failed reset does not let a stale ack hide the new import\'s '
      'own warning, even after a restart', () async {
    final store = await armStore();
    final s = ImportReentryStore();
    store.refuse = true;
    // What runImport does: begin, swallow the failure.
    try {
      await s.beginFreshImport();
    } catch (_) {}
    store.refuse = false;
    await s.add([kNeedsReentryCoachKey]); // the new backup needs the key too
    expect(s.pending.value, [kNeedsReentryCoachKey],
        reason: 'shown in the immediate report');

    // Leave the page / restart: a new store reads what was persisted.
    final restarted = ImportReentryStore();
    await restarted.load();
    expect(restarted.pending.value, [kNeedsReentryCoachKey],
        reason: 'the warning must be stored, not only reported once');
  });

  test('app: the same through AppState, as runImport calls it', () async {
    final store = await armStore();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    store.refuse = true;
    try {
      await app.beginFreshImport();
    } catch (_) {}
    store.refuse = false;
    await app.addImportReentry([kNeedsReentryCoachKey]);
    expect(app.importReentry.value, [kNeedsReentryCoachKey]);

    final restarted = AppState.forTesting();
    addTearDown(restarted.dispose);
    await restarted.loadImportReentry();
    expect(restarted.importReentry.value, [kNeedsReentryCoachKey]);
  });
}
