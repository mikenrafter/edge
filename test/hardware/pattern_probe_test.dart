// 8W/8Y: the pattern probe. The 20:40 lab log showed one buzz command is felt
// as ONE "bzz-bzz" however it is written, and that the band swallows a command
// written while it still plays. The probe tries ways of getting a COUNT of
// buzzes out of it: four waveforms x four ways of sending (separate commands
// paced by time, separate commands paced by the band's own "ended" event, one
// command with its loop count raised, one command listing the waveform N
// times) x counts 2 and 3. 8Y made it play on demand: the wearer presses Play
// for the test on screen, as often as they like. It is pure Dart with injected
// effects, so this file runs it on a virtual clock against fake band events.
//
// Pinned here: the catalogue (32 tests, how they cycle), what each way of
// sending writes and when (8Y added a fifth way, "delayed", to measure how
// long a silence is felt as), how a play ends (the band's 100 or 4 s), the
// cool-down before the next play, that only LIVE band events count (the 22:29
// log delivered dozens of old 60/100 events late, and the 22:36 burst released
// event-paced commands early), the budget of 160 commands per session, the
// refusals, the per-play log line and (8Z) the measured span of a play.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 20, 40);

/// A virtual clock. Waits move it; scheduled band events are delivered at
/// their own receipt time (inside whatever wait spans it), so the probe sees
/// them exactly when they "arrive". [at] schedules a plain callback the same
/// way (to press Stop at a known moment).
class _Clock {
  DateTime now = _t0;
  int get ms => now.difference(_t0).inMilliseconds;
  void Function(int id, DateTime received, DateTime happened)? deliver;
  final _due =
      <({int id, int recvMs, int happenedMs, void Function()? fn})>[];

  void schedule(int id, int recvMs, {int? happenedMs}) {
    _due.add((
      id: id,
      recvMs: recvMs,
      happenedMs: happenedMs ?? recvMs,
      fn: null,
    ));
    _due.sort((a, b) => a.recvMs.compareTo(b.recvMs));
  }

  void at(int ms, void Function() fn) {
    _due.add((id: 0, recvMs: ms, happenedMs: ms, fn: fn));
    _due.sort((a, b) => a.recvMs.compareTo(b.recvMs));
  }

  Future<void> wait(Duration d) async {
    final end = now.add(d);
    while (_due.isNotEmpty &&
        !_t0.add(Duration(milliseconds: _due.first.recvMs)).isAfter(end)) {
      final e = _due.removeAt(0);
      final at = _t0.add(Duration(milliseconds: e.recvMs));
      if (at.isAfter(now)) now = at;
      if (e.fn != null) {
        e.fn!();
      } else {
        deliver?.call(e.id, at, _t0.add(Duration(milliseconds: e.happenedMs)));
      }
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
  final steps = <String>[];
  bool connected;
  final bool writes;
  final String reply = 'pending';

  /// Band events to schedule after command number `i` lands: (event id, ms
  /// after the write landed).
  final List<(int, int)> Function(int i)? afterWrite;

  Iterable<String> get playLines =>
      steps.where((s) => s.startsWith('Pattern probe play: '));
}

const _pair = BuzzWaveform('band pair 47+152', [47, 152]);
const _alone = BuzzWaveform('effect 47 alone', [47]);

PatternTest _repeat([int n = 2]) =>
    PatternTest(waveform: _pair, style: BuzzStyle.repeat, count: n);

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

    test('five ways of sending: the four of 8W, then delayed (8Y)', () {
      expect(BuzzStyle.values, [
        BuzzStyle.paced,
        BuzzStyle.eventPaced,
        BuzzStyle.repeat,
        BuzzStyle.listed,
        BuzzStyle.delayed,
      ]);
    });

    test('40 tests: the first 32 cycle count 2 then 3, waveform every test, '
        'style every four', () {
      final tests = PatternProbe.defaultTests;
      expect(tests, hasLength(40));
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
        expect(tests[i].delayMs, 0, reason: 'test $i');
      }
    });

