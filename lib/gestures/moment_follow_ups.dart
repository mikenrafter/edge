// moment_follow_ups.dart — "Follow up with me about my marked moments".
//
// A marked moment is a journal tag `moment HH:mm` on its local day. When the
// follow-up setting is on, a moment marked since it was enabled that has no
// label yet is PENDING (for 7 days). Pure query + model here; the writer at the
// bottom is the one place an answer lands.
//
// Rules (AGENTS.md): never fabricate (a dose is never guessed; a nap never
// invents a sleep window), local day labels only, additive idempotent storage.

import 'dart:convert';

import '../data/day_label.dart' show dayLabelOf;
import '../data/db.dart';
import '../data/journal_fields.dart' show kJournalFieldsByKey;
import '../data/moment_label.dart';
import '../l10n/app_localizations.dart';

/// One quick answer. The id is persisted in `moment_label.label`.
enum MomentChoice {
  pillsMeds('pills_meds', 'Pills & meds'),
  nap('nap', 'Nap'),
  caffeine('caffeine', 'Caffeine'),
  alcohol('alcohol', 'Alcohol'),
  meal('meal', 'Meal'),
  workout('workout', 'Workout'),
  symptom('symptom', 'Symptom'),
  other('other', 'Other'),
  // One tap = one glass: no amount is asked (see MomentAnswerWriter.answer).
  water('water', 'Water');

  const MomentChoice(this.id, this.label);
  final String id;
  final String label;

  /// The EXISTING numeric journal field this answer maps to, or null when none
  /// fits (the answer is then the label alone).
  String? get journalField => switch (this) {
        MomentChoice.caffeine => 'caffeine_mg',
        MomentChoice.alcohol => 'alcohol_units',
        MomentChoice.water => 'water_ml',
        _ => null,
      };

  static MomentChoice? fromId(String? id) {
    for (final c in values) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The label in the app's language (English when no localizations).
  String localized(AppLocalizations? l) => switch (this) {
        MomentChoice.pillsMeds => l?.momentChoicePillsMeds ?? label,
        MomentChoice.nap => l?.momentChoiceNap ?? label,
        MomentChoice.caffeine => l?.momentChoiceCaffeine ?? label,
        MomentChoice.alcohol => l?.momentChoiceAlcohol ?? label,
        MomentChoice.meal => l?.momentChoiceMeal ?? label,
        MomentChoice.workout => l?.momentChoiceWorkout ?? label,
        MomentChoice.symptom => l?.momentChoiceSymptom ?? label,
        MomentChoice.other => l?.momentChoiceOther ?? label,
        MomentChoice.water => l?.momentChoiceWater ?? label,
      };
}

/// A marked moment as read off a journal day: local date + wall-clock minute.
typedef MarkedMoment = ({String date, String hhmm});

class PendingMoment {
  const PendingMoment({required this.date, required this.hhmm});

  /// 'YYYY-MM-DD', local.
  final String date;

  /// 'HH:mm', local.
  final String hhmm;

  String get key => '$date $hhmm';

  /// The moment as a LOCAL DateTime (the wall clock it was marked on).
  DateTime get local => momentLocalTime(date, hhmm)!;
}

class MomentFollowUps {
  const MomentFollowUps({
    required this.enabledSince,
    this.marked = const [],
    this.labelled = const {},
  });

  /// When the setting was switched on; null = off, nothing is pending.
  final DateTime? enabledSince;
  final List<MarkedMoment> marked;

  /// `MomentLabel.key`s that already have an answer (a skip counts).
  final Set<String> labelled;

  /// Days a moment stays pending, counted in local calendar days.
  static const int windowDays = 7;

  /// Pending moments at [now], oldest first. Pure.
  ///
  /// All comparisons are on LOCAL wall-clock minutes built from calendar
  /// fields: the 7-day cutoff is "same wall minute, 7 calendar days back", so a
  /// DST change does not move it by an hour.
  List<PendingMoment> pending(DateTime now) {
    final since = enabledSince?.toLocal();
    if (since == null) return const [];
    final from = DateTime(since.year, since.month, since.day, since.hour,
        since.minute);
    final n = now.toLocal();
    final cutoff =
        DateTime(n.year, n.month, n.day - windowDays, n.hour, n.minute);
    final seen = <String>{};
    final out = <(DateTime, PendingMoment)>[];
    for (final m in marked) {
      final at = momentLocalTime(m.date, m.hhmm);
      if (at == null || at.isBefore(from) || at.isBefore(cutoff)) continue;
      final p = PendingMoment(date: m.date, hhmm: m.hhmm);
      if (labelled.contains(p.key) || !seen.add(p.key)) continue;
      out.add((at, p));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final e in out) e.$2];
  }

