// SQLite adapter for WakeNightContext. Decoding and policy run in its worker.
import 'dart:convert';
import 'dart:isolate';

import '../data/db.dart';
import '../data/day_label.dart';
import '../data/journal_fields.dart';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import 'wake_confounders.dart';
import 'wake_night_context.dart';

final sharedWakeNightContext = WakeNightContext(const DbWakeNightSource());

class DbWakeNightSource implements WakeNightSource {
  const DbWakeNightSource();

  @override
  Future<String> revision(DateTime from, DateTime to) async {
    final db = await LocalDb.instance;
    final args = [dayLabelOf(from), dayLabelOf(to)];
    // Content stamp catches same-millisecond edits and deletions too. Bounded
    // to the occurrence's one or two calendar dates, including midnight.
    final j = await db.rawQuery(
      "SELECT group_concat(v, '|') AS rev FROM (SELECT quote(date)||quote(tags_json)||quote(updated_at) AS v FROM journal WHERE date>=? AND date<? ORDER BY date)",
      args,
    );
    final m = await db.rawQuery(
      "SELECT group_concat(v, '|') AS rev FROM (SELECT quote(date)||quote(field)||quote(value)||quote(at_min)||quote(updated_at) AS v FROM journal_metric WHERE date>=? AND date<? ORDER BY date,field)",
      args,
    );
    return '${j.single['rev']}/${m.single['rev']}';
  }

  @override
  Future<ConfounderProfile> profile(
    DateTime from,
    DateTime to,
    DateTime? expectedBedtime,
  ) async {
    final db = await LocalDb.instance;
    final args = [dayLabelOf(from), dayLabelOf(to)];
    final journal = await db.query(
      'journal',
      columns: ['date', 'tags_json'],
      where: 'date>=? AND date<?',
      whereArgs: args,
    );
    final metrics = await db.query(
      'journal_metric',
      columns: ['date', 'field', 'value', 'at_min'],
      where: 'date>=? AND date<?',
      whereArgs: args,
    );
    final input = WakeProfileInput(
      journal,
      metrics,
      expectedBedtime?.millisecondsSinceEpoch,
      WorkerInputs(
        nowEpochMs: from.millisecondsSinceEpoch,
        zoneId: 'UTC',
        localeTag: 'en',
      ),
    );
    return Isolate.run(() => wakeProfileHeavy(input));
  }
}

@SendableShape(
  'SQLite primitive row maps; tested by sendable_wakeProfileHeavy_test',
)
class WakeProfileInput {
  final List<Map<String, Object?>> journal, metrics;
  final int? bedtimeMs;
  final WorkerInputs worker;
  const WakeProfileInput(
    this.journal,
    this.metrics,
    this.bedtimeMs,
    this.worker,
  );
}

@heavy
ConfounderProfile wakeProfileHeavy(WakeProfileInput input) {
  WorkerInit.ensure(input.worker);
  assertWorker();
  return profileFromJournalRows(
    input.journal,
    input.metrics,
    input.bedtimeMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(input.bedtimeMs!),
  );
}

// Bounded to the sleep occurrence's journal dates. Both live policy and outcome
// learning use this decoder so context cannot diverge between the two paths.
ConfounderProfile profileFromJournalRows(
  List<Map<String, Object?>> journal,
  List<Map<String, Object?>> metrics,
  DateTime? bedtime,
) {
  final days = <String, WakeJournalDay>{};
  for (final row in journal) {
    final date = row['date'] as String;
    final tags = jsonDecode(row['tags_json'] as String);
    if (tags is! List || tags.any((v) => v is! String)) {
      throw const FormatException('journal tags');
    }
    days[date] = WakeJournalDay(
      DateTime.parse(date),
      tags.cast<String>().toSet(),
      {},
    );
  }
  for (final row in metrics) {
    final date = row['date'] as String;
    final day = days.putIfAbsent(
      date,
      () => WakeJournalDay(DateTime.parse(date), {}, {}),
    );
    day.metrics[row['field'] as String] = JournalMetricValue(
      (row['value'] as num).toDouble(),
      atMinuteOfDay: (row['at_min'] as num?)?.toInt(),
    );
  }
  return wakeConfounders(days.values.toList(), expectedBedtime: bedtime);
}
