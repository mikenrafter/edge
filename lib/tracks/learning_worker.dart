// TracksStore owns durable state. This worker owns a single immutable snapshot.
import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../data/day_label.dart';
import '../data/track_model.dart';
import '../data/track_snapshot.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';
import 'learning.dart';

@SendableShape('SQLite primitive maps; sendable_trackLearningHeavy_test')
class TrackLearningInput {
  const TrackLearningInput({
    required this.definitions,
    this.medications = const [],
    required this.events,
    required this.history,
    required this.absences,
    required this.states,
    required this.days,
    required this.worker,
    this.experiments = const [],
  });
  final List<Map<String, Object?>> definitions,
      events,
      history,
      absences,
      states,
      days;
  final List<Map<String, Object?>> medications, experiments;
  final WorkerInputs worker;
}

@SendableShape('Primitive row maps; sendable_trackLearningHeavy_test')
class TrackLearningResult {
  const TrackLearningResult(this.updates, this.summaries);
  final List<Map<String, Object?>> updates;
  final Map<String, Map<String, Object?>> summaries;
  Map<String, Object?> toJson() => {'updates': updates, 'summaries': summaries};
}

@heavy
TrackLearningResult trackLearningHeavy(TrackLearningInput input) {
  WorkerInit.ensure(input.worker);
  assertWorker();
  WorkerAudit.entered('trackLearningHeavy');
  final now = DateTime.fromMillisecondsSinceEpoch(input.worker.nowEpochMs);
  final tracks = decodeTrackDefinitionsHeavy(
    input.definitions,
    input.medications,
  );
  final events = [for (final row in input.events) TrackEvent.fromJson(row)];
  final ranges = [
    for (final row in input.history) TrackSetupRange.fromJson(row),
  ];
  final nights = trackNightsHeavy(input, tracks, events, ranges);
  final estimates = const TrackEffectEstimator().estimate(
    tracks: tracks,
    nights: nights,
    asOf: now,
  );
  const policy = TrackLearningPolicy();
  final updates = <Map<String, Object?>>[],
      summaries = <String, Map<String, Object?>>{};
  for (final track in tracks) {
    if (!track.enabled) continue;
    final saved = input.states
        .where((r) => r['track_id'] == track.id)
        .firstOrNull;
    final state = saved == null
        ? <String, dynamic>{}
        : (jsonDecode(saved['state_json'] as String) as Map)
              .cast<String, dynamic>();
    var started = (saved?['started_ms'] as int?) ?? input.worker.nowEpochMs;
    if (saved == null) {
      for (final event in events.where(
        (e) =>
            e.trackId == track.id &&
            e.atMs != null &&
            e.atMs! <= input.worker.nowEpochMs,
      )) {
        if (event.atMs! < started) started = event.atMs!;
      }
      for (final range in ranges.where((r) => r.trackId == track.id)) {
        final at = DateTime.parse(range.startDate).millisecondsSinceEpoch;
        if (at < started) started = at;
      }
    }
    final age = Duration(milliseconds: input.worker.nowEpochMs - started);
    // A running randomized experiment owns its track's estimation: nothing
    // observational fills in for days the experiment has not yet resolved.
    // CLAIM(experiment-precedence-is-abstention): "experiment days take
    // precedence in estimation" means exactly this abstention while the
    // experiment runs. An experiment's result is reported on its own screen and
    // does NOT feed the learned effect; afterwards its nights are ordinary
    // observational nights [review T18; plan note in fix-t3-report.md].
    final today = dayLabelOf(now);
    final inExperiment = input.experiments.any(
      (r) =>
          r['track_id'] == track.id &&
          (r['start_date'] as String).compareTo(today) <= 0 &&
          (r['end_date'] as String).compareTo(today) >= 0,
    );
    final own = inExperiment
        ? [
            for (final system in track.systems)
              TrackEffectEstimate(
                trackId: track.id,
                system: system,
                reason: 'experiment_learning',
              ),
          ]
        : estimates.where((e) => e.trackId == track.id).toList();
    final reason = age < policy.globalMinimum
        ? 'global_learning'
        : own.isEmpty
        ? 'missing_system_data'
        : own
              .firstWhere((e) => e.effect != null, orElse: () => own.first)
              .reason;
    final stats = <String, Object?>{};
    for (final system in track.systems) {
      var moments = const TrackMoments();
      for (final night in nights) {
        if (night.at.isAfter(now) ||
            !night.completeTrackIds.contains(track.id) ||
            !night.events.any(
              (e) =>
                  e.trackId == track.id &&
                  e.atMs != null &&
                  e.atMs! <= night.at.millisecondsSinceEpoch &&
                  night.at.millisecondsSinceEpoch - e.atMs! <
                      const Duration(hours: 24).inMilliseconds,
            )) {
          continue;
        }
        final value = night.outcomes[system];
        if (value != null && value.isFinite) moments = moments.add(value);
      }
      stats[system] = {
        'count': moments.count,
        'mean': moments.count == 0 ? null : moments.mean,
        'm2': moments.m2,
      };
    }
    final date = dayLabelOf(now), fields = {...track.kinetics.fields};
    var subActivities = track.subActivities;
    final periods = (state['periods_us'] as Map? ?? {}).cast<String, dynamic>();
    final logs = <Map<String, Object?>>[];
    final canStep = saved?['last_step_date'] != date;
    // ↳ CLAIM(experiment-precedence-is-abstention): the abstention is not weak
    // evidence, so no period adapts and no audit row is written (review T9).
    if (canStep && !inExperiment && age >= policy.globalMinimum) {
      for (final field in trackKineticKeys) {
        if (fields[field]?.locked == true &&
            !hasUnlockedOverride(subActivities, field)) {
          continue;
        }
        final oldPeriod = periods[field] as int?;
        final intrinsic = policy
            .minimumFor(field, track.kinetics)
            .inMicroseconds;
        final period = policy.minimumFor(
          field,
          track.kinetics,
          learnedMinimum: Duration(microseconds: oldPeriod ?? intrinsic),
        );
        // Weak evidence lengthens observation; stable evidence gradually brings
        // it back toward the kinetics floor. Neither can bypass the floor.
        final supported = own.any((e) => e.effect != null);
        final adapted = policy.minimumFor(
          field,
          track.kinetics,
          learnedMinimum: Duration(
            microseconds: (period.inMicroseconds * (supported ? .99 : 1.01))
                .round(),
          ),
        );
        periods[field] = adapted.inMicroseconds;
        if (adapted != period) {
          logs.add({
            'track_id': track.id,
            'date': date,
            'field': '$field:minimum',
            'before_value': period.inMicroseconds.toDouble(),
            'after_value': adapted.inMicroseconds.toDouble(),
            'reason': supported
                ? 'stable_evidence_period'
                : 'need_more_evidence_period',
          });
        }
        final targets = own
            .where(
              (e) => e.effect != null && e.kineticTargets.containsKey(field),
            )
            .toList();
        if (targets.isEmpty) continue;
        // Conflicting system fits do not change a shared kinetic field.
        final target = targets.first.kineticTargets[field]!;
        if (targets.any(
          (e) => (e.kineticTargets[field]! - target).abs() > target.abs() * .1,
        )) {
          continue;
        }
        // ↳ CLAIM(override-independent)
        final applied = applyKineticTarget(
          policy: policy,
          track: track,
          fields: fields,
          subActivities: subActivities,
          field: field,
          age: age,
          target: target,
          date: date,
          reason: 'time_ordered_matched_fit',
          learnedMinimum: adapted,
        );
        // Only ever adds or updates keys; never clear (a held step returns
        // the same values and clearing would empty the map) [R3-1].
        fields.addAll(applied.fields);
        subActivities = applied.subActivities;
        logs.addAll(applied.logs);
      }
    }
    final changed = logs.any(
      (r) => !(r['field'] as String).endsWith(':minimum'),
    );
    final nextState = {
      'periods_us': periods,
      'statistics': stats,
      'effects': [
        for (final e in own)
          {
            'system': e.system,
            'effect': e.effect,
            'reason': e.reason,
            'matched_pairs': e.matchedPairs,
            'shuffle_p': e.shuffleP,
            'adjusted_p': e.adjustedP,
          },
      ],
    };
    updates.add({
      'track_id': track.id,
      'started_ms': started,
      'last_step_date': date,
      'state_json': jsonEncode(nextState),
      'logs': logs,
      if (changed)
        'definition_json': jsonEncode({
          ...track.toJson(),
          'kinetics': TrackKinetics(fields).toJson(),
          'sub_activities': [for (final s in subActivities) s.toJson()],
        }),
    });
    summaries[track.id] = {
      'reason': reason,
      'days': age.inDays,
      'minimum_days': policy.globalMinimum.inDays,
      ...nextState,
    };
  }
  return TrackLearningResult(updates, summaries);
}

