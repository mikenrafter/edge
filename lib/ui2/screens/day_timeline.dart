import '../day_timeline/day_graph.dart';
export '../day_timeline/day_graph.dart' show DayGraph, kDayMinutes;
import '../day_timeline/timeline_chart.dart';
import '../day_timeline/timeline_filter.dart';
import '../day_timeline/timeline_filter_button.dart';
import 'detected_activities.dart' show NapAutoLogRow;
import 'review_read_label.dart';
import '../../l10n/presentation_text.dart';
import '../../l10n/display_text.dart';
import 'dart:convert' show jsonDecode;
import 'rhr_annotations.dart';
import '../read_prefetch.dart';
import '../../sync/import_focus.dart';
import '../../data/day_label.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../ble/adapters/signals.dart' show InputSignal;
import '../../compute/inputs/canonical.dart' show timelineObservations;
import '../../compute/inputs/measurement_inputs.dart'
    show bmiScalesOf, nearWeight;
import '../../compute/profile.dart' show bmiOf;
import '../../data/coverage_resolver.dart' show OwnedSpan, coverageFromJson, spanAt;

import '../../data/water_moment.dart';
import '../../data/assumed_water.dart' show AssumedGlass, AssumedState;
import '../../data/db.dart';
import '../../data/load_timings.dart';
import '../../compute/findings.dart';
import '../../data/read_paused.dart';
import '../../wake/wake_timeline.dart';
import '../../data/journal_fields.dart';
import '../../data/local_repository.dart';
import '../../data/med_store.dart';
import '../../data/moment_label.dart';
import '../../models/activity_suggestion.dart';
import '../../gestures/moment_follow_ups.dart';
import '../../gestures/moment_review_service.dart';
import 'day_review.dart';
import 'typical_day.dart';
import 'moment_follow_up.dart' show MomentAnswerEditLoader, MomentReviewEditor;
import '../../gestures/symptom_description.dart' show StoredSymptom;
import '../../data/nutrition_store.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/locale_controller.dart';
import '../activity/catalogue.dart';
import '../profile/devices.dart'
    show DeviceFilter, DeviceOption, signalCandidates;
import '../profile/wearable_numbers.dart' show deviceScoreLabel, observationTitle;
import '../ui2.dart';
import 'investigate.dart' show Investigate;
import 'log_workout.dart' show LogWorkout, bumpInsights;
import 'naps.dart' show NapsScreen;
import 'home_screen.dart';
import 'metric_detail.dart';





// DAY TIMELINE — what happened, in the order it happened.
//
// Every screen in this app answers "how much" for one number over many days.
// None of them answered "what was going on around then", which is the question
// somebody asks the moment a line moves: the workout, the nap, the coffee at
// nine, the night the band spent on the charger. The pieces were all on disk
// and all on the same axis already — `getDayTimeline` joins HR, HRV, sleep,
// naps, sessions and events; `getDayWear` holds the off-wrist segments; meals,
// doses and timed journal fields each carry their own clock — and nothing put
// them in one column.
//
// WHAT IT IS NOT. It is not an explanation. Two things next to each other on a
// clock is adjacency, and adjacency is not cause — a timeline is the most
// tempting place in the app to imply otherwise, so the page states the limit
// in the same words the journal findings use and never orders items by
// anything but time.
//
// A THING WITH NO CLOCK DOES NOT GET A PLACE ON ONE. A journal note is stored
// per DAY with no time, and so is a meal logged without one. Placing those
// anywhere on the axis — midnight, noon, the middle — would be inventing the
// one fact the entry is missing. They go in their own block underneath, which
// says what it is.



import '../../data/triathlon_store.dart' show kTriathlonDoubleTapEventId;

/// One thing that happened, at a time it is known to have happened at.
@immutable
class Moment {
  const Moment({
    required this.at,
    required this.title,
    required this.icon,
    this.color,
    this.until,
    this.detail = '',
    this.eventId,
    this.annotationKind,
    this.annotationLabel,
    this.identity,
    this.editRef,
    this.fixedLines = false,
    this.eventGroup,
    this.wakeGroup,
    this.wakeKind,
    this.timelineKind,
    this.members = const <int>[],
  });

  final DayTimelineKind? timelineKind;

  final int? wakeGroup;
  final WakeNightEventKind? wakeKind;

  final String? identity;

  /// What opens this row's own editor ('nap', 'session:ID', 'moment:DATE HH:mm'
  /// for an answered marked moment), or NULL when the row has none. Only rows that can be edited carry one.
  final String? editRef;

  /// An answered marked moment: the row is one title line and one detail line
  /// (ellipsis), reserved even when empty, so changing the answer never
  /// changes the row's height. The full text is in the row's semantics.
  final bool fixedLines;

  /// A family of band events folded together even when their ids differ (the
  /// charger and battery pack). Null: fold only equal [eventId]s.
  final String? eventGroup;

  /// What the chart annotation says when it is not the moment's [title] (the
  /// main sleep's "Main sleep 11:10 PM to 6:40 AM"). Null: use [title].
  final String? annotationLabel;

  /// What chart annotation this moment becomes, or NULL when it is not one
  /// (sleep, band events, the day's extremes — facts about the band or the
  /// arithmetic, not things the wearer logged).
  final AnnotationKind? annotationKind;

  /// Epoch seconds. The ONLY sort key — nothing on this page is ranked.
  final int at;

  /// Epoch seconds when this was a span rather than an instant.
  final int? until;

  final String title;
  final String detail;
  final IconData icon;

  /// The accent this line is drawn in, or NULL for a fact about the band
  /// rather than about the person — the charger, the restart, the wrist it was
  /// not on. Those render in muted ink, because a colour is a claim that the
  /// row belongs to a domain and none of them do.
  final Color? color;

  /// Epoch seconds of each event folded into this line, in order, when it is a
  /// run of the same band event (see [kEventRunGapSec]); empty for anything
  /// that stands alone. [MomentRow] opens a run to these.
  final List<int> members;
  /// The band event id this line came from, or NULL for anything else. Only
  /// equal non-null ids can be folded together by [groupRepeatedEvents].
  final int? eventId;
}

/// One wake epoch, or a run of consecutive matching band events.
@immutable
class MomentGroup {
  const MomentGroup(this.moments);
  final List<Moment> moments;
  bool get isWake => first.annotationKind == AnnotationKind.wake;
  bool get mixed => moments.any((m) => m.title != moments.first.title);
  int get count => moments.fold(
      0, (count, m) => count + (m.members.isEmpty ? 1 : m.members.length));
  Moment get first => moments.first;
}

/// [dayMoments] folds same-ID runs before merging in other timeline rows.
/// Same event id, or the same event group (e.g. charger on/off), with nothing
/// else between them in time order: one row (owner, 2026-10-26: same-type UI
/// events collapse, never a pile of identical markers). #764's 10-minute runs
/// nest inside these groups.
bool _sameRun(Moment a, Moment b) => a.eventId == b.eventId ||
    (a.eventGroup != null && a.eventGroup == b.eventGroup);

List<MomentGroup> groupRepeatedEvents(List<Moment> sorted) {
  final out = <List<Moment>>[];
  final wakes = <int?, List<Moment>>{};
  for (final m in sorted) {
    if (m.annotationKind == AnnotationKind.wake) {
      final group = wakes[m.wakeGroup];
      if (group == null) {
        final fresh = <Moment>[m];
        wakes[m.wakeGroup] = fresh;
        out.add(fresh);
      } else {
        group.add(m);
      }
    } else if (out.isNotEmpty && m.eventId != null && _sameRun(out.last.last, m)) {
      out.last.add(m);
    } else {
      out.add([m]);
    }
  }
  return [for (final g in out) MomentGroup(g)];
}

/// Something that was logged for this day and carries no time of day. Kept
/// apart from [Moment] by the type, so it cannot accidentally be placed.
@immutable
class DayNote {
  const DayNote(this.title, this.detail, this.icon);
  final String title, detail;
  final IconData icon;
}

/// Band events worth a line. Everything else the strap emits is about the
/// strap — bonds, flash writes, sync bookkeeping — and belongs on Devices, not
/// in somebody's day.
Map<int, (String, IconData)> _events(AppLocalizations? l) => {
  7: (l?.dayTimelineChargerOn ?? 'On the charger', LucideIcons.plugZap),
  8: (l?.dayTimelineChargerOff ?? 'Off the charger', LucideIcons.unplug),
  kTriathlonDoubleTapEventId: (l?.dayTimelineDoubleTap ?? 'You double-tapped the band', LucideIcons.hand),
  15: (l?.dayTimelineRestarted ?? 'The band restarted', LucideIcons.rotateCw),
  21: (l?.dayTimelineBatteryPackAttached ?? 'Battery pack attached',
      LucideIcons.batteryPlus),
  22: (l?.dayTimelineBatteryPackRemoved ?? 'Battery pack removed', LucideIcons.battery),
  57: (l?.dayTimelineAlarmWentOff ?? 'Alarm went off', LucideIcons.alarmClock),
};

/// Charger and battery-pack events fold into one collapsed line.
const _chargerEvents = {7, 8, 21, 22};

/// The row icon for a marked moment's answer. The chart's own marker uses the
/// same glyph for water, so the list and the chart agree.
IconData momentChoiceIcon(MomentChoice? c) => switch (c) {
      MomentChoice.pillsMeds => LucideIcons.pill,
      MomentChoice.nap => LucideIcons.bedDouble,
      MomentChoice.caffeine => LucideIcons.coffee,
      MomentChoice.alcohol => LucideIcons.wine,
      MomentChoice.meal => LucideIcons.utensils,
      MomentChoice.workout => LucideIcons.dumbbell,
      MomentChoice.symptom => LucideIcons.heartPulse,
      MomentChoice.water => LucideIcons.glassWater,
      MomentChoice.other || null => LucideIcons.bookmark,
    };

/// The same band event closer to the last one than this is one run on the
/// timeline (double-taps, restarts, an alarm's snoozes).
const int kEventRunGapSec = 10 * 60;

/// An off-wrist gap shorter than this is a dropout, not an event in a day.
/// Listing every one of them would bury the four that mean something under
/// forty that mean the strap moved.
const int kMinOffWristMin = 15;

String _dur(num? minutes, AppLocalizations? l) {
  if (minutes == null) return '';
  final m = minutes.round();
  return presentationText(l, m < 60 ? '${m}m' : '${m ~/ 60}h ${m % 60}m');
}

String _span(int from, int? to) =>
    to == null ? clockOfTs(from) : '${clockOfTs(from)} – ${clockOfTs(to)}';

