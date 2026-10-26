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

  // Natural, Gradual and acknowledgement share one occurrence. Merge inside
  // a transaction so one mode cannot overwrite another mode's checkpoint.
  Future<T> update<T>(int epoch, T Function(Map<String, Object?>) change) async {
    final db = await LocalDb.instance;
    return db.transaction((txn) async {
      final rows = await txn.query('wake_meta', columns: ['value'],
          where: 'key = ?', whereArgs: ['run_state']);
      Map<String, Object?> run = {};
      if (rows.isNotEmpty) {
        try {
          final decoded = jsonDecode(rows.single['value'] as String);
          if (decoded is Map<String, dynamic> && decoded['epoch'] == epoch) {
            run = decoded;
          }
        } on FormatException { /* Start a new checkpoint for corrupt JSON. */ }
      }
      run['epoch'] = epoch;
      for (final key in ['gradualNext', 'naturalNextMs']) {
        if (run[key] is! int) run[key] = 0;
      }
      for (final key in ['acknowledged', 'naturalFired']) {
        if (run[key] is! bool) run[key] = false;
      }
      final result = change(run);
      await txn.insert('wake_meta', {'key': 'run_state', 'value': jsonEncode(run)},
          conflictAlgorithm: ConflictAlgorithm.replace);
      return result;
    });
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
