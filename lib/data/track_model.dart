// TracksStore owns mutable track definitions, setup history and manual events.
// These immutable values preserve unknown kinetics and independent field locks.

class TrackKineticField {
  const TrackKineticField({this.value, this.locked = false});
  final double? value;
  final bool locked;
  factory TrackKineticField.fromJson(Map<String, dynamic> j) =>
      TrackKineticField(
        value: (j['value'] as num?)?.toDouble(),
        locked: j['locked'] == true,
      );
  Map<String, Object?> toJson() => {'value': value, 'locked': locked};
}

const trackKineticKeys = [
  'half_life_hours',
  'onset_hours',
  'tolerance_days',
  'withdrawal_days',
];
const trackRoles = [
  'own_sleep',
  'detectable',
  'workout_modifier',
  'recovery_modifier',
  'exclude_baselines',
  'reminder_aware',
];
const trackSystems = [
  'sleep',
  'hr',
  'hrv',
  'stress',
  'blood_pressure',
  'glucose',
  'skin_temp',
  'workout_intensity',
  'recovery',
  'mood',
  'respiration',
];

class TrackKinetics {
  const TrackKinetics(this.fields);
  final Map<String, TrackKineticField> fields;
  factory TrackKinetics.fromJson(Map<String, dynamic> j) => TrackKinetics({
    for (final key in {...trackKineticKeys, ...j.keys})
      key: TrackKineticField.fromJson(
        (j[key] as Map? ?? {}).cast<String, dynamic>(),
      ),
  });
  Map<String, Object?> toJson() => {
    for (final e in fields.entries) e.key: e.value.toJson(),
  };
}

class TrackSubActivity {
  const TrackSubActivity({
    required this.id,
    required this.name,
    this.kinetics = const TrackKinetics({}),
  });
  final String id, name;
  final TrackKinetics kinetics;
  factory TrackSubActivity.fromJson(Map<String, dynamic> j) => TrackSubActivity(
    id: j['id'] as String,
    name: j['name'] as String,
    kinetics: TrackKinetics.fromJson(
      (j['kinetics'] as Map? ?? {}).cast<String, dynamic>(),
    ),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kinetics': kinetics.toJson(),
  };
}

class TrackDefinition {
  const TrackDefinition({
    required this.id,
    required this.name,
    required this.icon,
    required this.kind,
    this.unit = '',
    this.kinetics = const TrackKinetics({}),
    this.subActivities = const [],
    this.roles = const [],
    this.systems = const [],
    this.detectionMin = 0,
    this.detectionMax = 10,
    this.noUnadjustedData = false,
    this.prescribed = false,
    this.enabled = true,
    this.loggingComplete = false,
    this.loggingCompleteSinceMs,
    this.sources = const [],
  });
  final String id, name, icon, kind, unit;
  final TrackKinetics kinetics;
  final List<TrackSubActivity> subActivities;
  final List<String> roles, systems, sources;
  final int detectionMin, detectionMax;
  final bool noUnadjustedData, enabled, loggingComplete;

