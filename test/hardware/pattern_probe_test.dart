// 8W: the pattern probe. The 20:40 lab log showed one buzz command is felt as
// ONE "bzz-bzz" however it is written, and that the band swallows a command
// written while it still plays. The probe tries ways of getting a COUNT of
// buzzes out of it: four waveforms × four ways of sending (separate commands
// paced by time, separate commands paced by the band's own "ended" event, one
// command with its loop count raised, one command listing the waveform N
// times) × counts 2 and 3. It is pure Dart with injected effects, so this file
// runs it on a virtual clock against fake band events.
//
// Pinned here: the catalogue (32 tests, how they cycle, the command budget),
// what each way of sending writes and when, how a test ends (the band's 100 or
// the settle time), the log line, and every way the run stops.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 20, 40);

/// A virtual clock. Waits move it; scheduled band events are delivered at
/// their own receipt time (inside whatever wait spans it), so the probe sees
/// them exactly when they "arrive".
class _Clock {
  DateTime now = _t0;
  int get ms => now.difference(_t0).inMilliseconds;
  void Function(int id, DateTime received, DateTime happened)? deliver;
  final _due = <({int id, int recvMs, int happenedMs})>[];

  void schedule(int id, int recvMs, {int? happenedMs}) {
    _due.add((id: id, recvMs: recvMs, happenedMs: happenedMs ?? recvMs));
    _due.sort((a, b) => a.recvMs.compareTo(b.recvMs));
  }

  Future<void> wait(Duration d) async {
    final end = now.add(d);
    while (_due.isNotEmpty &&
        !_t0.add(Duration(milliseconds: _due.first.recvMs)).isAfter(end)) {
      final e = _due.removeAt(0);
      final at = _t0.add(Duration(milliseconds: e.recvMs));
      if (at.isAfter(now)) now = at;
      deliver?.call(e.id, at, _t0.add(Duration(milliseconds: e.happenedMs)));
    }
    now = end;
    await Future<void>.delayed(Duration.zero);
  }
}

typedef _Send = ({int startMs, int landedMs, List<int> effects, int loop});

class _Rig {
  _Rig({
    List<PatternTest>? tests,
    int latencyMs = 0,
    this.afterWrite,
    this.writes = true,
    PatternAnswer? Function(PatternTest, int)? answer,
    void Function(PatternProbe probe, int index)? onAsk,
    void Function(PatternProbe probe, int sendIndex)? onSend,
    this.connected = true,
  }) {
    probe = PatternProbe(
      sendPattern: (effects, loop, onReply) async {
        final i = sends.length;
        final start = clock.ms;
        sends.add((
          startMs: start,
          landedMs: start,
          effects: List.of(effects),
          loop: loop,
        ));
        onSend?.call(probe, i);
        if (!writes) return false;
        clock.now = clock.now.add(Duration(milliseconds: latencyMs));
        sends[i] = (
          startMs: start,
          landedMs: clock.ms,
          effects: List.of(effects),
          loop: loop,
        );
        for (final (id, afterMs)
            in afterWrite?.call(i) ?? const <(int, int)>[]) {
          clock.schedule(id, clock.ms + afterMs);
        }
        onReply(reply, 50);
        return true;
      },
      askFelt: (t, i) async {
        asks.add((test: t, index: i, atMs: clock.ms));
        onAsk?.call(probe, i);
        return answer == null ? PatternAnswer(2, 1) : answer(t, i);
      },
      isConnected: () => connected,
      step: steps.add,
      now: () => clock.now,
      wait: clock.wait,
      tests: tests,
    );
    clock.deliver = probe.onBandEvent;
  }

  final clock = _Clock();
  late final PatternProbe probe;
  final sends = <_Send>[];
  final asks = <({PatternTest test, int index, int atMs})>[];
  final steps = <String>[];
  bool connected;
  final bool writes;
  final String reply = 'pending';

  /// Band events to schedule after command number `i` lands: (event id, ms
  /// after the write landed).
  final List<(int, int)> Function(int i)? afterWrite;
}

const _pair = BuzzWaveform('band pair 47+152', [47, 152]);
const _alone = BuzzWaveform('effect 47 alone', [47]);

/// The band says 60, then 100 1.5 s after the write.
List<(int, int)> _bandPlays(int _) => const [(60, 15), (100, 1500)];

