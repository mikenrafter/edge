import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/resonance/resonance_analyzer.dart';
import 'package:openstrap_edge/explore/resonance/resonance_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

SweepSessionRecord rec(
  ComparisonOutcome outcome, {
  double? rate,
  ({double lo, double hi})? range,
  DateTime? at,
  List<BlockResult> blocks = const [],
}) =>
    SweepSessionRecord(
      at: at ?? DateTime.utc(2026, 10, 7, 8),
      outcome: outcome,
      rateBpm: rate,
      range: range,
      blocks: blocks,
    );

SweepSessionRecord tentative(double rate) =>
    rec(ComparisonOutcome.tentativeRate, rate: rate);
SweepSessionRecord tied(double lo, double hi) =>
    rec(ComparisonOutcome.tiedRange, range: (lo: lo, hi: hi));
SweepSessionRecord inconclusive() =>
    rec(ComparisonOutcome.inconclusiveFlat);
SweepSessionRecord stopped() => rec(ComparisonOutcome.stoppedEarly);

void main() {
  group('suggestedPracticeRate', () {
    test('no sessions, or one conclusive session, suggests nothing', () {
      expect(suggestedPracticeRate(const []), isNull);
      expect(suggestedPracticeRate([tentative(5.5)]), isNull);
      expect(suggestedPracticeRate([tied(5.0, 6.0)]), isNull);
      expect(suggestedPracticeRate([inconclusive(), stopped()]), isNull);
    });

    test('two tentative rates that agree give their mean', () {
      expect(suggestedPracticeRate([tentative(5.5), tentative(5.5)]),
          closeTo(5.5, 1e-9));
      expect(suggestedPracticeRate([tentative(5.5), tentative(5.8)]),
          closeTo(5.65, 1e-9));
    });

    test('0.5 bpm apart still agrees, more does not', () {
      expect(suggestedPracticeRate([tentative(6.0), tentative(5.5)]),
          closeTo(5.75, 1e-9));
      expect(suggestedPracticeRate([tentative(6.0), tentative(5.0)]), isNull);
      expect(suggestedPracticeRate([tentative(5.0), tentative(5.6)]), isNull);
    });

    test('two ranges give the midpoint of their overlap', () {
      expect(suggestedPracticeRate([tied(5.0, 6.0), tied(5.5, 6.5)]),
          closeTo(5.75, 1e-9));
    });

    test('a rate inside a range gives that rate', () {
      expect(suggestedPracticeRate([tentative(5.5), tied(5.0, 6.0)]),
          closeTo(5.5, 1e-9));
      expect(suggestedPracticeRate([tied(5.0, 6.0), tentative(5.5)]),
          closeTo(5.5, 1e-9));
    });

    test('ranges that do not overlap or come near each other disagree', () {
      expect(suggestedPracticeRate([tied(4.5, 5.0), tied(6.0, 6.5)]), isNull);
    });

    test('inconclusive and stopped sessions in between do not break the pair',
        () {
      expect(
          suggestedPracticeRate(
              [tentative(5.5), inconclusive(), stopped(), tentative(5.5)]),
          closeTo(5.5, 1e-9));
    });

    test('only the two most recent conclusive sessions are compared', () {
      // Newest two disagree; the third would agree with the newest.
      expect(
          suggestedPracticeRate(
              [tentative(6.0), inconclusive(), tentative(5.0), tentative(6.0)]),
          isNull);
    });
  });

  group('SweepSessionRecord JSON', () {
    const blocks = [
      BlockResult(
        rateBpm: 6.0,
        amplitudeBpm: 9.5,
        coverage: 0.99,
        observedFraction: 1.0,
        cycles: 12,
        rejection: null,
      ),
      BlockResult(
        rateBpm: 5.0,
        amplitudeBpm: null,
        coverage: 0.7,
        observedFraction: 0.97,
        cycles: 4,
        rejection: BlockRejection.lowCoverage,
      ),
    ];

    SweepSessionRecord roundTrip(SweepSessionRecord r) =>
        SweepSessionRecord.fromJson(
            jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);

    void expectSame(SweepSessionRecord a, SweepSessionRecord b) {
      expect(a.at.isAtSameMomentAs(b.at), isTrue);
      expect(a.outcome, b.outcome);
      expect(a.rateBpm, b.rateBpm);
      expect(a.range?.lo, b.range?.lo);
      expect(a.range?.hi, b.range?.hi);
      expect(a.blocks.length, b.blocks.length);
      for (var i = 0; i < a.blocks.length; i++) {
        final x = a.blocks[i], y = b.blocks[i];
        expect(x.rateBpm, y.rateBpm);
        expect(x.amplitudeBpm, y.amplitudeBpm);
        expect(x.coverage, y.coverage);
        expect(x.observedFraction, y.observedFraction);
        expect(x.cycles, y.cycles);
        expect(x.rejection, y.rejection);
      }
    }

    test('a tentative rate with admitted and rejected blocks', () {
      final r = rec(ComparisonOutcome.tentativeRate, rate: 5.5, blocks: blocks);
      expectSame(roundTrip(r), r);
    });

    test('a range, and an inconclusive session with nulls', () {
      final a = rec(ComparisonOutcome.tiedRange,
          range: (lo: 5.0, hi: 6.0), blocks: blocks);
      expectSame(roundTrip(a), a);
      final b = rec(ComparisonOutcome.inconclusiveBoundary);
      final back = roundTrip(b);
      expectSame(back, b);
      expect(back.rateBpm, isNull);
      expect(back.range, isNull);
    });
  });

  group('ResonanceHistoryStore', () {
    const store = ResonanceHistoryStore();
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('empty storage loads an empty list', () async {
      expect(await store.load(), isEmpty);
    });

    test('add then load: newest first, under the documented key', () async {
      await store.add(rec(ComparisonOutcome.tentativeRate,
          rate: 5.0, at: DateTime.utc(2026, 10, 1)));
      await store.add(rec(ComparisonOutcome.tentativeRate,
          rate: 5.5, at: DateTime.utc(2026, 10, 2)));
      final all = await store.load();
      expect(all.map((r) => r.rateBpm), [5.5, 5.0]);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getKeys(), contains('explore.resonance.history'));
    });

    test('keeps at most 20, dropping the oldest', () async {
      for (var i = 0; i < 25; i++) {
        await store.add(rec(ComparisonOutcome.tentativeRate,
            rate: 4.0 + i * 0.1, at: DateTime.utc(2026, 10, 1).add(Duration(days: i))));
      }
      final all = await store.load();
      expect(all.length, 20);
      expect(all.first.rateBpm, closeTo(4.0 + 24 * 0.1, 1e-9));
      expect(all.last.rateBpm, closeTo(4.0 + 5 * 0.1, 1e-9));
    });

    test('clear empties it', () async {
      await store.add(tentative(5.5));
      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('corrupt storage reads as empty and does not throw', () async {
      for (final bad in <Object>[
        '{not json',
        '{"a": 1}',
        '[1, 2, 3]',
        '[{"outcome": "nonsense"}]',
        42,
      ]) {
        SharedPreferences.setMockInitialValues({'explore.resonance.history': bad});
        expect(await store.load(), isEmpty, reason: '$bad');
      }
    });

    test('a corrupt history does not stop a new session being saved',
        () async {
      SharedPreferences.setMockInitialValues(
          {'explore.resonance.history': '{not json'});
      await store.add(tentative(5.5));
      expect((await store.load()).map((r) => r.rateBpm), [5.5]);
    });
  });

  group('preferred rate', () {
    const store = ResonanceHistoryStore();
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('unset is null; set and read back; null clears', () async {
      expect(await store.preferredRate(), isNull);
      await store.setPreferredRate(5.5);
      expect(await store.preferredRate(), 5.5);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getDouble('explore.resonance.preferred_rate'), 5.5);
      await store.setPreferredRate(null);
      expect(await store.preferredRate(), isNull);
    });

    test('is separate from the measured suggestion and from the history',
        () async {
      await store.setPreferredRate(6.0);
      expect(await store.load(), isEmpty);
      expect(suggestedPracticeRate(await store.load()), isNull);
      await store.add(tentative(5.0));
      await store.add(tentative(5.0));
      expect(suggestedPracticeRate(await store.load()), closeTo(5.0, 1e-9));
      expect(await store.preferredRate(), 6.0);
      await store.clear();
      expect(await store.preferredRate(), 6.0,
          reason: 'clearing history leaves the comfortable rate alone');
    });
  });
}