/// THE JOIN. Pure, so the ordering and the placement rules are testable
/// without a database or a frame.
///
/// [timeline] is `getDayTimeline`, [wear] is `getDayWear`. Everything else is
/// one store each. A source that returned nothing simply contributes nothing —
/// there is no placeholder for a domain the user does not use.
List<Moment> dayMoments({
  required Map<String, dynamic> timeline,
  Map<String, dynamic> wear = const {},
  List<FoodEntry> meals = const [],
  List<({String label, int at})> doses = const [],
  Map<String, JournalMetricValue> journal = const {},
  List<JournalFieldSpec> fields = const [],
  List<MomentLabel> momentLabels = const [],
  List<StoredSymptom> symptoms = const [],
  List<AssumedGlass> assumedWater = const [],
  List<WaterMoment> waterMoments = const [],
  AppLocalizations? l,
  WakeNightTimeline wakeTimeline = const WakeNightTimeline(),
}) {
  final out = <Moment>[];
  int? asInt(Object? v) => (v as num?)?.toInt();

  // Sleep. The onset normally sits in the PREVIOUS calendar day — a day's
  // sleep is the night that ended that morning — so it sorts to the top and
  // reads as what it is: you were already asleep when this day started.
  //
  // MAIN SLEEP. One entry is the night on the chart: the longest one whose wake
  // is after its onset, the earlier onset on a tie. `getDayTimeline` sends at
  // most one today; the rule keeps a second entry from being a coin flip. The
  // others stay rows in this list and are not annotated.
  final sleeps = [
    for (final s in (timeline['sleep'] as List?) ?? const [])
      if (s is Map) (on: asInt(s['onset_ts']), off: asInt(s['wake_ts'])),
  ];
  int? mainAt;
  for (var i = 0; i < sleeps.length; i++) {
    final on = sleeps[i].on, off = sleeps[i].off;
    if (on == null || off == null || off <= on) continue;
    final best = mainAt == null ? null : sleeps[mainAt];
    if (best == null) {
      mainAt = i;
      continue;
    }
    final len = off - on, bestLen = best.off! - best.on!;
    if (len > bestLen || (len == bestLen && on < best.on!)) mainAt = i;
  }
  for (var i = 0; i < sleeps.length; i++) {
    final on = sleeps[i].on, off = sleeps[i].off;
    if (on == null || off == null) continue;
    final isMain = i == mainAt;
    out.add(Moment(
      at: on,
      until: off,
      title: l?.dayTimelineAsleep ?? 'Asleep',
      detail: '${_span(on, off)} · ${_dur((off - on) / 60, l)}',
      icon: LucideIcons.moon,
      color: C.blue,
      annotationKind: isMain ? AnnotationKind.mainSleep : null,
      // Clock times only: the onset is usually the evening before, and the
      // chart's own axis already says which day it is.
      annotationLabel: isMain
          ? (l?.dayTimelineMainSleep(clockOfTs(on), clockOfTs(off)) ??
              'Main sleep ${clockOfTs(on)} to ${clockOfTs(off)}')
          : null,
    ));
  }

  for (final n in (timeline['naps'] as List?) ?? const []) {
    if (n is! Map) continue;
    final on = asInt(n['start']), off = asInt(n['end']);
    if (on == null) continue;
    out.add(Moment(
      at: on,
      until: off,
      title: l?.dayTimelineNap ?? 'Nap',
      detail: '${_span(on, off)} · ${_dur(n['duration_min'] as num?, l)}',
      icon: LucideIcons.bedDouble,
      color: C.indigo,
      annotationKind: AnnotationKind.nap,
      identity: 'nap:$on',
      editRef: 'nap',
    ));
  }

  for (final s in (timeline['sessions'] as List?) ?? const []) {
    if (s is! Map) continue;
    final on = asInt(s['start_ts']);
    if (on == null) continue;
    final type = s['type']?.toString();
    final act = activityByName(type);
    final sid = s['id']?.toString();
    final sidOk = sid != null && sid.isNotEmpty ? sid : null;
    final bits = <String>[
      _span(on, asInt(s['end_ts'])),
      if (s['duration_min'] != null) _dur(s['duration_min'] as num?, l),
      if (s['avg_hr'] != null) presentationText(l, '${s['avg_hr']} bpm avg'),
    ];
    out.add(
      Moment(
        at: on,
        until: asInt(s['end_ts']),
        title: workoutTypeLabel(l, type),
      detail: bits.join(' · '),
      icon: act?.icon ?? LucideIcons.dumbbell,
      color: act?.color ?? C.orange,
      annotationKind: AnnotationKind.workout,
      identity: sidOk == null ? null : 'session:$sidOk',
      editRef: sidOk == null ? null : 'session:$sidOk|${type ?? ''}',
    ));
  }

  // The band off the wrist. This is the single most useful line on the page on
  // most people's days, because it is the reason the rest of the day is empty
  // — and the segments already carry the exact clock times.
  for (final w in (wear['segments'] as List?) ?? const []) {
    if (w is! Map || w['on'] == true) continue;
    final on = asInt(w['start']), off = asInt(w['end']);
    final len = (w['len_min'] as num?) ?? (on != null && off != null ? (off - on) / 60 : null);
    if (on == null || len == null || len < kMinOffWristMin) continue;
    out.add(
      Moment(
        at: on,
        until: off,
        title: l?.dayTimelineBandOffWrist ?? 'Band off your wrist',
        detail: '${_span(on, off)} · ${_dur(len, l)}',
        icon: LucideIcons.watch,
      ),
    );
  }

  // The day's extremes. NOT anomalies — the highest and lowest reading a day
  // has is arithmetic, and calling it unusual would be a claim the number does
  // not support. What it is good for is a time to look at.
  final highs = timeline['highs'];
  if (highs is Map) {
    for (final e in [
      ('peak_hr', l?.dayTimelineHighestHr ?? 'Highest heart rate', LucideIcons.trendingUp),
      ('low_hr', l?.dayTimelineLowestHr ?? 'Lowest heart rate', LucideIcons.trendingDown),
    ]) {
      final h = highs[e.$1];
      final t = h is Map ? asInt(h['t']) : null;
      final v = h is Map ? h['v'] as num? : null;
      if (t == null || v == null) continue;
      out.add(Moment(
        at: t,
        title: e.$2,
        detail: l?.dayTimelineBpmAt(v.round(), clockOfTs(t)) ??
            '${v.round()} bpm at ${clockOfTs(t)}',
        icon: e.$3,
        color: C.red,
      ));
    }
  }

  // Events, de-duplicated: the strap delivers the same (id, ts) up to four
  // times, and a day with the charger on it should not read as four chargers.
  final seen = <String>{};
  final events = _events(l);
  final stream = <(int, int)>[]; // (ts, event id)
  for (final e in (timeline['events'] as List?) ?? const []) {
    if (e is! Map) continue;
    final id = asInt(e['event_id']), t = asInt(e['ts']);
    final def = id == null ? null : events[id];
    if (def == null || t == null || !seen.add('$id/$t')) continue;
    stream.add((t, id!));
  }
  // The same band event again and again (a ball sport sets the firmware's tap
  // detector off on every contact; a boot loop restarts it) is one span
  // carrying the band's own count, not one line per event burying the day.
  // A run is consecutive events of one kind, each under [kEventRunGapSec]
  // after the last; a different visible band event ends it, even at the same
  // second, so a charger that goes on and off is still told in order.
  stream.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  final simultaneous = <int, Set<int>>{};
  for (final e in stream) {
    (simultaneous[e.$1] ??= <int>{}).add(e.$2);
  }
  for (var i = 0; i < stream.length;) {
    final id = stream[i].$2;
    var j = i;
    while (j + 1 < stream.length &&
        stream[j + 1].$2 == id &&
        simultaneous[stream[j].$1]!.length == 1 &&
        simultaneous[stream[j + 1].$1]!.length == 1 &&
        stream[j + 1].$1 - stream[j].$1 < kEventRunGapSec) {
      j++;
    }
    final n = j - i + 1, from = stream[i].$1, to = stream[j].$1;
    final def = events[id]!;
    out.add(Moment(
      at: from,
      until: n > 1 ? to : null,
      title: def.$1,
      detail: n > 1
          ? '${clockOfTs(from)}–${clockOfTs(to)} · $n×'
          : '',
      icon: def.$2,
      members: n > 1 ? [for (var k = i; k <= j; k++) stream[k].$1] : const [],
      eventId: id,
      eventGroup: _chargerEvents.contains(id) ? 'charger' : null,
    ));
    i = j + 1;
  }

  // A confirmed meal moment can describe an existing timed food entry. Join
  // only the same clock minute: nearby times are not evidence of one meal.
  final mealLabels = {for (final label in momentLabels)
    if (label.label == 'meal' && label.atSec != null)
      label.atSec! ~/ 60: label};
  final joinedMealLabels = <String>{};
  for (final m in meals) {
    final t = m.atTs;
    if (t == null) continue;
    final kcal = m.kcal;
    final label = mealLabels[t ~/ 60];
    final joined = label != null && joinedMealLabels.add(label.key);
    out.add(Moment(
      at: t,
      identity: joined ? 'moment:${label.key}' : null,
      // The meal answer behind this food row can still be changed.
      editRef: joined ? 'moment:${label.key}' : null,
      fixedLines: joined,
      title: m.label.isEmpty ? localizedText(l, m.meal) : m.label,
      detail: [
        clockOfTs(t),
        if (m.meal.isNotEmpty) localizedText(l, m.meal),
        // A bare occasion is complete as a log. It just has no energy on it,
        // and printing "0 kcal" for one is the fabrication this app refuses.
        if (kcal != null) '${kcal.round()} kcal',
        if (joined && label.note?.isNotEmpty == true) label.note!,
      ].join(' · '),
      icon: LucideIcons.utensils,
      color: C.domFood,
      annotationKind: joined ? AnnotationKind.moment : AnnotationKind.journal,
    ));
  }

  for (final d in doses) {
    out.add(Moment(
      at: d.at,
      title: d.label,
      detail: l?.dayTimelineTakenAt(clockOfTs(d.at)) ?? 'Taken at ${clockOfTs(d.at)}',
      icon: LucideIcons.pill,
      color: C.purple,
      annotationKind: AnnotationKind.journal,
    ));
  }

  // Timed journal fields — caffeine and alcohol carry the minute they last
  // landed, which is the sleep-relevant fact about both.
  final dayStart = asInt(timeline['day_start']);
  final specs = {for (final f in fields) f.key: f};
  // A dose answered from a marked moment writes the label AND adds to its
  // journal field at the same minute: one event, and the moment is it.
  final answered = <String>{
    for (final m in momentLabels)
      if (MomentChoice.fromId(m.label)?.journalField case final f?)
        '$f@${m.hhmm}',
  };
  journal.forEach((key, v) {
    final min = v.atMinuteOfDay;
    if (min == null || dayStart == null) return;
    final spec = specs[key];
    final n = v.value == v.value.roundToDouble()
        ? v.value.round().toString()
        : v.value.toStringAsFixed(1);
    // The stored minute is WALL-CLOCK, so the instant is built from calendar
    // fields: dayStart + min * 60 is elapsed time and is an hour off on a 23 h
    // or 25 h day.
    final d0 = DateTime.fromMillisecondsSinceEpoch(dayStart * 1000);
    final at =
        DateTime(d0.year, d0.month, d0.day, min ~/ 60, min % 60)
                .millisecondsSinceEpoch ~/
            1000;
    final hhmm = '${(min ~/ 60).toString().padLeft(2, '0')}:'
        '${(min % 60).toString().padLeft(2, '0')}';
    out.add(Moment(
      at: at,
      title: spec == null
          ? key.replaceAll('_', ' ')
          : spec.custom
              ? spec.label
              : localizedText(l, spec.label),
      // "last one at" is the stored meaning, and saying just "at" would turn a
      // total plus one timestamp into a single event that never happened.
      detail:
          '$n${spec == null || spec.unit.isEmpty ? '' : ' ${spec.custom ? spec.unit : localizedText(l, spec.unit)}'} · '
          '${l?.dayTimelineLastAt(clockOfTs(at)) ?? 'last at ${clockOfTs(at)}'}',
      icon: LucideIcons.notebookPen,
      color: C.domMind,
      // The water total is an aggregate of assumed glasses and water taps,
      // which are annotated from their own records; it is never a third event.
      annotationKind: key == 'water_ml' || answered.contains('$key@$hhmm')
          ? null
          : AnnotationKind.journal,
    ));
  });

  // Marked moments the wearer labelled. A marked moment has a real clock (the
  // minute the tap happened), so it is placed there. A skipped one has no label
  // to show, and a label this build does not know is not turned into text.
  final symptomAt = {for (final y in symptoms) y.key: y};
  for (final m in momentLabels) {
    if (joinedMealLabels.contains(m.key)) continue;
    final choice = MomentChoice.fromId(m.label);
    final at = m.atSec;
    if (choice == null || at == null) continue;
    final note = m.note;
    // A symptom answered with a description reads as that sentence; one
    // answered before descriptions existed keeps its plain "Symptom".
    final described =
        choice == MomentChoice.symptom ? symptomAt[m.key]?.description : null;
    out.add(Moment(
      at: at,
      identity: 'moment:${m.key}',
      // The answer can be changed: its row carries an Edit (CLS-1).
      editRef: 'moment:${m.key}',
      fixedLines: true,
      title: described?.describe(l) ?? choice.localized(l),
      // The row carries the clock; the detail is only the wearer's note.
      detail: note != null && note.isNotEmpty ? note : '',
      icon: momentChoiceIcon(choice),
      color: choice == MomentChoice.water ? C.sky : C.domMind,
      annotationKind: switch (choice) {
        MomentChoice.water => AnnotationKind.water,
        MomentChoice.symptom => AnnotationKind.symptom,
        _ => AnnotationKind.moment,
      },
    ));
  }

  // "Assume I drank water" glasses. A removed one is a tombstone — it records
  // that the slot was handled, not that anything happened — so it is not shown.
  for (final g in waterMoments) {
    out.add(Moment(at: g.local.millisecondsSinceEpoch ~/ 1000,
      identity: 'water:${g.id}', title: MomentChoice.water.localized(l),
      detail: '', icon: LucideIcons.droplet, color: C.sky,
      annotationKind: AnnotationKind.water));
  }
  for (final g in assumedWater) {
    if (g.state == AssumedState.removed) continue;
    final at = g.local.millisecondsSinceEpoch ~/ 1000;
    out.add(Moment(
      at: at,
      title: l?.assumedWaterTitle ?? 'Assumed glass of water',
      detail: '',
      icon: LucideIcons.droplet,
      color: C.sky,
      annotationKind: AnnotationKind.assumedWater,
    ));
  }

  for (final a in wakeAnnotations(wakeTimeline, l: l)) {
    out.add(Moment(
      at: a.at.toInt(),
      until:a.until?.toInt(),
      title: a.label,
      icon: a.icon ?? annotationIcon(a.kind),
      wakeGroup: a.groupId,
      wakeKind: a.wakeKind,
      color: annotationColor(a.kind),
      annotationKind: a.kind,
      identity: a.id,
    ));
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// [dayMoments] as chart annotations (domain: epoch seconds). Only moments with
/// an [Moment.annotationKind] become one; a moment with an end later than its
/// start is a range, anything else a point. Ids are unique and stable.
List<ChartAnnotation> dayAnnotations(List<Moment> moments) =>
    [for (final e in annotatedMoments(moments)) e.$1];

/// Each chart annotation with the moment it was made from, in the same order
/// and with the same ids as [dayAnnotations]. A tap on a marker names an id;
/// this says WHICH row that was, even when two rows share a time.
List<(ChartAnnotation, Moment)> annotatedMoments(List<Moment> moments) {
  final used = <String, int>{};
  final out = <(ChartAnnotation, Moment)>[];
  for (final m in moments) {
    final kind = m.annotationKind;
    if (kind == null) continue;
    final base = m.identity ?? '${kind.name}:${m.at}';
    final n = used[base] = (used[base] ?? -1) + 1;
    final end = m.until;
    out.add((ChartAnnotation(
      id: m.identity ?? (n == 0 ? base : '$base#$n'),
      kind: kind,
      at: m.at.toDouble(),
      until: end != null && end > m.at ? end.toDouble() : null,
      label: m.annotationLabel ?? m.title,
      icon: m.icon,
      groupId: m.wakeGroup,
      wakeKind: m.wakeKind,
    ), m));
  }
  return out;
}

/// Logged for the day, with no time on it. Same sources, opposite branch.
List<DayNote> dayNotes({
  List<FoodEntry> meals = const [],
  Map<String, JournalMetricValue> journal = const {},
  List<JournalFieldSpec> fields = const [],
  List<Map<String, dynamic>> journalRows = const [],
  AppLocalizations? l,
}) {
  final out = <DayNote>[];
  for (final r in journalRows) {
    final note = (r['note'] as String?)?.trim() ?? '';
    // `tags_json`, not `tags` — the column holds a JSON list and a reader that
    // asked for the wrong name got null and silently dropped every tagged day
    // whose note was empty.
    final tags = <String>[];
    try {
      final j = jsonDecode((r['tags_json'] as String?) ?? '[]');
      if (j is List) tags.addAll([for (final t in j) t.toString()]);
    } catch (_) {/* a malformed row loses its tags, not the note */}
    if (note.isEmpty && tags.isEmpty) continue;
    out.add(
      DayNote(
        note.isEmpty ? (l?.dayTimelineTaggedTitle ?? 'Tagged') : note,
        tags.map((t) => localizedJournalTag(l, t)).join(' · '),
        LucideIcons.notebookPen,
      ),
    );
  }
  final specs = {for (final f in fields) f.key: f};
  journal.forEach((key, v) {
    if (v.atMinuteOfDay != null) return;
    final spec = specs[key];
    final n = v.value == v.value.roundToDouble()
        ? v.value.round().toString()
        : v.value.toStringAsFixed(1);
    out.add(
      DayNote(
        spec == null
            ? key.replaceAll('_', ' ')
            : spec.custom
            ? spec.label
            : localizedText(l, spec.label),
        '$n${spec == null || spec.unit.isEmpty ? '' : ' ${spec.custom ? spec.unit : localizedText(l, spec.unit)}'}',
        LucideIcons.clipboardList,
      ),
    );
  });
  for (final m in meals) {
    if (m.atTs != null) continue;
    out.add(
      DayNote(
        m.label.isEmpty ? localizedText(l, m.meal) : m.label,
        [
          if (m.meal.isNotEmpty) localizedText(l, m.meal),
          if (m.kcal != null) '${m.kcal!.round()} kcal',
        ].join(' · '),
        LucideIcons.utensils,
      ),
    );
  }
  return out;
}

// ═══════════════════ the day on one clock ═══════════════════
//
// The picture of the same day the list below is the writing of. One
// destination, two halves: the graph answers WHEN, the list answers WHAT, and
// neither is a second copy of the other.
//
// THREE LANES, and the count is the design. Heart rate is the spine — it is the
// only thing this band measures all day at a rate worth drawing. Sleep is not a
// lane: the night is the main-sleep annotation above the plot and a nap its
// own annotation, so no band hides the curve. Workouts are blocks on the top edge.
// Movement is a strip along the floor. Everything else the day holds — meals,
// doses, notes, breathing, temperature, HRV — stays in the list rather than
// getting a lane, because ten labelled lanes is a chart nobody reads twice and
// the things that were left out are all better as a line of text with a time
// on it than as a shape.
//
// GAPS STAY GAPS. The band spends real hours off the wrist, and a line drawn
// across those hours is a measurement of somebody who was not wearing it. A
// minute with nothing in it breaks the curve AND changes the ground behind it,
// so an empty stretch reads as absent rather than as flat.

/// THE JOIN, for the picture. Pure, like [dayMoments] — the placement rules
/// are the thing worth testing and they need neither a database nor a frame.
///
/// [timeline] is `getDayTimeline`. Anything it did not carry contributes
/// nothing; there is no placeholder lane for a day with no workouts in it.
DayGraph dayGraph(Map<String, dynamic> timeline, {List<Object?>? hrOverride}) {
  final dayStart = (timeline['day_start'] as num?)?.toInt();
  if (dayStart == null || dayStart <= 0) return const DayGraph();
  // The day's REAL length. A spring-forward day is 23 h and a fall-back day is
  // 25 h, and a flat 1440 would drop the last hour of one of them — the same
  // bug day_label.dart exists to stop everywhere else.
  final end = localDayEndSec((timeline['date'] as String?) ?? '');
  final n = end == null || end <= dayStart
      ? kDayMinutes
      : ((end - dayStart) / 60).round();

  int? slot(Object? ts) {
    final t = (ts as num?)?.toInt();
    if (t == null) return null;
    final m = (t - dayStart) ~/ 60;
    return m < 0 || m >= n ? null : m;
  }

  final hr = List<double?>.filled(n, null);
  for (final e in hrOverride ?? (timeline['hr'] as List?) ?? const []) {
    if (e is! Map) continue;
    final i = slot(e['t']);
    final v = (e['v'] as num?)?.toDouble();
    // hr 0 is the pipeline's "no lock", not a heart that stopped.
    if (i == null || v == null || v <= 0) continue;
    hr[i] = v;
  }

  // The activity curve is 5-minute buckets. Each one fills its own five
  // minutes and no more — smearing it wider would put movement in minutes it
  // was never measured over.
  final movement = List<double?>.filled(n, null);
  for (final e in (timeline['activity'] as List?) ?? const []) {
    if (e is! Map) continue;
    final i = slot(e['t']);
    final v = (e['v'] as num?)?.toDouble();
    if (i == null || v == null || !v.isFinite) continue;
    for (var k = i; k < i + 5 && k < n; k++) {
      movement[k] = v;
    }
  }

  /// A span clipped to the day. A night's onset sits in the PREVIOUS calendar
  /// day, so it clips to midnight rather than being dropped — you were already
  /// asleep when this day started, and that is a fact about this day.
  (int, int, Color)? span(Object? from, Object? to, Color col) {
    final a = (from as num?)?.toInt(), b = (to as num?)?.toInt();
    if (a == null || b == null || b <= a) return null;
    final lo = ((a - dayStart) ~/ 60).clamp(0, n);
    final hi = ((b - dayStart) ~/ 60).clamp(0, n);
    return hi <= lo ? null : (lo, hi, col);
  }

  // Known sleep, night and nap, as spans. Not drawn (see [DayGraph.rest]); the
  // spans are what keeps a night from being called "not recorded".
  final rest = <(int, int, Color)>[
    for (final s in (timeline['sleep'] as List?) ?? const [])
      if (s is Map) ?span(s['onset_ts'], s['wake_ts'], C.blue),
    for (final s in (timeline['naps'] as List?) ?? const [])
      if (s is Map) ?span(s['start'], s['end'], C.blue),
  ];
  // ONE COLOUR FOR EVERY WORKOUT. The list below draws each activity in its
  // own, which is where that distinction is readable; up here it would be four
  // more hues on a chart whose whole job is to be glanced at, and a legend
  // swatch that lied about three quarters of the blocks.
  final work = <(int, int, Color)>[
    for (final s in (timeline['sessions'] as List?) ?? const [])
      if (s is Map) ?span(s['start_ts'], s['end_ts'], C.orange),
  ];

  return DayGraph(
      hr: hr, movement: movement, rest: rest, work: work, dayStart: dayStart);
}

// The existing durable proposal rows supply the Discarded view. This read
// does not restore or stage them; those actions belong to phase 3b.
Future<List<Moment>> _discardedMoments(String day, AppLocalizations? l) async {
  final start = localDayStartSec(day), end = localDayEndSec(day);
  if (start == null || end == null) return const [];
  final rows = await LocalDb.readerRun((db) => db.query('activity_suggestions',
    where: "status = 'discarded' AND start_ts >= ? AND start_ts < ?",
    whereArgs: [start, end], orderBy: 'start_ts, id'));
  return [for (final row in rows)
    for (final a in [ActivitySuggestion.fromRow(row)])
      Moment(at: a.startTs, until: a.endTs, identity: 'activity:${a.id}',
        timelineKind: DayTimelineKind.discarded,
        title: '${switch(a.kind) {
          ActivityKind.nap => l?.activityPossibleNap ?? 'Possible nap',
          ActivityKind.workout => l?.activityPossibleWorkout ?? 'Possible workout',
          ActivityKind.meal => l?.activityPossibleMeal ?? 'Possible meal',
          ActivityKind.track => l?.activityPossibleTrack(a.details['track_name'] as String? ?? a.trackId ?? '') ?? a.trackId ?? '',
        }} · ${l?.dayActivitiesDiscarded ?? 'Discarded'}',
        detail: _span(a.startTs, a.endTs),
        icon: switch(a.kind) {
          ActivityKind.nap => LucideIcons.bedDouble, ActivityKind.workout => LucideIcons.dumbbell,
          ActivityKind.meal => LucideIcons.utensils, ActivityKind.track => LucideIcons.tag,
        },
        annotationKind: switch(a.kind) {
          ActivityKind.nap => AnnotationKind.nap, ActivityKind.workout => AnnotationKind.workout,
          ActivityKind.meal || ActivityKind.track => AnnotationKind.journal,
        })];
}

