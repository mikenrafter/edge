import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'pulse_sleep_rr_fixture.dart';

const target = 3 * 86400000;
List<ana.PulseBeatInput> trace(int start, int minutes, int Function(int, int) rr) {
  var time = start, index = 0;
  final beats = <ana.PulseBeatInput>[];
  while (time < start + minutes * 60000) {
    final value = rr(index++, time - start);
    time += value;
    beats.add(ana.PulseBeatInput(id: '$start:$index', source: 'strap',
      index: beats.length, timeMs: time, rawMs: value.toDouble()));
  }
  return beats;
}
final history = [for (var day = 0; day < 3; day++)
  ...trace(day * 86400000, 55, (i, _) => sleepRrFixtures.first[i % sleepRrFixtures.first.length])];
Map<int, ana.PulseWindowContext> context(bool ready) => {
  for (var day = ready ? 0 : 3; day <= 3; day++)
    for (var t = day * 86400000; t < day * 86400000 + 55 * 60000; t += 300000)
      t: ana.PulseWindowContext(asleep: true, motion: false, wear: true,
        day: '2026-11-${(7 + day).toString().padLeft(2, '0')}')};
ana.PulseDetection run(List<ana.PulseBeatInput> beats, {bool ready = false,
    bool sleeping = true, int from = target + 300000,
    int to = target + 900000, int complete = target + 1200000}) {
  final all = [...(ready ? history : <ana.PulseBeatInput>[]), ...beats];
  return ana.detectPulseEpisodes([for (var i = 0; i < all.length; i++)
    ana.PulseBeatInput(id: all[i].id, source: 'strap', index: i,
      timeMs: all[i].timeMs, rawMs: all[i].rawMs)],
    sourceStartMs: ready ? 0 : target, completeThroughMs: complete,
    evaluateFromMs: from, evaluateToMs: to, context: sleeping ? context(ready) : {});
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
  test('all 4000 bounded irregular seeds survive calibrating and ready baselines', () {
    var controls = 0;
    final lost = <String>[];
    for (var seed = 0; seed < 4000; seed++) {
      final beats = bounded(seed);
      final blind = run(beats, sleeping: false);
      if (blind.episodes.isNotEmpty) controls++;
      for (final ready in [false, true]) {
        final result = run(beats, ready: ready);
        if (blind.episodes.isNotEmpty && result.episodes.isEmpty) lost.add('$seed:$ready');
        expect(result.windows.first.toJson()['baseline'],
          containsPair('status', ready ? 'ready' : 'calibrating'));
      }
    }
    print('BOUNDED_SWEEP ${jsonEncode({'seeds':4000,'controlEpisodes':controls,'lost':lost})}');
    expect(controls, 2996, reason: 'independent reviewer bounded corpus');
    expect(lost, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 30)));
  // WHY: a slow rate trend is outside the respiratory band despite positive lag-3.
  // # catches: treating any smooth variation as independent breathing evidence.
  test('60-beat slow drift plus irregular RR still qualifies with either baseline', () {
    for (final ready in [false, true]) {
      final random = Random(53);
      final beats = trace(target, 20,
        (i, _) => (1150 + 100 * sin(2*pi*i/60) + random.nextInt(400)-200).round());
      final result = run(beats, ready: ready);
      expect(result.episodes, hasLength(1), reason: 'ready=$ready');
      expect(result.windows.first.toJson()['baseline'],
        containsPair('status', ready ? 'ready' : 'calibrating'));
    }
  });
  // WHY: two independently supported, matching respiratory peaks are required.
  // # catches: single-window peak veto or accepting unrelated adjacent frequencies.
  test('a mismatched respiratory pair remains eligible', () {
    final beats = trace(target, 25, (i, elapsed) =>
      (1150 + 120*sin(2*pi*i/(elapsed < 600000 ? 3.2 : 4.8))).round());
    final result = run(beats);
    expect(result.episodes, hasLength(1));
  });
  // WHY/CLAIM(pulse-respiratory-pair): partial neighbor support cannot cancel an alert.
  // # catches: using an unsupported partner or anchoring pair selection at evaluationFrom.
  test('pair evidence is independent of range and arrival order; incomplete partner abstains', () {
    final beats = trace(target, 25, (i, _) => (1150 + 100*sin(2*pi*i/3.7)).round());
    final full = run(beats, from: target, to: target + 1200000);
    final narrow = run(beats, from: target + 300000, to: target + 600000);
    expect(narrow.windows.single.toJson(), full.windows[1].toJson());
    expect(narrow.windows.single.reasons, contains('sleepBreathing'));
    final shuffled = [...beats]..shuffle(Random(7));
    final again = ana.detectPulseEpisodes(shuffled, sourceStartMs: target,
      completeThroughMs: target+1200000, evaluateFromMs: target+300000,
      evaluateToMs: target+600000, context: context(false));
    expect(again.windows.single.toJson(), narrow.windows.single.toJson());
    final partial = run(beats, complete: target+600000,
      from: target, to: target+300000);
    // The partner at minute five lacks its following five minutes of correction support.
    expect(partial.windows.single.reasons, isNot(contains('sleepBreathing')));
    expect(partial.windows.single.qualified, isTrue);
  });
}