    test('tests 33 to 40 are the gap tests: 2 delayed commands, effect 14 '
        'then 47 alternating, delays 0, 300, 700, 1200', () {
      final gap = PatternProbe.defaultTests.skip(32).toList();
      expect(gap, hasLength(8));
      expect(gap.map((t) => t.waveform.name), [
        'effect 14',
        'effect 47 alone',
        'effect 14',
        'effect 47 alone',
        'effect 14',
        'effect 47 alone',
        'effect 14',
        'effect 47 alone',
      ]);
      expect(gap.map((t) => t.waveform.effects), [
        [14],
        [47],
        [14],
        [47],
        [14],
        [47],
        [14],
        [47],
      ]);
      expect(gap.map((t) => t.delayMs), [0, 0, 300, 300, 700, 700, 1200, 1200]);
      expect(gap.map((t) => t.count), everyElement(2));
      expect(gap.map((t) => t.style), everyElement(BuzzStyle.delayed));
    });

    test('in the first 32: 8 tests per waveform, 2 per waveform and way of '
        'sending (counts 2 and 3)', () {
      for (final w in BuzzWaveform.all) {
        final mine = PatternProbe.defaultTests
            .take(32)
            .where((t) => t.waveform.name == w.name);
        expect(mine, hasLength(8), reason: w.name);
        for (final s in BuzzStyle.values.take(4)) {
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
      expect(
        PatternTest(
          waveform: w14,
          style: BuzzStyle.delayed,
          count: 2,
          delayMs: 300,
        ).description,
        'effect 14, 2 commands, the second 300 ms after the first ends',
      );
      expect(
        PatternTest(
          waveform: _alone,
          style: BuzzStyle.delayed,
          count: 2,
        ).description,
        'effect 47 alone, 2 commands, the second 0 ms after the first ends',
      );
      for (final t in PatternProbe.defaultTests) {
        expect(t.description, startsWith(t.waveform.name));
      }
    });

    test('delayMs defaults to 0; a delayed test writes one command per '
        'count', () {
      expect(
        PatternTest(waveform: _alone, style: BuzzStyle.paced, count: 2).delayMs,
        0,
      );
      expect(
        PatternTest(
          waveform: _alone,
          style: BuzzStyle.delayed,
          count: 2,
          delayMs: 700,
        ).commands,
        2,
      );
    });

    test('one pass over the 40 tests is 72 commands (56 + 8 gap tests of 2); '
        'the session budget is 160, so two passes', () {
      final total = PatternProbe.defaultTests.fold<int>(
        0,
        (n, t) => n + t.commands,
      );
      expect(total, 72);
      expect(PatternProbe.maxCommands, 160);
    });
  });