// ═══════════════════ the screen ═══════════════════

class TimelineData {
  const TimelineData({
    this.day,
    this.days = const [],
    this.graph = const DayGraph(),
    this.moments = const [],
    this.notes = const [],
    this.raw,
    this.computedAtMs,
    this.readMillis = const {},
    this.loadMillis = 0,
    this.rhrMarks = const [],
    this.discarded = const [],
  });

  /// When the day's result was calculated (epoch ms), or null when unknown.
  final int? computedAtMs;
  final Map<String, int> readMillis;
  final int loadMillis;
  final List<ChartAnnotation> rhrMarks;
  final List<Moment> discarded;

  final String? day;

  /// Every derived day, newest first — what [DayNav] steers over.
  final List<String> days;

  /// The same day as [moments], drawn.
  final DayGraph graph;
  final List<Moment> moments;
  final List<DayNote> notes;

  /// The raw `getDayTimeline` payload [graph] was built from — retained so a
  /// per-device selection can rebuild [graph] with `dayGraph(raw!,
  /// hrOverride: …)` without a second `getDayTimeline` call (M6 §7.3).
  final Map<String, dynamic>? raw;

  static int _loadSequence = 0;

  // One decode of each day bundle per load, not one per getter (see
  // LocalRepository.sharingDayReads).
  static Future<TimelineData> load(
    LocalRepository repo, {
    String? want,
    AppLocalizations? l,
    void Function(Set<String>)? onPending,
    FutureOr<void> Function(TimelineData)? onPrimary,
  }) =>
      repo.sharingDayReads(InlineAsyncWork(() => _read(
            repo,
            want: want,
            l: l,
            onPending: onPending,
            onPrimary: onPrimary,
          )));