  static final _tag = RegExp(r'^moment ([01]\d|2[0-3]):([0-5]\d)$');

  /// The `moment HH:mm` tags of `LocalDb.journalRows` rows (`tags_json`).
  static List<MarkedMoment> parseMarked(List<Map<String, dynamic>> journalRows) {
    final out = <MarkedMoment>[];
    for (final r in journalRows) {
      final date = r['date'];
      final raw = r['tags_json'];
      if (date is! String || raw is! String) continue;
      Object? tags;
      try {
        tags = jsonDecode(raw);
      } catch (_) {
        continue; // a malformed row loses its tags, nothing else
      }
      if (tags is! List) continue;
      for (final t in tags) {
        final m = t is String ? _tag.firstMatch(t) : null;
        if (m != null) out.add((date: date, hhmm: '${m[1]}:${m[2]}'));
      }
    }
    return out;
  }

  /// Reads the journal and the labels from the database.
  static Future<MomentFollowUps> load({required DateTime? enabledSince}) async {
    if (enabledSince == null) return const MomentFollowUps(enabledSince: null);
    final from = dayLabelOf(enabledSince);
    final rows = await LocalDb.journalRows(sinceDaysEpoch: from);
    final labels = await LocalDb.momentLabels(sinceDate: from);
    return MomentFollowUps(
      enabledSince: enabledSince,
      marked: parseMarked(rows),
      labelled: {for (final l in labels) l.key},
    );
  }
}

/// The window the "Log a workout at this time" flow opens on: starts at the
/// moment's wall-clock minute, an hour long, but never ending after [now].
({DateTime start, DateTime end}) workoutPrefillFor(
    PendingMoment m, DateTime now) {
  final start = m.local;
  final n = now.toLocal();
  final nowMin = DateTime(n.year, n.month, n.day, n.hour, n.minute);
  final end = DateTime(
      start.year, start.month, start.day, start.hour, start.minute + 60);
  return (start: start, end: end.isAfter(nowMin) ? nowMin : end);
}

enum MomentAnswerResult { saved, alreadyAnswered }

/// Where an answer goes. Overridable so the screen can be tested without a DB.
class MomentAnswerWriter {
  const MomentAnswerWriter();

  /// Stores [choice] as the moment's label (always) and, for a dose field with a
  /// [value], adds it to that local day's journal metric. Null [value] never
  /// writes a metric. A moment that already has an answer is left alone.
  /// Water takes no amount: it adds one glass (`water_ml`'s step, clamped to
  /// its max) to the moment's local day.
  Future<MomentAnswerResult> answer(
    PendingMoment m,
    MomentChoice choice, {
    double? value,
    String? note,
    DateTime? now,
  }) async {
    final field = choice.journalField;
    if (choice == MomentChoice.water && value != null) {
      // One tap is one glass; an amount is never asked, so none is accepted.
      throw ArgumentError.value(value, 'value', 'Water takes no amount');
    }
    if (value != null) {
      final spec = field == null ? null : kJournalFieldsByKey[field];
      if (spec == null) {
        throw ArgumentError.value(
            value, 'value', '${choice.id} has no journal field to add to');
      }
      if (!value.isFinite || value <= 0 || value > spec.max) {
        throw ArgumentError.value(
            value, 'value', 'must be above 0 and at most ${spec.max}');
      }
    }
    final trimmed = note?.trim();
    return _store(
      MomentLabel(
        date: m.date,
        hhmm: m.hhmm,
        label: choice.id,
        note: trimmed == null || trimmed.isEmpty ? null : trimmed,
        answeredAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ),
      field: choice == MomentChoice.water
          ? field
          : (value == null ? null : field),
      // One glass: the field's own step (the + button's), clamped to its max.
      value: choice == MomentChoice.water ? kJournalFieldsByKey[field]!.step : value,
      max: choice == MomentChoice.water ? kJournalFieldsByKey[field]!.max : null,
    );
  }

  /// Marks the moment answered with no label.
  Future<MomentAnswerResult> skip(PendingMoment m, {DateTime? now}) =>
      _store(MomentLabel(
        date: m.date,
        hhmm: m.hhmm,
        answeredAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ));

  Future<MomentAnswerResult> _store(MomentLabel l,
      {String? field, double? value, double? max}) async {
    final saved = await LocalDb.answerMoment(l,
        metricField: field, metricValue: value, metricMax: max);
    return saved ? MomentAnswerResult.saved : MomentAnswerResult.alreadyAnswered;
  }
}