  /// The wearer was told to do this by a clinician. Stored in payload_json
  /// (no DDL); a `med:` track is prescribed regardless of the flag.
  final bool prescribed;
  bool get isPrescribed => prescribed || id.startsWith('med:');
  final int? loggingCompleteSinceMs;
  factory TrackDefinition.fromJson(Map<String, dynamic> j) => TrackDefinition(
    id: j['id'] as String,
    name: j['name'] as String,
    icon: j['icon'] as String? ?? 'track',
    kind: j['kind'] as String? ?? 'activity',
    unit: j['unit'] as String? ?? '',
    kinetics: TrackKinetics.fromJson(
      (j['kinetics'] as Map? ?? {}).cast<String, dynamic>(),
    ),
    subActivities: [
      for (final s in j['sub_activities'] as List? ?? [])
        TrackSubActivity.fromJson((s as Map).cast<String, dynamic>()),
    ],
    roles: (j['roles'] as List? ?? []).cast<String>(),
    systems: (j['systems'] as List? ?? []).cast<String>(),
    sources: (j['sources'] as List? ?? []).cast<String>(),
    detectionMin: (j['detection_min'] as num?)?.toInt() ?? 0,
    detectionMax: (j['detection_max'] as num?)?.toInt() ?? 10,
    noUnadjustedData: j['no_unadjusted_data'] == true,
    prescribed: j['prescribed'] == true,
    enabled: j['enabled'] != false,
    loggingComplete: j['logging_complete'] == true,
    loggingCompleteSinceMs: (j['logging_complete_since_ms'] as num?)?.toInt(),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'kind': kind,
    'unit': unit,
    'kinetics': kinetics.toJson(),
    'sub_activities': [for (final s in subActivities) s.toJson()],
    'roles': roles,
    'systems': systems,
    'sources': sources,
    'detection_min': detectionMin,
    'detection_max': detectionMax,
    'no_unadjusted_data': noUnadjustedData,
    'prescribed': prescribed,
    'enabled': enabled,
    'logging_complete': loggingComplete,
    'logging_complete_since_ms': loggingCompleteSinceMs,
  };
  String? get validationError {
    if (id.isEmpty || name.trim().isEmpty) return 'name';
    if (!['consumed', 'activity', 'condition'].contains(kind)) return 'kind';
    if (detectionMin < 0 || detectionMax < detectionMin) {
      return 'detection_bounds';
    }
    for (final k in [kinetics, ...subActivities.map((s) => s.kinetics)]) {
      for (final f in k.fields.values) {
        if (f.value != null && (!f.value!.isFinite || f.value! < 0)) {
          return 'kinetics';
        }
      }
    }
    if (subActivities.any((s) => s.id.isEmpty || s.name.trim().isEmpty) ||
        subActivities.map((s) => s.id).toSet().length != subActivities.length) {
      return 'sub_activities';
    }
    return null;
  }
}

/// The stored `end_date` of a period with no end ("since X").
// CLAIM(ongoing-sentinel): an ongoing period is stored with end_date =
// 9999-12-31, so the table CHECK (start_date <= end_date) stays true and every
// reader that tests `start <= day <= end` (learning, wake profile, the
// selected-day export, overlap validation) treats it as covering every later
// day with no extra branch [tracks_setup_range_test; tracks_history_schema_test].
// Only DoneRange can be ongoing; code outside this file asks `ongoing`, never
// compares against the literal.
const String kOngoingEndDate = '9999-12-31';

/// `TrackEvent.sourceKind` of an in-memory exposure synthesized from a period.
/// Such an event is never written to track_event and never shown.
const String kRangeExposureSource = 'history';

/// An amount per day in the unit the track had when the wearer entered it
/// ('' for a unitless track). The unit travels with the number so a later unit
/// change abstains instead of silently rescaling.
final class DailyAmount {
  const DailyAmount(this.value, this.unit);
  final double value;
  final String unit;
}

/// What a taken-daily period says about each day. Both parts are optional;
/// null means unknown, never zero.
final class DailyIntake {
  const DailyIntake({this.approxMinute, this.amount});

  /// Local wall-clock minute of the day, 0..1439.
  final int? approxMinute;
  final DailyAmount? amount;

  /// The first invalid field's stored name, or null.
  String? get validationError {
    final minute = approxMinute;
    if (minute != null && (minute < 0 || minute >= 1440)) {
      return 'approx_minute';
    }
    final a = amount;
    if (a != null && (!a.value.isFinite || a.value <= 0)) return 'amount';
    return null;
  }

  /// Parse, don't validate: a stored value that cannot be right reads as
  /// unknown, so learning never trusts a clamped or zero stand-in.
  factory DailyIntake.fromJson(Map<String, dynamic> j) {
    final rawMinute = j['approx_minute'];
    final minute =
        rawMinute is num &&
            rawMinute.isFinite &&
            rawMinute == rawMinute.truncate()
        ? rawMinute.toInt()
        : null;
    final rawAmount = j['amount'], rawUnit = j['amount_unit'];
    final value = rawAmount is num ? rawAmount.toDouble() : null;
    return DailyIntake(
      approxMinute: minute != null && minute >= 0 && minute < 1440
          ? minute
          : null,
      amount: value != null && value.isFinite && value > 0 && rawUnit is String
          ? DailyAmount(value, rawUnit)
          : null,
    );
  }
}