void main() {
  group('the catalogue', () {
    test('four waveforms', () {
      expect(BuzzWaveform.all.map((w) => w.name), [
        'band pair 47+152',
        'effect 47 alone',
        'effect 14',
        'effect 1',
      ]);
      expect(BuzzWaveform.all.map((w) => w.effects), [
        [47, 152],
        [47],
        [14],
        [1],
      ]);
    });

    test('four ways of sending', () {
      expect(BuzzStyle.values, [
        BuzzStyle.paced,
        BuzzStyle.eventPaced,
        BuzzStyle.repeat,
        BuzzStyle.listed,
      ]);
    });

    test('32 tests, cycling: count 2 then 3, waveform every test, style '
        'every four', () {
      final tests = PatternProbe.defaultTests;
      expect(tests, hasLength(32));
      for (var i = 0; i < 32; i++) {
        expect(tests[i].count, i < 16 ? 2 : 3, reason: 'test $i');
        expect(
          tests[i].waveform.name,
          BuzzWaveform.all[i % 4].name,
          reason: 'test $i',
        );
        expect(
          tests[i].style,
          BuzzStyle.values[(i ~/ 4) % 4],
          reason: 'test $i',
        );
      }
    });

    test('8 tests per waveform, 2 per waveform and way of sending (counts 2 '
        'and 3)', () {
      for (final w in BuzzWaveform.all) {
        final mine = PatternProbe.defaultTests.where(
          (t) => t.waveform.name == w.name,
        );
        expect(mine, hasLength(8), reason: w.name);
        for (final s in BuzzStyle.values) {
          expect(
            mine.where((t) => t.style == s).map((t) => t.count).toList()
              ..sort(),
            [2, 3],
            reason: '${w.name} $s',
          );
        }
      }
    });

    test('one line says what a test does', () {
      String d(BuzzWaveform w, BuzzStyle s, int n) =>
          PatternTest(waveform: w, style: s, count: n).description;
      const w14 = BuzzWaveform('effect 14', [14]);
      expect(d(w14, BuzzStyle.repeat, 3), 'effect 14, one command looped 3×');
      expect(
        d(_alone, BuzzStyle.paced, 2),
        'effect 47 alone, 2 commands 1.8 s apart',
      );
      expect(
        d(_alone, BuzzStyle.eventPaced, 3),
        'effect 47 alone, 3 commands, each after the band says the last one '
        'ended',
      );
      expect(
        d(_alone, BuzzStyle.listed, 2),
        'effect 47 alone, one command listing it 2× with a pause slot '
        'between',
      );
      for (final t in PatternProbe.defaultTests) {
        expect(t.description, startsWith(t.waveform.name));
      }
    });

    test('the budget: separate commands count each, one-command ways count '
        'one; the default fits and anything bigger is refused', () {
      int commands(PatternTest t) =>
          (t.style == BuzzStyle.paced || t.style == BuzzStyle.eventPaced)
          ? t.count
          : 1;
      final total = PatternProbe.defaultTests.fold<int>(
        0,
        (n, t) => n + commands(t),
      );
      expect(
        total,
        56,
        reason:
            'per waveform: paced 2+3, event-paced 2+3, repeat 1+1, '
            'listed 1+1 = 14, four waveforms',
      );
      expect(
        PatternProbe.maxCommands,
        greaterThanOrEqualTo(total),
        reason: 'the default run must fit its own budget',
      );
      expect(
        () => PatternProbe(
          sendPattern: (_, _, _) async => true,
          askFelt: (_, _) async => null,
          isConnected: () => true,
          tests: [
            for (var i = 0; i < PatternProbe.maxCommands; i++)
              PatternTest(waveform: _pair, style: BuzzStyle.paced, count: 2),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('a full default run writes exactly the budgeted commands', () async {
      final g = _Rig(afterWrite: _bandPlays);
      await g.probe.run();
      expect(g.asks, hasLength(32));
      expect(g.sends.length, lessThanOrEqualTo(PatternProbe.maxCommands));
      expect(g.sends, hasLength(56));
      expect(g.steps.last, 'Pattern probe finished.');
      expect(g.probe.running, isFalse);
    });
  });

  group('what each way of sending writes', () {
    Future<_Rig> run(
      BuzzWaveform w,
      BuzzStyle s,
      int n, {
      int latencyMs = 0,
      List<(int, int)> Function(int)? afterWrite,
    }) async {
      final g = _Rig(
        tests: [PatternTest(waveform: w, style: s, count: n)],
        latencyMs: latencyMs,
        afterWrite: afterWrite,
      );
      await g.probe.run();
      return g;
    }

    test('paced: N separate commands (loop 1), each 1800 ms after the '
        'previous write landed', () async {
      for (final n in [2, 3]) {
        final g = await run(_pair, BuzzStyle.paced, n, latencyMs: 80);
        expect(g.sends, hasLength(n));
        expect(g.sends.map((s) => s.effects), everyElement([47, 152]));
        expect(g.sends.map((s) => s.loop), everyElement(1));
        for (var i = 1; i < n; i++) {
          expect(
            g.sends[i].startMs - g.sends[i - 1].landedMs,
            1800,
            reason: 'command ${i + 1} of $n',
          );
        }
      }
    });

    test('paced ignores the band\'s events', () async {
      final g = await run(_alone, BuzzStyle.paced, 3, afterWrite: _bandPlays);
      expect(g.sends[1].startMs - g.sends[0].landedMs, 1800);
      expect(g.sends[2].startMs - g.sends[1].landedMs, 1800);
    });

    test('event-paced: the next command goes 100 ms after the band says it '
        'ended (event 100), not on event 60', () async {
      final g = await run(
        _alone,
        BuzzStyle.eventPaced,
        3,
        afterWrite: _bandPlays,
      );
      expect(g.sends, hasLength(3));
      expect(g.sends.map((s) => s.effects), everyElement([47]));
      expect(g.sends.map((s) => s.loop), everyElement(1));
      expect(g.sends[1].startMs - g.sends[0].landedMs, 1600);
      expect(g.sends[2].startMs - g.sends[1].landedMs, 1600);
    });

    test('event-paced: without a 100 the next command goes 2500 ms after '
        'the previous write', () async {
      final none = await run(_alone, BuzzStyle.eventPaced, 3);
      expect(none.sends[1].startMs - none.sends[0].landedMs, 2500);
      expect(none.sends[2].startMs - none.sends[1].landedMs, 2500);
      final only60 = await run(
        _alone,
        BuzzStyle.eventPaced,
        2,
        afterWrite: (_) => const [(60, 15)],
      );
      expect(only60.sends[1].startMs - only60.sends[0].landedMs, 2500);
    });

    test('event-paced: each command waits for ITS band event', () async {
      // Only the first write is followed by a 100.
      final g = await run(
        _pair,
        BuzzStyle.eventPaced,
        3,
        afterWrite: (i) => i == 0 ? _bandPlays(i) : const [],
      );
      expect(g.sends[1].startMs - g.sends[0].landedMs, 1600);
      expect(g.sends[2].startMs - g.sends[1].landedMs, 2500);
    });

    test(
      'repeat: ONE command, the waveform\'s effects, loop = the count',
      () async {
        for (final w in BuzzWaveform.all) {
          for (final n in [2, 3]) {
            final g = await run(w, BuzzStyle.repeat, n);
            expect(g.sends, hasLength(1), reason: '${w.name} ×$n');
            expect(g.sends.single.effects, w.effects, reason: '${w.name} ×$n');
            expect(g.sends.single.loop, n, reason: '${w.name} ×$n');
          }
        }
      },
    );

    test('listed: ONE command, loop 1, the waveform written N times with a '
        '152 slot between copies of a single effect', () async {
      const expected = <String, List<int>>{
        'band pair 47+152 2': [47, 152, 47, 152],
        'band pair 47+152 3': [47, 152, 47, 152, 47, 152],
        'effect 47 alone 2': [47, 152, 47],
        'effect 47 alone 3': [47, 152, 47, 152, 47],
        'effect 14 2': [14, 152, 14],
        'effect 14 3': [14, 152, 14, 152, 14],
        'effect 1 2': [1, 152, 1],
        'effect 1 3': [1, 152, 1, 152, 1],
      };
      for (final w in BuzzWaveform.all) {
        for (final n in [2, 3]) {
          final g = await run(w, BuzzStyle.listed, n);
          expect(g.sends, hasLength(1), reason: '${w.name} ×$n');
          expect(
            g.sends.single.effects,
            expected['${w.name} $n'],
            reason: '${w.name} ×$n',
          );
          expect(g.sends.single.loop, 1);
          expect(g.sends.single.effects.length, lessThanOrEqualTo(8));
        }
      }
    });
  });

  group('how a test ends, and the rest after it', () {
    test(
      'the settle wait ends on the band\'s 100 (after the last write)',
      () async {
        final g = _Rig(
          tests: [
            PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
          ],
          afterWrite: _bandPlays,
        );
        await g.probe.run();
        final landed = g.sends.single.landedMs;
        expect(g.asks.single.atMs - landed, inInclusiveRange(1500, 1600));
      },
    );

    test(
      'without a 100 (or with only a 60) it ends at the settle time, 3.5 s',
      () async {
        for (final after in <List<(int, int)> Function(int)?>[
          null,
          (_) => const [(60, 15)],
        ]) {
          final g = _Rig(
            tests: [
              PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
            ],
            afterWrite: after,
          );
          await g.probe.run();
          expect(
            g.asks.single.atMs - g.sends.single.landedMs,
            inInclusiveRange(3500, 3600),
          );
        }
      },
    );

    test('an earlier command\'s 100 does not end the wait after the last '
        'write', () async {
      final g = _Rig(
        tests: [PatternTest(waveform: _pair, style: BuzzStyle.paced, count: 2)],
        afterWrite: (i) => i == 0 ? _bandPlays(i) : const [],
      );
      await g.probe.run();
      expect(g.sends, hasLength(2));
      expect(
        g.asks.single.atMs - g.sends.last.landedMs,
        inInclusiveRange(3500, 3600),
      );
    });

    test('the wearer is asked after the test, with the test and its index; '
        'then the probe rests 3 s before the next', () async {
      final tests = [
        PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
        PatternTest(waveform: _alone, style: BuzzStyle.listed, count: 3),
      ];
      final g = _Rig(tests: tests, afterWrite: _bandPlays);
      await g.probe.run();
      expect(g.asks.map((a) => a.index), [0, 1]);
      expect(g.asks.map((a) => a.test.style), [
        BuzzStyle.repeat,
        BuzzStyle.listed,
      ]);
      expect(g.sends[1].startMs - g.asks[0].atMs, inInclusiveRange(3000, 3100));
      expect(g.probe.results, hasLength(2));
      expect(g.steps.last, 'Pattern probe finished.');
    });
  });

  group('the log line', () {
    test(
      'one command: payload, write time, reply, band events, the answer',
      () async {
        final g = _Rig(
          tests: [
            PatternTest(
              waveform: const BuzzWaveform('effect 14', [14]),
              style: BuzzStyle.repeat,
              count: 3,
            ),
          ],
          latencyMs: 80,
          answer: (_, _) => PatternAnswer(4, 2),
        );
        g.clock.schedule(60, 96, happenedMs: 95);
        g.clock.schedule(100, 1490, happenedMs: 1500);
        await g.probe.run();
        final line = g.steps.singleWhere(
          (s) => s.startsWith('Pattern probe 1/1, '),
        );
        final parts = [
          'Pattern probe 1/1, effect 14, one command looped 3×:',
          '1 command',
          '[01 0e 00 00 00 00 00 00 00 00 00 03]',
          'written at +80 ms',
          'replies pending',
          'band events 60 at +95 (got +96), 100 at +1500 (got +1490)',
          'felt 4 buzzes in 2 groups.',
        ];
        var at = 0;
        for (final p in parts) {
          final i = line.indexOf(p, at);
          expect(i, isNonNegative, reason: '"$p" in order in: $line');
          at = i + p.length;
        }
      },
    );

    test('the payload is the listed effects, loop 1', () async {
      final g = _Rig(
        tests: [
          PatternTest(
            waveform: const BuzzWaveform('effect 14', [14]),
            style: BuzzStyle.listed,
            count: 2,
          ),
        ],
      );
      await g.probe.run();
      expect(
        g.steps.singleWhere((s) => s.startsWith('Pattern probe 1/1, ')),
        contains('[01 0e 98 0e 00 00 00 00 00 00 00 01]'),
      );
    });

    test('a test number counts out of all the tests; an unsure answer says '
        'so', () async {
      final g = _Rig(
        tests: [
          PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
          PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 3),
        ],
        answer: (_, i) => i == 0 ? PatternAnswer(null, null) : null,
      );
      await g.probe.run();
      final lines = g.steps
          .where((s) => s.startsWith('Pattern probe '))
          .toList();
      expect(
        lines.where((l) => l.startsWith('Pattern probe 1/2, ')),
        hasLength(1),
      );
      expect(
        lines.where((l) => l.startsWith('Pattern probe 2/2, ')),
        hasLength(1),
      );
      for (final l in lines.where(
        (l) => RegExp(r'^Pattern probe \d/2, ').hasMatch(l),
      )) {
        expect(l, contains('not sure'));
      }
    });

    test('a command that was not written says so', () async {
      final g = _Rig(
        tests: [
          PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
        ],
        writes: false,
      );
      await g.probe.run();
      expect(
        g.steps.where((s) => s.startsWith('Pattern probe 1/1, ')).single,
        contains('not written'),
      );
    });
  });

  group('the run ends', () {
    test(
      'a test in which nothing was written ends the run with the reason',
      () async {
        final g = _Rig(
          tests: [
            PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
            PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 3),
          ],
          writes: false,
        );
        await g.probe.run();
        expect(
          g.probe.results,
          hasLength(1),
          reason: 'no point buzzing on into nothing',
        );
        expect(g.sends, hasLength(1));
        expect(g.asks, isEmpty, reason: 'nothing to feel, nothing to ask');
        expect(
          g.steps.last,
          'Pattern probe ended: the app sent no buzz in this test (see the '
          'reason above).',
        );
        expect(g.probe.running, isFalse);
      },
    );

    test('a sender that throws is a command not written', () async {
      final steps = <String>[];
      final probe = PatternProbe(
        sendPattern: (_, _, _) async => throw StateError('no link'),
        askFelt: (_, _) async => null,
        isConnected: () => true,
        step: steps.add,
        wait: (_) async {},
        tests: [
          PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
        ],
      );
      await probe.run();
      expect(
        steps.last,
        startsWith('Pattern probe ended: the app sent no buzz'),
      );
      expect(probe.running, isFalse);
    });

    test('Stop between tests ends the run after the current one', () async {
      final g = _Rig(
        tests: [
          for (var i = 0; i < 4; i++)
            PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
        ],
        onAsk: (p, i) {
          if (i == 1) p.stop();
        },
      );
      await g.probe.run();
      expect(g.sends, hasLength(2));
      expect(g.steps.last, 'Pattern probe stopped after 2 tests.');
      expect(g.probe.running, isFalse);
    });

    test('Stop in the middle of a test writes nothing more', () async {
      final g = _Rig(
        tests: [PatternTest(waveform: _pair, style: BuzzStyle.paced, count: 3)],
        onSend: (p, i) => p.stop(),
      );
      await g.probe.run();
      expect(g.sends, hasLength(1));
      expect(g.steps.last, startsWith('Pattern probe stopped'));
      expect(g.probe.running, isFalse);
    });

    test('a lost link ends the run', () async {
      late final _Rig g;
      g = _Rig(
        tests: [
          for (var i = 0; i < 3; i++)
            PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
        ],
        onAsk: (p, i) => g.connected = false,
      );
      await g.probe.run();
      expect(g.sends, hasLength(1));
      expect(g.steps.last, 'Pattern probe ended: the band is not connected.');
      expect(g.probe.running, isFalse);
    });

    test('with no link at the start nothing is written', () async {
      final g = _Rig(connected: false);
      await g.probe.run();
      expect(g.sends, isEmpty);
      expect(g.probe.results, isEmpty);
      expect(g.steps.last, 'Pattern probe ended: the band is not connected.');
    });

    test('running is true during the run and false after it, and a second '
        'run() while one is going does not start another', () async {
      late final _Rig g;
      Future<void>? second;
      g = _Rig(
        tests: [
          PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: 2),
        ],
        onSend: (p, i) {
          expect(p.running, isTrue);
          second = p.run();
        },
      );
      await g.probe.run();
      await second;
      expect(g.sends, hasLength(1));
      expect(g.probe.running, isFalse);
    });
  });
}
