// SQLite adapter for WakeNightContext. Decoding and policy run in its worker.
import 'dart:convert';
import 'dart:isolate';
import 'package:sqflite/sqflite.dart';

import '../data/db.dart';
import '../data/day_label.dart';
import '../data/journal_fields.dart';
import '../data/track_model.dart';
import '../data/track_snapshot.dart';
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
    final t = await db.rawQuery(
      "SELECT group_concat(v, '|') AS rev FROM (SELECT quote(id)||quote(payload_json) AS v FROM track_definition ORDER BY id)",
    );
    final e = await db.rawQuery(
      "SELECT group_concat(v, '|') AS rev FROM (SELECT quote(id)||quote(at_ms)||quote(amount)||quote(sub_activity_id)||quote(unit) AS v FROM track_event_feed WHERE date>=? AND date<? ORDER BY id)",
      args,
    );
    final h = await db.rawQuery(
      "SELECT group_concat(quote(id)||quote(start_date)||quote(end_date)||quote(done), '|') AS rev FROM track_setup_history",
    );
    final med = await db.rawQuery(
      "SELECT group_concat(v, '|') AS rev FROM (SELECT quote(key)||quote(label)||quote(dose_unit)||quote(active) AS v FROM med_def ORDER BY key)",
    );
    final learned = await db.rawQuery(
      "SELECT group_concat(v, '|') AS rev FROM (SELECT quote(key)||quote(value) AS v FROM wake_meta WHERE key LIKE 'natural_wake_user_%' ORDER BY key)",
    );
    return '${j.single['rev']}/${m.single['rev']}/${t.single['rev']}/${e.single['rev']}/${h.single['rev']}/${med.single['rev']}/${learned.single['rev']}';
  }

  @override
  Future<ConfounderProfile> profile(
    DateTime from,
    DateTime to,
    DateTime? expectedBedtime,
  ) async {
    return loadWakeProfile(await LocalDb.instance, from, to, expectedBedtime);
  }
}

Future<ConfounderProfile> loadWakeProfile(
  DatabaseExecutor db,
  DateTime from,
  DateTime to,
  DateTime? bedtime,
) async {
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
  final definitions = await db.query('track_definition');
  final medications = await db.query('med_def');
  final events = await db.query(
    'track_event_feed',
    where: 'date>=? AND date<?',
    whereArgs: args,
  );
  final history = await db.query(
    'track_setup_history',
    where: 'start_date<? AND end_date>=?',
    whereArgs: [args[1], args[0]],
  );
  final userParameters = await db.query(
    'wake_meta',
    where: "key LIKE 'natural_wake_user_%'",
  );
  final input = WakeProfileInput(
    journal,
    metrics,
    bedtime?.millisecondsSinceEpoch,
    WorkerInputs(
      nowEpochMs: from.millisecondsSinceEpoch,
      zoneId: 'UTC',
      localeTag: 'en',
    ),
    definitions: definitions,
    medications: medications,
    events: events,
    history: history,
    userParameters: userParameters,
  );
  return Isolate.run(() => wakeProfileHeavy(input));
}

@SendableShape(
  'SQLite primitive row maps; tested by sendable_wakeProfileHeavy_test',
)
class WakeProfileInput {
  final List<Map<String, Object?>> journal, metrics;
  final List<Map<String, Object?>> definitions,
      events,
      history,
      medications,
      userParameters;
  final int? bedtimeMs;
  final WorkerInputs worker;
  const WakeProfileInput(
    this.journal,
    this.metrics,
    this.bedtimeMs,
    this.worker, {
    this.definitions = const [],
    this.medications = const [],
    this.events = const [],
    this.history = const [],
    this.userParameters = const [],
  });
}

