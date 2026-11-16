import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'pulse_sleep_rr_fixture.dart';

final candidate = DateTime.utc(2026, 11, 10).millisecondsSinceEpoch;
List<ana.PulseBeatInput> beatsAt(int start, int minutes, List<int> rr) {
  final out = <ana.PulseBeatInput>[];
  var time = start, i = 0;
  while (time < start + minutes * 60000) {
    final value = rr[i % rr.length];
    time += value;
    out.add(
      ana.PulseBeatInput(
        id: '$start:$i',
        source: 'strap',
        index: i++,
        timeMs: time,
        rawMs: value.toDouble(),
      ),
    );
  }
  return out;
}

List<int> irregular() {
  final random = Random(53);
  return List.generate(5000, (_) => 950 + random.nextInt(400));
}

Map<int, ana.PulseWindowContext> contexts(
  int start,
  int minutes, {
  bool? asleep = true,
  bool? motion,
  bool? wear,
  bool? charging,
}) => {
  for (var t = start; t < start + minutes * 60000; t += ana.pulseWindowMs)
    t: ana.PulseWindowContext(
      asleep: asleep,
      motion: motion,
      wear: wear,
      charging: charging,
      day: DateTime.fromMillisecondsSinceEpoch(
        t,
        isUtc: true,
      ).toIso8601String().substring(0, 10),
    ),
};
ana.PulseDetection detect(
  List<ana.PulseBeatInput> beats,
  Map<int, ana.PulseWindowContext> context, {
  int? from,
}) => ana.detectPulseEpisodes(
  [
    for (var i = 0; i < beats.length; i++)
      ana.PulseBeatInput(
        id: beats[i].id,
        source: beats[i].source,
        index: i,
        timeMs: beats[i].timeMs,
        rawMs: beats[i].rawMs,
      ),
  ],
  completeThroughMs: candidate + 30 * 60000,
  sourceStartMs: beats.first.timeMs ~/ ana.pulseWindowMs * ana.pulseWindowMs,
  evaluateFromMs: from ?? candidate,
  evaluateToMs: candidate + 20 * 60000,
  context: context,
);

