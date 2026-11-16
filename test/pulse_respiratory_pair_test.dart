// Diagnostics are retained in the acceptance run log.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

const target = 3 * 86400000;
List<ana.PulseBeatInput> trace(
  int start,
  int minutes,
  int Function(int, int) rr,
) {
  var time = start, index = 0;
  final beats = <ana.PulseBeatInput>[];
  while (time < start + minutes * 60000) {
    final value = rr(index++, time - start);
    time += value;
    beats.add(
      ana.PulseBeatInput(
        id: '$start:$index',
        source: 'strap',
        index: beats.length,
        timeMs: time,
        rawMs: value.toDouble(),
      ),
    );
  }
  return beats;
}

// Twenty-four independent, quality-passing normal windows across three dates.
// Hourly spacing avoids repeatedly cleaning identical neighboring history in
// every seed. Tiny periodic variation has pNN70=0 and a raised personal ratio.
final history = [
  for (var day = 0; day < 3; day++)
    for (var hour = 0; hour < 8; hour++)
      ...trace(
        day * 86400000 + hour * 3600000,
        5,
        (i, _) => (1450 + 2 * sin(2 * pi * i / 3.7)).round(),
      ),
];
Map<int, ana.PulseWindowContext> context(bool ready) => {
  if (ready)
    for (var day = 0; day < 3; day++)
      for (var hour = 0; hour < 8; hour++)
        day * 86400000 + hour * 3600000: ana.PulseWindowContext(
          asleep: true,
          motion: false,
          wear: true,
          day: '2026-11-${(7 + day).toString().padLeft(2, '0')}',
        ),
  for (var t = target; t < target + 55 * 60000; t += 300000)
    t: const ana.PulseWindowContext(
      asleep: true,
      motion: false,
      wear: true,
      day: '2026-11-10',
    ),
};
ana.PulseDetection run(
  List<ana.PulseBeatInput> beats, {
  bool ready = false,
  bool sleeping = true,
  int from = target + 300000,
  int to = target + 900000,
  int complete = target + 1200000,
}) {
  final all = [...(ready ? history : <ana.PulseBeatInput>[]), ...beats];
  return ana.detectPulseEpisodes(
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
    sourceStartMs: ready ? 0 : target,
    completeThroughMs: complete,
    evaluateFromMs: from,
    evaluateToMs: to,
    context: sleeping ? context(ready) : {},
  );
}

List<ana.PulseBeatInput> bounded(int seed) {
  final random = Random(seed);
  return trace(target, 20, (_, elapsed) {
    final value = 950 + random.nextInt(400);
    return elapsed >= 300000 && elapsed < 900000 ? value : 1150;
  });
}