  static Future<TimelineData> _read(
    LocalRepository repo, {
    String? want,
    AppLocalizations? l,
    void Function(Set<String>)? onPending,
    FutureOr<void> Function(TimelineData)? onPrimary,
  }) async {
    final route = 'Review#${++_loadSequence}';
    final pending = <String>{};
    final elapsed = Stopwatch()..start();
    final costs = <String, int>{};
    Future<T> read<T>(String name, Future<T> Function() action) async {
      final timer = Stopwatch()..start();
      pending.add(name);
      onPending?.call(Set.unmodifiable(pending));
      try { return await LoadTimings.shared.scope(route, () => LoadTimings.shared.measure(name, 'read total',InlineAsyncWork( action))); }
      finally {
        costs[name] = timer.elapsedMilliseconds;
        pending.remove(name);
        onPending?.call(Set.unmodifiable(pending));
      }
    }
    final (days, today) = await (read('available days', repo.availableDays),
      want != null && localDayEndSec(want) != null
        ? Future<Map<String, dynamic>>.value(const {})
        : read('stored today', repo.getTodayStored)).wait;
    // A pending review can precede the day's first derivation. Keep its real
    // day even when availableDays has no bundle for it yet.
    final day = want != null && localDayEndSec(want) != null ? want : pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return TimelineData(days: days);

    // These are independent stored reads. Start them together so one slow
    // bundle does not delay every other source [structural review read test].
    final primaryTimeline = read('primary timeline', () => repo.getDayTimeline(day));
    final primaryWear = read('primary wear', () => repo.getDayWear(day));
    final primary = (primaryTimeline, primaryWear).wait.then((rows) async {
      final value = TimelineData(day: day, days: days, raw: rows.$1, graph: dayGraph(rows.$1),
        moments: dayMoments(timeline: rows.$1, wear: rows.$2, l: l));
      await onPrimary?.call(value);
      LoadTimings.shared.record('Review', 'first usable rows', elapsed.elapsedMicroseconds, route: route);
    }, onError: (Object error, StackTrace stack) {
      // The joined full read below reports this same source failure. This
      // optional early publication must not create a second unhandled error.
    });
    final flagsRead = read('resting heart rate flags', () async {
      try { return rhrChangeAnnotations(findingsHistory(await repo.getInsights()), l: l)
        .where((a) => a.id == 'rhr-shift:$day').toList(); }
      catch (_) { return <ChartAnnotation>[]; }
    });
    final ((timeline, wear, fields, journal, meals, notes, momentLabels),
      (symptoms, definitions, doseRows, rawObservations, hrv, wake, assumed, water)) = await (
      (read('heart rate, movement and sleep', () => primaryTimeline),
       read('wear coverage', () => primaryWear),
       read('journal fields', repo.getJournalFields),
       read('journal values', () => repo.getJournalMetrics(day)),
       read('meals', () => LocalDb.readerRun((db) => NutritionDb.entriesForDay(db, day))),
       read('journal notes', () => LocalDb.journalRows(date: day)),
       read('moment labels', () => LocalDb.momentLabels(date: day))).wait,
      (read('symptoms', () => LocalDb.symptomEntries(date: day)),
       read('medication definitions', () => LocalDb.readerRun((db) => MedDb.defs(db, activeOnly: false))),
       read('medication doses', () => LocalDb.readerRun((db) => MedDb.dosesForDay(db, day))),
       read('device observations', () => repo.getDayObservations(day)),
       read<Map<String, dynamic>>('calculation timestamp', () async {
         try { return {'computed_at': await LocalDb.dayComputedAtMs(day)}; } catch (_) { return {}; }
       }),
       read('wake timeline', () => repo.getWakeTimeline(day)),
       read('assumed water', () => LocalDb.assumedWater(date: day)),
       read('water moments', () => WaterMomentStore.forDay(day))).wait,
    ).wait;
    final defs = {for (final d in definitions) d.key: d};
    final taken = <({String label, int at})>[];
    doseRows.forEach((key, slots) {
      for (final row in slots.values) {
        final ts = (row['taken_ts'] as num?)?.toInt();
        if (ts == null) continue;
        taken.add((label: defs[key]?.label ?? key, at: ts));
      }
    });

    // WHAT OTHER SOURCES SAY about this day (M6). Gated on isNotEmpty being
    // the ONLY behaviour change: zero rows today, on every install, so the
    // list below is empty and this section renders nothing.
    final observations =
        await read('observation labels', () => timelineObservations(rawObservations, date: day));
    // A weighing's BMI is ours, off its weight and the profile's height:
    // only a scale whose flag is on crosses over (rule R6).
    final bmiScales = await read('BMI permissions', () => bmiScalesOf(observations));
    final profile = bmiScales.isNotEmpty ? await read('profile', repo.getProfile) : null;
    final heightCm = profile?['height_cm'] as num?;
    final weightKg = profile?['weight_kg'] as num?;

    // When this day's result was calculated: a Save's placeholder row waits
    // for a result newer than the Save. Unknown (no result) reads as not newer.
    final computedAtMs = (hrv['computed_at'] as num?)?.toInt();

    unawaited(primary);
    LoadTimings.shared.record('Review', 'all details ready', elapsed.elapsedMicroseconds, route: route);
    return TimelineData(
      day: day,
      days: days,
      computedAtMs: computedAtMs,
      rhrMarks: await flagsRead,
      discarded: await _discardedMoments(day, l),
      readMillis: Map.unmodifiable(costs),
      loadMillis: elapsed.elapsedMilliseconds,
      graph: dayGraph(timeline),
      raw: timeline,
      moments: dayMoments(
        timeline: timeline,
        wakeTimeline: wake,
        wear: wear,
        meals: [for (final m in meals) m.sanitised],
        doses: taken,
        journal: journal,
        fields: fields,
        momentLabels: momentLabels,
        symptoms: symptoms,
        assumedWater: assumed,
        waterMoments: water,
        l: l,
      ),
      notes: [
        ...dayNotes(
          meals: [for (final m in meals) m.sanitised],
          journal: journal,
          fields: fields,
          journalRows: [for (final r in notes) if (r['date'] == day) r],
          l: l,
        ),
        // ONE ROW PER OBSERVATION. Attribution always shown and never
        // abbreviated — a vendor number rendered without its source is a
        // number the user will read as ours. No tier, no confidence, no
        // dot — Observation deliberately carries none. A vendorKey renders
        // verbatim ('BioCharge' stays 'BioCharge'; mapping it onto one of
        // our keys is the worst available mistake here).
        // `observation.value` is nullable and an import preserves that, so the
        // value clause is dropped rather than interpolated — a null renders as
        // the literal "null", which reads as a measurement.
        // A device's daily mean is stored unrounded: one decimal at most
        // here. A snake_case name reads as words ('spo2_avg' is 'Spo2 avg'),
        // still the device's own name, never one of ours.
        for (final r in observations) ...[
          DayNote(
            measurementTitle(
                l, (r['vendor_key'] as String?) ?? (r['key'] as String?) ?? ''),
            r['value'] == null
                ? '${r['attribution']}'
                : '${observationValue(r['value'] as num)}${(r['unit'] as String?)?.isNotEmpty == true ? ' ${r['unit']}' : ''} · ${r['attribution']}',
            LucideIcons.tag,
          ),
          if (bmiOf(
                  r['key'] == 'weight' &&
                          bmiScales.contains(r['device_id']) &&
                          r['value'] is num &&
                          nearWeight(r['value'] as num, weightKg)
                      ? r['value'] as num?
                      : null,
                  heightCm)
              case final bmi?)
            DayNote(measurementTitle(l, 'bmi'),
                '${bmi.toStringAsFixed(1)} kg/m² · ${r['attribution']}',
                LucideIcons.tag),
        ],
      ],
    );
  }
}

/// An observation's title: a health measurement's own key (ours, or the
/// scale's impedance) worded; any other name as [observationTitle] reads it.
String measurementTitle(AppLocalizations? l, String name) => switch ((l, name)) {
  (final l?, 'weight') => l.journalComposeWeightLabel,
  (final l?, 'body_temp') => l.phoneImportBodyTemp,
  (final l?, 'impedance') => deviceScoreLabel(l, name),
  (_, 'bmi') => 'BMI',
  _ => observationTitle(name),
};

