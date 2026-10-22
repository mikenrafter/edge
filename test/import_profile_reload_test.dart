// After "Delete everything" + a full import the profile was never reloaded:
// `user` stayed null (signOut), so every post-import derive ran without age
// or sex and strain abstained `need_input:name=age`. These pin the reload on
// both import paths, the updateProfile merge, and the quiet-seed re-arm.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/quiet_level_seed.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'import_resume/import_resume_support.dart';
import 'support/app_state_derive_harness.dart';

const _name = 'import_profile_reload_test.db';

class _Probe implements ImportRollupProbe {
  final seen = <Profile>[];
  @override
  Future<void> finalize(Profile profile) async => seen.add(profile);
}

/// buildSource() plus a backup_prefs row carrying a stored profile.
Future<String> _backupWithProfile(Directory dir) async {
  final path = await buildSource(dir);
  final s = await databaseFactoryFfi.openDatabase(path);
  await s.execute('CREATE TABLE backup_prefs '
      '(key TEXT PRIMARY KEY, type TEXT, value TEXT)');
  await s.insert('backup_prefs', {
    'key': 'local_profile_json',
    'type': 'string',
    'value': jsonEncode({'age': 34, 'sex': 'f', 'weight_kg': 61.0}),
  });
  await s.close();
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState app;
  late _Probe probe;

  setUp(() async {
    await deriveDbSetUp(_name);
    ImportHooks.reset();
    tmp = Directory.systemTemp.createTempSync('import_profile_');
    app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    probe = _Probe();
    app.debugFinalizeImport = probe;
  });
  tearDown(() async {
    ImportHooks.reset();
    app.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    await deriveDbTearDown(_name);
  });

  test('importEdgeBackup reloads the restored profile before the rollup',
      () async {
    final path = await _backupWithProfile(tmp);
    expect(app.user, isNull);
    await app.importEdgeBackup(path);
    expect(probe.seen, isNotEmpty);
    expect(probe.seen.single.ageYears, 34);
    expect(probe.seen.single.sex, 'f');
    expect(app.user?['age'], 34);
  });

  test('resumeUnfinishedImport reloads the restored profile too', () async {
    final path = await _backupWithProfile(tmp);
    crashAt('decoded_onehz', 2);
    await expectLater(
        LocalDb.importFromDbFile(path), throwsA(isA<StateError>()));
    ImportHooks.chunk = null;
    await LocalDb.close();
    expect(app.user, isNull);
    await app.resumeUnfinishedImport(force: true);
    expect(probe.seen, isNotEmpty, reason: 'the resume ran the rollup');
    expect(probe.seen.single.ageYears, 34);
    expect(app.user?['sex'], 'f');
  });

  test('updateProfile on a wiped state keeps the restored fields', () async {
    // Prefs hold a profile that this AppState never loaded (user == null).
    SharedPreferences.setMockInitialValues({
      'local_profile_json': jsonEncode({'age': 34, 'sex': 'f'}),
    });
    expect(app.user, isNull);
    final out = await app.updateProfile({'weight_kg': 70.0});
    expect(out['age'], 34);
    expect(out['sex'], 'f');
    expect(out['weight_kg'], 70.0);
    final stored = jsonDecode(
        (await SharedPreferences.getInstance()).getString('local_profile_json')!)
        as Map;
    expect(stored['age'], 34);
  });

  test('an import that brought day_result re-arms the quiet seed', () async {
    await LocalDb.putComputeFreshness(kQuietHrrSeedKey, '{"done":true}');
    final path = await _backupWithProfile(tmp);
    await app.importEdgeBackup(path);
    expect(await LocalDb.computeFreshness(kQuietHrrSeedKey), isNull);
  });

  test('an import with no day_result leaves the quiet seed alone', () async {
    final path = p.join(tmp.path, 'bare.db');
    final s = await databaseFactoryFfi.openDatabase(path);
    await s.execute('CREATE TABLE metric_series '
        '(date TEXT, key TEXT, value REAL)');
    await s.close();
    await LocalDb.putComputeFreshness(kQuietHrrSeedKey, '{"done":true}');
    await app.importEdgeBackup(path);
    expect(await LocalDb.computeFreshness(kQuietHrrSeedKey), isNotNull);
  });
}
