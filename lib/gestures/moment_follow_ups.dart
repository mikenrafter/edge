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
import '../data/assumed_water.dart';
import '../data/db.dart';
import '../data/journal_fields.dart' show kJournalFieldsByKey;
import '../data/moment_label.dart';
import '../data/water_units.dart';
import '../state/units_controller.dart' show UnitSystem, UnitsController;
import '../l10n/app_localizations.dart';
import 'moment_review_queue.dart';
import 'symptom_description.dart';

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
/// Whether [t]'s wall-clock minute (year..minute fields) happens twice in the
/// zone: the clocks went back and that minute came round again.
///
/// Found from the zone's real offsets, not a fixed hour (Lord Howe goes back 30
/// minutes): every offset in force within a day and a half either side is a
/// candidate; the minute is read as each one would, and counts as an instant only
/// if the zone really was on that offset then. Two instants means repeated.
/// [offsetAt] is the zone seam (a UTC instant's offset from UTC); null is the
/// device's zone.
bool wallMinuteIsAmbiguous(DateTime t,
    {Duration Function(DateTime utcInstant)? offsetAt}) {
  final off = offsetAt ?? (DateTime u) => u.toLocal().timeZoneOffset;
  final wall = DateTime.utc(t.year, t.month, t.day, t.hour, t.minute);
  final offsets = <Duration>{
    for (var h = -36; h <= 36; h++) off(wall.add(Duration(hours: h))),
  };
  final instants = <int>{};
  for (final o in offsets) {
    final at = wall.subtract(o);
    if (off(at) == o) instants.add(at.millisecondsSinceEpoch);
  }
  return instants.length > 1;
}

typedef MarkedMoment = ({String date, String hhmm});

class PendingMoment {
  const PendingMoment(
      {required this.date,
      required this.hhmm,
      this.epochSec,
      this.ambiguous = false});

  /// The mark's own absolute time (epoch seconds), when it was recorded (a
  /// `moment-at` tag, written for marks in a repeated hour).
  final int? epochSec;

  /// True when only the wall-clock minute is known and that minute happened
  /// twice (clocks went back): its order and length cannot be told.
  final bool ambiguous;

  /// Epoch seconds of this mark: the recorded absolute time, else the wall
  /// clock. For an [ambiguous] mark without one this is a guess; never use it to
  /// order or measure a range.
  int get sec => epochSec ?? local.millisecondsSinceEpoch ~/ 1000;

  /// 'YYYY-MM-DD', local.
  final String date;

  /// 'HH:mm', local.
  final String hhmm;

  String get key => '$date $hhmm';

  /// The moment as a LOCAL DateTime: the recorded instant when there is one,
  /// else the wall clock it was marked on.
  DateTime get local => epochSec != null
      ? DateTime.fromMillisecondsSinceEpoch(epochSec! * 1000)
      : momentLocalTime(date, hhmm)!;
}

class MomentFollowUps {
  const MomentFollowUps({
    required this.enabledSince,
    this.marked = const [],
    this.labelled = const {},
    this.assumed = const [],
    this.absolute = const {},
    this.isAmbiguous,
  });

  /// `PendingMoment.key` -> epoch seconds, from `moment-at` tags.
  final Map<String, int> absolute;

  /// Whether a wall-clock minute happened twice; null is the real zone's answer.
  final bool Function(DateTime wall)? isAmbiguous;

  static final _tagAt = RegExp(r'^moment-at ([01]\d|2[0-3]):([0-5]\d) (\d{1,12})$');