/// A stored observation's value: whole, or to one decimal.
String observationValue(num v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

class DayTimelineScreen extends StatefulWidget {
  const DayTimelineScreen({super.key, this.day, this.data,
      this.reviewMoments, this.reviewService, this.reviewEditor, this.focusId, this.reviewActivities, this.reviewSnapshot, this.resolving = false, this.reviewEntry = false, this.resolvingLabel});

  final bool resolving, reviewEntry;
  final String? resolvingLabel;
  final String? focusId;
  final List<ActivitySuggestion>? reviewActivities;
  final ReviewReadSnapshot? reviewSnapshot;

  final List<PendingMoment>? reviewMoments;
  final MomentReviewService? reviewService;
  final MomentReviewEditor? reviewEditor;

  /// The day to open. Null means the newest derived one.
  final String? day;
  final TimelineData? data;

  @override
  State<DayTimelineScreen> createState() => _DayTimelineScreenState();
}

class _DayTimelineScreenState extends State<DayTimelineScreen>
    implements EdgeSwipeListener, AnnotationListener, NerdStatsListener,
        DayRowEditListener {
  final _filter = TimelineFilter();
  TimelineController? _chart;
  List<({String id, Moment moment})> _visibleRows = const [];
  bool _programmaticScroll = false;
  void _filterChanged() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_visibleRows.any((r) => r.id == _highlight)) {
        if (_visibleRows.isEmpty) { setState(() => _highlight = null); }
        else { _scrubRow(_chart?.scrub ?? _visibleRows.first.moment.at.toDouble()); }
      }
    });
  }
  TimelineController _chartFor(DayGraph graph) {
    final start = graph.dayStart ?? localDayStartSec(_day ?? todayLabel())!;
    final end = graph.slots > 0 ? start + graph.slots * 60 : localDayEndSec(_day ?? todayLabel())!;
    if (_chart?.home != TimelineView(start.toDouble(),end.toDouble())) {
      final old = _chart;
      _chart = TimelineController(homeStartSec:start,homeEndSec:end);
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    return _chart!;
  }
  void _scrubRow(double at) {
    if (_visibleRows.isEmpty) return;
    var nearest = _visibleRows.first;
    for (final row in _visibleRows.skip(1)) {
      final distance=(row.moment.at-at).abs();
      final best=(nearest.moment.at-at).abs();
      if (distance < best || (distance == best && row.id == _highlight)) { nearest = row; }
    }
    if (_highlight != nearest.id) _reveal(nearest.id);
  }
  void _listScrolled() {
    if (_programmaticScroll || !_listController.hasClients ||
        _listController.position.userScrollDirection == ScrollDirection.idle) { return; }
    final viewport = _listController.position.context.storageContext.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final center = viewport.localToGlobal(Offset(0,viewport.size.height/2)).dy;
    ({String id, Moment moment})? closest;
    double distance = double.infinity;
    for (final row in _visibleRows) {
      final box = _rowKeys[row.id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final delta = (box.localToGlobal(Offset(0,box.size.height/2)).dy-center).abs();
      if (delta < distance) { distance=delta; closest=row; }
    }
    if (closest != null) {
      _chart?.reveal(closest.moment.at.toDouble());
      if (_highlight != closest.id) setState(() => _highlight=closest!.id);
    }
  }
  void _selectRow(String id, Moment m) {
    _chart?.reveal(m.at.toDouble());
    _reveal(id);
  }
  DayReviewController? _review;
  final _rowKeys = <String, GlobalKey>{};
  final _listController = ScrollController();
  String? _highlight;
  Timer? _highlightTimer;
  bool _allowPop = false;
  bool _askingLeave = false;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _chart?.dispose();
    _filter.removeListener(_filterChanged);
    _filter.dispose();
    _listController.dispose();
    _review?.removeListener(_onReview);
    _review?.dispose();
    super.dispose();
  }

  bool _focused = false;
  int _savedRevision = 0;
  void _onReview() {
    if (!mounted) return;
    setState(() {});
    final focus = widget.focusId;
    if (!_focused && focus != null && _review?.needsReview('activity:$focus') == true) {
      _focused = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _reveal('activity:$focus');
        }
      });
    }
    if ((_review?.savedRevision ?? 0) != _savedRevision) {
      _savedRevision = _review!.savedRevision;
      if (widget.data == null) unawaited(_load());
    }
  }

  Future<void> _loadReview(String day) async {
    final repo = repoOf(context);
    if (repo == null) return;
    _review?.removeListener(_onReview);
    _review?.dispose();
    _savedRevision = 0;
    _review = DayReviewController(repo, day,
        service: widget.reviewService,
        moments: widget.reviewMoments,
        editor: widget.reviewEditor, activities: widget.reviewActivities, snapshot: widget.reviewSnapshot,
        enabledSince: context.read<AppState>().gestureSettings.followUpMoments
            ? context.read<AppState>().gestureSettings.followUpMomentsSince : null);
    _review!.addListener(_onReview);
    await _review!.load();
  }

  Future<bool> _canLeave() async {
    if (_review?.busy == true || _askingLeave) return false;
    if (_review?.hasChanges != true) return true;
    _askingLeave = true;
    final l = AppLocalizations.of(context);
    try {
      return await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        key: const ValueKey('apk2-review-leave-dialog'),
        // Title and body scroll together so large text cannot overflow.
        scrollable: true,
        title: Text(l?.dayReviewLeaveTitle ?? 'Discard unsaved decisions?'),
        content: Text(l?.dayReviewLeaveBody ??
            'Your staged decisions have not been saved.'),
        actions: [
          TextButton(key: const ValueKey('apk2-review-stay'),
            onPressed: () => Navigator.pop(c, false),
            child: Text(l?.dayReviewStay ?? 'Stay')),
          TextButton(key: const ValueKey('apk2-review-leave'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(l?.dayReviewLeave ?? 'Discard and leave')),
        ],
      )) ?? false;
    } finally {
      _askingLeave = false;
    }
  }

  @override
  void onEdgeSwipe() => unawaited(_leave());

  Future<void> _leave() async {
    if (!await _canLeave() || !mounted) return;
    await _review?.discardDraft();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// The heart-rate panel's Nerd stats action, for the day on screen.
  @override
  void openNerdStats() =>
      go(context, Investigate('resting_hr', day: _day ?? _d?.day));

  /// A chart marker tap scrolls the list to the very row the marker was made
  /// from (two rows can share a minute).
  @override
  void annotationTapped(String id) {
    final hit = _visibleRows.where((r) => r.id == id ||
      dayAnnotations([r.moment]).any((a) => a.id == id)).firstOrNull;
    if (hit == null) return;
    final group = groupRepeatedEvents([for (final row in _visibleRows) row.moment])
        .where((g) => g.moments.contains(hit.moment)).first;
    final target = group.isWake ? group.first : hit.moment;
    final row = _visibleRows.firstWhere((r) => identical(r.moment,target));
    final state = _rowKeys[row.id]?.currentState;
    if (state is _MomentGroupRowState) state.expand();
    _selectRow(row.id,row.moment);
  }

  /// Opens the editor of a saved row (a nap, a workout) and reloads after.
  @override
  Future<void> openRowEditor(Moment m) async {
    final ref = m.editRef, day = _day ?? _d?.day;
    if (ref == null || day == null) return;
    if (ref.startsWith('moment:')) {
      // Opens at once; the editor reads its own row (see MomentAnswerEditLoader).
      final changed = await go<bool>(context,
          MomentAnswerEditLoader(day: day, answerKey: ref.substring(7)));
      if (changed == true && mounted) bumpInsights(context);
    } else if (ref == 'nap') {
      await go(context, NapsScreen(day: day));
    } else if (ref.startsWith('session:')) {
      final parts = ref.substring(8).split('|');
      final l = AppLocalizations.of(context);
      await go(context, LogWorkout(
          sessionId: parts.first,
          start: DateTime.fromMillisecondsSinceEpoch(m.at * 1000),
          end: DateTime.fromMillisecondsSinceEpoch((m.until ?? m.at) * 1000),
          activity: parts.length > 1 ? activityByName(parts[1]) : null,
          title: l?.workoutFixTimes ?? 'Fix the times'));
    }
    if (mounted && widget.data == null) unawaited(_load());
  }

  void _reveal(String id) {
    _highlightTimer?.cancel();
    setState(() => _highlight = id);
    void scroll() {
      final row = _rowKeys[id]?.currentContext;
      if (row != null) {
        _programmaticScroll = true;
        Scrollable.ensureVisible(row,
            duration: motion(context, Motion.slow), alignment: 0).whenComplete(() {
          _programmaticScroll = false;
        });
      }
    }
    // Rows are built eagerly, so a marker tap scrolls at once: an animation
    // started from a post-frame callback gets no progress until the frame
    // after, which leaves the row offscreen for a whole frame interval.
    if (_rowKeys[id]?.currentContext != null) {
      scroll();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) scroll();
      });
    }

  }

  TimelineData? _d;
  bool _loading = true;
  String? _day;

  /// The devices that could serve `hr` on this screen — registry-only, no
  /// query. Empty on every single-device install, which keeps the filter row
  /// absent (M6 §7.3).
  List<DeviceOption> _candidates = const [];

  /// The device whose own curve [_d]'s graph is drawn from, or null for the
  /// merged one. Cleared on every day change — a device selection is about
  /// the day on screen.
  String? _device;
  bool _deviceBounded = false;
  String? _deviceOldest;

  // `TimelineData` bakes `AppLocalizations` strings into `moments`/`notes` at
  // load time (see `TimelineData.load`), so a language switch while this
  // screen is alive would otherwise leave it showing the old locale until
  // something else (a day change, a revision bump) happens to reload it.
  // Sentinel so the system-default locale (`code == null`) is not mistaken
  // for "never seen yet" on the first pass.
  static const Object _localeUnset = Object();
  Object? _seenLocale = _localeUnset;

  /// Bumped on every `_load()` call so an OLDER one that resolves after a
  /// NEWER one (a locale change firing while a day-nav load is still in
  /// flight) can tell it lost the race and must not overwrite fresher data.
  int _loadToken = 0;

  /// The same guard for the per-device chart read, which awaits on its own.
  /// Bumped by `_load()` too, so a day change also invalidates a device
  /// request still in flight — otherwise the older response landed last and
  /// rebuilt `_d` from the PREVIOUS day's raw.
  int _deviceToken = 0;

  @override
  void initState() {
    super.initState();
    _filter.addListener(_filterChanged);
    _listController.addListener(_listScrolled);
    _day = widget.day;
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _d?.day != null) _loadReview(_d!.day!);
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(DayTimelineScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolving && !widget.resolving) {
      _day = widget.day;
      _load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `code` alone misses a SYSTEM locale change while it is null (no
    // in-app override) — see the same fix in RevisionReload.
    final Object localeKey;
    try {
      final code = context.watch<LocaleController>().code;
      localeKey = code ?? Localizations.localeOf(context);
    } catch (_) {
      return;
    }
    if (identical(_seenLocale, _localeUnset)) {
      _seenLocale = localeKey;
    } else if (_seenLocale != localeKey && widget.data == null) {
      _seenLocale = localeKey;
      _load();
    }
  }

  Set<String> _pendingReads = const {};
  bool _reviewReading = false;
  int _reviewReadToken = 0;
  Future<void> _readReview(String day) async {
    final token = ++_reviewReadToken;
    if (mounted) setState(() => _reviewReading = true);
    try { await _loadReview(day); }
    finally { if (mounted && token == _reviewReadToken) setState(() => _reviewReading = false); }
  }

  Future<void> _load() async {
    if (widget.resolving) return;
    final token = ++_loadToken;
    _deviceToken++;
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted && token == _loadToken) setState(() => _loading = false);
      return;
    }
    final l = AppLocalizations.of(context);
    final releasePrefetch = ReadPrefetch.shared.visibleRead('review-day');
    try {
      final reviewRead = _day != null && _review?.day != _day ? _readReview(_day!) : Future<void>.value();
      var completeRead = false;
      final d = await TimelineData.load(repo, want: _day, l: l, onPrimary: (primary) async {
        await reviewRead;
        if (mounted && token == _loadToken && _review?.day != primary.day && primary.day != null) {
          await _readReview(primary.day!);
        }
        if (mounted && token == _loadToken && !completeRead) setState(() { _d = primary; _loading = false; });
        releasePrefetch();
      }, onPending: (reads) {
        if (mounted && token == _loadToken) setState(() => _pendingReads = reads);
      });
      completeRead = true;
      // A device's own HR curve needs HR of either cadence: a ring's 5-minute
      // history draws as well as a band's 1 Hz stream.
      final candidates = mounted
          ? _anyHrCandidates(context, context.read<AppState>())
          : const <DeviceOption>[];
      if (mounted && token == _loadToken) {
        // The chart can take its actual shape while the saved-review read finishes.
        setState(() => _d = d);
        await reviewRead;
        if (_review?.day != d.day && d.day != null) await _readReview(d.day!);
        if (!mounted || token != _loadToken) return;
        _review?.reconcileSettled(d.computedAtMs);
        setState(() => (
          _d = d,
          _candidates = candidates,
          _device = null,
          // Cleared WITH `_device`. Left behind, the bounded-history message
          // and its oldest-day marker outlived the selection that produced
          // them and rendered against no selected device at all.
          _deviceBounded = false,
          _loading = false,
          _failed = false,
        ));
        if (d.day != null) {
          unawaited(
            ReadPrefetch.shared.warm(
              'review-day',
              [
                InlineAsyncWork(() => repo.getDayTimeline(d.day!)),
                InlineAsyncWork(() => repo.getDayWear(d.day!)),
              ],
              busy: () =>
                  !mounted ||
                  ModalRoute.of(context)?.isCurrent == false ||
                  ImportFocus.active.value ||
                  context.read<AppState>().deriving ||
                  context.read<AppState>().derivePending,
            ),
          );
        }
      }
    } on ReadPaused {
      if (mounted && token == _loadToken) {
        setState(() {
        _pendingReads = const {'import to finish copying stored data'};
        _loading = false;
      });
      }
    } catch (_) {
      if (mounted && token == _loadToken) {
        // A saved row still waits for its stored twin: say so and offer a retry.
        if (_review?.hasSettled == true) _review!.markReloadFailed(true);
        setState(() { _loading = false; _failed = true; });
      }
    } finally {
      releasePrefetch();
    }
  }

  @override
  Future<void> reloadDay() => _load();

  Future<void> _selectDevice(String? id) async {
    final token = ++_deviceToken;
    final d = _d;
    final day = _day ?? d?.day;
    if (d?.raw == null || day == null) return;
    if (id == null) {
      setState(() {
        _device = null;
        _deviceBounded = false;
        _d = TimelineData(
          day: d!.day,
          days: d.days,
          graph: dayGraph(d.raw!),
          moments: d.moments,
          discarded: d.discarded,
          rhrMarks: d.rhrMarks,
          notes: d.notes,
          raw: d.raw,
          computedAtMs: d.computedAtMs,
        );
      });
      return;
    }
    final repo = repoOf(context);
    if (repo == null) return;
    final Map<String, Object?> c;
    try {
      c = await repo.getDeviceChart('hr', deviceId: id, date: day);
    } catch (_) {
      // A failed read leaves the graph and the selection exactly as they were:
      // the alternative is an empty chart under a device pill, which claims
      // that device recorded nothing.
      return;
    }
    // A newer selection (another device, or a day change through `_load`)
    // started while this read was in flight, so this answer is about a
    // timeline that is no longer on screen.
    if (!mounted || token != _deviceToken) return;
    final bounded = c['bounded'] == true;
    setState(() {
      _device = id;
      _deviceBounded = bounded;
      _deviceOldest = c['oldest'] as String?;
      _d = TimelineData(
        day: d!.day,
        days: d.days,
        graph: bounded
            ? const DayGraph()
            : dayGraph(d.raw!, hrOverride: c['points'] as List?),
        moments: d.moments,
        discarded: d.discarded,
        rhrMarks: d.rhrMarks,
        notes: d.notes,
        raw: d.raw,
        computedAtMs: d.computedAtMs,
      );
    });
  }

  Future<void> _goDay(String day) async {
    if (day == (_day ?? _d?.day)) return;
    if (_review?.hasChanges == true || _review?.busy == true || _askingLeave) {
      if (!await _canLeave() || !mounted) return;
      await _review?.discardDraft();
    }
    if (!mounted) return;
    _review?.removeListener(_onReview);
    _review?.dispose();
    setState(() {
      _review = null;
      _day = day;
      _d = TimelineData(day: day, days: _d?.days ?? const []);
      _candidates = const [];
      _device = null;
      _deviceBounded = false;
      _highlight = null;
      _loading = true;
      _failed = false;
    });
    _load();
  }

  /// The old list display: one [MomentRow] per line, runs of the same band
  /// event (and the charger family) folded into a collapsed [MomentGroupRow].
  /// A row's buttons sit under it.
  List<Widget> _dayRows(List<({String id, Moment moment})> rows,
      DayReviewController? review) {
    final p = P.of(context);
    final out = <Widget>[];
    for (final g in groupRepeatedEvents([for (final r in rows) r.moment])) {
      final row = rows.firstWhere((r) => identical(r.moment, g.first));
      if (g.moments.length > 1 || g.isWake) {
        out.add(MomentGroupRow(g, key: _rowKeys.putIfAbsent(row.id, GlobalKey.new)));
        continue;
      }
      if (g.first.members.isNotEmpty) {
        out.add(MomentRow(g.first,
            key: _rowKeys.putIfAbsent(row.id, GlobalKey.new),
            displayTitle: _repeatTitle(AppLocalizations.of(context), g)));
        continue;
      }
      out.add(Semantics(selected:_highlight==row.id,
        onTap:()=>_selectRow(row.id,row.moment),child:Pressable(
        onTap: () => _selectRow(row.id,row.moment),
        child: Container(
        key: _rowKeys.putIfAbsent(row.id, GlobalKey.new),
        child: Container(
          key: ValueKey('apk2-day-row:${row.id}'),
          color: _highlight == row.id ? p.wash(C.domMind) : null,
          child: DayReviewActions.shows(review, row.id, row.moment, this)
              // Buttons belong to their item: one inset card holds both.
              ? Container(
                  margin: const EdgeInsets.symmetric(vertical: S.x1),
                  padding: const EdgeInsets.symmetric(horizontal: S.x3),
                  decoration: BoxDecoration(color: p.card2,
                      // Always the same 1 px frame (transparent once reviewed), so a Save moves no row.
                      border: Border.all(color: review?.needsReview(row.id)==true ? p.on(C.blue) : const Color(0x00000000)),
                      borderRadius: BorderRadius.circular(R.md)),
                  child: MomentRow(row.moment,
                      below: DayReviewActions(controller: review, id: row.id,
                          moment: row.moment, editor: this)))
              : MomentRow(row.moment),
        ),
      ))));
    }
    return out;
  }

  @override
  Widget build(BuildContext c) => DayNavigationFrame(
      selectedDay: _day ?? _d?.day ?? widget.day ?? todayLabel(),
      onSelect: _goDay, child: _content(c));

  Widget _content(BuildContext c) {
    final d = _d ?? const TimelineData();
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    if (_failed) {
      return detailScaffold(c, l?.dayTimelineTitle ?? 'Breakdown of your day', [
        ...dayNavRow(_day ?? d.day, d.days, _goDay),
        const SizedBox(height: S.x2),
        StatusCard(
          (_day ?? d.day) == null
              ? (l?.wellnessLoadFailedTitle ?? 'This could not be read')
              : (l?.homeDayLoadFailedTitle(prettyDay(_day ?? d.day, l)) ??
                  '${prettyDay(_day ?? d.day, l)} could not be read'),
          l?.homeLoadFailedBody ??
              'The stored day failed to load. Nothing was deleted — this is a '
                  'read that went wrong, not missing data.',
          fix: l?.homeTryAgain ?? 'Try again',
          icon: LucideIcons.databaseZap,
          onFix: () {
            setState(() => (_loading = true, _failed = false));
            _load();
          },
        ),
      ], framed: true);
    }
    final review = _review;
    final byId = <String, Moment>{
      if (review != null)
        for (final row in review.pendingRows(c)) row.id: Moment(
          at:row.moment.at,until:row.moment.until,title:row.moment.title,
          detail:row.moment.detail,icon:row.moment.icon,color:row.moment.color,
          identity:row.id,timelineKind:review.needsReview(row.id) ? DayTimelineKind.pending : DayTimelineKind.saved,
          annotationKind:row.moment.icon==LucideIcons.bedDouble ? AnnotationKind.nap :
            row.moment.icon==LucideIcons.utensils || row.moment.icon==LucideIcons.tag || row.moment.icon==LucideIcons.circleHelp
              ? AnnotationKind.journal : row.id.startsWith('activity:') ? AnnotationKind.workout : AnnotationKind.moment),
      for (final m in d.discarded) m.identity!: m,
      for (var i = 0; i < d.moments.length; i++)
        d.moments[i].identity ?? 'event:$i:${d.moments[i].at}': d.moments[i],
    };
    // Equal times keep the order they had: review rows by their place in the
    // list (a stored row by the placeholder it replaced), then the rest as
    // they arrived. The sort alone is not stable.
    final arrived = [
      for (final row in byId.entries) (id: row.key, moment: row.value),
    ];
    final ranked = [
      for (var i = 0; i < arrived.length; i++)
        (rank: review?.rowOrder(arrived[i].id, arrived[i].moment) ?? (1 << 30) + i,
            row: arrived[i]),
    ]..sort((a, b) => a.row.moment.at != b.row.moment.at
          ? a.row.moment.at.compareTo(b.row.moment.at)
          : a.rank.compareTo(b.rank));
    bool visible(Moment m) {
      if (m.annotationKind == AnnotationKind.mainSleep || m.annotationKind == AnnotationKind.wake ||
          (m.annotationKind == null && m.timelineKind == null)) { return true; }
      return _filter.kinds.contains(m.timelineKind ?? DayTimelineKind.saved);
    }
    final rows = [for (final e in ranked) if (visible(e.row.moment)) e.row];
    _visibleRows = rows;
    final chart = _chartFor(d.graph);
    final annotations = [...dayAnnotations([for (final row in rows) row.moment]),...d.rhrMarks];
    final title = widget.reviewEntry
        ? (l?.homeReviewActivities ?? 'Review activities')
        : (l?.dayTimelineTitle ?? 'Breakdown of your day');
    return PopScope(
      canPop: _allowPop || (review?.hasChanges != true && review?.busy != true),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: Stack(children: [
        SafeArea(child: LayoutBuilder(builder: (c, box) => Column(children: [
          // CLAIM(review-keys): the live guide "remove a detected nap or workout"
          // anchors its second step on this key, present only while reviewing
          // (every pending row prints its own Discard, so that label is ambiguous)
          // [guide_remove_detected.dart; guide_conformance_test 'review keys'].
          NavBar(title,
              key: widget.reviewEntry ? const ValueKey('day-review-nav') : null,
              onBack: _leave),
          // The chart scrolls with the page, as it did before review existed.
          // The Save bar is a sibling BELOW the list, so no row sits behind it.
          Expanded(child: SingleChildScrollView(
            key: const ValueKey('apk2-day-list'),
            controller: _listController,
            child: _VisibleDayListSemantics(controller: _listController,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                DayNav(day: _day ?? d.day ?? todayLabel(), days: d.days,
                  onDay: _goDay, alwaysShow: true),
                const SizedBox(height: S.x3),
                TextButton(onPressed: () => go(c, const TypicalDayScreen()),
                  child: Text(l?.typicalDayTitle ?? 'Typical day')),
                if (!_loading && _d == null && _pendingReads.contains('import to finish copying stored data'))
                  StatusCard(l?.reviewWaitingImportTitle ?? 'Waiting for import',
                    l?.reviewWaitingImportBody ?? 'The import is copying stored data. Your activities can be read when it finishes.',
                    fix: l?.reviewTryAgain ?? 'Try again', onFix: _load),
                // This caption slot exists in both states. It never inserts a
                // row above the chart when a slow read changes stage.
                SizedBox(height: F.cap.fontSize! * MediaQuery.textScalerOf(c).scale(1) * 1.5,
                  child: _loading ? Text(_reviewReading && _pendingReads.isEmpty
                      ? reviewReadLabel('saved activity reviews', l)
                      : _pendingReads.isEmpty ? (widget.resolvingLabel ?? reviewReadLabel('saved activity reviews', l))
                      : reviewReadLabel(_pendingReads.first, l), maxLines: 1,
                      overflow: TextOverflow.ellipsis, style: F.cap.copyWith(color: p.ink3)) : d.computedAtMs == null
                                      ? null
                                      : Text(
                                          (l ??
                                                  lookupAppLocalizations(
                                                    const Locale('en'),
                                                  ))
                                              .asOfTime(
                                                clockOfTs(
                                                  d.computedAtMs! ~/ 1000,
                                                ),
                                              ),
                                          style: F.cap.copyWith(color: p.ink3),
                                        ),
                                ),
                if (_loading) ...[
                  KeyedSubtree(key: const ValueKey('apk2-day-chart'),
                    child: _DayGraphZoom(d.graph, key:ValueKey(_day ?? d.day ?? todayLabel()), pending: true,
                      controller: chart, controls: TimelineFilterButton(filter:_filter),
                      annotations: annotations,nerdStats:this,fineDetail:false)),
                  if (_d != null && !d.graph.hasCurve && rows.isEmpty && d.notes.isEmpty)
                    StatusCard(l?.dayTimelineNothingRecordedTitle ?? 'Nothing was recorded on this day',
                      l?.dayTimelineNothingRecordedBody ?? 'Nothing recorded. The band was probably off.', icon: LucideIcons.circleSlash),
                  if (_d == null || rows.isNotEmpty) PendingContent(pending: true, child: Section(l?.dayTimelineWhatHappenedSection ?? 'What happened',
                    Surface(pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
                      child: _d == null ? const PendingRows(count: 3) : Column(children: _dayRows(rows, review))))),
                ] else ...[
                  if (_candidates.length >= 2)
                    DeviceFilter(options: _candidates, selected: _device,
                        onSelect: _selectDevice),
                  if (_deviceBounded)
                    Text(l?.dayTimelineDeviceBounded(_deviceOldest ?? '') ??
                        'Per-device detail is kept for recent days only.',
                        style: F.cap.copyWith(color: p.ink2)),
                  if (!_deviceBounded)
                    KeyedSubtree(key: const ValueKey('apk2-day-chart'),
                      child: _DayGraphZoom(d.graph,
                          fineDetail: _device == null,
                          owners: coverageFromJson(d.raw?['hr_owner']),
                          controller: chart, controls: TimelineFilterButton(filter:_filter),
                          onScrub: _scrubRow, emphasis: review?.reviewing == true ? review!.ids.toSet() : null,
                          annotations: annotations,
                          listener: this,
                          nerdStats: this,
                          key: ValueKey(_day ?? d.day ?? todayLabel()))),
                  if (rows.isEmpty && d.notes.isEmpty && byId.isEmpty && !d.graph.hasCurve)
                    StatusCard(
                      l?.dayTimelineNothingRecordedTitle ??
                          'Nothing was recorded on this day',
                      l?.dayTimelineNothingRecordedBody ??
                          'Nothing recorded. The band was probably off.',
                      icon: LucideIcons.circleSlash),
                  if (rows.isEmpty && byId.isNotEmpty)
                    Text(l!.timelineNoMatches,style:F.body.copyWith(color:p.ink2)),
                  if (rows.isNotEmpty)
                    Section(
                      l?.dayTimelineWhatHappenedSection ?? 'What happened',
                      Surface(
                        pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
                        child: Column(children: _dayRows(rows, review)),
                      ),
                    )
                  else if (d.moments.isEmpty && d.notes.isNotEmpty)
                    StatusCard(
                      l?.dayTimelineNoTimeTitle ?? 'Entries without a time',
                      l?.dayTimelineNoTimeBody ??
                          'What was logged for it is below.',
                      icon: LucideIcons.clock),
                  if (d.notes.isNotEmpty) alsoLoggedSection(c, d.notes),
                  const SizedBox(height: S.x4),
                  Text(l?.metricDetailPatternsNotCauses ??
                      'Patterns in your logs, not causes.',
                      style: F.over.copyWith(color: p.ink3)),
                  const SizedBox(height: S.x5),
                if (widget.reviewEntry) const NapAutoLogRow(),
                DayReviewNotices(controller: review, reloader: this),
                DayReviewSaveBar(key: review != null && !review.loading &&
                  (review.hasChanges || review.busy)
                  ? const ValueKey('apk2-review-savebar') : null, controller: review),
                const SizedBox(height: DayNavigationFrame.clearance),
                ],
                ]))),
          )),
        ]))),
        // Cupertino suppresses its route gesture while PopScope guards a
        // batch. Keep the leading-edge swipe as a request for confirmation.
        if (Theme.of(c).platform == TargetPlatform.iOS && !_allowPop &&
            (review?.hasChanges == true || review?.busy == true))
          EdgeSwipeBack(listener: this),
        ]),
      ),
    );
  }


  /// The last read threw. Without it a failed day step drew the previous
  /// day's timeline under the new date, and a failed first read drew an empty
  /// day.
  bool _failed = false;
}

