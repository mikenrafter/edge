// RED: the re-entry notes reload after a backup lands is UI bookkeeping. When
// it throws (no binding, any preferences failure) the import and its report
// must stay intact; it used to fail the whole runImport.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

/// Reads fail; the cached SharedPreferences instance's reload() reaches this.
class _ThrowingStore extends SharedPreferencesStorePlatform {
  @override
  Future<Map<String, Object>> getAll() async =>
      throw StateError('prefs read failed');
  @override
  Future<bool> clear() async => true;
  @override
  Future<bool> remove(String key) async => true;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      true;
}

/// A backup that lands 3 days and says one secret needs entering again.
class _LandedBackup extends AppState {
  _LandedBackup() : super.forTesting();

  @override
  Future<int> importEdgeBackup(String path) async {
    lastBackupSummary =
        const ImportSummary(needsReentry: [kNeedsReentryCoachKey]);
    return 3;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a throwing re-entry reload does not fail the import or its report',
      () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance(); // cached; reload() hits the store
    final real = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _ThrowingStore();
    addTearDown(() => SharedPreferencesStorePlatform.instance = real);

    final tmp = await Directory.systemTemp.createTemp('reentry_nonfatal_');
    addTearDown(() => tmp.delete(recursive: true));
    // Not a SQLite file name check: runImport routes on content, so write the
    // SQLite magic and name it as a backup.
    final f = File('${tmp.path}/b.db')
      ..writeAsBytesSync([...'SQLite format 3\x00'.codeUnits, ...List.filled(64, 0)]);

    final out = await runImport(_LandedBackup(), [f.path]);

    expect(out.days, 3);
    expect(out.summary?.needsReentry, [kNeedsReentryCoachKey]);
  });
}