  group('what each way of sending writes', () {
    Future<_Rig> play(
      BuzzWaveform w,
      BuzzStyle s,
      int n, {
      int latencyMs = 0,
      List<(int, int)> Function(int)? afterWrite,
    }) async {
      final t = PatternTest(waveform: w, style: s, count: n);
      final g = _Rig(tests: [t], latencyMs: latencyMs, afterWrite: afterWrite);
      final r = await g.probe.play(t);
      expect(r, isNotNull);
      return g;
    }

    test('paced: N separate commands (loop 1), each 1800 ms after the '
        'previous write landed', () async {
      for (final n in [2, 3]) {
        final g = await play(_pair, BuzzStyle.paced, n, latencyMs: 80);
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
      final g = await play(
        _alone,
        BuzzStyle.paced,
        3,
        afterWrite: _bandPlays,
      );
      expect(g.sends[1].startMs - g.sends[0].landedMs, 1800);
      expect(g.sends[2].startMs - g.sends[1].landedMs, 1800);
    });

    test('event-paced: the next command goes 100 ms after the band says it '
        'ended (event 100), not on event 60', () async {
      final g = await play(
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
      final none = await play(_alone, BuzzStyle.eventPaced, 3);
      expect(none.sends[1].startMs - none.sends[0].landedMs, 2500);
      expect(none.sends[2].startMs - none.sends[1].landedMs, 2500);
      final only60 = await play(
        _alone,
        BuzzStyle.eventPaced,
        2,
        afterWrite: (_) => const [(60, 15)],
      );
      expect(only60.sends[1].startMs - only60.sends[0].landedMs, 2500);
    });

    test('event-paced: each command waits for ITS band event', () async {
      // Only the first write is followed by a 100.
      final g = await play(
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
            final g = await play(w, BuzzStyle.repeat, n);
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
          final g = await play(w, BuzzStyle.listed, n);
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

    test('delayed: the next command goes delayMs after the band\'s 100 for '
        'the last one', () async {
      for (final d in [0, 300, 700, 1200]) {
        final t = PatternTest(
          waveform: _alone,
          style: BuzzStyle.delayed,
          count: 2,
          delayMs: d,
        );
        final g = _Rig(tests: [t], afterWrite: _bandPlays);
        final r = await g.probe.play(t);
        expect(r, isNotNull);
        expect(g.sends, hasLength(2), reason: 'delay $d');
        expect(g.sends.map((s) => s.effects), everyElement([47]));
        expect(g.sends.map((s) => s.loop), everyElement(1));
        expect(
          g.sends[1].startMs - g.sends[0].landedMs,
          1500 + d,
          reason: 'delay $d: the 100 comes 1500 ms after the write',
        );
      }
    });

    test('delayed: without a 100 the next command goes 2500 ms after the '
        'previous write, whatever the delay', () async {
      for (final d in [0, 700]) {
        final t = PatternTest(
          waveform: _alone,
          style: BuzzStyle.delayed,
          count: 2,
          delayMs: d,
        );
        final g = _Rig(tests: [t], afterWrite: (_) => const [(60, 15)]);
        await g.probe.play(t);
        expect(g.sends[1].startMs - g.sends[0].landedMs, 2500, reason: '$d');
      }
    });

    test('delayed: an old 100 does not release the next command', () async {
      final t = PatternTest(
        waveform: _alone,
        style: BuzzStyle.delayed,
        count: 2,
        delayMs: 300,
      );
      final g = _Rig(tests: [t]);
      g.clock.schedule(100, 400, happenedMs: -30000);
      await g.probe.play(t);
      expect(g.sends[1].startMs - g.sends[0].landedMs, 2500);
    });

    test('the first play writes at once; the result lists the commands and '
        'the live events', () async {
      final t = PatternTest(
        waveform: _alone,
        style: BuzzStyle.paced,
        count: 2,
      );
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      final r = await g.probe.play(t);
      expect(g.sends.first.startMs, 0, reason: 'nothing to cool down from');
      expect(r, isNotNull);
      expect(r!.test, same(t));
      expect(r.commands, hasLength(2));
      expect(r.commands.every((c) => c.written), isTrue);
      expect(r.events.map((e) => e.eventId), containsAll([60, 100]));
    });
  });

  group('how a play ends', () {
    test('it ends on the band\'s 100 after the last write', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      await g.probe.play(t);
      expect(
        g.clock.ms - g.sends.single.landedMs,
        inInclusiveRange(1500, 1600),
      );
      expect(g.probe.running, isFalse);
    });

    test('without a 100 (or with only a 60) it ends 4 s after the write', () async {
      for (final after in <List<(int, int)> Function(int)?>[
        null,
        (_) => const [(60, 15)],
      ]) {
        final t = _repeat();
        final g = _Rig(tests: [t], afterWrite: after);
        await g.probe.play(t);
        expect(
          g.clock.ms - g.sends.single.landedMs,
          inInclusiveRange(4000, 4100),
        );
      }
    });

    test('an earlier command\'s 100 does not end the wait after the last '
        'write', () async {
      final t = PatternTest(waveform: _pair, style: BuzzStyle.paced, count: 2);
      final g = _Rig(
        tests: [t],
        afterWrite: (i) => i == 0 ? _bandPlays(i) : const [],
      );
      await g.probe.play(t);
      expect(g.sends, hasLength(2));
      expect(
        g.clock.ms - g.sends.last.landedMs,
        inInclusiveRange(4000, 4100),
      );
    });

    test('Stop ends the wait at once; the play still returns what it wrote',
        () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.at(1000, g.probe.stop);
      final r = await g.probe.play(t);
      expect(r, isNotNull);
      expect(r!.commands, hasLength(1));
      expect(g.clock.ms, inInclusiveRange(1000, 1100));
      expect(g.probe.running, isFalse);
    });
  });

  group('the cool-down before a play', () {
    // The band drops a command sent while it still plays, so the next play
    // waits for a live 100 after the previous play's last write, or 4 s after
    // that write, whichever comes first. Stop cuts the previous play's own
    // wait short, which leaves cool-down to do.
    test('a play right after a finished one writes straight away', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      await g.probe.play(t);
      final before = g.clock.ms;
      await g.probe.play(t);
      expect(g.sends, hasLength(2));
      expect(g.sends[1].startMs - before, inInclusiveRange(0, 100));
    });

    test('with no live 100 it waits until 4 s after the last write', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.at(1000, g.probe.stop);
      await g.probe.play(t);
      expect(g.clock.ms, inInclusiveRange(1000, 1100));
      final second = await g.probe.play(t);
      expect(second, isNotNull);
      expect(g.sends, hasLength(2));
      expect(
        g.sends[1].startMs - g.sends[0].landedMs,
        inInclusiveRange(4000, 4100),
      );
    });

    test('a live 100 after the last write ends the cool-down early', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.at(1000, g.probe.stop);
      g.clock.schedule(100, 1300);
      await g.probe.play(t);
      await g.probe.play(t);
      expect(g.sends, hasLength(2));
      expect(
        g.sends[1].startMs - g.sends[0].landedMs,
        inInclusiveRange(1300, 1400),
      );
    });

    test('an old 100 (delivered late) does not end the cool-down', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.at(1000, g.probe.stop);
      g.clock.schedule(100, 1300, happenedMs: -30000);
      await g.probe.play(t);
      await g.probe.play(t);
      expect(
        g.sends[1].startMs - g.sends[0].landedMs,
        inInclusiveRange(4000, 4100),
      );
    });

    test('Stop during the cool-down writes nothing and returns null', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.at(1000, g.probe.stop);
      await g.probe.play(t);
      g.clock.at(2000, g.probe.stop);
      final second = await g.probe.play(t);
      expect(second, isNull);
      expect(g.sends, hasLength(1));
      expect(g.probe.running, isFalse);
    });
  });

  group('only live band events count', () {
    test('an old event (happened well before the play) is not recorded', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(60, 300, happenedMs: -20000);
      g.clock.schedule(100, 400, happenedMs: -19900);
      g.clock.schedule(60, 1000, happenedMs: 990);
      final r = await g.probe.play(t);
      expect(r!.events.map((e) => e.eventId), [60]);
      expect(r.events.single.happenedMs, 990);
    });

    test('an event that happened up to 500 ms before the play counts, one '
        'earlier does not', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(60, 1000, happenedMs: -500);
      g.clock.schedule(61, 1100, happenedMs: -501);
      final r = await g.probe.play(t);
      expect(r!.events.map((e) => e.eventId), [60]);
      expect(r.events.single.happenedMs, -500);
    });

    test('an event received 2 s or more after it happened is not live', () async {
      final t = _repeat();
      final late = _Rig(tests: [t]);
      late.clock.schedule(100, 2100, happenedMs: 100);
      final r = await late.probe.play(t);
      expect(r!.events, isEmpty);
      expect(
        late.clock.ms - late.sends.single.landedMs,
        inInclusiveRange(4000, 4100),
        reason: 'the late 100 does not end the play',
      );

      final ok = _Rig(tests: [t]);
      ok.clock.schedule(100, 2099, happenedMs: 100);
      final r2 = await ok.probe.play(t);
      expect(r2!.events.map((e) => e.eventId), [100]);
      expect(
        ok.clock.ms - ok.sends.single.landedMs,
        inInclusiveRange(2099, 2200),
      );
    });

    test('22:36: a burst of old 100s does not release event-paced commands, '
        'the live 100 does', () async {
      final t = PatternTest(
        waveform: _alone,
        style: BuzzStyle.eventPaced,
        count: 3,
      );
      final g = _Rig(tests: [t]);
      // About 25 backlog events, 17-80 s old, arriving just after command 1.
      for (var i = 0; i < 25; i++) {
        g.clock.schedule(
          i.isEven ? 100 : 60,
          300 + i * 5,
          happenedMs: -(17000 + i * 2500),
        );
      }
      // The band's own 100 for command 1.
      g.clock.schedule(100, 1500);
      // Another old burst after command 2 (written at 1600): no live 100.
      for (var i = 0; i < 10; i++) {
        g.clock.schedule(100, 1900 + i * 5, happenedMs: -30000 - i);
      }
      final r = await g.probe.play(t);
      expect(g.sends, hasLength(3));
      expect(
        g.sends[1].startMs,
        1600,
        reason: 'the old 100s at +300 did not release it, the live 100 did',
      );
      expect(
        g.sends[2].startMs - g.sends[1].landedMs,
        2500,
        reason: 'old 100s alone fall back to the 2.5 s timeout',
      );
      expect(r!.events.where((e) => e.happenedMs < 0), isEmpty);
      expect(r.events.map((e) => e.eventId), [100]);
    });

    test('an old 100 does not end the wait after the last write', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(100, 1200, happenedMs: -40000);
      await g.probe.play(t);
      expect(
        g.clock.ms - g.sends.single.landedMs,
        inInclusiveRange(4000, 4100),
      );
    });
  });

  group('the budget: 160 commands per session', () {
    PatternTest paced3() =>
        PatternTest(waveform: _alone, style: BuzzStyle.paced, count: 3);

    test('plays are counted together; one that would go over is refused '
        'before it writes anything', () async {
      final t3 = paced3();
      final one = _repeat();
      final g = _Rig(tests: [t3, one], afterWrite: _bandPlays);
      for (var i = 0; i < 53; i++) {
        expect(await g.probe.play(t3), isNotNull, reason: 'play ${i + 1}');
      }
      expect(g.sends, hasLength(159));
      final steps = g.steps.length;
      expect(await g.probe.play(t3), isNull, reason: '162 > 160');
      expect(g.sends, hasLength(159), reason: 'nothing written');
      expect(g.steps.length, greaterThan(steps), reason: 'it says why');
      expect(g.steps.last, startsWith('Pattern probe'));
      expect(await g.probe.play(one), isNotNull, reason: 'exactly 160');
      expect(g.sends, hasLength(160));
      expect(await g.probe.play(one), isNull);
      expect(g.sends, hasLength(160));
      expect(g.probe.running, isFalse);
    });

    test('a full pass over the 40 default tests uses 72 of the 160', () async {
      final g = _Rig(afterWrite: _bandPlays);
      for (final t in PatternProbe.defaultTests) {
        expect(await g.probe.play(t), isNotNull);
      }
      expect(g.sends, hasLength(72));
      for (final t in PatternProbe.defaultTests) {
        expect(await g.probe.play(t), isNotNull);
      }
      expect(g.sends, hasLength(144));
      var refused = 0;
      for (final t in PatternProbe.defaultTests) {
        if (await g.probe.play(t) == null) refused++;
      }
      expect(g.sends.length, lessThanOrEqualTo(PatternProbe.maxCommands));
      expect(refused, greaterThan(0));
    });
  });

  group('refusals', () {
    test('a play while one is going is refused and writes nothing', () async {
      final t = _repeat();
      late final _Rig g;
      Future<PatternTestResult?>? second;
      g = _Rig(
        tests: [t],
        onSend: (p, i) {
          expect(p.running, isTrue);
          second = p.play(t);
        },
      );
      final first = await g.probe.play(t);
      expect(first, isNotNull);
      expect(await second, isNull);
      expect(g.sends, hasLength(1));
      expect(g.probe.running, isFalse);
      expect(g.steps.where((s) => s.startsWith('Pattern probe')), isNotEmpty);
    });

    test('with no link nothing is written, and it says so', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], connected: false);
      expect(await g.probe.play(t), isNull);
      expect(g.sends, isEmpty);
      expect(g.steps.last, contains('not connected'));
      expect(g.probe.running, isFalse);
    });

    test('a lost link stops the commands still to come', () async {
      final t = PatternTest(waveform: _pair, style: BuzzStyle.paced, count: 3);
      late final _Rig g;
      g = _Rig(tests: [t], onSend: (p, i) => g.connected = false);
      final r = await g.probe.play(t);
      expect(g.sends, hasLength(1));
      expect(r, isNotNull);
      expect(r!.commands, hasLength(1));
      expect(g.probe.running, isFalse);
    });

    test('a play in which nothing was written returns null with the reason '
        'logged', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], writes: false);
      expect(await g.probe.play(t), isNull);
      expect(g.sends, hasLength(1));
      expect(g.playLines.single, contains('not written'));
      expect(g.probe.running, isFalse);
    });

    test('a sender that throws is a command not written', () async {
      final steps = <String>[];
      final t = _repeat();
      final probe = PatternProbe(
        sendPattern: (_, _, _) async => throw StateError('no link'),
        isConnected: () => true,
        step: steps.add,
        wait: (_) async {},
        tests: [t],
      );
      expect(await probe.play(t), isNull);
      expect(steps.any((s) => s.contains('not written')), isTrue);
      expect(probe.running, isFalse);
    });

    test('a refused play does not use up the budget', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], connected: false);
      for (var i = 0; i < 200; i++) {
        await g.probe.play(t);
      }
      g.connected = true;
      expect(await g.probe.play(t), isNotNull);
    });
  });

  group('the log line', () {
    test(
      'one command: payload, write time, reply, live band events, no felt '
      'part',
      () async {
        const t = PatternTest(
          waveform: BuzzWaveform('effect 14', [14]),
          style: BuzzStyle.repeat,
          count: 3,
        );
        final g = _Rig(tests: [t], latencyMs: 80);
        g.clock.schedule(60, 96, happenedMs: 95);
        g.clock.schedule(100, 1490, happenedMs: 1500);
        await g.probe.play(t);
        final line = g.playLines.single;
        final parts = [
          'Pattern probe play: 1/1, effect 14, one command looped 3×:',
          '1 command',
          '[01 0e 00 00 00 00 00 00 00 00 00 03]',
          'written at +80 ms',
          'replies pending',
          'band events 60 at +95 (got +96), 100 at +1500 (got +1490)',
        ];
        var at = 0;
        for (final p in parts) {
          final i = line.indexOf(p, at);
          expect(i, isNonNegative, reason: '"$p" in order in: $line');
          at = i + p.length;
        }
        expect(line, isNot(contains('felt')));
      },
    );

    test('the payload is the listed effects, loop 1', () async {
      const t = PatternTest(
        waveform: BuzzWaveform('effect 14', [14]),
        style: BuzzStyle.listed,
        count: 2,
      );
      final g = _Rig(tests: [t]);
      await g.probe.play(t);
      expect(
        g.playLines.single,
        contains('[01 0e 98 0e 00 00 00 00 00 00 00 01]'),
      );
    });

    test('the number counts the test among all the tests (the list length), '
        'and every play writes a line', () async {
      final g = _Rig();
      final tests = PatternProbe.defaultTests;
      await g.probe.play(tests[4]);
      await g.probe.play(tests[39]);
      await g.probe.play(tests[4]);
      final lines = g.playLines.toList();
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('Pattern probe play: 5/40, '));
      expect(lines[1], startsWith('Pattern probe play: 40/40, '));
      expect(lines[2], startsWith('Pattern probe play: 5/40, '));
      expect(lines[0], contains(tests[4].description));
    });

    test('it measures the silences (each live 60 minus the previous 100) and '
        'the buzzes (each 100 minus its 60), in ms', () async {
      final t = PatternTest(waveform: _alone, style: BuzzStyle.paced, count: 3);
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      await g.probe.play(t);
      // 60 at +15, 100 at +1500 after each write; the writes land at 0, 1800
      // and 3600.
      final line = g.playLines.single;
      expect(line, contains('silences: 315, 315'));
      expect(line, contains('buzzes: 1485, 1485, 1485'));
      expect(line, isNot(contains('felt')));
    });

    test('a delayed play: the silence is the delay plus the time the band '
        'takes to start', () async {
      final t = PatternTest(
        waveform: _alone,
        style: BuzzStyle.delayed,
        count: 2,
        delayMs: 700,
      );
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      await g.probe.play(t);
      // 100 at +1500, the second write at +2200, its 60 at +2215.
      final line = g.playLines.single;
      expect(line, contains('silences: 715'));
      expect(line, contains('buzzes: 1485, 1485'));
    });

    test('old events are not measured', () async {
      final t = PatternTest(waveform: _alone, style: BuzzStyle.paced, count: 2);
      final g = _Rig(tests: [t]);
      g.clock.schedule(100, 200, happenedMs: -25000);
      g.clock.schedule(60, 300, happenedMs: -25020);
      g.clock.schedule(100, 5000, happenedMs: -24000);
      await g.probe.play(t);
      expect(g.playLines.single, isNot(contains('silences: 1')));
      expect(g.playLines.single, isNot(contains('buzzes: 1')));
    });

    test('old events are left out of the line too', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(100, 500, happenedMs: -25000);
      await g.probe.play(t);
      expect(g.playLines.single, contains('band events none'));
    });
  });

  group('the measured span (8Z)', () {
    // The tempo fit needs how long a test took to play: the phone's receive
    // time of the first live 60 to that of the last live 100, in ms.
    test('one command: the first 60 to the 100', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      final r = await g.probe.play(t);
      expect(r!.spanMs, 1485, reason: '60 at +15, 100 at +1500');
    });

    test('several commands: the first 60 to the LAST 100', () async {
      final t = PatternTest(waveform: _alone, style: BuzzStyle.paced, count: 3);
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      final r = await g.probe.play(t);
      // Writes land at 0, 1800 and 3600: 60 at +15, the last 100 at +5100.
      expect(r!.spanMs, 5085);
    });

    test('it uses the times the phone received the events, not the band\'s '
        'own', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(60, 96, happenedMs: 95);
      g.clock.schedule(100, 1490, happenedMs: 1500);
      final r = await g.probe.play(t);
      expect(r!.spanMs, 1394);
    });

    test('null when there is no 100', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], afterWrite: (_) => const [(60, 15)]);
      final r = await g.probe.play(t);
      expect(r!.spanMs, isNull);
    });

    test('null when there is no 60', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], afterWrite: (_) => const [(100, 1500)]);
      final r = await g.probe.play(t);
      expect(r!.spanMs, isNull);
    });

    test('null when there are no events', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      final r = await g.probe.play(t);
      expect(r!.spanMs, isNull);
    });

    test('null when the only 100 came before the first 60', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(100, 200);
      g.clock.schedule(60, 300);
      final r = await g.probe.play(t);
      expect(r!.spanMs, isNull);
    });

    test('old events do not count', () async {
      final t = _repeat();
      final g = _Rig(tests: [t]);
      g.clock.schedule(60, 100, happenedMs: -25000);
      g.clock.schedule(100, 1500, happenedMs: -25000);
      final r = await g.probe.play(t);
      expect(r!.spanMs, isNull);
    });
  });

  group('the lead (8Z)', () {
    // The Bluetooth delay: the first live 60 (phone receive time) minus the
    // moment the first write landed, in ms.
    test('the first live 60 minus the first write landing', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      final r = await g.probe.play(t);
      expect(r!.leadMs, 15, reason: 'the write lands at 0, the 60 at +15');
    });

    test('a write that takes time: the lead runs from when it landed', () async {
      final t = _repeat();
      final g = _Rig(tests: [t], latencyMs: 80);
      g.clock.schedule(60, 96, happenedMs: 95);
      g.clock.schedule(100, 1490, happenedMs: 1500);
      final r = await g.probe.play(t);
      expect(r!.leadMs, 16, reason: 'landed at +80, the 60 got +96');
    });

    test('with several commands it is measured from the first one', () async {
      final t = PatternTest(waveform: _alone, style: BuzzStyle.paced, count: 3);
      final g = _Rig(tests: [t], afterWrite: _bandPlays);
      final r = await g.probe.play(t);
      expect(r!.leadMs, 15);
    });

    test('null without a live 60', () async {
      final t = _repeat();
      final none = _Rig(tests: [t]);
      expect((await none.probe.play(t))!.leadMs, isNull);
      final only100 = _Rig(tests: [t], afterWrite: (_) => const [(100, 1500)]);
      expect((await only100.probe.play(t))!.leadMs, isNull);
      final old = _Rig(tests: [t]);
      old.clock.schedule(60, 100, happenedMs: -25000);
      expect((await old.probe.play(t))!.leadMs, isNull);
    });
  });
}
