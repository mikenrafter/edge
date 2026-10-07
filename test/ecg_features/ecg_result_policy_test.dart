// ECG features, phase 1 (RED): the overwrite rule and the metrics a result
// really has. Pure functions in lib/ecg/ecg_result.dart.
//
// OVERWRITE (owner spec 5): a new reading started within 10 minutes AFTER an
// inconclusive one REPLACES that record instead of adding a new one. A
// complete one is never overwritten. Decisions on the edges: the window is
// inclusive (exactly 10:00 replaces); only the MOST RECENT reading is
// considered; a partial neither replaces nor is replaced (never trade a fuller
// record for a thinner one); a start before the previous end (clock skew) adds.
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

  group('ecgReplaceTargetId', () {
    EcgReading incoming(int startTs,
            {EcgReadingStatus status = EcgReadingStatus.completed}) =>
        fixtureReading(id: 'new', startTs: startTs, status: status);

    test('within 10 minutes after an inconclusive: replaces it', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(
        ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 1000 + 120)),
        prev.id,
      );
    });

    test('exactly 10:00 after still replaces; one second more adds', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 1600)),
          prev.id);
      expect(ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 1601)),
          isNull);
    });

    test('a start at the same second the inconclusive ended replaces', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 1000)),
          prev.id);
    });

    test('a start BEFORE the previous one ended (clock skew) adds', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 999)),
          isNull);
    });

    test('after a complete reading: always a new record, never an overwrite',
        () {
      final prev = fixtureReading(endTs: kT0 + 1000);
      for (final dt in [0, 30, 120, 599, 600]) {
        expect(ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 1000 + dt)),
            isNull,
            reason: '+${dt}s');
      }
    });

    test('after a partial: a new record (a partial is never overwritten)', () {
      final prev = partialEndingAt(kT0 + 1000);
      expect(ecgReplaceTargetId(latest: prev, incoming: incoming(kT0 + 1100)),
          isNull);
    });

    test('no previous reading: a new record', () {
      expect(ecgReplaceTargetId(latest: null, incoming: incoming(kT0)), isNull);
    });

    test('an inconclusive follow-up replaces an inconclusive one too', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(
        ecgReplaceTargetId(
          latest: prev,
          incoming: incoming(kT0 + 1100, status: EcgReadingStatus.inconclusive),
        ),
        prev.id,
      );
    });

    test('a partial follow-up does NOT replace the inconclusive one (a '
        'thinner record never displaces a fuller one)', () {
      final prev = inconclusiveEndingAt(kT0 + 1000);
      expect(
        ecgReplaceTargetId(
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