void main() {
  // WHY/CLAIM(pulse-context): absent optional sensors must never disable screening.
  // # catches: making wear==true or motion==false a prerequisite.
  test('unknown context is explicit and remains eligible', () {
    final result = detect(beatsAt(candidate, 30, irregular()), {});
    expect(
      result.windows.first.ratio,
      lessThan(0.95),
      reason: 'a 0.95 personal cutoff would hide this irregular control',
    );
    expect(result.episodes, hasLength(1));
    expect(result.episodes.single.alertEligible, isTrue);
    expect(
      result.windows.first.toJson()['context'],
      containsPair('status', 'unknown'),
    );
    expect(
      result.windows.first.toJson()['thresholds'],
      containsPair('ratio', 0.7),
    );
  });
  // WHY/CLAIM(pulse-context): positive charging evidence overrides unknown wear.
  // # catches: wiring only the on_wrist column, which is null in the export.
  test('charging suppresses despite unknown motion and wear', () {
    final result = detect(
      beatsAt(candidate, 30, irregular()),
      contexts(candidate, 30, charging: true),
    );
    expect(result.episodes, isEmpty);
    expect(result.windows.first.reasons, contains('charging'));
  });
  // WHY/CLAIM(pulse-sleep-pattern): waking periodicity is outside this narrow veto.
  // # catches: applying an unconditional autocorrelation veto.
  test('the same patterned RR can qualify awake but not in low-HR sleep', () {
    final beats = beatsAt(candidate, 30, sleepRrFixtures.first);
    expect(
      detect(beats, contexts(candidate, 30, asleep: false)).episodes,
      hasLength(1),
    );
    expect(detect(beats, contexts(candidate, 30)).episodes, isEmpty);
  });
  // WHY/CLAIM(pulse-baseline): historical normal sleeping variation must affect both floors.
  // # catches: keeping fixed thresholds, self-training, or pooling awake and sleep.
  test(
    'baseline uses three earlier days, both metrics, and preserves irregular controls',
    () {
      final history = <ana.PulseBeatInput>[],
          context = <int, ana.PulseWindowContext>{};
      // The residual guard accepts only the supported subset of this capture
      // as normal. Supply enough history to retain >=24 quality windows;
      // keep all baseline thresholds and irregular-control assertions unchanged.
      for (var day = 3; day >= 1; day--) {
        final t = candidate - day * 24 * 3600000;
        history.addAll(beatsAt(t, 115, sleepRrFixtures.first));
        context.addAll(contexts(t, 115, motion: false, wear: true));
      }
      final target = beatsAt(candidate, 30, irregular());
      context.addAll(contexts(candidate, 30, motion: false, wear: true));
      final result = detect([...history, ...target], context);
      final thresholds = result.windows.first.toJson()['thresholds'] as Map;
      expect(
        thresholds['ratio'],
        0.7,
        reason: 'personalization cannot veto uncorrelated RR',
      );
      final personal = result.windows.first.toJson()['baseline'] as Map;
      expect(personal['ratioThreshold'], greaterThan(0.7));
      expect(thresholds['ratio'], lessThanOrEqualTo(0.95));
      expect(thresholds['pnnPct'], 30);
      expect(personal['pnnThreshold'], greaterThan(30));
      expect(thresholds['pnnPct'], lessThanOrEqualTo(60));
      expect(result.episodes, hasLength(1));
      final baseline = result.windows.first.toJson()['baseline'] as Map;
      expect(baseline['days'], 3);
      expect(baseline['windows'], greaterThanOrEqualTo(24));
      final cold = detect(
        target,
        contexts(candidate, 30, motion: false, wear: true),
      );
      expect(
        cold.windows.last.toJson()['thresholds'],
        containsPair('ratio', 0.7),
      );
      final awake = detect(
        [...history, ...target],
        {
          ...context,
          ...contexts(candidate, 30, asleep: false, motion: false, wear: true),
        },
      );
      expect(
        awake.windows.first.toJson()['thresholds'],
        containsPair('ratio', 0.7),
      );
      final shuffled = [...history, ...target]..shuffle(Random(7));
      // Canonical indices, not list arrival order, determine RR order.
      final canonical = [...history, ...target];
      final indexed = {
        for (var i = 0; i < canonical.length; i++) canonical[i].id: i,
      };
      final again = ana.detectPulseEpisodes(
        [
          for (final b in shuffled)
            ana.PulseBeatInput(
              id: b.id,
              source: b.source,
              index: indexed[b.id]!,
              timeMs: b.timeMs,
              rawMs: b.rawMs,
            ),
        ],
        completeThroughMs: candidate + 30 * 60000,
        sourceStartMs: candidate - 3 * 24 * 3600000,
        evaluateFromMs: candidate,
        evaluateToMs: candidate + 20 * 60000,
        context: context,
      );
      expect(again.toJson(), result.toJson());
    },
  );
  // WHY/CLAIM(pulse-baseline): early irregularity cannot normalize later irregularity.
  // # catches: learning the first three days indiscriminately.
  test(
    'irregular first three days do not raise later irregular detection floors',
    () {
      final history = <ana.PulseBeatInput>[],
          context = <int, ana.PulseWindowContext>{};
      for (var day = 3; day >= 1; day--) {
        final t = candidate - day * 24 * 3600000;
        history.addAll(beatsAt(t, 55, irregular()));
        context.addAll(contexts(t, 55, motion: false, wear: true));
      }
      final target = beatsAt(candidate, 30, irregular());
      context.addAll(contexts(candidate, 30, motion: false, wear: true));
      final result = detect([...history, ...target], context);
      expect(result.episodes, hasLength(1));
      expect(
        result.windows.first.toJson()['thresholds'],
        containsPair('ratio', 0.7),
      );
      expect(
        result.windows.first.toJson()['thresholds'],
        containsPair('pnnPct', 30),
      );
      expect(
        result.windows.first.toJson()['baseline'],
        containsPair('windows', 0),
      );
    },
  );

  // WHY/CLAIM(pulse-baseline): stored episodes of every status cannot train normality.
  // # catches: omitting the episode exclusion or its thirty-minute halo.
  test('episode exclusion halos remove otherwise normal baseline windows', () {
    final history = <ana.PulseBeatInput>[],
        context = <int, ana.PulseWindowContext>{};
    final excluded = <List<int>>[];
    for (var day = 3; day >= 1; day--) {
      final t = candidate - day * 24 * 3600000;
      history.addAll(beatsAt(t, 55, sleepRrFixtures.first));
      context.addAll(contexts(t, 55, motion: false, wear: true));
      // The stored stretch itself is later. Its thirty-minute halo covers training.
      excluded.add([t + 55 * 60000, t + 65 * 60000]);
    }
    final all = [...history, ...beatsAt(candidate, 30, irregular())];
    context.addAll(contexts(candidate, 30, motion: false, wear: true));
    final result = ana.detectPulseEpisodes(
      [
        for (var i = 0; i < all.length; i++)
          ana.PulseBeatInput(
            id: all[i].id,
            source: 'strap',
            index: i,
            timeMs: all[i].timeMs,
            rawMs: all[i].rawMs,
          ),
      ],
      completeThroughMs: candidate + 30 * 60000,
      sourceStartMs: candidate - 3 * 24 * 3600000,
      evaluateFromMs: candidate,
      evaluateToMs: candidate + 20 * 60000,
      context: context,
      baselineExclusions: {'strap': excluded},
    );
    final baseline = result.windows.first.toJson()['baseline'] as Map;
    expect(baseline['windows'], lessThan(24));
    expect(baseline['status'], 'calibrating');
    expect(result.episodes, hasLength(1));
  });
}
