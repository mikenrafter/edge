// P8a item 2: learning treats every day of a "taken daily" period as an
// in-memory exposure (never persisted, never shown as an event). Tests below
// pin: which days get one, what the exposure says (time, amount, unit), how the
// estimator reads it, and that the worker feeds it to nights.
//
// Dates are local wall-clock dates built with DateTime(y, m, d, h, min), never
// from UTC instants, so the file means the same under TZ=UTC and a DST zone.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/track_model.dart';
import 'package:openstrap_edge/tracks/learning.dart';
import 'package:openstrap_edge/tracks/learning_worker.dart';
import 'package:openstrap_edge/tracks/range_exposure.dart';
import 'package:openstrap_edge/util/worker_init.dart';

const _estimator = TrackEffectEstimator();

TrackDefinition _track({
  String unit = 'mg',
  double? onset = 0,
  double? tolerance,
  double? withdrawal,
  bool loggingComplete = false,
}) => TrackDefinition(
  id: 'a',
  name: 'A',
  icon: 'track',
  kind: 'consumed',
  unit: unit,
  systems: const ['sleep'],
  loggingComplete: loggingComplete,
  kinetics: TrackKinetics({
    'half_life_hours': const TrackKineticField(value: 6),
    'onset_hours': TrackKineticField(value: onset),
    if (tolerance != null)
      'tolerance_days': TrackKineticField(value: tolerance),
    if (withdrawal != null)
      'withdrawal_days': TrackKineticField(value: withdrawal),
  }),
);

DoneRange _done(
  String from, {
  String? until,
  int? minute = 480,
  DailyAmount? amount = const DailyAmount(50, 'mg'),
  String id = 'r',
}) => DoneRange(
  id: id,
  trackId: 'a',
  startDate: from,
  untilDate: until,
  intake: DailyIntake(approxMinute: minute, amount: amount),
);

NotDoneRange _notDone(String from, String to, {String id = 'n'}) =>
    NotDoneRange(id: id, trackId: 'a', startDate: from, endDate: to);

RangeExposures _exposures(
  List<TrackSetupRange> ranges, {
  List<TrackEvent> real = const [],
  List<({String trackId, String date})> absences = const [],
}) => RangeExposures(ranges: ranges, realEvents: real, absences: absences);

