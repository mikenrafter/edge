// Phase 4 red: per-interval ownership, abstention and resolved-data rows
// (contracts 2, 3 and 7). Real LocalDb, two-device fixtures.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'support/sources_support.dart';

void main() {
  useSourcesDb('sources_resolved_data_test.db');

  // 2026-09-01, local wall clock.
  int t(int h, [int m = 0]) => sec(2026, 9, 1, h, m);
  final sources = [kBand, strap(kStrapA)];

  group('partial overlap selects the right owner per interval per signal', () {
    Future<void> seedOverlap() async {
      // Primary: rr 00-04, hr1Hz 00-06. Strap: rr 02-06 (overlaps 02-04).
      await insertCoverage(kPrimary, InputSignal.rrIntervals, t(0), t(4));
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(0), t(6));
      await insertCoverage(kStrapA, InputSignal.rrIntervals, t(2), t(6));
    }

    test('the higher-ranked strap owns the overlap, each side owns its own',
        () async {
      await seedOverlap();
      await LocalDb.setSignalPriority(InputSignal.rrIntervals, [kStrapA, kPrimary]);
      final svc = openService(sources: sources);
      final rr = await resolveJson(svc, InputSignal.rrIntervals, t(0), t(6));
      expectTiles(rr, t(0), t(6));

      final before = at(rr, t(1));
      expect(before['winner'], kPrimary);
      expect(before['kind'], 'single');
      expect(before['reasonCode'], 'onlySource');

      final overlap = at(rr, t(3));
      expect(overlap['winner'], kStrapA);
      expect(overlap['kind'], 'overlap');
      expect(overlap['alternatives'], [kPrimary]);
      expect(overlap['reasonCode'], 'userPriority');

      final after = at(rr, t(5));
      expect(after['winner'], kStrapA);
      expect(after['kind'], 'single');
      expect(after['reasonCode'], 'onlySource');
    });

    test('reversing the order moves only the contested interval', () async {
      await seedOverlap();
      await LocalDb.setSignalPriority(InputSignal.rrIntervals, [kPrimary, kStrapA]);
      final svc = openService(sources: sources);
      final rr = await resolveJson(svc, InputSignal.rrIntervals, t(0), t(6));
      expect(at(rr, t(1))['winner'], kPrimary);
      final overlap = at(rr, t(3));
      expect(overlap['winner'], kPrimary);
      expect(overlap['alternatives'], [kStrapA]);
      expect(at(rr, t(5))['winner'], kStrapA,
          reason: 'the primary stopped covering at 04:00; no contention left');
    });

    test('each signal resolves under its own order', () async {
      await seedOverlap();
      await insertCoverage(kStrapA, InputSignal.hr1Hz, t(2), t(6));
      await LocalDb.setSignalPriority(InputSignal.rrIntervals, [kStrapA, kPrimary]);
      await LocalDb.setSignalPriority(InputSignal.hr1Hz, [kPrimary, kStrapA]);
      final svc = openService(sources: sources);
      final rr = await resolveJson(svc, InputSignal.rrIntervals, t(0), t(6));
      final hr = await resolveJson(svc, InputSignal.hr1Hz, t(0), t(6));
      expect(at(rr, t(3))['winner'], kStrapA);
      expect(at(hr, t(3))['winner'], kPrimary,
          reason: 'same instant, different signal, different owner');
      expect(at(hr, t(5))['winner'], kPrimary);
    });
  });

  group('missing or thin data abstains', () {
    test('a gap between two covered stretches is not bridged', () async {
      // ONE device, so the engine's identity short-circuit would hand it the
      // whole window. The view must show what was actually recorded.
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(0), t(1));
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(2), t(3));
      final svc = openService(sources: [kBand]);
      final hr = await resolveJson(svc, InputSignal.hr1Hz, t(0), t(3));
      expectTiles(hr, t(0), t(3));
      expect(hr.length, 3, reason: 'covered, gap, covered');

      final gap = at(hr, t(1, 30));
      expect(gap['winner'], isNull, reason: 'no manufactured continuity');
      expect(gap['kind'], 'gap');
      expect(gap['agreement'], 'none');
      expect(gap['reasonCode'], 'noCoverage');
      expect(gap['alternatives'], isEmpty);
      expect((gap['reason'] as String).trim(), isNotEmpty);
      expect(at(hr, t(0, 30))['winner'], kPrimary);
      expect(at(hr, t(2, 30))['winner'], kPrimary);
    });

    test('a stretch shorter than the hysteresis span resolves to absent',
        () async {
      // kOwnershipHysteresisBuckets * kOwnershipBucketSeconds = 180 s is the
      // minimum a covered stretch must last. 60 s is thin; 10 min is not.
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(0), t(2));
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(3), t(3) + 60);
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(5), t(5, 10));
      final svc = openService(sources: [kBand]);
      final hr = await resolveJson(svc, InputSignal.hr1Hz, t(0), t(6));
      expectTiles(hr, t(0), t(6));

      expect(at(hr, t(1))['winner'], kPrimary);
      expect(at(hr, t(2, 30))['reasonCode'], 'noCoverage');

      final thin = at(hr, t(3) + 30);
      expect(thin['winner'], isNull, reason: 'thin data is absent, not a value');
      expect(thin['kind'], 'gap');
      expect(thin['agreement'], 'none');
      expect(thin['reasonCode'], 'thinData');
      expect((thin['reason'] as String).trim(), isNotEmpty);

      final enough = at(hr, t(5, 5));
      expect(enough['winner'], kPrimary);
      expect(enough['reasonCode'], 'onlySource');
    });

    test('thin coverage does not win over a lower-ranked source that has '
        'enough', () async {
      await insertCoverage(kPrimary, InputSignal.hr1Hz, t(0), t(2));
      await insertCoverage(kStrapA, InputSignal.hr1Hz, t(1), t(1) + 60);
      await LocalDb.setSignalPriority(InputSignal.hr1Hz, [kStrapA, kPrimary]);
      final svc = openService(sources: sources);
      final hr = await resolveJson(svc, InputSignal.hr1Hz, t(0), t(2));
      expect(at(hr, t(1) + 30)['winner'], kPrimary,
          reason: 'a 60 s blip from the top-ranked device is not enough');
    });
  });

  group('resolved rows', () {
    // 2026-09-02, both devices cover hr1Hz 00-02 and the strap-like second
    // device outranks the primary.
    const g = 'gen5-abcd';
    int d(int h, [int m = 0]) => sec(2026, 9, 2, h, m);

    Future<List<Map<String, Object?>>> overlapRows({
      int? hrPrimary,
      int? hrOther,
    }) async {
      await insertCoverage(kPrimary, InputSignal.hr1Hz, d(0), d(2));
      await insertCoverage(g, InputSignal.hr1Hz, d(0), d(2));
      if (hrPrimary != null) await insertOneHz(kPrimary, d(0), d(2), hrPrimary);
      if (hrOther != null) await insertOneHz(g, d(0), d(2), hrOther);
      await LocalDb.setSignalPriority(InputSignal.hr1Hz, [g, kPrimary]);
      final svc = openService(sources: [kBand, strap(g)]);
      return resolveJson(svc, InputSignal.hr1Hz, d(0), d(2));
    }

    test('a contested row carries winner, alternatives, agreement and reason',
        () async {
      final rows = await overlapRows(hrPrimary: 60, hrOther: 61);
      expectTiles(rows, d(0), d(2));
      final row = at(rows, d(1));
      expect(row['signal'], 'hr1Hz');
      expect(row['winner'], g);
      expect(row['alternatives'], [kPrimary]);
      expect(row['kind'], 'overlap');
      expect(row['agreement'], 'agree');
      expect(row['reasonCode'], 'userPriority');
      expect((row['reason'] as String).trim(), isNotEmpty);
      final values = Map<String, Object?>.from(row['values'] as Map);
      expect(values[kPrimary], closeTo(60, 0.01), reason: 'mean retained hr');
      expect(values[g], closeTo(61, 0.01));
    });

    test('sources that read far apart disagree', () async {
      // The tolerance is the implementation's; 1 bpm vs 25 bpm sit clearly on
      // either side of any plausible choice.
      final rows = await overlapRows(hrPrimary: 60, hrOther: 85);
      expect(at(rows, d(1))['agreement'], 'disagree');
      expect(at(rows, d(1))['winner'], g,
          reason: 'disagreement is reported, it does not change the owner');
    });

    test('overlap with no retained values compares nothing', () async {
      final rows = await overlapRows();
      final row = at(rows, d(1));
      expect(row['agreement'], 'none');
      expect(row['winner'], g);
      expect(Map<String, Object?>.from(row['values'] as Map), isEmpty,
          reason: 'no value is invented when the substrate has been pruned');
    });

    test('a single covering source is "single", with no alternatives',
        () async {
      await insertCoverage(kPrimary, InputSignal.hr1Hz, d(0), d(2));
      final svc = openService(sources: [kBand]);
      final rows = await resolveJson(svc, InputSignal.hr1Hz, d(0), d(2));
      expect(rows.single['agreement'], 'single');
      expect(rows.single['alternatives'], isEmpty);
      expect(rows.single['kind'], 'single');
    });

    test('without a stored order the primary wins and the other is listed',
        () async {
      await insertCoverage(kPrimary, InputSignal.hr1Hz, d(0), d(2));
      await insertCoverage(g, InputSignal.hr1Hz, d(0), d(2));
      final svc = openService(sources: [kBand, strap(g)]);
      final rows = await resolveJson(svc, InputSignal.hr1Hz, d(0), d(2));
      final row = at(rows, d(1));
      expect(row['winner'], kPrimary);
      expect(row['alternatives'], [g]);
      expect(row['reasonCode'], 'defaultPrimary');
    });

    test('reasons are deterministic and rows tile the window', () async {
      await insertCoverage(kPrimary, InputSignal.hr1Hz, d(0), d(2));
      await insertCoverage(g, InputSignal.hr1Hz, d(1), d(3));
      await LocalDb.setSignalPriority(InputSignal.hr1Hz, [g, kPrimary]);
      final svc = openService(sources: [kBand, strap(g)]);
      final first = await resolveJson(svc, InputSignal.hr1Hz, d(0), d(3));
      final second = await resolveJson(svc, InputSignal.hr1Hz, d(0), d(3));
      expect(second, first, reason: 'same inputs, byte-identical rows');
      expectTiles(first, d(0), d(3));
      const codes = {
        'onlySource',
        'userPriority',
        'defaultPrimary',
        'noCoverage',
        'thinData',
      };
      for (final r in first) {
        expect(codes, contains(r['reasonCode']));
        expect({'single', 'overlap', 'gap'}, contains(r['kind']));
        expect({'agree', 'disagree', 'single', 'none'}, contains(r['agreement']));
      }
    });
  });
}
