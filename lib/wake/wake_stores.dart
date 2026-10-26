import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../data/db.dart';
import 'wake_settings.dart';

class DbWakeStateStore {
  const DbWakeStateStore();

  Future<Map<String, Object?>?> load() async {
    final db = await LocalDb.instance;
    final rows = await db.query('wake_meta', columns: ['value'],
        where: 'key = ?', whereArgs: ['run_state']);
    if (rows.isEmpty) return null;
    try {
      final state = jsonDecode(rows.single['value'] as String);
      return state is Map<String, dynamic> ? state : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> save(Map<String, Object?> state) async {
    final value = jsonEncode(state);
    final db = await LocalDb.instance;
    await db.insert('wake_meta', {'key': 'run_state', 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

class DbWakeSettingsStore {
  const DbWakeSettingsStore();
  Future<WakeSettings> load() async {
    final db = await LocalDb.instance;
    final rows = await db.query('wake_meta', columns: ['value'],
        where: 'key = ?', whereArgs: ['settings']);
    if (rows.isEmpty) return const WakeSettings();
    try {
      return WakeSettings.fromJson(
          (jsonDecode(rows.single['value'] as String) as Map).cast<String, Object?>());
    } on FormatException {
      return const WakeSettings();
    } on ArgumentError {
      return const WakeSettings();
    } on TypeError {
      return const WakeSettings();
    }
  }

  Future<void> save(WakeSettings settings) async {
    settings.validate();
    final value = jsonEncode(settings.toJson());
    final db = await LocalDb.instance;
    await db.insert('wake_meta', {'key': 'settings', 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