String _label(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

TrackEvent _realLog(String date, int hour, double amount) {
  final d = DateTime.parse(date);
  return TrackEvent(
    id: 'real-$date',
    trackId: 'a',
    date: date,
    atMs: DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch,
    amount: amount,
    unit: 'mg',
  );
}

void _expectSameFeatures(
  TrackExposureFeatures actual,
  TrackExposureFeatures expected,
) {
  expect(actual.dose, expected.dose, reason: 'dose');
  expect(actual.residualMg, expected.residualMg, reason: 'residualMg');
  expect(actual.timingHours, expected.timingHours, reason: 'timingHours');
  expect(actual.nextNightDose, expected.nextNightDose, reason: 'nextNightDose');
  expect(
    actual.effectiveResidual,
    expected.effectiveResidual,
    reason: 'effectiveResidual',
  );
  expect(
    actual.withdrawalPressure,
    expected.withdrawalPressure,
    reason: 'withdrawalPressure',
  );
  expect(actual.exposureRunDays, expected.exposureRunDays, reason: 'run');
  expect(actual.abstinenceDays, expected.abstinenceDays, reason: 'abstinence');
}

void main() {
  group('RangeExposures.on: which days get an exposure, and what it says', () {
    // why: the exposure carries the range's approximate time and amount, as a
    // local wall-clock instant. 2026-03-08 is the US spring-forward day, so
    // "midnight plus 480 minutes" would be 09:00 there; the owner means 08:00.
    // proves: CLAIM(range-exposure)
    test('timed exposure is the local wall-clock minute of that date', () {
      final e = _exposures([_done('2026-03-01')]);
      for (final date in ['2026-03-08', '2026-03-10', '2026-07-01']) {
        final d = DateTime.parse(date);
        final event = e.on('a', date)!;
        expect(
          event.atMs,
          DateTime(d.year, d.month, d.day, 8).millisecondsSinceEpoch,
          reason: date,
        );
        expect(event.amount, 50);
        expect(event.unit, 'mg');
        expect(event.trackId, 'a');
        expect(event.date, date);
        expect(
          event.sourceKind,
          kRangeExposureSource,
          reason: 'never a manual/feed source, so it cannot be mistaken for a log',
        );
        expect(event.id, 'history:a:$date');
      }
    });

    test('no time and no amount leave both unknown', () {
      final event = _exposures([
        _done('2026-03-01', minute: null, amount: null),
      ]).on('a', '2026-03-10')!;
      expect(event.atMs, isNull);
      expect(event.amount, isNull);
    });

    test('the period bounds are inclusive; ongoing has no upper bound', () {
      final bounded = _exposures([_done('2026-03-01', until: '2026-03-05')]);
      expect(bounded.on('a', '2026-02-28'), isNull);
      expect(bounded.on('a', '2026-03-01'), isNotNull);
      expect(bounded.on('a', '2026-03-05'), isNotNull);
      expect(bounded.on('a', '2026-03-06'), isNull);
      final ongoing = _exposures([_done('2026-03-01')]);
      expect(ongoing.on('a', '2026-02-28'), isNull);
      expect(ongoing.on('a', '2031-01-01'), isNotNull);
    });

    test('another track has no exposure from this track\'s range', () {
      expect(_exposures([_done('2026-03-01')]).on('b', '2026-03-10'), isNull);
    });

    // why: "real logs on a date override the range entirely". Not just the
    // hour of the log, and not per-field: the day is the wearer's own record.
    test('a real log on the date removes the exposure for that date only', () {
      final e = _exposures(
        [_done('2026-03-01')],
        real: [_realLog('2026-03-10', 21, 30)],
      );
      expect(e.on('a', '2026-03-10'), isNull);
      expect(e.on('a', '2026-03-09'), isNotNull);
      expect(e.on('a', '2026-03-11'), isNotNull);
    });

    test('a real log of another track does not override', () {
      final other = TrackEvent(
        id: 'o',
        trackId: 'b',
        date: '2026-03-10',
        amount: 1,
      );
      expect(
        _exposures([_done('2026-03-01')], real: [other]).on('a', '2026-03-10'),
        isNotNull,
      );
    });

    // why: an explicit "none today" is a statement about that date.
    test('an explicit absence carves the date out', () {
      final e = _exposures(
        [_done('2026-03-01')],
        absences: [(trackId: 'a', date: '2026-03-10')],
      );
      expect(e.on('a', '2026-03-10'), isNull);
      expect(e.on('a', '2026-03-11'), isNotNull);
      expect(
        _exposures(
          [_done('2026-03-01')],
          absences: [(trackId: 'b', date: '2026-03-10')],
        ).on('a', '2026-03-10'),
        isNotNull,
      );
    });

    test('a not-done period has no exposure', () {
      expect(_exposures([_notDone('2026-03-01', '2026-03-05')]).on('a', '2026-03-03'), isNull);
    });

    // why: restored or foreign data can overlap. The wearer's "I did not" must
    // win over "I did", never the other way round.
    test('a not-done period carves out of an overlapping done period', () {
      final e = _exposures([
        _done('2026-03-01', until: '2026-03-31'),
        _notDone('2026-03-10', '2026-03-12'),
      ]);
      expect(e.on('a', '2026-03-09'), isNotNull);
      expect(e.on('a', '2026-03-10'), isNull);
      expect(e.on('a', '2026-03-12'), isNull);
      expect(e.on('a', '2026-03-13'), isNotNull);
    });
  });

  group('estimator features from a range exposure', () {
    final bedtime = DateTime(2026, 3, 10, 22);

    List<TrackEvent> synthetic(DoneRange range, List<String> dates) {
      final e = _exposures([range]);
      return [for (final d in dates) e.on('a', d)!];
    }

    // why: "a range is the same as the same daily logs". Expected numbers by
    // hand, bedtime 22:00, 08:00 intake:
    //   03-10 08:00 is 14 h back: dose 50, timing 14 h, residual 50*2^(-14/6)
    //   03-09 08:00 is 38 h back: lag 50, residual 50*2^(-38/6)
    //   2^(-14/6)=0.198425 -> 9.9213 ; 2^(-38/6)=0.012394 -> 0.6197 ; sum 10.541
    // proves: CLAIM(range-exposure)
    test('timed amount range equals the same daily logs, feature by feature', () {
      final fromRange = _estimator.features(
        _track(),
        synthetic(_done('2026-03-01'), ['2026-03-09', '2026-03-10']),
        bedtime,
      );
      final fromLogs = _estimator.features(_track(), [
        _realLog('2026-03-09', 8, 50),
        _realLog('2026-03-10', 8, 50),
      ], bedtime);
      expect(fromRange.dose, 50);
      expect(fromRange.nextNightDose, 50);
      expect(fromRange.timingHours, closeTo(14, 1e-9));
      expect(fromRange.residualMg, closeTo(10.541, 0.005));
      _expectSameFeatures(fromRange, fromLogs);
    });

    // why: slow (tolerance / withdrawal) features also read the range. Twelve
    // consecutive daily doses end at bedtime: run 12, no abstinence.
    test('slow history features from a range equal those from daily logs', () {
      final track = _track(tolerance: 3, withdrawal: 6);
      final dates = [
        for (var i = 0; i < 70; i++) _label(DateTime(2026, 1, 1 + i)),
      ].where((d) => d.compareTo('2026-02-27') >= 0 && d.compareTo('2026-03-10') <= 0).toList();
      expect(dates, hasLength(12));
      final fromRange = _estimator.features(
        track,
        synthetic(_done('2026-02-27'), dates),
        bedtime,
        historyComplete: true,
      );
      final fromLogs = _estimator.features(
        track,
        [for (final d in dates) _realLog(d, 8, 50)],
        bedtime,
        historyComplete: true,
      );
      expect(fromRange.exposureRunDays, 12);
      expect(fromRange.abstinenceDays, 0);
      expect(fromRange.effectiveResidual, isNotNull);
      _expectSameFeatures(fromRange, fromLogs);
    });

    // why: CLAIM(onset-unknown) must hold for a synthesized exposure too.
    // proves: CLAIM(onset-unknown)
    test('an unknown onset keeps the residual unknown but the dose known', () {
      final events = synthetic(_done('2026-03-01'), ['2026-03-10']);
      final unknown = _estimator.features(_track(onset: null), events, bedtime);
      expect(unknown.dose, 50);
      expect(unknown.residualMg, isNull);
      // positive control: a known onset gives the 9.92 mg residual.
      expect(
        _estimator.features(_track(onset: 0), events, bedtime).residualMg,
        closeTo(9.9213, 0.001),
      );
    });

    // why: S3/R3-4. Only identical units are compatible. A range entered in ml
    // on a mg track must not become a dose of 50 mg. proves: CLAIM(unit-abstain)
    test('a range in another unit abstains for dose and residual', () {
      for (final minute in <int?>[480, null]) {
        final events = synthetic(
          _done('2026-03-01', minute: minute, amount: const DailyAmount(50, 'ml')),
          ['2026-03-10'],
        );
        final f = _estimator.features(_track(), events, bedtime);
        expect(f.dose, isNull, reason: 'minute=$minute');
        expect(f.residualMg, isNull, reason: 'minute=$minute');
        expect(f.presenceOnly, isFalse, reason: 'an amount was given, in the wrong unit');
      }
      // positive control: same range in the track's unit (case and spaces
      // ignored, as for logged events) is used.
      final ok = synthetic(
        _done('2026-03-01', amount: const DailyAmount(50, ' MG ')),
        ['2026-03-10'],
      );
      expect(_estimator.features(_track(), ok, bedtime).dose, 50);
    });

    // why (review P8a-P1): a range amount is only as good as the unit it was
    // entered in, empty unit included. A saved 50 with no unit must not become
    // 50 mg when the track later gains the unit mg, nor 50 of an unknown unit
    // on a unitless track that was saved as mg. Real events keep the legacy
    // "no unit means the track's unit"; ranges do not (the unit is always
    // stored with the amount). proves: CLAIM(unit-abstain)
    test('a range amount needs exactly the track unit, empty units included', () {
      for (final minute in <int?>[480, null]) {
        double? doseFor(String trackUnit, String rangeUnit) {
          final events = synthetic(
            _done('2026-03-01', minute: minute, amount: DailyAmount(50, rangeUnit)),
            ['2026-03-10'],
          );
          return _estimator.features(_track(unit: trackUnit), events, bedtime).dose;
        }

        expect(doseFor('mg', ''), isNull, reason: 'empty vs mg, minute=$minute');
        expect(doseFor('', 'mg'), isNull, reason: 'mg vs empty, minute=$minute');
        expect(doseFor('mg', 'ml'), isNull, reason: 'minute=$minute');
        // positive controls: identical units, including both empty.
        expect(doseFor('mg', 'mg'), 50, reason: 'minute=$minute');
        expect(doseFor('', ''), 50, reason: 'both empty, minute=$minute');
      }
    });

    // why: real logs keep the legacy rule, so the P1 change must not reach them.
    test('a real log without a unit still counts as the track unit', () {
      final log = TrackEvent(
        id: 'x',
        trackId: 'a',
        date: '2026-03-10',
        atMs: DateTime(2026, 3, 10, 16).millisecondsSinceEpoch,
        amount: 80,
      );
      expect(_estimator.features(_track(), [log], bedtime).dose, 80);
    });

    // why (review P8a-P4): merged backups can hold overlapping done periods. If
    // they disagree on a date the dose is ambiguous, so that date is unknown
    // (never "first row wins", which flips with row order); if they agree it is
    // not ambiguous. proves: CLAIM(range-overlap)
    test('overlapping periods that disagree make the date unknown, in any order', () {
      final a = _done('2026-03-01', until: '2026-03-31', id: 'a');
      final b = _done(
        '2026-03-05',
        id: 'b',
        amount: const DailyAmount(100, 'mg'),
      );
      for (final ranges in [
        [a, b],
        [b, a],
      ]) {
        final e = _exposures(ranges);
        final events = [for (final d in ['2026-03-09', '2026-03-10']) e.on('a', d)!];
        final f = _estimator.features(_track(), events, bedtime);
        expect(f.dose, isNull, reason: 'ambiguous 50 vs 100');
        expect(f.residualMg, isNull);
        expect(f.presenceOnly, isFalse);
        // a date only one period covers is still fine
        expect(
          _estimator
              .features(_track(), [e.on('a', '2026-03-03')!], DateTime(2026, 3, 3, 22))
              .dose,
          50,
        );
      }
    });

    test('overlapping periods that agree are not ambiguous', () {
      final e = _exposures([
        _done('2026-03-01', until: '2026-03-31', id: 'a'),
        _done('2026-03-05', id: 'b'),
      ]);
      final f = _estimator.features(_track(), [e.on('a', '2026-03-10')!], bedtime);
      expect(f.dose, 50);
    });

    test('a different time alone is also ambiguous', () {
      final e = _exposures([
        _done('2026-03-01', id: 'a', minute: 480),
        _done('2026-03-01', id: 'b', minute: 600),
      ]);
      expect(
        _estimator.features(_track(), [e.on('a', '2026-03-10')!], bedtime).dose,
        isNull,
      );
    });

    // why: no time means the residual cannot be placed (CLAIM(onset-unknown)
    // family), but the day's amount is still the day's dose. The evening-date
    // rule (the date of the instant six hours before bedtime) is the one
    // documented approximation. proves: CLAIM(range-untimed-dose)
    test('an untimed range gives dose and lag but no residual or timing', () {
      final f = _estimator.features(
        _track(),
        synthetic(_done('2026-03-01', minute: null), ['2026-03-09', '2026-03-10']),
        bedtime,
      );
      expect(f.dose, 50);
      expect(f.nextNightDose, 50);
      expect(f.residualMg, isNull);
      expect(f.timingHours, isNull);
    });

    // bedtime 01:00 on 03-11: six hours earlier is 19:00 on 03-10, so 03-10 is
    // the evening date; the untimed 03-11 intake comes after waking.
    test('an untimed intake dated after a post-midnight bedtime is not a dose', () {
      final late = DateTime(2026, 3, 11, 1);
      final f = _estimator.features(
        _track(),
        synthetic(_done('2026-03-01', minute: null), ['2026-03-10', '2026-03-11']),
        late,
      );
      expect(f.dose, 50, reason: 'only 03-10 counts; 100 would double count');
      expect(
        f.nextNightDose,
        0,
        reason: '03-10 is the evening date (dose), so nothing is yet the lag',
      );
      expect(f.residualMg, isNull);
    });

    // why: "no amount: on/off contrast only (no dose fitting)". Presence is a
    // separate fact from dose; dose and residual stay null so no dose term is
    // ever fitted to an invented number.
    test('a range without an amount is presence only', () {
      final f = _estimator.features(
        _track(),
        synthetic(_done('2026-03-01', amount: null), ['2026-03-09', '2026-03-10']),
        bedtime,
      );
      expect(f.presenceOnly, isTrue);
      expect(f.exposureLevel, 1.0);
      expect(f.dose, isNull);
      expect(f.residualMg, isNull);
      expect(f.timingHours, isNull);
      expect(f.nextNightDose, isNull);
      // controls: a night with nothing in range is a known zero, not presence.
      final none = _estimator.features(_track(), const [], bedtime);
      expect(none.presenceOnly, isFalse);
      expect(none.dose, 0);
      expect(none.exposureLevel, 0.0);
    });

    test('presence only needs an exposure in the last 24 h', () {
      // the only presence is 03-09 08:00 (38 h back): known no recent exposure
      final f = _estimator.features(
        _track(),
        synthetic(_done('2026-03-01', amount: null), ['2026-03-09']),
        bedtime,
      );
      expect(f.presenceOnly, isFalse);
      expect(f.dose, 0);
      expect(f.nextNightDose, isNull, reason: 'yesterday\'s amount is unknown');
    });

    // why: presence (level 1) and a real amount (mg) are different scales; one
    // night mixing them is unknown, not 1 + 80.
    test('presence mixed with a real amount in the window is unknown', () {
      final events = [
        ...synthetic(_done('2026-03-01', amount: null), ['2026-03-10']),
        _realLog('2026-03-10', 9, 80),
      ];
      final f = _estimator.features(_track(), events, bedtime);
      expect(f.presenceOnly, isFalse);
      expect(f.dose, isNull);
    });
  });

  group('estimator on a cohort built from ranges', () {
    // 16 alternating weeks, as in track_effect_estimator_test's cohort():
    // odd weeks are inside a taken-daily period, even weeks are not. Sleep is
    // 58 in exposed weeks and 50 otherwise; every matching covariate is equal.
    List<TrackNight> cohort({
      int? minute,
      DailyAmount? amount,
      bool realLogs = false,
    }) {
      final exposures = RangeExposures(
        ranges: [
          for (var w = 1; w < 16; w += 2)
            _done(
              _label(DateTime(2025, 1, 1 + w * 7)),
              until: _label(DateTime(2025, 1, 1 + w * 7 + 6)),
              minute: minute,
              amount: amount,
              id: 'w$w',
            ),
        ],
        realEvents: const [],
        absences: const [],
      );
      return List.generate(112, (i) {
        final at = DateTime(2025, 1, 1 + i, 22);
        final exposed = (i ~/ 7).isOdd;
        final dates = [
          for (var back = 0; back < 3; back++)
            _label(DateTime(2025, 1, 1 + i - back)),
        ];
        return TrackNight(
          at: at,
          bedtimeMinute: 1320,
          sleepDebtHours: 0,
          load: 0,
          baselines: const {'sleep': 50},
          outcomes: {'sleep': exposed ? 58.0 : 50.0},
          events: realLogs
              ? [
                  // the same intake as the range, written as ordinary logs
                  for (final d in dates)
                    if (exposures.on('a', d) != null)
                      _realLog(d, minute! ~/ 60, amount!.value),
                ]
              : [for (final d in dates) ?exposures.on('a', d)],
          completeTrackIds: const {'a'},
          negativeControls: const {'sleep': 50},
        );
      });
    }

    TrackEffectEstimate estimateFor(List<TrackNight> nights) => _estimator
        .estimate(
          tracks: [_track()],
          nights: nights,
          asOf: DateTime(2025, 6, 1),
        )
        .single;

    // hand: 56 exposed nights each match the control of the same weekday, each
    // pair differs by 58-50 = 8; shrinkage weight 56/(56+8) = 0.875, so the
    // reported effect is 8 * 0.875 = 7.
    test('no amount: on/off contrast, no dose terms', () {
      final e = estimateFor(cohort(minute: 960));
      expect(e.reason, 'estimated');
      expect(e.matchedPairs, 56);
      expect(e.effect, closeTo(7.0, 1e-9));
      expect(e.coefficients, isEmpty, reason: 'no dose fitting without an amount');
      expect(e.kineticTargets, isEmpty);
    });

    // why: a persisted habitual reference (CLAIM(baseline-reference)) is a dose
    // in the track's own scale. A presence night (level 1) must not be ordered
    // against it; with a 100 mg reference these nights are unknown, so no pair
    // forms. Nights logged at exactly 100 mg are the controls that would
    // otherwise pair with them.
    test('a presence night is not compared with a persisted mg reference', () {
      final baseline = TrackDefinition.fromJson({
        ..._track().toJson(),
        'no_unadjusted_data': true,
      });
      final presence = cohort(minute: 960);
      final nights = [
        for (final n in presence)
          if (n.outcomes['sleep'] == 58.0)
            n
          else
            TrackNight(
              at: n.at,
              bedtimeMinute: n.bedtimeMinute,
              sleepDebtHours: n.sleepDebtHours,
              load: n.load,
              baselines: n.baselines,
              outcomes: n.outcomes,
              completeTrackIds: n.completeTrackIds,
              negativeControls: n.negativeControls,
              events: [_realLog(_label(n.at), 16, 100)],
            ),
      ];
      final e = _estimator
          .estimate(
            tracks: [baseline],
            nights: nights,
            asOf: DateTime(2025, 6, 1),
            references: const {'a': 100},
          )
          .single;
      expect(e.matchedPairs, 0);
      expect(e.reason, isNot('estimated'));
    });

    test('no amount and no time is the same contrast', () {
      final e = estimateFor(cohort());
      expect(e.reason, 'estimated');
      expect(e.matchedPairs, 56);
      expect(e.effect, closeTo(7.0, 1e-9));
      expect(e.coefficients, isEmpty);
    });

    // why: parity at the estimate level: a range cohort and the cohort of the
    // same daily logs fit the same terms to the same pairs.
    test('timed amount range gives the same estimate as the same logs', () {
      const amount = DailyAmount(100, 'mg');
      final fromRange = estimateFor(cohort(minute: 960, amount: amount));
      final fromLogs = estimateFor(
        cohort(minute: 960, amount: amount, realLogs: true),
      );
      expect(fromRange.reason, 'estimated');
      expect(fromRange.reason, fromLogs.reason);
      expect(fromRange.matchedPairs, fromLogs.matchedPairs);
      expect(fromRange.effect, fromLogs.effect);
      expect(fromRange.coefficients, fromLogs.coefficients);
    });
  });

  group('trackNightsHeavy feeds ranges to nights', () {
    final bedtime = DateTime(2026, 10, 25, 22);

    TrackLearningInput input({
      required List<TrackSetupRange> ranges,
      List<TrackEvent> events = const [],
      List<Map<String, Object?>> absences = const [],
      TrackDefinition? track,
    }) => TrackLearningInput(
      definitions: [
        {'id': 'a', 'payload_json': jsonEncode((track ?? _track()).toJson())},
      ],
      events: [for (final e in events) e.toJson()],
      history: [for (final r in ranges) r.toJson()],
      absences: absences,
      states: const [],
      days: [
        {
          'day_id': '2026-10-26',
          'window_json': jsonEncode({
            'value': {
              'onset_ms': bedtime.millisecondsSinceEpoch,
              'offset_ms': bedtime
                  .add(const Duration(hours: 8))
                  .millisecondsSinceEpoch,
            },
          }),
          'payload_json': jsonEncode({
            'scalars': {'rhr': 55, 'strain': 4},
            'sleep': {
              'accounting': {
                'value': {'tst_sec': 7 * 3600},
              },
            },
            'coverage': {'rr_coverage': .95},
          }),
        },
      ],
      worker: WorkerInputs(
        nowEpochMs: DateTime(2026, 10, 27).millisecondsSinceEpoch,
        zoneId: 'UTC',
        localeTag: 'en',
      ),
    );

    TrackNight night(
      List<TrackSetupRange> ranges, {
      List<TrackEvent> events = const [],
      List<Map<String, Object?>> absences = const [],
    }) {
      final i = input(ranges: ranges, events: events, absences: absences);
      return trackNightsHeavy(i, [_track()], [
        for (final r in i.events) TrackEvent.fromJson(r),
      ], ranges).single;
    }

    Set<String> synthetic(TrackNight n) => {
      for (final e in n.events)
        if (e.sourceKind == kRangeExposureSource) e.id,
    };

    // why: end to end. The 60 h slow window (10 half-lives) starts 10-23
    // 10:00, so dates 10-23..10-25 each get an 08:00 / 50 mg exposure, the
    // features equal the hand numbers of the unit test above (same arithmetic
    // at the same offsets), and the range alone makes the dates complete.
    // proves: CLAIM(range-exposure), range counts as complete logging
    test('an ongoing range yields exposures and completeness', () {
      final n = night([_done('2026-10-01')]);
      expect(synthetic(n), {
        'history:a:2026-10-23',
        'history:a:2026-10-24',
        'history:a:2026-10-25',
      });
      expect(
        n.completeTrackIds,
        {'a'},
        reason: 'track has no logging pledge: only the range completes it',
      );
      final f = _estimator.features(_track(), n.events, n.at);
      expect(f.dose, 50);
      expect(f.nextNightDose, 50);
      expect(f.residualMg, closeTo(10.541, 0.005));
    });

    test('without a range the same night is incomplete and has no exposure', () {
      final n = night([]);
      expect(synthetic(n), isEmpty);
      expect(n.completeTrackIds, isEmpty);
    });

    test('a real log overrides the range for its date', () {
      final n = night(
        [_done('2026-10-01')],
        events: [_realLog('2026-10-24', 20, 30)],
      );
      expect(synthetic(n), {'history:a:2026-10-23', 'history:a:2026-10-25'});
      expect(n.events.where((e) => e.id == 'real-2026-10-24'), hasLength(1));
    });

    test('an explicit absence carves a date out and still counts as confirmed', () {
      final n = night(
        [_done('2026-10-01')],
        absences: [
          {'track_id': 'a', 'date': '2026-10-24'},
        ],
      );
      expect(synthetic(n), {'history:a:2026-10-23', 'history:a:2026-10-25'});
      expect(n.completeTrackIds, {'a'});
    });

    test('a not-done period carves out and counts as confirmed', () {
      final n = night([
        _done('2026-10-01', until: '2026-10-23'),
        _notDone('2026-10-24', '2026-10-25'),
      ]);
      expect(synthetic(n), {'history:a:2026-10-23'});
      expect(n.completeTrackIds, {'a'});
    });

    // why: a unit mismatch must abstain through the worker path too.
    // proves: CLAIM(unit-abstain)
    test('a range in another unit leaves the night dose unknown', () {
      final n = night([
        _done('2026-10-01', amount: const DailyAmount(50, 'ml')),
      ]);
      expect(_estimator.features(_track(), n.events, n.at).dose, isNull);
    });
  });
}