void main() {
  // WHY/CLAIM(pulse-respiratory-pair): chance lag correlation must not hide irregularity.
  // # catches: the reviewed lag-3 OR lag-4 veto, even with a ready personal baseline.
  test(
    'all 4000 bounded irregular seeds survive calibrating and ready baselines',
    () {
      var controls = 0;
      final lost = <String>[];
      for (var seed = 0; seed < 4000; seed++) {
        if (seed % 500 == 0) {
          print('SWEEP_PROGRESS seed=$seed');
        }
        final beats = bounded(seed);
        final blind = run(beats, sleeping: false);
        if (blind.episodes.isNotEmpty) {
          controls++;
        }
        for (final ready in [false, true]) {
          final result = run(beats, ready: ready);
          if (blind.episodes.isNotEmpty && result.episodes.isEmpty) {
            lost.add('$seed:$ready');
          }
          expect(
            result.windows.first.toJson()['baseline'],
            containsPair('status', ready ? 'ready' : 'calibrating'),
          );
        }
      }
      print(
        'BOUNDED_SWEEP ${jsonEncode({'seeds': 4000, 'controlEpisodes': controls, 'lost': lost})}',
      );
      expect(
        controls,
        greaterThanOrEqualTo(2900),
        reason: 'keep a meaningful control corpus',
      );
      expect(lost, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 30)),
    tags: 'sweep',
  );
  // WHY: a slow rate trend is outside the respiratory band despite positive lag-3.
  // # catches: treating any smooth variation as independent breathing evidence.
  test(
    '60-beat slow drift plus irregular RR still qualifies with either baseline',
    () {
      for (final ready in [false, true]) {
        final random = Random(53);
        final beats = trace(
          target,
          20,
          (i, _) =>
              (1150 + 100 * sin(2 * pi * i / 60) + random.nextInt(400) - 200)
                  .round(),
        );
        final result = run(beats, ready: ready);
        expect(result.episodes, hasLength(1), reason: 'ready=$ready');
        expect(
          result.windows.first.toJson()['baseline'],
          containsPair('status', ready ? 'ready' : 'calibrating'),
        );
      }
    },
  );
  // WHY: retain the reviewer's entire unbounded corpus, not only known failures.
  // # catches: a new spectral false negative outside the eight old lag failures.
  test(
    '4000 unbounded irregular seeds retain their episodes',
    () {
      var controls = 0;
      final lost = <int>[];
      for (var seed = 0; seed < 4000; seed++) {
        final random = Random(seed);
        final beats = trace(target, 20, (_, _) => 950 + random.nextInt(400));
        final blind = run(beats, sleeping: false), sleeping = run(beats);
        if (blind.episodes.isNotEmpty) {
          controls++;
          if (sleeping.episodes.isEmpty) {
            lost.add(seed);
          }
        }
      }
      print(
        'UNBOUNDED_SWEEP ${jsonEncode({'seeds': 4000, 'controls': controls, 'lost': lost})}',
      );
      expect(controls, greaterThanOrEqualTo(3900));
      expect(lost, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 10)),
    tags: 'sweep',
  );
  // WHY: the independent margin study's strongest paired noise hump is not respiration.
  // # catches: accepting concentrated broad noise without a prominent peak.
  test('strongest paired noise hump remains eligible', () {
    expect(run(bounded(2172), sleeping: false).episodes, hasLength(1));
    expect(run(bounded(2172)).episodes, hasLength(1));
  });
  // WHY: record timestamp jitter is not beat timing; large missing spans still abstain.
  // # catches: using quantized record time for RR spectra or joining recording holes.
  test('RR clock tolerates record jitter but refuses a recording hole', () {
    final beats = trace(
      target,
      25,
      (i, _) => (1150 + 100 * sin(2 * pi * i / 3.7)).round(),
    );
    List<ana.PulseBeatInput> displaced(bool hole) => [
      for (final b in beats)
        ana.PulseBeatInput(
          id: b.id,
          source: b.source,
          index: b.index,
          rawMs: b.rawMs,
          timeMs:
              b.timeMs +
              (hole
                  ? (b.timeMs >= target + 480000 ? 8000 : 0)
                  : (b.timeMs % 300000 > 5000 && b.timeMs % 300000 < 295000
                        ? [0, 200, -100, 100][b.index % 4]
                        : 0)),
        ),
    ];
    final jittered = run(displaced(false));
    expect(jittered.episodes, isEmpty);
    expect(
      [
        for (final w in jittered.windows)
          (w.breathingPeakHz, w.breathingConcentration, w.breathingProminence),
      ],
      [
        for (final w in run(beats).windows)
          (w.breathingPeakHz, w.breathingConcentration, w.breathingProminence),
      ],
    );
    final broken = run(displaced(true)).windows.first;
    expect(broken.qualityReasons, contains('gaps'));
    expect(broken.exclusionReasons, isNot(contains('sleepBreathing')));
  });
  // WHY: retain the reviewer's eight independently irregular unbounded probes.
  // # catches: reintroducing the chance-correlation veto outside bounded episodes.
  test('reviewer unbounded irregular probes survive both baseline states', () {
    for (final seed in [156, 1224, 1922, 2013, 2519, 2764, 2879, 3288]) {
      final random = Random(seed);
      final beats = trace(target, 20, (_, _) => 950 + random.nextInt(400));
      for (final ready in [false, true]) {
        expect(
          run(beats, ready: ready).episodes,
          hasLength(1),
          reason: 'seed=$seed, ready=$ready',
        );
      }
    }
  });
  // WHY: respiratory exclusion must generalize beyond captured owner arrays.
  // # catches: tuning only to one captured breathing rate or requiring positive lag one.
  test('independent respiratory rates with gradual drift are excluded', () {
    for (final frequency in [0.23, 0.27, 0.31]) {
      final beats = trace(target, 25, (_, elapsed) {
        final seconds = elapsed / 1000;
        return (1150 +
                110 *
                    sin(
                      2 *
                          pi *
                          (frequency * seconds + 0.000005 * seconds * seconds),
                    ))
            .round();
      });
      for (final ready in [false, true]) {
        expect(
          run(beats, sleeping: false, ready: ready).episodes,
          hasLength(1),
        );
        expect(
          run(beats, ready: ready).episodes,
          isEmpty,
          reason: 'frequency=$frequency, ready=$ready',
        );
      }
    }
  });
  // WHY: two independently supported, matching respiratory peaks are required.
  // # catches: single-window peak veto or accepting unrelated adjacent frequencies.
  test('a mismatched respiratory pair remains eligible', () {
    final beats = trace(
      target,
      25,
      (i, elapsed) =>
          (1150 +
                  120 *
                      sin(
                        2 * pi * i / ((elapsed ~/ 300000).isEven ? 3.2 : 4.8),
                      ))
              .round(),
    );
    final result = run(beats);
    expect(result.episodes, hasLength(1));
  });
  // WHY/CLAIM(pulse-respiratory-pair): partial neighbor support cannot cancel an alert.
  // # catches: using an unsupported partner or anchoring pair selection at evaluationFrom.
  test(
    'pair evidence is independent of range and arrival order; incomplete partner abstains',
    () {
      final beats = trace(
        target,
        25,
        (i, _) => (1150 + 100 * sin(2 * pi * i / 3.7)).round(),
      );
      final full = run(beats, from: target, to: target + 1200000);
      final narrow = run(beats, from: target + 300000, to: target + 600000);
      expect(narrow.windows.single.toJson(), full.windows[1].toJson());
      expect(narrow.windows.single.reasons, contains('sleepBreathing'));
      final shuffled = [...beats]..shuffle(Random(7));
      final again = ana.detectPulseEpisodes(
        shuffled,
        sourceStartMs: target,
        completeThroughMs: target + 1200000,
        evaluateFromMs: target + 300000,
        evaluateToMs: target + 600000,
        context: context(false),
      );
      expect(again.windows.single.toJson(), narrow.windows.single.toJson());
      final partial = run(
        beats,
        complete: target + 600000,
        from: target,
        to: target + 300000,
      );
      // The partner at minute five lacks its following five minutes of correction support.
      expect(partial.windows.single.reasons, isNot(contains('sleepBreathing')));
      expect(partial.windows.single.qualified, isTrue);
    },
  );
}
