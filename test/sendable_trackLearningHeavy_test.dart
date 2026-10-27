// ignore_for_file: file_names
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/tracks/learning.dart';
import 'package:openstrap_edge/tracks/learning_worker.dart';
import 'package:openstrap_edge/util/worker_init.dart';

final _bedtime = DateTime.utc(2026, 10, 25, 22);
final _track = TrackDefinition(
  id: 'a',
  name: 'A',
  icon: 'track',
  kind: 'consumed',
  systems: const ['sleep'],
  loggingComplete: true,
  loggingCompleteSinceMs: DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
  kinetics: const TrackKinetics({
    'half_life_hours': TrackKineticField(value: 6),
  }),
);

TrackLearningInput _input({
  List<TrackEvent> events = const [],
  List<TrackSetupRange> history = const [],
  List<Map<String, Object?>> absences = const [],
  TrackDefinition? track,
  DateTime? now,
  List<Map<String, Object?>>? days,
}) => TrackLearningInput(
  definitions: [
    {'id': 'a', 'payload_json': jsonEncode((track ?? _track).toJson())},
  ],
  events: [for (final event in events) event.toJson()],
  history: [for (final range in history) range.toJson()],
  absences: absences,
  states: const [],
  days: days ?? [_day('2026-10-26', _bedtime)],
  worker: WorkerInputs(
    nowEpochMs: (now ?? DateTime.utc(2026, 10, 27)).millisecondsSinceEpoch,
    zoneId: 'UTC',
    localeTag: 'en',
  ),
);

Map<String, Object?> _day(
  String id,
  DateTime at, {
  double hr = 55,
  double sleepHours = 7,
}) => {
  'day_id': id,
  // This is the persisted Metric envelope, not an invented flat window.
  'window_json': jsonEncode({
    'value': {
      'onset_ms': at.millisecondsSinceEpoch,
      'offset_ms': at.add(const Duration(hours: 8)).millisecondsSinceEpoch,
    },
    'confidence': .9,
  }),
  'payload_json': jsonEncode({
    'scalars': {'rhr': hr, 'strain': 4},
    'sleep': {
      'accounting': {
        'value': {'tst_sec': sleepHours * 3600},
      },
    },
    'coverage': {'rr_coverage': .95},
  }),
};

