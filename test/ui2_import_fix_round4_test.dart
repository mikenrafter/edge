// RED: review round 3 of the import notes.
//
//  1. A resume must never clear what is pending or acknowledged: warnings
//     restored from an earlier run stay, and a dismissal made while the resume
//     runs stays dismissed.
//  2. The pending notes are written as part of the import (before the journal
//     is marked done), so a failure after the copy, or a kill, cannot lose
//     them; a write that fails is reported (the import fails and the journal
//     stays unfinished, so the next start retries).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'import_resume/import_resume_support.dart';
import 'support/app_state_derive_harness.dart';

const _prefKey = 'import_reentry_pending';
const _name = 'import_round4.db';

class NoRollup implements ImportRollupProbe {
  @override
  Future<void> finalize(Profile profile) async {}
}

class _Probe implements ImportRollupProbe {
  _Probe({this.during, this.throwing});
  final void Function()? during;
  final Object? throwing;
  @override
  Future<void> finalize(Profile profile) async {
    during?.call();
    if (throwing != null) throw throwing!;
  }
}

/// A source export; [lostKey] adds the marker that says a coach key was set.
Future<String> sourceWith(Directory dir, {required bool lostKey}) async {
  final path = await buildSource(dir);
  if (lostKey) {
    final s = await databaseFactoryFfi.openDatabase(path);
    await s.execute('CREATE TABLE backup_prefs '
        '(key TEXT PRIMARY KEY, type TEXT, value TEXT)');
    await s.insert('backup_prefs',
        {'key': 'coach_api_key_present', 'type': 'bool', 'value': 'true'});
    await s.close();
  }
  return path;
}

Future<void> killMidCopy(String path) async {
  crashAt('decoded_onehz', 2);
  await expectLater(
      LocalDb.importFromDbFile(path), throwsA(isA<StateError>()));
  ImportHooks.chunk = null;
  await LocalDb.close();
}

Future<String?> _stored() async =>
    (await SharedPreferences.getInstance()).getString(_prefKey);

/// Refuses writes to the re-entry key; everything else works.
class _RefusingStore extends SharedPreferencesStorePlatform {
  final _inner = InMemorySharedPreferencesStore.empty();
  @override
  Future<bool> clear() => _inner.clear();
  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();
  @override
  Future<bool> remove(String key) => _inner.remove(key);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      key.endsWith(_prefKey) ? false : _inner.setValue(valueType, key, value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState app;

  setUp(() async {
    await deriveDbSetUp(_name);
    ImportHooks.reset();
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('import_round4_');
    app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugFinalizeImport = _Probe();
  });
  tearDown(() async {
    ImportHooks.reset();
    app.dispose();
    SharedPreferences.setMockInitialValues({});
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    await deriveDbTearDown(_name);
  });

  group('1: a resume never clears', () {
    test('a warning restored from an earlier backup survives the resume of a '
        'later one that has none', () async {
      SharedPreferences.setMockInitialValues({_prefKey: kNeedsReentryCoachKey});
      await app.loadImportReentry();
      expect(app.importReentry.value, [kNeedsReentryCoachKey], reason: 'guard');
      await killMidCopy(await sourceWith(tmp, lostKey: false));
      await app.resumeUnfinishedImport(force: true);
      expect(app.importReentry.value, [kNeedsReentryCoachKey]);
      expect(await _stored(), contains(kNeedsReentryCoachKey));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a dismissal made while the resume runs stays dismissed', () async {
      SharedPreferences.setMockInitialValues({_prefKey: kNeedsReentryCoachKey});
      await app.loadImportReentry();
      app.debugFinalizeImport = _Probe(during: app.dismissImportReentry);
      await killMidCopy(await sourceWith(tmp, lostKey: true));
      await app.resumeUnfinishedImport(force: true);
      expect(app.importReentry.value, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(await _stored() ?? '', isEmpty,
          reason: 'and it is not back at the next start either');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('2: durable as part of the import', () {
    test('a rebuild that throws after the copy still leaves the warning for '
        'the next start', () async {
      app.debugFinalizeImport = _Probe(throwing: StateError('rebuild failed'));
      await killMidCopy(await sourceWith(tmp, lostKey: true));
      await app.resumeUnfinishedImport(force: true);
      final restarted = AppState.forTesting();
      addTearDown(restarted.importProgress.dispose);
      await restarted.loadImportReentry();
      expect(restarted.importReentry.value, [kNeedsReentryCoachKey]);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a refused write is reported: the import fails and stays unfinished',
        () async {
      final path = await sourceWith(tmp, lostKey: true);
      SharedPreferencesStorePlatform.instance = _RefusingStore();
      SharedPreferences.resetStatic();
      addTearDown(SharedPreferences.resetStatic);
      await expectLater(LocalDb.importFromDbFile(path), throwsA(anything),
          reason: 'a warning that cannot be saved must not pass silently');
      expect((await ImportJournal.current())?.state,
          isNot(ImportJournalState.done),
          reason: 'unfinished, so the next start retries');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
