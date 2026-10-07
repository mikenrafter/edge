// wake_outcome.dart — one record per wake: what fired, whether the band got it,
// and the SEPARATE responses seen afterwards. Shadow-mode instrumentation only
// (developer-only, default off, see Prefs.exploreWakeOutcomes); nothing here
// changes an alarm.
//
// Why separate responses. Sleep inertia after waking is mixed in its relation
// to the awakening stage, and prior sleep loss and circadian timing matter too
// (Hilditch & McHill 2019, doi:10.2147/NSS.S188911). A multimodal smart alarm
// showed little overall effect, with subgroup differences (Campanella et al.
// 2024, doi:10.3390/clockssleep6010013). Neither validates "time until the
// double confirmation" as a measure of a clean wake: that confirmation pairs an
// app open with movement or an alarm event, so it largely measures phone use.
// So each response is kept on its own, and a response that was not seen is
// null (unknown / censored), never 0 and never a maximum.

/// What the wearer did after the wake fired. Never substituted for one another.
enum WakeResponseKind {
  /// "I'm up" on Home, or a band double tap: a deliberate dismissal.
  deliberateAck,

  /// A foreground app touch.
  appInteraction,

  /// Band movement.
  movement,
}

/// Why a morning cannot be compared with the others. Declared in this order;
/// [WakeOutcome.exclusions] lists them in this order, without duplicates.
enum WakeExclusion {
  /// No wake haptic reached the band (and no armed native alarm at T).
  noDelivery,

  /// The app was already in use in the 10 minutes before the fire.
  alreadyAwake,

  /// The sleep-stage evidence behind the fire was older than 180 s.
  staleStage,

  /// Another alarm sat within 15 minutes before the fire.
  competingAlarm,

  /// The first response came more than 4 h after the fire: a different sleep
  /// episode, not a response to this wake.
  crossedEpisode,
}

/// Which mechanism woke the wearer.
enum WakeFiredBy { natural, gradual, native, none }

class WakeOutcome {
  const WakeOutcome({
    required this.wakeSec,
    required this.firedBy,
    this.firedAtSec,
    this.stageAtFire,
    this.stageAgeSec,
    required this.delivered,
    required this.latencySec,
    this.grogginess,
    this.minutesBeforeT,
    this.exclusions = const [],
  });

  /// T, the must-be-up-by time, epoch seconds. The key of the record.
  final int wakeSec;

  final WakeFiredBy firedBy;

  /// When the first wake haptic was delivered (native: T), epoch seconds.
  /// Null when nothing fired.
  final int? firedAtSec;

  /// 'rem' | 'awake' | null (no stage evidence: gradual, native, or a
  /// user-activity Natural fire).
  final String? stageAtFire;

  /// Age of the stage evidence at the fire, whole seconds. Null when unknown.
  final int? stageAgeSec;

  /// The band accepted at least one wake haptic, or the native alarm at T was
  /// confirmed armed.
  final bool delivered;

  /// Seconds from the fire to each response. Always holds all three keys; a
  /// null value means NOT OBSERVED (censored), never 0 and never a maximum.
  final Map<WakeResponseKind, int?> latencySec;

  /// 1..5, user-entered; null until rated.
  final int? grogginess;

  /// How early the fire was, minutes before T (native: 0.0). Null when nothing
  /// fired.
  final double? minutesBeforeT;

  final List<WakeExclusion> exclusions;

  /// Delivered and nothing excludes it.
  bool get usable => throw UnimplementedError();

  Map<String, Object?> toJson() => throw UnimplementedError();

  /// Throws FormatException/TypeError on a malformed map; callers that read
  /// storage catch it (see WakeOutcomeStore).
  factory WakeOutcome.fromJson(Map<String, Object?> json) =>
      throw UnimplementedError();
}
