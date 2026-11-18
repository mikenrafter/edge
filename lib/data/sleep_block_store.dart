// Owner: SleepBlockStore owns sleep assertions. Callers supply the executor;
// storage errors propagate so the caller's transaction rolls back.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqflite/sqflite.dart';
import '../compute/nap_edits.dart';
import 'sleep_editor.dart';
import 'sleep_import_rules.dart';

enum AbsorbMode { backfill, importFile }

abstract final class SleepBlockStore {
  static Future<List<SleepImportEntry>> absorb(DatabaseExecutor tx, {
    required List<Map<String,Object?>> overrides,
    required List<Map<String,Object?>> naps,
    Iterable<Map<String,Object?>> servedDayResults = const [],
    List<Map<String,Object?>> blocks = const [],
    required AbsorbMode mode,
  }) async => [];
  static Future<void> backfill(DatabaseExecutor tx) async {}
  static Future<List<SleepBlock>> live(DatabaseExecutor tx,int fromSec,int toSec) async => [];
  static Future<SleepEditorRead> read(DatabaseExecutor tx,String day) async => SleepEditorRead(
    dayId:day,entries:const [],revision:null,draftGeneration:0);
  static Future<List<NapEdit>> napEdits(DatabaseExecutor tx,String day) async => [];
  static Future<void> _project(DatabaseExecutor tx,Set<String> ownerDays) async {}
  @visibleForTesting
  static Future<void> projectForTest(DatabaseExecutor tx,Set<String> ownerDays) => _project(tx,ownerDays);
}