// Rows are built eagerly so a chart marker can reveal any of them. Flutter's
// single-child viewport keeps *all* offscreen semantics as hidden nodes. Limit
// this written list to its visible slice so old review reasons aren't announced
// again while reading a different row. The tray keeps its page semantics.
class _VisibleDayListSemantics extends SingleChildRenderObjectWidget {
  const _VisibleDayListSemantics({required this.controller, required super.child});
  final ScrollController controller;
  @override
  RenderObject createRenderObject(BuildContext c) =>
      _VisibleDayListRender(controller);
}

class _VisibleDayListRender extends RenderProxyBox {
  _VisibleDayListRender(this.controller);
  final ScrollController controller;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller.addListener(markNeedsSemanticsUpdate);
  }
  @override
  void detach() {
    controller.removeListener(markNeedsSemanticsUpdate);
    super.detach();
  }
  @override
  Rect? describeSemanticsClip(RenderObject? child) {
    if (!controller.hasClients || !controller.position.hasViewportDimension) return null;
    return Rect.fromLTWH(0, controller.position.pixels, size.width,
        controller.position.viewportDimension);
  }
}

/// What the movement lane plots, in the words its key and note use. The lane is
/// `activity_curve`: per 5 minutes, the share of seconds in which the wrist's
/// orientation changed by more than 5 degrees between consecutive readings
/// (0…1, shown as a percentage). It is a share of time, not a count of steps or
/// an acceleration, so the unit is "% of time moving".
/// The graph, or nothing.
///
/// NOTHING when there is no heart-rate curve: the curve is what the y axis is
/// for, and a frame with an axis and no line under it reads as a measurement
/// of zero. A day like that is entirely carried by the list underneath, which
/// is the right shape for it — a handful of things that happened, in order.
///
/// [zoomed] draws a window of the day: clock-time x labels, and a frame that
/// says "no heart rate here" instead of vanishing, so the zoom control under
/// it stays reachable. [fine] is a per-second curve over the same window,
/// drawn instead of the per-minute one when the raw rows still exist.
/// [footnote], when given, is shown after the movement note. [annotations] are the
/// day's labelled moments, marked over the plot on `g.dayStart` ..
/// `g.dayStart + g.slots * 60`.
Widget? dayGraphCard(BuildContext c, DayGraph g,
    {bool zoomed = false, List<double?>? fine, String? footnote,
    List<ChartAnnotation> annotations = const [], AnnotationListener? listener,
    NerdStatsListener? nerdStats}) {
  if (!g.hasCurve && !zoomed) return null;
  return _DayGraphZoom(g, fineDetail:false,annotations:annotations,fineCurve:fine,footnote:footnote,
    listener:listener,nerdStats:nerdStats);
}