void main() {
  test(
    'medication snapshots merge their separate label and omit deleted medicines',
    () async {
      final input = TrackLearningInput(
        definitions: [
          {
            'payload_json': jsonEncode({
              'id': 'med:pill',
              'icon': 'pill',
              'kind': 'consumed',
            }),
          },
          {
            'payload_json': jsonEncode({
              'id': 'med:deleted',
              'icon': 'pill',
              'kind': 'consumed',
            }),
          },
        ],
        medications: const [
          {
            'key': 'pill',
            'label': 'My medicine',
            'dose_unit': 'mg',
            'active': 1,
          },
        ],
        events: const [],
        history: const [],
        absences: const [],
        states: const [],
        days: const [],
        worker: const WorkerInputs(
          nowEpochMs: 0,
          zoneId: 'UTC',
          localeTag: 'en',
        ),
      );
      final result = (await Isolate.run(
        () => trackLearningHeavy(input),
      )).toJson();
      expect((result['summaries'] as Map).keys, ['med:pill']);
      expect((result['updates'] as List).single['track_id'], 'med:pill');
    },
  );

  test(
    'slow learning retains fully logged history beyond the immediate lag window',
    () {
      final definition = TrackDefinition.fromJson({
        ..._track.toJson(),
        'logging_complete_since_ms': DateTime.utc(
          2026,
          7,
          1,
        ).millisecondsSinceEpoch,
        'kinetics': {
          ..._track.kinetics.toJson(),
          'tolerance_days': {'value': 3.0, 'locked': false},
          'withdrawal_days': {'value': 6.0, 'locked': false},
        },
      });
      final event = TrackEvent(
        id: 'old',
        trackId: 'a',
        date: '2026-09-25',
        amount: 100,
        atMs: _bedtime
            .subtract(const Duration(days: 30))
            .millisecondsSinceEpoch,
      );
      final night = trackNightsHeavy(
        _input(track: definition, events: [event]),
        [definition],
        [event],
        [],
      ).single;
      expect(night.completeHistoryTrackIds, {'a'});
      expect(night.events.map((e) => e.id), ['old']);
      final f = const TrackEffectEstimator().features(
        definition,
        night.events,
        night.at,
        historyComplete: night.completeHistoryTrackIds.contains('a'),
      );
      expect(f.dose, 0);
      expect(f.withdrawalPressure, greaterThan(0));
      final recent = TrackDefinition.fromJson({
        ...definition.toJson(),
        'logging_complete_since_ms': DateTime.utc(
          2026,
          10,
          1,
        ).millisecondsSinceEpoch,
      });
      expect(
        trackNightsHeavy(
          _input(track: recent),
          [recent],
          [],
          [],
        ).single.completeHistoryTrackIds,
        isEmpty,
      );
    },
  );

  test(
    'real day-result envelopes train selected-system statistics across isolate',
    () async {
      final input = _input(
        events: [
          TrackEvent(
            id: 'a-1',
            trackId: 'a',
            date: '2026-10-25',
            atMs: _bedtime
                .subtract(const Duration(hours: 6))
                .millisecondsSinceEpoch,
            amount: 100,
          ),
        ],
      );
      final result = (await Isolate.run(
        () => trackLearningHeavy(input),
      )).toJson();
      final state =
          jsonDecode((result['updates'] as List).single['state_json'] as String)
              as Map;
      expect(state['statistics'], {
        'sleep': {'count': 1, 'mean': 420.0, 'm2': 0.0},
      });
      expect(
        (state['effects'] as List).single['reason'],
        'insufficient_samples',
      );
      expect((result['updates'] as List).single['definition_json'], isNull);
    },
  );

  test('untimed logged use cannot become a fabricated zero-dose control', () {
    final input = _input(
      events: [
        const TrackEvent(
          id: 'a-1',
          trackId: 'a',
          date: '2026-10-25',
          amount: 100,
        ),
      ],
    );
    final night = trackNightsHeavy(
      input,
      [_track],
      [TrackEvent.fromJson(input.events.single)],
      [],
    ).single;
    expect(
      const TrackEffectEstimator()
          .features(_track, night.events, night.at)
          .dose,
      isNull,
    );
  });

  test(
    'setup history of use without a dose cannot become clean control data',
    () {
      final range = TrackSetupRange(
        id: 'h',
        trackId: 'a',
        startDate: '2026-10-01',
        endDate: '2026-10-26',
        done: true,
      );
      final night = trackNightsHeavy(
        _input(history: [range]),
        [_track],
        [],
        [range],
      ).single;
      expect(
        const TrackEffectEstimator()
            .features(_track, night.events, night.at)
            .dose,
        isNull,
      );
    },
  );

  test('logging pledge must cover the complete lag exposure window', () {
    final recent = TrackDefinition.fromJson({
      ..._track.toJson(),
      'logging_complete_since_ms': _bedtime
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    });
    final night = trackNightsHeavy(
      _input(track: recent),
      [recent],
      [],
      [],
    ).single;
    expect(night.completeTrackIds, isEmpty);
    expect(
      trackNightsHeavy(_input(), [_track], [], []).single.completeTrackIds,
      {'a'},
    );
  });

  test(
    'matching debt and negative controls precede the outcome and exposure',
    () {
      final input = _input(
        days: [
          for (var i = 0; i < 10; i++)
            _day(
              '2026-10-${17 + i}',
              _bedtime.subtract(Duration(days: 9 - i)),
              hr: 50.0 + i,
              sleepHours: i == 9
                  ? 1
                  : [0, 1, 7, 8].contains(i)
                  ? 8
                  : 6,
            ),
        ],
      );
      final nights = trackNightsHeavy(input, [_track], [], []);
      // Prior recent median=6h, prior weekend p75=8h. The current one-hour
      // outcome must not enter the predictor. Real per-day payload has no debt.
      expect(nights.last.sleepDebtHours, 2.0);
      expect(nights.last.negativeControls['hr'], 56.0);
      expect(nights.first.sleepDebtHours.isNaN, isTrue);
      expect(nights[2].sleepDebtHours.isNaN, isTrue);
      expect(nights.first.negativeControls, isEmpty);
    },
  );

  test(
    'an unrelated long-window track cannot delay acute negative controls',
    () {
      final unrelated = TrackDefinition(
        id: 'long',
        name: 'Long',
        icon: 'track',
        kind: 'consumed',
        systems: const ['mood'],
        loggingComplete: true,
        loggingCompleteSinceMs: DateTime.utc(2020).millisecondsSinceEpoch,
        kinetics: const TrackKinetics({
          'withdrawal_days': TrackKineticField(value: 28),
          'tolerance_days': TrackKineticField(value: 4),
        }),
      );
      final input = _input(
        days: [
          for (var i = 0; i < 10; i++)
            _day(
              '2026-10-${17 + i}',
              _bedtime.subtract(Duration(days: 9 - i)),
              hr: 50.0 + i,
            ),
        ],
      );
      final night = trackNightsHeavy(input, [_track, unrelated], [], []).last;
      expect(night.negativeControlsByTrack['a']?['hr'], 56.0);
    },
  );

  test('stale none-today confirmation cannot certify a later logged event', () {
    final definition = TrackDefinition.fromJson({
      ..._track.toJson(),
      'logging_complete': false,
    });
    final absences = [
      for (final date in ['2026-10-23', '2026-10-24', '2026-10-25'])
        {'track_id': 'a', 'date': date},
    ];
    final event = TrackEvent(
      id: 'new',
      trackId: 'a',
      date: '2026-10-25',
      atMs: _bedtime.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      amount: 100,
    );
    final input = _input(
      track: definition,
      absences: absences,
      events: [event],
    );
    final night = trackNightsHeavy(input, [definition], [event], []).single;
    expect(night.completeTrackIds, isEmpty);
    final clean = trackNightsHeavy(
      _input(track: definition, absences: absences),
      [definition],
      [],
      [],
    ).single;
    expect(clean.completeTrackIds, {'a'});
  });

  test('an outcome night cannot train before its sleep window has ended', () {
    final input = _input(now: _bedtime.add(const Duration(hours: 1)));
    expect(trackNightsHeavy(input, [_track], [], []), isEmpty);
  });
}
