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
  bool refuse = false; // the main value
  bool refuseStale = false; // the stale-set value
  bool failReads = false; // every read throws
  bool _no(String key) =>
      (refuse && key.endsWith(_prefKey)) ||
      (refuseStale && key.endsWith('import_reentry_stale'));
  @override
  Future<bool> clear() => _inner.clear();
  @override
  Future<Map<String, Object>> getAll() async {
    if (failReads) throw StateError('prefs unreadable');
    return _inner.getAll();
  }

  @override
  Future<bool> remove(String key) async =>
      _no(key) ? false : _inner.remove(key);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _no(key) ? false : _inner.setValue(valueType, key, value);
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

  // Sol r1 P2 #1: the bypass is for THIS import's own warnings until the user
  // dismisses them; a dismissal must stay dismissed.
  test('store: after a failed reset, add -> dismiss -> add (a retry) keeps the '
      'warning dismissed', () async {
    final store = await armStore();
    final s = ImportReentryStore();
    store.refuse = true;
    try {
      await s.beginFreshImport();
    } catch (_) {}
    store.refuse = false;
    await s.add([kNeedsReentryCoachKey]);
    expect(s.pending.value, [kNeedsReentryCoachKey]);
    await s.dismiss();
    expect(s.pending.value, isEmpty);
    await s.add([kNeedsReentryCoachKey]); // the import retries its summary
    expect(s.pending.value, isEmpty, reason: 'the user dismissed it');
    final restarted = ImportReentryStore();
    await restarted.load();
    expect(restarted.pending.value, isEmpty);
  });

  // Sol r1 P2 #2: the process dies after the failed reset and before the first
  // add. The resumed summary's add() must still show the fresh import's
  // warning, whether or not the reset can be retried yet.
  for (final stillRefusing in [true, false]) {
    test('store: restart BEFORE the first add (writes ${stillRefusing ? 'still '
        'refused' : 'working again'}) still shows the new warning', () async {
      final store = await armStore();
      final first = ImportReentryStore();
      store.refuse = true;
      try {
        await first.beginFreshImport();
      } catch (_) {}
      // The process dies here. A fresh store is what the restart builds.
      SharedPreferences.resetStatic();
      store.refuse = stillRefusing;
      final restarted = ImportReentryStore();
      await restarted.load(); // launch: retries the owed reset
      store.refuse = false;
      await restarted.add([kNeedsReentryCoachKey]); // resumed summary
      expect(restarted.pending.value, [kNeedsReentryCoachKey]);
      final again = ImportReentryStore();
      await again.load();
      expect(again.pending.value, [kNeedsReentryCoachKey]);
    });
  }

  // Sol r2 P2 #1: dismissing must be safe against a refused or interrupted
  // stale-set write. The stale id is removed FIRST and strictly; a failure
  // throws and the dismissal is not applied.
  test('store: a refused stale-set write fails the dismissal, never half-applies '
      'it', () async {
    final store = await armStore();
    final s = ImportReentryStore();
    store.refuse = true;
    try {
      await s.beginFreshImport();
    } catch (_) {}
    store.refuse = false;
    await s.add([kNeedsReentryCoachKey]);
    store.refuseStale = true;
    var threw = false;
    try {
      await s.dismiss();
    } catch (_) {
      threw = true;
    }
    store.refuseStale = false;
    expect(threw, isTrue, reason: 'a failure is retried once, then thrown');
    await s.add([kNeedsReentryCoachKey]); // the import retries its summary
    final again = ImportReentryStore();
    await again.load();
    // Either the dismissal did not happen (still pending) or it fully did
    // (stays dismissed): never dismissed-but-bypassable.
    expect(again.pending.value, [kNeedsReentryCoachKey]);
    await s.dismiss(); // the user tries again, now it works
    await s.add([kNeedsReentryCoachKey]);
    expect(s.pending.value, isEmpty);
    final last = ImportReentryStore();
    await last.load();
    expect(last.pending.value, isEmpty);
  });

  test('store: a crash between the two dismissal writes loses nothing and '
      'deletes no live acknowledgement', () async {
    final store = await armStore();
    final s = ImportReentryStore();
    store.refuse = true;
    try {
      await s.beginFreshImport();
    } catch (_) {}
    store.refuse = false;
    await s.add([kNeedsReentryCoachKey]);
    store.refuse = true; // the stale id goes first; the main write then dies
    try {
      await s.dismiss();
    } catch (_) {}
    store.refuse = false;
    SharedPreferences.resetStatic();
    final restarted = ImportReentryStore();
    await restarted.load();
    expect(restarted.pending.value, [kNeedsReentryCoachKey],
        reason: 'the dismissal never landed, so the warning is still due');
    await restarted.dismiss();
    await restarted.add([kNeedsReentryCoachKey]);
    expect(restarted.pending.value, isEmpty);
  });

  // Sol r2 P2 #2: the first read can fail before the stale ids are recorded.
  test('store: a failed initial read still lets the fresh import\'s warning '
      'through, and the bypass respects a later dismissal', () async {
    final store = await armStore();
    await SharedPreferences.getInstance();
    final s = ImportReentryStore();
    store.failReads = true;
    try {
      await s.beginFreshImport();
    } catch (_) {}
    store.failReads = false; // prefs recover
    await s.add([kNeedsReentryCoachKey]);
    expect(s.pending.value, [kNeedsReentryCoachKey]);
    final restarted = ImportReentryStore();
    await restarted.load();
    expect(restarted.pending.value, [kNeedsReentryCoachKey],
        reason: 'persisted once prefs recovered');
    await s.dismiss();
    await s.add([kNeedsReentryCoachKey]);
    expect(s.pending.value, isEmpty, reason: 'a dismissal stays dismissed');
  });
}
