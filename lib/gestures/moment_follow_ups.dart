// moment_follow_ups.dart — "Follow up with me about my marked moments".
//
// A marked moment is a journal tag `moment HH:mm` on its local day. When the
// follow-up setting is on, a moment marked since it was enabled that has no
// label yet is PENDING (for 7 days). Pure query + model here; the writer at the
// bottom is the one place an answer lands.
//
// Rules (AGENTS.md): never fabricate (a dose is never guessed; a nap never
// invents a sleep window), local day labels only, additive idempotent storage.

/// One quick answer. The id is persisted in `moment_label.label`.
enum MomentChoice {
  pillsMeds('pills_meds', 'Pills & meds'),
  nap('nap', 'Nap'),
  caffeine('caffeine', 'Caffeine'),
  alcohol('alcohol', 'Alcohol'),
  meal('meal', 'Meal'),
  workout('workout', 'Workout'),
  symptom('symptom', 'Symptom'),
  other('other', 'Other');

  const MomentChoice(this.id, this.label);
  final String id;
  final String label;

  /// The EXISTING numeric journal field this answer maps to, or null when none
  /// fits (the answer is then the label alone).
  String? get journalField => switch (this) {
        MomentChoice.caffeine => 'caffeine_mg',
        MomentChoice.alcohol => 'alcohol_units',
        _ => null,
      };

  static MomentChoice? fromId(String? id) {
    for (final c in values) {
      if (c.id == id) return c;
    }
    return null;
  }
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
  DateTime get local => throw UnimplementedError('PendingMoment.local');
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
  List<PendingMoment> pending(DateTime now) =>
      throw UnimplementedError('MomentFollowUps.pending');

  /// The `moment HH:mm` tags of `LocalDb.journalRows` rows (`tags_json`).
  static List<MarkedMoment> parseMarked(List<Map<String, dynamic>> journalRows) =>
      throw UnimplementedError('MomentFollowUps.parseMarked');

  /// Reads the journal and the labels from the database.
  static Future<MomentFollowUps> load({required DateTime? enabledSince}) =>
      throw UnimplementedError('MomentFollowUps.load');
}

/// The window the "Log a workout at this time" flow opens on: starts at the
/// moment's wall-clock minute, an hour long, but never ending after [now].
({DateTime start, DateTime end}) workoutPrefillFor(
        PendingMoment m, DateTime now) =>
    throw UnimplementedError('workoutPrefillFor');

enum MomentAnswerResult { saved, alreadyAnswered }

/// Where an answer goes. Overridable so the screen can be tested without a DB.
class MomentAnswerWriter {
  const MomentAnswerWriter();

  /// Stores [choice] as the moment's label (always) and, for a dose field with a
  /// [value], adds it to that local day's journal metric. Null [value] never
  /// writes a metric. A moment that already has an answer is left alone.
  Future<MomentAnswerResult> answer(
    PendingMoment m,
    MomentChoice choice, {
    double? value,
    String? note,
    DateTime? now,
  }) =>
      throw UnimplementedError('MomentAnswerWriter.answer');

  /// Marks the moment answered with no label.
  Future<MomentAnswerResult> skip(PendingMoment m, {DateTime? now}) =>
      throw UnimplementedError('MomentAnswerWriter.skip');
}
