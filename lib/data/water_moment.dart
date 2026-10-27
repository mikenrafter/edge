// WaterMomentStore owns explicit glass moments. LocalDb serializes its writes
// with journal totals in the same transaction. Storage failures propagate.
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'db.dart';
import 'journal_fields.dart';

class WaterMoment {
  const WaterMoment(this.id, this.date, this.atMin, this.ml);
  final String id, date;
  final int atMin;
  final double ml;
  DateTime get local {
    final d = DateTime.parse(date);
    return DateTime(d.year, d.month, d.day, atMin ~/ 60, atMin % 60);
  }
}

abstract final class WaterMomentStore {
  static Future<void> create(DatabaseExecutor db) => db.execute(
    'CREATE TABLE IF NOT EXISTS water_moment ('
    'id TEXT PRIMARY KEY, date TEXT NOT NULL, at_min INTEGER NOT NULL, '
    'ml REAL NOT NULL CHECK(ml > 0))',
  );

  /// A timestamped increase is an explicit glass. An unchanged total is a
  /// replay, and a total with no clock cannot establish a glass's time.
  static Future<void> recordTotalChange(
    DatabaseExecutor tx,
    String date,
    JournalMetricValue? next,
  ) async {
    final rows = await tx.query(
      'journal_metric',
      columns: ['value'],
      where: 'date = ? AND field = ?',
      whereArgs: [date, 'water_ml'],
    );
    final old = rows.isEmpty ? 0.0 : (rows.single['value'] as num).toDouble();
    final added = (next?.value ?? 0) - old;
    final minute = next?.atMinuteOfDay;
    if (added > 0 && minute != null && minute >= 0 && minute < 1440) {
      await tx.insert('water_moment', {
        'id': const Uuid().v4(),
        'date': date,
        'at_min': minute,
        'ml': added,
      });
    }
    // Corrections reduce the latest explicit moments. No historical glass is
    // invented for the part of an aggregate that has no timestamped record.
    if (added < 0) {
      var left = -added;
      final moments = await tx.query(
        'water_moment',
        where: 'date = ?',
        whereArgs: [date],
        orderBy: 'at_min DESC, rowid DESC',
      );
      for (final row in moments) {
        if (left <= 0) break;
        final ml = (row['ml'] as num).toDouble();
        if (left >= ml) {
          await tx.delete(
            'water_moment',
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        } else {
          await tx.update(
            'water_moment',
            {'ml': ml - left},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
        left -= ml;
      }
    }
  }

  static Future<List<WaterMoment>> forDay(String date) async {
    final rows = await (await LocalDb.instance).query(
      'water_moment',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'at_min ASC, rowid ASC',
    );
    return [
      for (final r in rows)
        WaterMoment(
          r['id'] as String,
          date,
          (r['at_min'] as num).toInt(),
          (r['ml'] as num).toDouble(),
        ),
    ];
  }

  static Future<double?> change(String date, double delta, int atMin) async {
    if (!delta.isFinite || atMin < 0 || atMin >= 1440) {
      throw ArgumentError('water change');
    }
    return (await LocalDb.instance).transaction((tx) async {
      final rows = await tx.query(
        'journal_metric',
        where: 'date = ? AND field = ?',
        whereArgs: [date, 'water_ml'],
      );
      final old = rows.isEmpty ? 0.0 : (rows.single['value'] as num).toDouble();
      final value = delta < 0 && old <= 0
          ? null
          : (old + delta)
                .clamp(0.0, kJournalFieldsByKey['water_ml']!.max)
                .toDouble();
      final next = value == null
          ? null
          : JournalMetricValue(value, atMinuteOfDay: atMin);
      await recordTotalChange(tx, date, next);
      if (next == null) {
        await tx.delete(
          'journal_metric',
          where: 'date = ? AND field = ?',
          whereArgs: [date, 'water_ml'],
        );
      } else {
        await tx.insert('journal_metric', {
          'date': date,
          'field': 'water_ml',
          'value': value,
          'at_min': atMin,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      return value;
    });
  }
}
