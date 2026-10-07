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
  /// No wake haptic reached the band (and no armed, confirmed native alarm at T).
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

const Object _keep = Object();

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
    this.configuredWindowMinutes,
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

  /// The BAND was a delivered target of at least one wake haptic, or the native
  /// alarm at T was armed and confirmed.
  final bool delivered;

  /// Seconds from the fire to each response. Always holds all three keys; a
  /// null value means NOT OBSERVED (censored), never 0 and never a maximum.
  final Map<WakeResponseKind, int?> latencySec;

  /// 1..5, user-entered; null until rated.
  final int? grogginess;

  /// How early the fire was, minutes before T (native: 0.0). Null when nothing
  /// fired.
  final double? minutesBeforeT;

  /// The Natural window configured for that night, minutes (the plan row's
  /// naturalMinutes). This, not when the fire happened, is the policy that was
  /// in force. Null when unknown (no plan row, or stored before it was kept).
  final int? configuredWindowMinutes;

  final List<WakeExclusion> exclusions;

  /// Delivered and nothing excludes it.
  bool get usable => delivered && exclusions.isEmpty;

  /// A copy with the given fields replaced. EVERY place that rebuilds an
  /// outcome goes through this, so a field added later cannot be dropped by a
  /// hand-written constructor call (rating once lost configuredWindowMinutes
  /// that way). Only [grogginess] can be set back to null (pass null
  /// explicitly); the other nullable fields keep their value when omitted.
  WakeOutcome copyWith({
    int? firedAtSec,
    String? stageAtFire,
    int? stageAgeSec,
    bool? delivered,
    Map<WakeResponseKind, int?>? latencySec,
    Object? grogginess = _keep,
    double? minutesBeforeT,
    int? configuredWindowMinutes,
    List<WakeExclusion>? exclusions,
  }) =>
      WakeOutcome(
        wakeSec: wakeSec,
        firedBy: firedBy,
        firedAtSec: firedAtSec ?? this.firedAtSec,
        stageAtFire: stageAtFire ?? this.stageAtFire,
        stageAgeSec: stageAgeSec ?? this.stageAgeSec,
        delivered: delivered ?? this.delivered,
        latencySec: latencySec ?? this.latencySec,
        grogginess:
            identical(grogginess, _keep) ? this.grogginess : grogginess as int?,
        minutesBeforeT: minutesBeforeT ?? this.minutesBeforeT,
        configuredWindowMinutes:
            configuredWindowMinutes ?? this.configuredWindowMinutes,
        exclusions: exclusions ?? this.exclusions,
      );

  Map<String, Object?> toJson() => {
        'wakeSec': wakeSec,
        'firedBy': firedBy.name,
        'firedAtSec': firedAtSec,
        'stageAtFire': stageAtFire,
        'stageAgeSec': stageAgeSec,
        'delivered': delivered,
        'latencySec': {
          for (final kind in WakeResponseKind.values) kind.name: latencySec[kind],
        },
        'grogginess': grogginess,
        'minutesBeforeT': minutesBeforeT,
        'configuredWindowMinutes': configuredWindowMinutes,
        'exclusions': [for (final exclusion in exclusions) exclusion.name],
      };

  /// Throws FormatException/TypeError on a malformed map; callers that read
  /// storage catch it (see WakeOutcomeStore).
  factory WakeOutcome.fromJson(Map<String, Object?> json) {
    T requiredValue<T>(String key) {
      final value = json[key];
      if (value is! T) throw FormatException('Invalid wake outcome $key');
      return value;
    }

    int? nullableInt(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! int) throw FormatException('Invalid wake outcome $key');
      return value;
    }

    String? nullableString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) throw FormatException('Invalid wake outcome $key');
      return value;
    }

    double? nullableDouble(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! num) throw FormatException('Invalid wake outcome $key');
      return value.toDouble();
    }

    final firedByName = requiredValue<String>('firedBy');
    final firedBy = WakeFiredBy.values.where((v) => v.name == firedByName);
    if (firedBy.isEmpty) throw FormatException('Invalid wake outcome firedBy');

    final rawLatency = requiredValue<Object?>('latencySec');
    if (rawLatency is! Map) throw FormatException('Invalid wake outcome latencySec');
    final latency = <WakeResponseKind, int?>{};
    for (final kind in WakeResponseKind.values) {
      if (!rawLatency.containsKey(kind.name)) {
        throw FormatException('Missing wake outcome latency ${kind.name}');
      }
      final value = rawLatency[kind.name];
      if (value != null && value is! int) {
        throw FormatException('Invalid wake outcome latency ${kind.name}');
      }
      latency[kind] = value as int?;
    }

    final rawExclusions = requiredValue<Object?>('exclusions');
    if (rawExclusions is! List) {
      throw FormatException('Invalid wake outcome exclusions');
    }
    final exclusions = <WakeExclusion>[];
    for (final value in rawExclusions) {
      if (value is! String) {
        throw FormatException('Invalid wake outcome exclusion');
      }
      final matching = WakeExclusion.values.where((v) => v.name == value);
      if (matching.isEmpty) {
        throw FormatException('Invalid wake outcome exclusion');
      }
      exclusions.add(matching.first);
    }

    return WakeOutcome(
      wakeSec: requiredValue<int>('wakeSec'),
      firedBy: firedBy.first,
      firedAtSec: nullableInt('firedAtSec'),
      stageAtFire: nullableString('stageAtFire'),
      stageAgeSec: nullableInt('stageAgeSec'),
      delivered: requiredValue<bool>('delivered'),
      latencySec: latency,
      grogginess: nullableInt('grogginess'),
      minutesBeforeT: nullableDouble('minutesBeforeT'),
      configuredWindowMinutes: nullableInt('configuredWindowMinutes'),
      exclusions: exclusions,
    );
  }
}
