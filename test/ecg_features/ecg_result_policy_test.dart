// ECG features, phase 1: the attempt-join rule and the metrics a result
// really has. Pure functions in lib/ecg/ecg_result.dart.
//
// JOIN (owner spec 5, changed by design 04): a new reading started within 10
// minutes AFTER a non-final one joins that reading's attempt group instead of
// deleting it. A final one is never joined. Decisions on the edges: the window
// is inclusive (exactly 10:00 joins); only the MOST RECENT reading is
// considered; a partial neither joins nor is joined; a start before the
// previous end (clock skew) starts a group.
//
// METRICS (owner spec 3, 7): only what really exists. Average heart rate and
// signal quality. There is no RMSSD or SDNN from an ECG anywhere in edge or in
// the pinned analytics (its HRV is PRV from the PPG RR series; there is no
// R-peak detector), so the result never has one and a page never invents one.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_result.dart';

import 'support/ecg_fixtures.dart';

void main() {
  group('constants', () {
    test('the overwrite window is 10 minutes', () {
      expect(kEcgOverwriteWindow, const Duration(minutes: 10));
    });
    test('a partial keeps metrics only with 10 s of signal (1000 samples at '
        '100 Hz)', () {
      expect(kEcgPartialMinSamples, 1000);
      expect(kEcgPartialMinSamples, 10 * kEcgSampleRateHz);
    });
  });

  // Design 04 replaced "replace the inconclusive one" with "join its attempt
  // group": nothing is deleted. The 10-minute window, its inclusive edge, the
  // clock-skew rule and "a partial neither joins nor is joined" are unchanged;
  // what is non-final changed from "status inconclusive" to "outcome not
  // readable or inconclusive" (the full boundary matrix is in
  // test/ecg_transparency/ecg_attempts_policy_test.dart).
  group('ecgJoinTargetId (was ecgReplaceTargetId)', () {
    EcgReading incoming(int startTs,
            {EcgReadingStatus status = EcgReadingStatus.completed}) =>
        fixtureReading(id: 'new', startTs: startTs, status: status);

    test('within 10 minutes after an inconclusive: joins it', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(
        ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 1000 + 120)),
        prev.id,
      );
    });

    test('exactly 10:00 after still joins; one second more starts a group', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 1600)),
          prev.id);
      expect(ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 1601)),
          isNull);
    });

    test('a start at the same second the inconclusive ended joins', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 1000)),
          prev.id);
    });

    test('a start BEFORE the previous one ended (clock skew) starts a group',
        () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 999)),
          isNull);
    });

    test('after a final reading: always its own group, never a join', () {
      final prev = fixtureReading(endTs: kT0 + 1000);
      for (final dt in [0, 30, 120, 599, 600]) {
        expect(ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 1000 + dt)),
            isNull,
            reason: '+${dt}s');
      }
    });

    test('after a partial: its own group (a partial is never joined)', () {
      final prev = partialEndingAt(kT0 + 1000);
      expect(ecgJoinTargetId(latest: prev, incoming: incoming(kT0 + 1100)),
          isNull);
    });

    test('no previous reading: its own group', () {
      expect(ecgJoinTargetId(latest: null, incoming: incoming(kT0)), isNull);
    });

    test('an inconclusive follow-up joins an inconclusive one too', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(
        ecgJoinTargetId(
          latest: prev,
          incoming: incoming(kT0 + 1100, status: EcgReadingStatus.inconclusive),
        ),
        prev.id,
      );
    });

    test('a partial follow-up does NOT join the inconclusive one', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(
        ecgJoinTargetId(
          latest: prev,
          incoming: incoming(kT0 + 1100, status: EcgReadingStatus.partial),
        ),
        isNull,
      );
    });
  });

  group('ecgMetricsOf', () {
    EcgMetric m(List<EcgMetric> all, String key) =>
        all.singleWhere((x) => x.key == key);

    test('a full reading: average heart rate in bpm and the band\'s signal '
        'quality, with real names', () {
      final all = ecgMetricsOf(fixtureReading(avgHr: 77, quality: 3));
      expect([for (final x in all) x.key], ['avgHr', 'quality']);
      expect(m(all, 'avgHr').name, 'Average heart rate');
      expect(m(all, 'avgHr').value, 77);
      expect(m(all, 'avgHr').unit, 'bpm');
      expect(m(all, 'avgHr').display, '77 bpm');
      expect(m(all, 'quality').name, 'Signal quality');
      expect(m(all, 'quality').value, 3);
      expect(m(all, 'quality').display, '3');
    });

    test('absent input is null and shown as "—", never zero', () {
      final all = ecgMetricsOf(fixtureReading(avgHr: null, quality: null));
      for (final x in all) {
        expect(x.value, isNull, reason: x.key);
        expect(x.display, '—', reason: x.key);
      }
    });

    test('the band sends 0 for "none": that is absent, not a reading of 0', () {
      final all = ecgMetricsOf(fixtureReading(avgHr: 0, quality: 0));
      for (final x in all) {
        expect(x.value, isNull, reason: x.key);
        expect(x.display, '—', reason: x.key);
      }
    });

    test('a thin partial has no metrics at all (all null)', () {
      final all = ecgMetricsOf(partialEndingAt(kT0 + 12));
      expect(all.every((x) => x.value == null), isTrue);
    });

    test('there is NO RMSSD and NO SDNN: nothing on the phone or in the '
        'analytics computes them from an ECG', () {
      for (final r in [
        fixtureReading(),
        inconclusiveEndingAt(kT0 + 30),
        partialEndingAt(kT0 + 30),
      ]) {
        final keys = [for (final x in ecgMetricsOf(r)) x.key.toLowerCase()];
        expect(keys, isNot(contains('rmssd')));
        expect(keys, isNot(contains('sdnn')));
      }
    });
  });

  group('EcgMetric.display', () {
    test('a whole value has no decimals, a fraction keeps one, a missing '
        'value is "—"', () {
      const rmssd = EcgMetric(key: 'rmssd', name: 'RMSSD', value: 42, unit: 'ms');
      expect(rmssd.display, '42 ms');
      expect(
        const EcgMetric(key: 'rmssd', name: 'RMSSD', value: 42.4, unit: 'ms')
            .display,
        '42.4 ms',
      );
      expect(
        const EcgMetric(key: 'rmssd', name: 'RMSSD', value: null, unit: 'ms')
            .display,
        '—',
      );
      expect(
        const EcgMetric(key: 'q', name: 'Signal quality', value: 3, unit: '')
            .display,
        '3',
      );
    });
  });
}