@heavy
List<TrackNight> trackNightsHeavy(
  TrackLearningInput input,
  List<TrackDefinition> tracks,
  List<TrackEvent> events,
  List<TrackSetupRange> ranges,
) {
  final rows = [...input.days]
    ..sort((a, b) => (a['day_id'] as String).compareTo(b['day_id'] as String));
  final nights = <TrackNight>[];
  final past = <String, List<double>>{};
  Map<String, dynamic> map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : {};
  double? number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  Map<String, double>? previous;
  final durationHours = <double>[], freeDurationHours = <double>[];
  final observations = <({int endMs, Map<String, double> outcomes})>[];
  for (final row in rows) {
    final payload = map(jsonDecode(row['payload_json'] as String));
    final envelope = map(jsonDecode(row['window_json'] as String? ?? '{}'));
    final window = envelope['value'] is Map ? map(envelope['value']) : envelope;
    final onset = number(window['onset_ms']);
    final offset = number(window['offset_ms']);
    // An outcome is available only after its full window, even during an
    // historical replay whose as-of instant falls inside a finalized night.
    if (onset == null ||
        offset == null ||
        offset <= onset ||
        offset > input.worker.nowEpochMs) {
      continue;
    }
    final at = DateTime.fromMillisecondsSinceEpoch(onset.toInt());
    final sc = map(payload['scalars']);
    final sleep = map(payload['sleep']);
    final accounting = map(map(sleep['accounting'])['value']);
    // Sleep debt is a cross-day metric, not a field in per-day payloads.
    // Ask the existing analytics implementation using only completed prior
    // nights, preserving absence when habitual/free-night input is too thin.
    final recent = durationHours.length <= 7
        ? durationHours
        : durationHours.sublist(durationHours.length - 7);
    final debt = ana.sleepDebt(recent, freeDurationHours).value?.debtHours;
    final outcomes = <String, double>{};
    final sourceKeys = {
      'hr': 'rhr',
      'hrv': 'rmssd',
      'stress': 'stress',
      'skin_temp': 'skin_temp_dev_c',
      'workout_intensity': 'strain',
      'recovery': 'readiness',
      'respiration': 'resp_rate',
    };
    for (final e in sourceKeys.entries) {
      final value = number(sc[e.value]);
      if (value != null) outcomes[e.key] = value;
    }
    final tst = number(accounting['tst_sec']);
    if (tst != null) outcomes['sleep'] = tst / 60;
    final baselines = <String, double>{};
    for (final e in past.entries) {
      final trailing = e.value.length <= 28
          ? e.value
          : e.value.sublist(e.value.length - 28);
      if (trailing.length >= 7) {
        baselines[e.key] = trailing.reduce((a, b) => a + b) / trailing.length;
      }
    }
    final exposureStart = at.subtract(const Duration(hours: 48));
    final dates = <String>[];
    for (
      var cursor = DateTime(
        exposureStart.year,
        exposureStart.month,
        exposureStart.day,
      );
      !cursor.isAfter(at);
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1)
    ) {
      dates.add(dayLabelOf(cursor));
    }
    final complete = <String>{}, historyComplete = <String>{};
    final oldest = tracks
        .where((t) => t.enabled)
        .fold<Duration>(
          const Duration(hours: 48),
          (window, track) => trackHistoryWindow(track) > window
              ? trackHistoryWindow(track)
              : window,
        );
    final historyStart = at.subtract(oldest);
    final firstHistoryDate = dayLabelOf(historyStart);
    final lastHistoryDate = dayLabelOf(at);
    final nightEvents = [
      for (final e in events)
        if (e.atMs == null
            ? e.date.compareTo(firstHistoryDate) >= 0 &&
                  e.date.compareTo(lastHistoryDate) <= 0
            : e.atMs! <= at.millisecondsSinceEpoch &&
                  e.atMs! >= historyStart.millisecondsSinceEpoch)
          e,
    ];
    for (final d in tracks) {
      bool confirmedDate(String date) =>
          input.absences.any(
            (a) =>
                a['track_id'] == d.id &&
                a['date'] == date &&
                !events.any((e) => e.trackId == d.id && e.date == date),
          ) ||
          ranges.any(
            (r) =>
                r.trackId == d.id &&
                r.startDate.compareTo(date) <= 0 &&
                r.endDate.compareTo(date) >= 0,
          );
      final since = d.loggingComplete ? d.loggingCompleteSinceMs : null;
      if ((since != null && exposureStart.millisecondsSinceEpoch >= since) ||
          dates.every(confirmedDate)) {
        complete.add(d.id);
      }
      final start = at.subtract(trackHistoryWindow(d));
      var fullHistory = since != null && start.millisecondsSinceEpoch >= since;
      var confirmedHistory = true;
      for (
        var day = DateTime(start.year, start.month, start.day);
        !day.isAfter(at);
        day = DateTime(day.year, day.month, day.day + 1)
      ) {
        final date = dayLabelOf(day);
        if (!confirmedDate(date)) confirmedHistory = false;
        if (ranges.any(
              (r) =>
                  r.trackId == d.id &&
                  r.done &&
                  r.startDate.compareTo(date) <= 0 &&
                  r.endDate.compareTo(date) >= 0,
            ) &&
            !nightEvents.any((e) => e.trackId == d.id && e.date == date)) {
          // Setup history establishes use, never a dose or time. These markers
          // preserve unknown exposure for both acute and slow learning.
          nightEvents.add(
            TrackEvent(id: 'history:${d.id}:$date', trackId: d.id, date: date),
          );
        }
      }
      fullHistory = fullHistory || confirmedHistory;
      if (fullHistory) historyComplete.add(d.id);
    }
    final negative = observations
        .where((n) => n.endMs <= exposureStart.millisecondsSinceEpoch)
        .lastOrNull
        ?.outcomes;
    final controlsByTrack = <String, Map<String, double>>{};
    for (final track in tracks.where((t) => t.enabled)) {
      final history = historyComplete.contains(track.id)
          ? const TrackEffectEstimator().features(
              track,
              nightEvents,
              at,
              historyComplete: true,
            )
          : null;
      // A track's eligible history chooses its own pre-exposure control. An
      // unrelated long-window track cannot postpone another track's learning.
      final cutoff = at.subtract(
        history?.effectiveResidual != null
            ? trackHistoryWindow(track)
            : const Duration(hours: 48),
      );
      controlsByTrack[track.id] =
          observations
              .where((n) => n.endMs <= cutoff.millisecondsSinceEpoch)
              .lastOrNull
              ?.outcomes ??
          {};
    }
    // Missing covariates stay NaN and are rejected by matching. An absent
    // debt, load or coverage is never replaced by an apparently clean zero.
    nights.add(
      TrackNight(
        at: at,
        bedtimeMinute: at.hour * 60 + at.minute,
        sleepDebtHours: debt ?? double.nan,
        load: previous?['workout_intensity'] ?? double.nan,
        outcomes: outcomes,
        baselines: baselines,
        completeTrackIds: complete,
        completeHistoryTrackIds: historyComplete,
        coverage: number(map(payload['coverage'])['rr_coverage']) ?? 0,
        negativeControls: negative ?? {},
        negativeControlsByTrack: controlsByTrack,
        events: nightEvents,
      ),
    );
    for (final e in outcomes.entries) {
      past.putIfAbsent(e.key, () => []).add(e.value);
    }
    previous = outcomes;
    if (tst != null) {
      durationHours.add(tst / 3600);
      // Same engineering calendar-weekend approximation as crossday_pipeline.
      if (DateTime.parse(row['day_id'] as String).weekday >=
          DateTime.saturday) {
        freeDurationHours.add(tst / 3600);
      }
    }
    observations.add((endMs: offset.toInt(), outcomes: outcomes));
  }
  return nights;
}