  /// The `moment-at HH:mm <epoch seconds>` tags of journal rows, by moment key.
  /// A mark made in a repeated hour (clocks went back) also records when it
  /// really happened; without it its order against another mark in that hour is
  /// unknowable.
  static Map<String, int> parseAbsolute(List<Map<String, dynamic>> journalRows) {
    final out = <String, int>{};
    for (final r in journalRows) {
      final date = r['date'];
      final raw = r['tags_json'];
      if (date is! String || raw is! String) continue;
      Object? tags;
      try {
        tags = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      if (tags is! List) continue;
      for (final t in tags) {
        final m = t is String ? _tagAt.firstMatch(t) : null;
        if (m != null) out['$date ${m[1]}:${m[2]}'] = int.parse(m[3]!);
      }
    }
    return out;
  }

  /// When the setting was switched on; null = off, nothing is pending.
  final DateTime? enabledSince;
  final List<MarkedMoment> marked;

  /// `MomentLabel.key`s that already have an answer (a skip counts).
  final Set<String> labelled;

  /// Assumed water glasses read off `assumed_water` (any state).
  final List<AssumedGlass> assumed;

  /// Assumed glasses still waiting for keep / remove at [now]: state
  /// `assumed`, not before the setting was enabled, within [windowDays] local
  /// calendar days, oldest first. Empty when the setting is off. Pure.
  List<AssumedGlass> pendingAssumed(DateTime now) {
    final since = enabledSince?.toLocal();
    if (since == null) return const [];
    final from = DateTime(since.year, since.month, since.day, since.hour, since.minute);
    final n = now.toLocal();
    final cutoff =
        DateTime(n.year, n.month, n.day - windowDays, n.hour, n.minute);
    final out = [
      for (final g in assumed)
        if (g.state == AssumedState.assumed &&
            !g.local.isBefore(from) &&
            !g.local.isBefore(cutoff))
          g,
    ]..sort((a, b) => a.local.compareTo(b.local));
    return out;
  }

  /// Everything waiting for the wearer at [now]: pending moments plus assumed
  /// glasses. The Home card counts this.
  int pendingCount(DateTime now) =>
      pending(now).length + pendingAssumed(now).length;

  /// What the Home card counts: pending marks and glasses plus the started
  /// ranges of [queue] with no pending mark left (an owed announcement would
  /// otherwise be invisible). 0 while the setting is off.
  int reviewCount(DateTime now, MomentReviewQueue queue) {
    if (enabledSince == null) return 0;
    final keys = {for (final m in pending(now)) m.key};
    return pendingCount(now) + queue.orphanRanges(keys).length;
  }

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
      final key = '${m.date} ${m.hhmm}';
      final epoch = absolute[key];
      final p = PendingMoment(
        date: m.date,
        hhmm: m.hhmm,
        epochSec: epoch,
        ambiguous: epoch == null && (isAmbiguous ?? wallMinuteIsAmbiguous)(at),
      );
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
    final glasses = await LocalDb.assumedWater(sinceDate: from);
    return MomentFollowUps(
      enabledSince: enabledSince,
      marked: parseMarked(rows),
      absolute: parseAbsolute(rows),
      labelled: {for (final l in labels) l.key},
      assumed: glasses,
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
  /// Water takes no amount: it adds one glass (the unit-aware step, clamped to
  /// `water_ml`'s max) to the moment's local day.
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
    // One glass is the unit-aware step: 250 ml, or one US cup (8 fl oz) when the
    // saved units preference is imperial. Always stored as ml.
    final glass = choice == MomentChoice.water
        ? WaterUnits.stepMl(await _savedSystem())
        : null;
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
      value: glass ?? value,
      max: choice == MomentChoice.water ? kJournalFieldsByKey[field]!.max : null,
    );
  }

  /// Answers a moment "Symptom" with a structured description: ONE transaction
  /// writes the `symptom` label and the `symptom_entry` row on the moment's
  /// local day. A moment that already has an answer is left alone. RED stub.
  Future<MomentAnswerResult> answerSymptom(
    PendingMoment m,
    SymptomDescription d, {
    DateTime? now,
  }) async {
    String? typed(String? v) {
      final t = v?.trim();
      return t == null || t.isEmpty ? null : t;
    }

    if (d.kind == SymptomKind.other && typed(d.kindOther) == null) {
      throw ArgumentError.value(d.kindOther, 'kindOther', 'Other needs text');
    }
    if (d.area == SymptomArea.other && typed(d.areaOther) == null) {
      throw ArgumentError.value(d.areaOther, 'areaOther', 'Other needs text');
    }
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final saved = await LocalDb.answerMomentSymptom(
      MomentLabel(
          date: m.date,
          hhmm: m.hhmm,
          label: MomentChoice.symptom.id,
          answeredAtMs: at),
      StoredSymptom(
          date: m.date, hhmm: m.hhmm, description: d, createdAtMs: at),
    );
    return saved ? MomentAnswerResult.saved : MomentAnswerResult.alreadyAnswered;
  }

  static Future<UnitSystem> _savedSystem() async {
    try {
      return await UnitsController.savedSystem();
    } catch (_) {
      return UnitSystem.metric; // no preference store (a headless/test run)
    }
  }

  /// The label id stored for the mark at [date] [hhmm] (null: none, or a skip).
  Future<String?> labelOf(String date, String hhmm) async {
    final labels = await LocalDb.momentLabels(date: date);
    for (final l in labels) {
      if (l.key == '$date $hhmm') return l.label;
    }
    return null;
  }

  /// Whether this moment already has an answer (a skip counts).
  Future<bool> isAnswered(PendingMoment m) async {
    final labels = await LocalDb.momentLabels(date: m.date);
    return labels.any((l) => l.key == m.key);
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
