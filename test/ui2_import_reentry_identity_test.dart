// RED (Sol r4, round 5): re-entry notes and acknowledgements are keyed by the
// import RUN that produced them, (runId, itemId). An ack only suppresses the
// same item of the same run, so:
//   * a fresh run is never hidden by an older run's ack, with no reset step to
//     fail, be killed before, or be skipped because an older journal exists;
//   * a resume of the same run keeps the user's dismissal;
//   * a backup that replaces an unfinished journal is a new run;
//   * old-format stored values are "run unknown": their acks match no new run
//     and their pending items stay visible;
//   * a dismissal is one write.
//
// Compile stubs (production, pre-fix behaviour): `add(ids, {runId})` ignores
// the run, and `reentryRunIdOf` returns a constant (lib/data/import_reentry_store.dart).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/import_reentry_store.dart';

const _prefKey = 'import_reentry_pending';
const _x = kNeedsReentryCoachKey;

class _CountingStore extends SharedPreferencesStorePlatform {
  _CountingStore(Map<String, Object> data)
      : _inner = InMemorySharedPreferencesStore.withData(data);
  final InMemorySharedPreferencesStore _inner;
  int writes = 0;
  bool refuse = false;
  @override
  Future<bool> clear() => _inner.clear();
  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();
  @override
  Future<bool> remove(String key) async {
    writes++;
    return refuse ? false : _inner.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    return refuse ? false : _inner.setValue(valueType, key, value);
  }
}

Future<_CountingStore> _arm([Map<String, Object> data = const {}]) async {
  final store = _CountingStore(data);
  SharedPreferencesStorePlatform.instance = store;
  SharedPreferences.resetStatic();
  return store;
}

/// What a restart sees.
Future<ImportReentryStore> _restart() async {
  SharedPreferences.resetStatic();
  final s = ImportReentryStore();
  await s.load();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferences.resetStatic();
  });

  test('run identity: a resume is the same run, a replaced journal is a new one',
      () {
    expect(reentryRunIdOf(7, 1000), reentryRunIdOf(7, 1000));
    expect(reentryRunIdOf(7, 1000), isNot(reentryRunIdOf(8, 2000)));
    expect(reentryRunIdOf(7, 1000), isNot(reentryRunIdOf(7, 2000)));
  });

  test('a fresh run is not hidden by an older run\'s dismissal', () async {
    await _arm();
    final s = ImportReentryStore();
    await s.add([_x], runId: 'A');
    await s.dismiss();
    expect(s.pending.value, isEmpty);
    await s.add([_x], runId: 'B'); // a new backup, same missing key
    expect(s.pending.value, [_x]);
    expect((await _restart()).pending.value, [_x], reason: 'stored, not only shown');
  });

  test('a backup that replaces an unfinished import is a new run', () async {
    await _arm();
    final s = ImportReentryStore();
    await s.add([_x], runId: 'A'); // run A never finished
    await s.dismiss(); // the user dismissed A's note meanwhile
    // The new backup replaces A's journal: a different run, whatever A's state.
    await s.add([_x], runId: 'B');
    expect(s.pending.value, [_x]);
  });

  test('killed before the first add of a new run: the stored ack of an older '
      'run does not hide it', () async {
    await _arm({'flutter.$_prefKey': ';$_x'}); // an older version's ack
    final restarted = await _restart(); // the process died and came back
    await restarted.add([_x], runId: 'B'); // the resumed run records its note
    expect(restarted.pending.value, [_x]);
    expect((await _restart()).pending.value, [_x]);
  });

  test('a resume of the same run keeps the dismissal', () async {
    await _arm();
    final s = ImportReentryStore();
    await s.add([_x], runId: 'A');
    await s.dismiss();
    final restarted = await _restart();
    await restarted.add([_x], runId: 'A'); // the resume records its summary again
    expect(restarted.pending.value, isEmpty);
    expect((await _restart()).pending.value, isEmpty);
  });

  test('old stored formats: pending stays visible, acks match no new run',
      () async {
    await _arm({'flutter.$_prefKey': _x}); // pending-only form
    final s = await _restart();
    expect(s.pending.value, [_x]);
    await s.add([_x], runId: 'B');
    expect(s.pending.value, [_x], reason: 'once, not twice');

    await _arm({'flutter.$_prefKey': ';$_x'}); // pending;acked form, acked only
    final t = await _restart();
    expect(t.pending.value, isEmpty);
    await t.add([_x], runId: 'B');
    expect(t.pending.value, [_x]);
  });

  test('a dismissal is one write, and a refused one changes nothing', () async {
    final store = await _arm();
    final s = ImportReentryStore();
    await s.add([_x], runId: 'A');
    store.writes = 0;
    await s.dismiss();
    expect(store.writes, 1, reason: 'pending and acks live in one value');

    final t = ImportReentryStore();
    await _arm();
    await t.add([_x], runId: 'A');
    final refusing = await _arm({'flutter.$_prefKey': (await SharedPreferences.getInstance()).getString(_prefKey) ?? ''});
    refusing.refuse = true;
    final u = ImportReentryStore();
    await u.load();
    final before = u.pending.value;
    await expectLater(u.dismiss(), throwsA(isA<StateError>()));
    expect(u.pending.value, before, reason: 'not dismissed, so still shown');
  });

  test('a multi-select batch shares one run: a dismissal between two backups '
      'holds for the second', () async {
    await _arm();
    final s = ImportReentryStore();
    await s.batch(() async {
      await s.add([_x], runId: 'journal-1');
      await s.dismiss();
      await s.add([_x], runId: 'journal-2'); // the next file of the same batch
    });
    expect(s.pending.value, isEmpty);
    await s.add([_x], runId: 'journal-3'); // a later, separate import
    expect(s.pending.value, [_x]);
  });

  test('the same run retrying its record step after a dismissal adds nothing',
      () async {
    await _arm();
    final s = ImportReentryStore();
    await s.add([_x], runId: 'A');
    await s.dismiss();
    await s.add([_x], runId: 'A');
    expect(s.pending.value, isEmpty);
  });

  test('overlapping imports do not share a run: B\'s own warning shows after A '
      'dismissed the same item', () async {
    await _arm();
    final s = ImportReentryStore();
    final aDismissed = Completer<void>();
    final release = Completer<void>();
    final a = s.batch(() async {
      await s.add([_x], runId: 'A1');
      await s.dismiss();
      aDismissed.complete();
      await release.future; // A is still open
    });
    await aDismissed.future;
    await s.batch(() async {
      await s.add([_x], runId: 'B1'); // a separate import, same missing key
    });
    expect(s.pending.value, [_x], reason: 'A\'s dismissal is not B\'s');
    release.complete();
    await a;
  });
}