/// Per-second rows longer than this are not fetched: the chart is a few
/// hundred pixels wide, and past two hours a second-by-second line is drawn
/// at the same density as the stored per-minute one.
const int kFineWindowMinutes = 120;

/// [rows] (`rec_ts`, `hr`, `device_id`) as one slot per second of
/// [fromSec, toSec), `null` where nothing was recorded. hr 0 is "no lock",
/// never a reading. [owners] is the day's stored HR ownership: a second some
/// device owns takes only that device's row, the same pick the stored curve
/// made, so two devices on one second never race for the slot.
List<double?> perSecondHr(
    List<Map<String, Object?>> rows, int fromSec, int toSec,
    {List<OwnedSpan> owners = const []}) {
  final out = List<double?>.filled(toSec > fromSec ? toSec - fromSec : 0, null);
  for (final r in rows) {
    final t = (r['rec_ts'] as num?)?.toInt();
    final v = (r['hr'] as num?)?.toDouble();
    if (t == null || v == null || v <= 0) continue;
    final owner = owners.isEmpty ? null : spanAt(owners, t)?.deviceId;
    if (owner != null &&
        owner != ((r['device_id'] as String?) ?? LocalDb.kPrimaryDeviceId)) {
      continue;
    }
    final i = t - fromSec;
    if (i >= 0 && i < out.length) out[i] = v;
  }
  return out;
}

/// The day chart plus a range control under it. The whole day is the stored
/// per-minute curve, which is kept for every derived day. Zoomed to two hours
/// or less it re-reads the band's per-second rows — those are pruned a few
/// days behind the newest sync, so on an older day it says it is still
/// showing minutes rather than pretending to more detail.
class _DayGraphZoom extends StatefulWidget {
  const _DayGraphZoom(this.graph,
      {super.key,
      this.fineDetail = true,
      this.owners = const [],
      this.annotations = const [],
      this.listener,
      this.nerdStats, this.controller, this.controls, this.onScrub, this.emphasis, this.pending=false, this.fineCurve, this.footnote});

  final bool pending;
  final List<double?>? fineCurve;
  final String? footnote;
  final TimelineController? controller;
  final Set<String>? emphasis;
  final Widget? controls;
  final ValueChanged<double>? onScrub;
  final AnnotationListener? listener;
  final NerdStatsListener? nerdStats;

  final DayGraph graph;
  final bool fineDetail;

  /// The day's HR ownership spans, empty on a one-device day.
  final List<OwnedSpan> owners;

  /// The day's labelled moments as chart annotations (epoch seconds). A
  /// zoomed window marks the ones inside it; the domain follows the window.
  final List<ChartAnnotation> annotations;

  @override
  State<_DayGraphZoom> createState() => _ZoomState();
}

