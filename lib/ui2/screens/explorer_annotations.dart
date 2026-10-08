// Where the Explorer's annotations come from.
//
// The pure half ([rangeAnnotations]) joins already-read rows into annotations
// through the day timeline's own join ([dayMoments]), so the Explorer and the
// day page can never disagree about what a moment is called or what kind it
// is. The IO half ([loadAnnotations]) only reads rows.
//
// A source that returned nothing contributes nothing. Nothing is placed on a
// clock it does not have: a journal field with no time, or a meal logged
// without one, is not an annotation (the day page lists those under the
// chart's day instead).

import 'package:flutter/foundation.dart';

import '../../data/assumed_water.dart' show AssumedGlass;
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/journal_fields.dart';
import '../../data/moment_label.dart';
import '../../gestures/symptom_description.dart' show StoredSymptom;
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'day_timeline.dart';

/// Reads the annotations for the local days [from]..[to] inclusive ('YYYY-MM-DD'),
/// in epoch seconds. Null results are not allowed: failure is an empty list.
typedef AnnotationLoader = Future<List<ChartAnnotation>> Function(
    String from, String to);

/// The annotations of the days [from]..[to] from already-read rows. Domain:
/// epoch seconds. Pure.
///
/// Workouts come from [sessions] (rows with `start_ts`, `end_ts`, `type`). Naps
/// are not read here: a detected nap lives inside a derived day, and a range
/// read of those would cost a day-result decode per day. The intraday Explorer
/// already shades them.
List<ChartAnnotation> rangeAnnotations({
  required String from,
  required String to,
  List<Map<String, dynamic>> sessions = const [],
  List<MomentLabel> momentLabels = const [],
  List<StoredSymptom> symptoms = const [],
  List<AssumedGlass> assumedWater = const [],
  Map<String, Map<String, JournalMetricValue>> journalByDay = const {},
  List<JournalFieldSpec> fields = kJournalFields,
  AppLocalizations? l,
}) {
  bool inRange(String d) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  String dayOfTs(num ts) => dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000));

  final days = <String>{
    for (final m in momentLabels) m.date,
    for (final s in symptoms) s.date,
    for (final g in assumedWater) g.date,
    ...journalByDay.keys,
    for (final s in sessions)
      if ((s['start_ts'] as num?) != null) dayOfTs(s['start_ts'] as num),
  }.where(inRange).toList()
    ..sort();

  final out = <ChartAnnotation>[];
  for (final day in days) {
    final start = localDayStartSec(day);
    if (start == null) continue;
    final moments = dayMoments(
      timeline: {
        'day_start': start,
        'sessions': [
          for (final s in sessions)
            if ((s['start_ts'] as num?) != null && dayOfTs(s['start_ts'] as num) == day) s,
        ],
      },
      journal: journalByDay[day] ?? const {},
      fields: fields,
      momentLabels: [for (final m in momentLabels) if (m.date == day) m],
      symptoms: [for (final s in symptoms) if (s.date == day) s],
      assumedWater: [for (final g in assumedWater) if (g.date == day) g],
      l: l,
    );
    // Ids repeat across days (`water:<at>` is unique only within one), so the
    // day goes in front.
    for (final a in dayAnnotations(moments)) {
      out.add(ChartAnnotation(
        id: '$day/${a.id}',
        kind: a.kind,
        at: a.at,
        until: a.until,
        label: a.label,
      ));
    }
  }
  return out;
}

/// The detected naps of one day's `getDayTimeline` as range annotations (domain:
/// epoch seconds), through the same join as every other annotation. Ids carry
/// the day, like [rangeAnnotations]'s. Pure.
List<ChartAnnotation> napAnnotations(
  String day,
  Map<String, dynamic> timeline, {
  AppLocalizations? l,
}) =>
    [
      for (final a in dayAnnotations(dayMoments(
        timeline: {'naps': timeline['naps']},
        l: l,
      )))
        if (a.kind == AnnotationKind.nap)
          ChartAnnotation(
            id: '$day/${a.id}',
            kind: a.kind,
            at: a.at,
            until: a.until,
            label: a.label,
          ),
    ];

/// The real reader. Never throws: a store that cannot be read leaves the chart
/// without annotations, which is a smaller claim, not a wrong one.
Future<List<ChartAnnotation>> loadAnnotations(String from, String to,
    {AppLocalizations? l}) async {
  try {
    final lo = localDayStartSec(from), hi = localDayEndSec(to);
    if (lo == null || hi == null) return const [];
    final results = await Future.wait<Object?>([
      LocalDb.sessionsInRange(lo, hi - 1),
      LocalDb.momentLabels(sinceDate: from),
      LocalDb.symptomEntries(sinceDate: from),
      LocalDb.assumedWater(sinceDate: from),
      LocalDb.journalMetricsByDay(sinceDaysEpoch: from),
      LocalDb.journalFieldDefs(),
    ]);
    return rangeAnnotations(
      from: from,
      to: to,
      sessions: (results[0] as List).cast<Map<String, dynamic>>(),
      momentLabels: (results[1] as List).cast<MomentLabel>(),
      symptoms: (results[2] as List).cast<StoredSymptom>(),
      assumedWater: (results[3] as List).cast<AssumedGlass>(),
      journalByDay:
          (results[4] as Map).cast<String, Map<String, JournalMetricValue>>(),
      fields: [...kJournalFields, ...(results[5] as List).cast<JournalFieldSpec>()],
      l: l,
    );
  } catch (e) {
    debugPrint('explorer annotations: $e');
    return const [];
  }
}