/// A date range of the setup history. Sealed: a period either was done (and
/// may then carry an intake and have no end) or was not (and carries neither),
/// so the invalid mixes cannot be built.
/// Mating parts: TracksStore (validates and persists), tracks_schema.dart (the
/// columns), learning_worker.dart / range_exposure.dart (reads).
// CLAIM(range-invariants): a NotDoneRange has no intake and no open end by
// construction; a stored row that says otherwise reads as plain not-done
// [tracks_setup_range_test].
// CLAIM(range-columns): the stored row is exactly id, track_id, start_date,
// end_date, done, approx_minute, amount, amount_unit; the last three are NULL
// unless done = 1 [tracks_setup_range_test, tracks_history_schema_test].
sealed class TrackSetupRange {
  const TrackSetupRange._(this.id, this.trackId, this.startDate);

  /// The five-field form every pre-P8a caller used. An ongoing end is only
  /// meaningful for a done range.
  factory TrackSetupRange({
    required String id,
    required String trackId,
    required String startDate,
    required String endDate,
    required bool done,
  }) => done
      ? DoneRange(
          id: id,
          trackId: trackId,
          startDate: startDate,
          untilDate: endDate == kOngoingEndDate ? null : endDate,
        )
      : NotDoneRange(
          id: id,
          trackId: trackId,
          startDate: startDate,
          endDate: endDate,
        );
  final String id, trackId, startDate;

  /// The stored end; [kOngoingEndDate] for an ongoing period.
  String get endDate;
  bool get done;

  /// The first invalid intake field's name, or null. Dates are validated by
  /// TracksStore, which owns the calendar rules.
  String? get validationError;
  factory TrackSetupRange.fromJson(Map<String, dynamic> j) {
    final done = j['done'] == true || j['done'] == 1;
    final id = j['id'] as String,
        trackId = j['track_id'] as String,
        start = j['start_date'] as String,
        end = j['end_date'] as String;
    return done
        ? DoneRange(
            id: id,
            trackId: trackId,
            startDate: start,
            untilDate: end == kOngoingEndDate ? null : end,
            intake: DailyIntake.fromJson(j),
          )
        : NotDoneRange(
            id: id,
            trackId: trackId,
            startDate: start,
            endDate: end,
          );
  }
  Map<String, Object?> toJson();
}

final class NotDoneRange extends TrackSetupRange {
  const NotDoneRange({
    required String id,
    required String trackId,
    required String startDate,
    required this.endDate,
  }) : super._(id, trackId, startDate);
  @override
  final String endDate;
  @override
  bool get done => false;
  @override
  String? get validationError => null;
  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'track_id': trackId,
    'start_date': startDate,
    'end_date': endDate,
    'done': 0,
    'approx_minute': null,
    'amount': null,
    'amount_unit': null,
  };
}

final class DoneRange extends TrackSetupRange {
  const DoneRange({
    required String id,
    required String trackId,
    required String startDate,
    this.untilDate,
    this.intake = const DailyIntake(),
  }) : super._(id, trackId, startDate);

  /// The last day, or null for an ongoing period.
  final String? untilDate;
  final DailyIntake intake;
  bool get ongoing => untilDate == null;
  @override
  String get endDate => untilDate ?? kOngoingEndDate;
  @override
  bool get done => true;
  @override
  String? get validationError => intake.validationError;
  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'track_id': trackId,
    'start_date': startDate,
    'end_date': endDate,
    'done': 1,
    'approx_minute': intake.approxMinute,
    'amount': intake.amount?.value,
    'amount_unit': intake.amount?.unit,
  };
}

class TrackEvent {
  const TrackEvent({
    required this.id,
    required this.trackId,
    required this.date,
    this.atMs,
    this.amount,
    this.subActivityId,
    this.unit,
    this.sourceKind = 'manual',
    String? sourceId,
  }) : sourceId = sourceId ?? id;
  final String id, trackId, date, sourceKind, sourceId;
  final int? atMs;
  final double? amount;
  final String? subActivityId, unit;
  factory TrackEvent.fromJson(Map<String, dynamic> j) => TrackEvent(
    id: j['id'] as String,
    trackId: j['track_id'] as String,
    date: j['date'] as String,
    atMs: (j['at_ms'] as num?)?.toInt(),
    amount: (j['amount'] as num?)?.toDouble(),
    subActivityId: j['sub_activity_id'] as String?,
    unit: j['unit'] as String?,
    sourceKind: j['source_kind'] as String? ?? 'manual',
    sourceId: j['source_id'] as String?,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'track_id': trackId,
    'date': date,
    'at_ms': atMs,
    'amount': amount,
    'sub_activity_id': subActivityId,
    'unit': unit,
    'source_kind': sourceKind,
    'source_id': sourceId,
  };
}