class _ZoomState extends State<_DayGraphZoom> {
  late TimelineController _controller;
  List<double?>? _fine;
  bool _fineMissing=false, _fineFailed=false;
  int? _fineStart;
  int _token=0;
  Timer? _readTimer;
  TimelineController _makeController() {
    final start=widget.graph.dayStart??0;
    return widget.controller ?? TimelineController(homeStartSec:start,
      homeEndSec:start+(widget.graph.slots>0?widget.graph.slots:1)*60);
  }
  @override
  void initState() { super.initState(); _controller=_makeController(); _controller.range.addListener(_rangeChanged); }
  @override
  void didUpdateWidget(_DayGraphZoom old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller,widget.controller) ||
        (widget.controller==null && (old.graph.dayStart!=widget.graph.dayStart || old.graph.slots!=widget.graph.slots))) {
      _controller.range.removeListener(_rangeChanged);
      if(old.controller==null) _controller.dispose();
      _controller=_makeController(); _controller.range.addListener(_rangeChanged);
      _token++; _fine=null; _fineMissing=false; _fineFailed=false;
    } else if (!identical(old.graph,widget.graph) || old.fineDetail!=widget.fineDetail) {
      _token++; _fine=null; _fineMissing=false; _fineFailed=false;
    }
  }
  @override
  void dispose() {
    _token++; _readTimer?.cancel(); _controller.range.removeListener(_rangeChanged);
    if(widget.controller==null) _controller.dispose();
    super.dispose();
  }
  void _rangeChanged() {
    _token++; _readTimer?.cancel();
    if(_fine!=null || _fineMissing || _fineFailed) {
      setState(() { _fine=null; _fineMissing=false; _fineFailed=false; });
    }
    if(!_controller.animating) _readTimer=Timer(Motion.fast,_readFine);
  }
  Future<void> _readFine() async {
    final from=_controller.view.start.floor(),to=_controller.view.end.ceil();
    if(!widget.fineDetail || to-from>kFineWindowMinutes*60 || to<=from || !_controller.zoomed) return;
    final token=++_token;
    try {
      final db=await LocalDb.instance;
      final rows=await db.rawQuery(
        'SELECT rec_ts, hr, device_id FROM decoded_onehz '
        'WHERE rec_ts >= ? AND rec_ts < ? AND hr > 0 AND ${derivableSourceSql()} '
        'ORDER BY rec_ts ASC',[from,to]);
      final curve=perSecondHr(rows,from,to,owners:widget.owners);
      if(!mounted || token!=_token) return;
      setState(() { _fineStart=from; _fine=curve.any((v)=>v!=null)?curve:null; _fineMissing=_fine==null; });
    } catch (_) {
      if(mounted && token==_token) setState(()=>_fineFailed=true);
    }
  }
  @override
  Widget build(BuildContext c) {
    final l=AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Surface(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        PendingContent(pending:widget.pending,child:SharedTimelineChart(controller:_controller,graph:widget.graph,
          fine:_fine??widget.fineCurve,fineStartSec:_fineStart??widget.graph.dayStart,nerdStats:widget.nerdStats,emphasis:widget.emphasis,
          annotations:widget.annotations.where((a)=>a.kind!=AnnotationKind.rhrShift).toList(),
          onAnnotationSelected:(id)=>widget.listener?.annotationTapped(id),onScrub:widget.onScrub)),
        if(_fineFailed) TextButton(onPressed:_readFine,child:Text(l.homeTryAgain)),
        Text(_fineFailed ? l.wellnessLoadFailedTitle : _fine!=null ? l.dayTimelineZoomPerSecond :
          _fineMissing ? l.dayTimelineZoomPerMinuteOnly : l.dayTimelineZoomPerMinute,style:F.cap.copyWith(color:P.of(c).ink3)),
        if(widget.footnote!=null) Text(widget.footnote!,style:F.cap.copyWith(color:P.of(c).ink3)),
        const SizedBox(height:S.x2),
        LayoutBuilder(builder:(c,box) {
          final zoom=TimelineZoomControls(controller:_controller);
          return MediaQuery.textScalerOf(c).scale(1)>1.5 || box.maxWidth<300
            ? Wrap(alignment:WrapAlignment.spaceBetween,crossAxisAlignment:WrapCrossAlignment.center,
                children:[zoom,if(widget.controls!=null) widget.controls!])
            : Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[Flexible(child:zoom),if(widget.controls!=null) widget.controls!]);
        }),
      ])),
      DayRhrNotice(widget.annotations,widget.graph.dayStart==null?null:
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch(widget.graph.dayStart!*1000))),
    ]);
  }
}

/// The page's body, given loaded data. Split out so the gallery can build every
/// state of it without a repository.
///
/// [fineDetail] allows the zoomed chart to read per-second rows; off while a
/// single device is selected, because those rows are not split by device.
List<Widget> timelineBody(BuildContext c, TimelineData d,
    {bool fineDetail = true}) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final graph = d.graph.hasCurve
      ? _DayGraphZoom(d.graph,
          fineDetail: fineDetail,
          owners: coverageFromJson(d.raw?['hr_owner']),
          annotations: [...dayAnnotations(d.moments), ...d.rhrMarks],
          key: ValueKey(d.day))
      : null;
  return [
    ?graph,
    if (d.moments.isEmpty && d.notes.isEmpty && graph == null)
      StatusCard(
        l?.dayTimelineNothingRecordedTitle ?? 'Nothing was recorded on this day',
        l?.dayTimelineNothingRecordedBody ??
            'Nothing recorded. The band was probably off.',
        icon: LucideIcons.circleSlash,
      )
    else ...[
      if (d.moments.isEmpty)
        StatusCard(
          l?.dayTimelineNoTimeTitle ?? 'Entries without a time',
          l?.dayTimelineNoTimeBody ?? 'What was logged for it is below.',
          icon: LucideIcons.clock,
        )
      else
        // The written half of the same day. It carries its own heading now
        // that the picture is above it: the graph says when, this says what,
        // and without a name between them the rows read as a caption.
        Section(
          l?.dayTimelineWhatHappenedSection ?? 'What happened',
          Surface(
            pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
            child: Column(
              children: [
                for (final g in groupRepeatedEvents(d.moments))
                  g.moments.length > 1 || g.isWake
                      ? MomentGroupRow(g, key: ValueKey((g.first.title, g.first.at)))
                      : MomentRow(g.first,
                          key: g.first.members.isEmpty
                              ? null
                              : ValueKey((g.first.eventId, g.first.at)),
                          displayTitle: g.count > 1 ? _repeatTitle(l, g) : null),
              ],
            ),
          ),
        ),
      if (d.notes.isNotEmpty) alsoLoggedSection(c, d.notes),
    ],
    const SizedBox(height: S.x4),
    Text(
      l?.metricDetailPatternsNotCauses ??
          'Patterns in your logs, not causes.',
      style: F.over.copyWith(color: p.ink3, height: 1.5),
    ),
  ];
}

/// The "Also logged on this day" section: entries that carry no time.
Widget alsoLoggedSection(BuildContext c, List<DayNote> notes) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  return Section(
    l?.dayTimelineAlsoLoggedSection ?? 'Also logged on this day',
    Surface(
      pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
      child: Column(
        children: [
          for (final n in notes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(n.icon, size: 17, color: p.ink3),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(n.title, style: F.body.copyWith(color: p.ink)),
                        if (n.detail.isNotEmpty)
                          Text(n.detail,
                              style: F.cap.copyWith(color: p.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// One line of the day. The time is the left column and everything aligns to
/// it, because the ONE thing this page is ordered by should be the one thing
/// you can scan.
class MomentRow extends StatefulWidget {
  const MomentRow(this.m, {super.key, this.below, this.displayTitle});
  final String? displayTitle;
  final Moment m;

  /// Under the line, outside its (excluded) semantics: the row's buttons.
  final Widget? below;

  @override
  State<MomentRow> createState() => _MomentRowState();
}

class _MomentRowState extends State<MomentRow> {
  bool _open = false;

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext c) {
    final m = widget.m, p = P.of(c);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scaled with the text, not fixed: the column exists so the times
          // line up, and a hard 62 px is a clipped clock at 3.1x on exactly
          // the phones whose owners chose 3.1x.
          SizedBox(
            width: MediaQuery.textScalerOf(c).scale(58),
            child: Text(clockOfTs(m.at), style: F.n17.copyWith(color: p.ink3)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(m.icon,
                size: 17, color: m.color == null ? p.ink3 : p.on(m.color!)),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.displayTitle ?? m.title,
                  maxLines: m.fixedLines ? 1 : null,
                  overflow: m.fixedLines ? TextOverflow.ellipsis : null,
                  style: F.body
                      .copyWith(color: p.ink, fontWeight: FontWeight.w600),
                ),
                if (m.fixedLines)
                  Text(m.detail.isEmpty ? ' ' : m.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: F.cap.copyWith(color: p.ink2, height: 1.4))
                else if (m.detail.isNotEmpty)
                  Text(m.detail,
                      style: F.cap.copyWith(color: p.ink2, height: 1.4)),
              ],
            ),
          ),
          if (m.members.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                  _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 17,
                  color: p.ink3),
            ),
        ],
      ),
    );
    final label = '${clockOfTs(m.at)}, ${m.title}. ${m.detail}';
    // A lone event is exactly the line it always was; only a run opens.
    if (m.members.isEmpty) {
      final line = Semantics(label: label, excludeSemantics: true, child: row);
      final below = widget.below;
      if (below == null) return line;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [line, below],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: label,
          button: true,
          expanded: _open,
          onTap: _toggle,
          excludeSemantics: true,
          child: Pressable(
            onTap: _toggle,
            child: row,
          ),
        ),
        if (_open)
          Padding(
            padding: EdgeInsets.only(
                left: MediaQuery.textScalerOf(c).scale(58),
                bottom: S.x3),
            child: Wrap(
              spacing: S.x4,
              runSpacing: S.x1,
              children: [
                for (final t in m.members)
                  Text(clockOfTs(t), style: F.n17.copyWith(color: p.ink2)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Devices that can draw their own HR curve: those declaring 1 Hz HR, or
/// sparse HR (selectable either way; the reason a device is disabled is kept
/// only when it has neither).
List<DeviceOption> _anyHrCandidates(BuildContext c, AppState app) {
  final dense = signalCandidates(c, app, requires: {InputSignal.hr1Hz});
  final sparse = signalCandidates(c, app, requires: {InputSignal.hrSparse});
  return [
    for (final o in dense)
      o.selectable
          ? o
          : sparse.firstWhere((x) => x.deviceId == o.deviceId && x.selectable,
              orElse: () => o),
  ];
}

String _repeatTitle(AppLocalizations? l, MomentGroup group) =>
    l?.dayTimelineRepeatedGroup(group.first.title, group.count) ??
    '${group.first.title} · ${group.count} times';

/// A run of the same band event as one line, "<title> · N times", that opens
/// to the individual times. Collapsed by default: five double taps in a row is
/// one thing that happened, not five.
class MomentGroupRow extends StatefulWidget {
  const MomentGroupRow(this.group, {super.key});
  final MomentGroup group;

  @override
  State<MomentGroupRow> createState() => _MomentGroupRowState();
}

class _MomentGroupRowState extends State<MomentGroupRow> {
  // Same-event groups are temporary disclosures, not saved section accordions.
  bool _open = false;
  void expand() {
    if (!_open) setState(() => _open = true);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final g = widget.group, f = g.first;
    final ack = g.moments
        .where((m) => m.wakeKind == WakeNightEventKind.ack)
        .firstOrNull;
    final fire = g.moments
        .where(
          (m) =>
              m.wakeKind == WakeNightEventKind.natural ||
              m.wakeKind == WakeNightEventKind.gradual ||
              m.wakeKind == WakeNightEventKind.alarm,
        )
        .firstOrNull;
    final end = ack?.at ?? g.moments.last.at;
    final minutes = ack == null || fire == null || ack.at < fire.at
        ? null
        : (ack.at - fire.at) ~/ 60;
    final groupTitle = g.isWake
        ? (minutes == null
              ? '${l?.wakeJournalGroupName ?? 'Wake-up'} ${clockOfTs(f.at)}–${clockOfTs(end)} · ${l?.wakeJournalTimeToWakeUnknown ?? 'Time to wake: —'}'
              : (l?.wakeJournalGroup(
                      clockOfTs(f.at),
                      clockOfTs(end),
                      minutes,
                    ) ??
                    'Wake-up ${clockOfTs(f.at)}–${clockOfTs(end)} · $minutes min to wake'))
        : g.mixed
        ? (l?.dayTimelineBandEventsGroup(g.count) ??
              'Charger and battery · ${g.count} events')
        : _repeatTitle(l, g);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Pressable(
          onTap: () => setState(() => _open = !_open),
          semanticLabel:
              '${f.title}, ${g.count} times, ${_open ? 'expanded' : 'collapsed'}',
          child: Row(
            children: [
              Expanded(
                child: MomentRow(Moment(
                  at: f.at,
                  title: groupTitle,
                  icon: f.icon,
                  color: f.color,
                )),
              ),
              Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 17, color: p.ink3),
            ],
          ),
        ),
        if (_open && g.isWake)
          Padding(
            padding: const EdgeInsets.only(left: S.x4),
            child: Column(children: [for (final m in g.moments) MomentRow(m)]),
          ),
        if (_open && !g.isWake)
          // The individual times sit under the title column, in the row's own
          // clock style, so an opened group reads as more of the same row.
          Padding(
            padding: EdgeInsets.only(
                left: MediaQuery.textScalerOf(c).scale(58) + 17 + S.x3,
                bottom: S.x2),
            child: Wrap(
              spacing: S.x4,
              runSpacing: S.x1,
              children: [
                for (final m in g.moments)
                  for (final at in m.members.isEmpty ? [m.at] : m.members)
                    Text(
                      g.mixed
                          ? '${clockOfTs(at)}  ${m.title}'
                          : clockOfTs(at),
                      style: F.n17.copyWith(color: p.ink3)),
              ],
            ),
          ),
      ],
    );
  }
}

