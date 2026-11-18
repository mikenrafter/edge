// Owns conversion of a closed, immutable snapshot into a private target file.
import 'package:sqflite/sqflite.dart';
import 'prune_cursor.dart';

class OfficialMapReport {
  const OfficialMapReport(this.path, this.cursor, this.tables);
  final String path;
  final PrunedBeforeChoice cursor;
  final Map<String, Object?> tables;
}

Future<OfficialMapReport> mapOfficialSnapshot({
  required String snapshotPath,
  required String outputPath,
  DatabaseFactory? factory,
  LocalCalendar calendar = const DayLabelCalendar(),
}) async => OfficialMapReport(outputPath,
    const PrunedBeforeChoice(null, PrunedBeforeReason.noForkCursor), const {});

Future<int?> oldestMappedExactSec(DatabaseExecutor db) async => null;