@heavy
ConfounderProfile wakeProfileHeavy(WakeProfileInput input) {
  WorkerInit.ensure(input.worker);
  assertWorker();
  // CLAIM(preset-gate): a journal aggregate adjusts thresholds only while its
  // preset track definition is enabled and has the own_sleep role and sleep
  // system; a missing definition means the unedited preset [S2;
  // sendable_wakeProfileHeavy_test].
  final gated = gatedJournalFieldsHeavy(input);
  final preset = profileFromJournalRows(
    input.journal,
    [
      for (final m in input.metrics)
        // ↳ CLAIM(preset-gate)
        if (!gated.contains(m['field'])) m,
    ],
    input.bedtimeMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(input.bedtimeMs!),
  );
  if (input.bedtimeMs == null) return preset;
  final context = trackContextHeavy(input);
  final combined = preset.combine(context.profile);
  // CLAIM(adjusted-only-if-learned): a track's label is "adjusted for" only
  // when learned wake parameters for exactly this context are stored and
  // non-zero; otherwise the track is observed context (userTrackIds) and its
  // thresholds stay the identity [S12; tracks_natural_learning_test].
  final learned = {
    for (final row in input.userParameters)
      row['key'] as String: jsonDecode(row['value'] as String) as Map,
  };
  bool applied(String id) {
    final data = learned[naturalUserParameterKey(
      id,
      combined.userTrackIds,
      combined.track,
    )];
    return data != null &&
        (((data['triggerRunOffsetSec'] as num?) ?? 0) != 0 ||
            ((data['windowLeadMinutes'] as num?) ?? 0) != 0);
  }

  return combined.combine(
    ConfounderProfile(
      // ↳ CLAIM(adjusted-only-if-learned)
      adjustedFor: {
        for (final e in context.labels.entries)
          if (applied(e.key)) e.value,
      },
    ),
  );
}

const _journalFieldTrack = {
  'caffeine_mg': 'caffeine',
  'alcohol_units': 'alcohol',
};

@heavy
Set<String> gatedJournalFieldsHeavy(WakeProfileInput input) {
  final byId = {
    for (final d in decodeTrackDefinitionsHeavy(
      input.definitions,
      input.medications,
    ))
      d.id: d,
  };
  return {
    for (final e in _journalFieldTrack.entries)
      if (byId[e.value] case final d?
          when !d.enabled ||
              !d.roles.contains('own_sleep') ||
              !d.systems.contains('sleep'))
        e.key,
  };
}

@heavy
({ConfounderProfile profile, Map<String, String> labels}) trackContextHeavy(
  WakeProfileInput input,
) {
  final bedtime = input.bedtimeMs!;
  final date = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(bedtime));
  final events = [for (final r in input.events) TrackEvent.fromJson(r)];
  var result = ConfounderProfile.identity;
  final labels = <String, String>{};
  for (final d in decodeTrackDefinitionsHeavy(
    input.definitions,
    input.medications,
  )) {
    if (!d.enabled ||
        !d.roles.contains('own_sleep') ||
        !d.systems.contains('sleep')) {
      continue;
    }
    final active = events
        .where(
          (e) =>
              e.trackId == d.id &&
              e.atMs != null &&
              e.atMs! <= bedtime &&
              bedtime - e.atMs! <= const Duration(hours: 24).inMilliseconds,
        )
        .toList();
    final knownDone = input.history.any(
      (h) =>
          h['track_id'] == d.id &&
          h['done'] == 1 &&
          (h['start_date'] as String).compareTo(date) <= 0 &&
          (h['end_date'] as String).compareTo(date) >= 0,
    );
    if (active.isEmpty && !knownDone) continue;
    active.sort((a, b) => b.atMs!.compareTo(a.atMs!));
    final lead = active.isEmpty
        ? null
        : (bedtime - active.first.atMs!) / 3600000;
    final label = lead == null
        ? d.name
        : '${d.name} ${lead == lead.roundToDouble() ? lead.toInt() : lead.toStringAsFixed(1)} h before bed';
    result = result.combine(ConfounderProfile(userTrackIds: {d.id}));
    labels[d.id] = label;
  }
  return (profile: result, labels: labels);
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
