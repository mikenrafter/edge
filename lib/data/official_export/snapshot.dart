// Captures portable preferences/files around the SQL snapshot. A changed owner
// makes this attempt fail instead of silently mixing boundary states.
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../backup_extras.dart';
import '../db.dart';
import '../../settings/settings_repository.dart';
import 'mapper.dart';
import 'profile.dart';

class StrictOfficialSnapshot implements OfficialSnapshot {
  const StrictOfficialSnapshot();
  @override
  Future<String> capture(String destinationPath) =>
      captureStrictOfficialSnapshot(destinationPath);
}

Future<Map<String, Object?>> _extrasBoundary() async {
  final sp = await SharedPreferences.getInstance();
  await sp.reload();
  if (sp.containsKey(SettingsRepository.journalKey)) {
    throw StateError('Resolve the pending settings recovery before exporting');
  }
  final keys = sp.getKeys().where(prefsKeyBackedUp).toList()..sort();
  final docs = await getApplicationDocumentsDirectory();
  final files = <String, String>{};
  final roots = [docs, Directory('${docs.path}/device_lab/imu')];
  for (final root in roots) {
    if (!await root.exists()) continue;
    await for (final e in root.list(followLinks: false)) {
      final name = e.path.split('/').last;
      if (root != docs && name.endsWith('.part')) {
        throw StateError(
          'Finish the active Device lab recording before exporting',
        );
      }
      if (e is! File) continue;
      final approved = root == docs
          ? RegExp(r'^coach_(s|idx)_[A-Za-z0-9_-]{1,120}\.json$').hasMatch(name)
          : RegExp(r'^[A-Za-z0-9_-]{1,80}\.jsonl$').hasMatch(name);
      if (approved) files[e.path] = await exportFileHash(e.path);
    }
  }
  final paths = files.keys.toList()..sort();
  return {
    'prefs': {for (final key in keys) key: sp.get(key)},
    'files': {for (final path in paths) path: files[path]},
  };
}

Future<String> captureStrictOfficialSnapshot(String destinationPath) async {
  await SettingsRepository.instance.waitUntilIdle();
  final db = await LocalDb.instance;
  if ((await db.query(
    'sessions',
    columns: ['id'],
    where: "status='live'",
    limit: 1,
  )).isNotEmpty) {
    throw StateError('Finish the active workout before exporting');
  }
  final before = await _extrasBoundary();
  final path = await LocalDb.exportCopy(
    includeSubstrateArchive: true,
    extras: BackupExtras.all,
    strictExtras: true,
    destinationPath: destinationPath,
  );
  final after = await _extrasBoundary();
  if (jsonEncode(before) != jsonEncode(after)) {
    throw StateError(
      'Settings or saved files changed during the snapshot. Retry after the edit finishes.',
    );
  }
  return path;
}
