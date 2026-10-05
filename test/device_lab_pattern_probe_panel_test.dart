// 8Y/8Z/8AA: the pattern probe as a transcriber, runner half and entry point. The
// runner opens a session (refusals, the session line), plays the current test
// on demand, passes edits through to the entry session, and writes what was
// transcribed into the lab log when it closes (or when Stop is pressed). The
// "Hardware probes" panel only opens the probe page. The page itself is
// pinned in pattern_probe_page_test.dart. Fake async time: the probe's real
// waits are pumped, not slept.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/pattern_probe_page.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

typedef _Sent = ({List<int> effects, int loop});

/// Whether test [i] is flagged unstable (8AC); read dynamically so the rest
/// of this file compiles before the session has the flag.
bool _unstable(PatternEntrySession s, int i) => (s as dynamic).unstable(i) as bool;

/// Flip [up] to false to drop the link after the probe is open.
class _Link {
  bool up = true;
}

HardwareProbeRunner _runner(
  DeviceLabLog lab, {
  bool connected = true,
  bool mg = true,
  bool writeOk = true,
  _Link? link,
  List<_Sent>? sent,
  Completer<void>? holdBuzz,
  Completer<void>? holdPattern,
  void Function(HardwareProbeRunner r)? onSend,
}) {
  late final HardwareProbeRunner r;
  r = HardwareProbeRunner(
    lab: lab,
    sendBuzz: (onReply) async {
      await holdBuzz?.future;
      onReply('pending', 40);
      return true;
    },
    sendPattern: (effects, loop, onReply) async {
      sent?.add((effects: List.of(effects), loop: loop));
      await holdPattern?.future;
      onSend?.call(r);
      if (writeOk) onReply('pending', 40);
      return writeOk;
    },
    isConnected: () => connected && (link?.up ?? true),
    ecgSupported: () => mg,
    ecgBusy: () => false,
    beginEcg: () async => false,
    endEcg: () async {},
    isEcgAlive: () => false,
  );
  return r;
}

/// A live band event: the strap clock is exact, so it is never "before" the
/// play that provoked it.
StrapEvent _event(int id) {
  final ms = DateTime.now().millisecondsSinceEpoch;
  return StrapEvent(
    eventId: id,
    tsEpoch: ms ~/ 1000,
    tsSubsec: ((ms % 1000) * 32768) ~/ 1000,
    receivedAt: DateTime.now(),
    hex: '',
    deviceId: 'band',
  );
}

/// A live 100 stamped with the (fake) clock, for plays that must end at the
/// write: the probe's clock is `clock.now`, which only moves when a test pumps.
StrapEvent _clockEvent(int id) {
  // The runner moves event times onto `clock` by the (small, growing) gap
  // between `clock` and the wall clock, so a stamp equal to now could land a
  // few microseconds before the write and not count as after it; stamp a
  // little ahead.
  final now = clock.now().add(const Duration(seconds: 10));
  final ms = now.millisecondsSinceEpoch;
  return StrapEvent(
    eventId: id,
    tsEpoch: ms ~/ 1000,
    tsSubsec: ((ms % 1000) * 32768) ~/ 1000,
    receivedAt: now,
    hex: '',
    deviceId: 'band',
  );
}

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1200, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: w)),
    ),
  );
}

void main() {
  group('HardwareProbeRunner pattern transcriber', () {
    test('refuses with a reason instead of opening', () async {
      final lab = DeviceLabLog();
      final off = _runner(lab, connected: false);
      await off.openPattern();
      expect(off.note, 'Connect the band first.');
      expect(off.running, isNull);
      expect(off.pattern, isNull);
      final notMg = _runner(lab, mg: false);
      await notMg.openPattern();
      expect(notMg.note, 'This band cannot play custom patterns.');
      expect(notMg.running, isNull);
      expect(notMg.pattern, isNull);
      expect(lab.sessionSummaries, isEmpty);
    });

    testWidgets('refuses while another probe runs', (t) async {
      final lab = DeviceLabLog();
      final hold = Completer<void>();
      final sent = <_Sent>[];
      final r = _runner(lab, holdBuzz: hold, sent: sent);
      unawaited(r.runBuzz());
      await t.pump(const Duration(milliseconds: 500));
      expect(r.running, ProbeKind.buzz);
      await r.openPattern();
      expect(r.note, 'A probe is already running.');
      expect(r.running, ProbeKind.buzz);
      expect(r.pattern, isNull);
      expect(sent, isEmpty);
      r.stop();
      hold.complete();
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
    });

    testWidgets('opening starts the session and sends nothing', (t) async {
      final lab = DeviceLabLog();
      final sent = <_Sent>[];
      final r = _runner(lab, sent: sent);
      var heard = 0;
      r.addListener(() => heard++);
      await r.openPattern();
      expect(r.running, ProbeKind.pattern);
      expect(heard, greaterThan(0));
      final s = r.pattern;
      expect(s, isNotNull);
      expect(s!.testIndex, 0);
      expect(s.cursor, 0);
      expect(s.activeRendition, 0);
      expect(r.patternPlaying, isFalse);
      expect(r.patternTestCount, 40);
      expect(sent, isEmpty, reason: 'the band buzzes only on Play');
      expect(r.canRunBuzz, isFalse);
      // The session is open: closing it ends it with the session line.
      r.closePattern();
      expect(
        lab.sessionSummaries.single,
        startsWith(
          'Pattern probe | 40 tests, transcribed: 4 waveforms × 4 ways of '
          'sending × 2 counts, plus 8 gap tests | 0 of 40 tests transcribed, 0 plays | ',
        ),
      );
    });

    testWidgets('Play sends the current test and counts it once played', (
      t,
    ) async {
      final lab = DeviceLabLog();
      final sent = <_Sent>[];
      final r = _runner(
        lab,
        sent: sent,
        // The band answers with a haptic-start event as it is written.
        onSend: (r) => r.onBandEvent(_event(60)),
      );
      await r.openPattern();
      unawaited(r.playPattern());
      await t.pump();
      expect(r.patternPlaying, isTrue);
      // Test 1 is the band pair, two commands 1.8 s apart, then the wait for
      // the band's end event (4 s at most).
      await t.pump(const Duration(seconds: 10));
      expect(r.patternPlaying, isFalse);
      expect(sent.map((s) => s.effects), [
        [47, 152],
        [47, 152],
      ]);
      expect(sent.map((s) => s.loop), [1, 1]);
      expect(r.pattern!.plays(0), 1);
      expect(r.pattern!.plays(1), 0);
      final log = lab.steps.join('\n');
      expect(log, contains('Pattern probe play: 1/40'));
      expect(
        log,
        contains('band events 60 at +'),
        reason: 'band events reach the running probe through the runner',
      );
      r.closePattern();
      await t.pump();
    });

    testWidgets('each play logs the measured silences and buzzes', (t) async {
      final lab = DeviceLabLog();
      final r = _runner(
        lab,
        onSend: (r) {
          r.onBandEvent(_event(60));
          r.onBandEvent(_event(100));
        },
      );
      await r.openPattern();
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      final log = lab.steps.join('\n');
      expect(log, contains('silences: '));
      expect(log, contains('buzzes: '));
      r.closePattern();
    });

    testWidgets('a play that writes nothing is not counted', (t) async {
      final lab = DeviceLabLog();
      final r = _runner(lab, writeOk: false);
      await r.openPattern();
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      expect(r.patternPlaying, isFalse);
      expect(r.pattern!.plays(0), 0);
      r.closePattern();
      expect(
        lab.sessionSummaries.single,
        contains('0 of 40 tests transcribed, 0 plays'),
      );
    });

    testWidgets('a play after the link dropped is not counted', (t) async {
      final lab = DeviceLabLog();
      final link = _Link();
      final sent = <_Sent>[];
      final r = _runner(lab, link: link, sent: sent);
      await r.openPattern();
      link.up = false;
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      expect(r.patternPlaying, isFalse);
      expect(sent, isEmpty);
      expect(r.pattern!.plays(0), 0);
      r.closePattern();
    });

    testWidgets('Play while a play runs does nothing more', (t) async {
      final lab = DeviceLabLog();
      final hold = Completer<void>();
      final sent = <_Sent>[];
      final r = _runner(lab, holdPattern: hold, sent: sent);
      await r.openPattern();
      unawaited(r.playPattern());
      await t.pump(const Duration(milliseconds: 200));
      expect(r.patternPlaying, isTrue);
      expect(sent, hasLength(1));
      unawaited(r.playPattern());
      await t.pump(const Duration(milliseconds: 200));
      expect(sent, hasLength(1), reason: 'the second Play is refused');
      hold.complete();
      await t.pump(const Duration(seconds: 20));
      expect(r.patternPlaying, isFalse);
      expect(r.pattern!.plays(0), 1, reason: 'one play, not two');
      r.closePattern();
    });

    test('Play with nothing open does nothing', () async {
      final r = _runner(DeviceLabLog());
      await r.playPattern();
      expect(r.pattern, isNull);
      expect(r.patternPlaying, isFalse);
    });

    testWidgets('edits pass through and notify', (t) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      var heard = 0;
      r.addListener(() => heard++);
      final s = r.pattern!;

      void expectNotified(String what, void Function() act) {
        final before = heard;
        act();
        expect(heard, greaterThan(before), reason: '$what notifies');
      }

      expectNotified('tap', () => r.patternTap(2));
      expectNotified('tap', () => r.patternTap(1));
      expectNotified('tap', () => r.patternTap(4));
      expect(s.rendition(0, 0).code, 'N2mf R1 N4mf');
      expect(s.cursor, 3);

      expectNotified('move', () => r.patternMove(-2));
      expect(s.cursor, 1);
      r.patternTap(6);
      expect(
        s.rendition(0, 0).code,
        'N2mf R6 N4mf',
        reason: 'replaced in place',
      );
      expect(s.cursor, 2);

      expectNotified('delete', r.patternDelete);
      expect(s.rendition(0, 0).code, 'N2mf R6');

      expectNotified('rendition', () => r.patternRendition(1));
      expect(s.activeRendition, 1);
      r.patternTap(4);
      expect(s.rendition(0, 1).code, 'N4mf');
      expect(s.rendition(0, 0).code, 'N2mf R6');

      expectNotified('next test', () => r.patternTest(1));
      expect(s.testIndex, 1);
      expect(s.activeRendition, 0, reason: 'a new test starts on A');
      expectNotified('previous test', () => r.patternTest(-1));
      expect(s.testIndex, 0);
      r.patternTest(-1);
      expect(s.testIndex, 0, reason: 'clamped at the first test');
      r.closePattern();
    });

    testWidgets('the toggle and the tempo switch pass through and notify', (
      t,
    ) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      final s = r.pattern!;
      var heard = 0;
      r.addListener(() => heard++);
      expect(s.nextIsNote, isTrue);
      expect(s.dynamicTempo, isTrue);

      var before = heard;
      r.patternToggleKind();
      expect(heard, greaterThan(before), reason: 'the toggle notifies');
      expect(s.nextIsNote, isFalse);
      r.patternTap(2);
      expect(s.rendition(0, 0).code, 'R2', reason: 'the override is used');
      expect(s.nextIsNote, isTrue, reason: 'and it flips after the tap');

      before = heard;
      r.patternDynamicTempo(false);
      expect(heard, greaterThan(before), reason: 'the switch notifies');
      expect(s.dynamicTempo, isFalse);
      expect(s.unitMs, 125);
      before = heard;
      r.patternDynamicTempo(true);
      expect(heard, greaterThan(before));
      expect(s.dynamicTempo, isTrue);

      // With nothing open both do nothing.
      r.closePattern();
      final closed = _runner(DeviceLabLog());
      closed.patternToggleKind();
      closed.patternDynamicTempo(false);
      expect(closed.pattern, isNull);
    });

    testWidgets('the dynamic passes through and notifies; a note tap writes '
        'it', (t) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      final s = r.pattern!;
      var heard = 0;
      r.addListener(() => heard++);
      expect(s.nextDynamic, PatternDynamic.mf);

      var before = heard;
      r.patternDynamic(PatternDynamic.ff);
      expect(heard, greaterThan(before), reason: 'the dynamic notifies');
      expect(s.nextDynamic, PatternDynamic.ff);
      r.patternTap(4);
      r.patternTap(2);
      r.patternTap(1);
      expect(s.rendition(0, 0).code, 'N4ff R2 N1ff');

      // On a note under the cursor it edits that note.
      r.patternMove(-3);
      expect(s.cursor, 0);
      before = heard;
      r.patternDynamic(PatternDynamic.pp);
      expect(heard, greaterThan(before));
      expect(s.rendition(0, 0).code, 'N4pp R2 N1ff');
      expect(s.cursor, 0);
      expect(s.nextDynamic, PatternDynamic.pp);

      // With nothing open it does nothing.
      r.closePattern();
      final closed = _runner(DeviceLabLog());
      closed.patternDynamic(PatternDynamic.pp);
      expect(closed.pattern, isNull);
    });

    testWidgets('patternToggleUnstable passes through, notifies and flags '
        'the open test only (8AC)', (t) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      final s = r.pattern!;
      var heard = 0;
      r.addListener(() => heard++);
      expect(_unstable(s, 0), isFalse);
      var before = heard;
      (r as dynamic).patternToggleUnstable();
      expect(heard, greaterThan(before), reason: 'the toggle notifies');
      expect(_unstable(s, 0), isTrue);
      expect(_unstable(s, 1), isFalse);
      r.patternTest(1);
      expect(_unstable(s, 1), isFalse);
      before = heard;
      (r as dynamic).patternToggleUnstable();
      expect(heard, greaterThan(before));
      expect(_unstable(s, 1), isTrue);
      expect(_unstable(s, 0), isTrue, reason: 'test 1 left test 0 alone');
      (r as dynamic).patternToggleUnstable();
      expect(_unstable(s, 1), isFalse);

      // With nothing open it does nothing.
      r.closePattern();
      final closed = _runner(DeviceLabLog());
      (closed as dynamic).patternToggleUnstable();
      expect(closed.pattern, isNull);
    });

    testWidgets('an unstable test reaches the lab log with the unstable '
        'wording (8AC)', (t) async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await r.openPattern();
      r.patternTap(4);
      r.patternRendition(1);
      r.patternTap(8);
      (r as dynamic).patternToggleUnstable();
      r.closePattern();
      expect(
        lab.steps.join('\n'),
        contains('unstable (A and B are the shortest and longest): '
            'A = quarter note mf (N4mf); B = half note mf (N8mf); '
            'played 0×.'),
      );
    });

    testWidgets('opening a session writes the probe set id once (8AC)', (
      t,
    ) async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await r.openPattern();
      const line = 'Pattern probe set: whoop-mg-pattern-v1';
      expect(
        lab.steps.where((l) => l.contains(line)),
        hasLength(1),
        reason: 'written once when the session opens',
      );
      r.patternTap(2);
      r.patternDynamic(PatternDynamic.values.byName('f'));
      r.patternTest(1);
      expect(lab.steps.where((l) => l.contains(line)), hasLength(1));
      r.closePattern();
      expect(lab.steps.where((l) => l.contains(line)), hasLength(1));
      // A second session writes it again, once.
      await r.openPattern();
      expect(lab.steps.where((l) => l.contains(line)), hasLength(2));
      r.closePattern();
    });

    testWidgets('patternPlays counts the plays that start, for the '
        'metronome', (t) async {
      final hold = Completer<void>();
      final r = _runner(DeviceLabLog(), holdPattern: hold);
      expect(r.patternPlays, 0);
      await r.playPattern();
      expect(r.patternPlays, 0, reason: 'nothing open, no play');
      await r.openPattern();
      expect(r.patternPlays, 0);
      var heard = 0;
      r.addListener(() => heard++);
      unawaited(r.playPattern());
      await t.pump(const Duration(milliseconds: 200));
      expect(r.patternPlays, 1, reason: 'bumped as the play starts');
      expect(heard, greaterThan(0));
      unawaited(r.playPattern());
      await t.pump(const Duration(milliseconds: 200));
      expect(r.patternPlays, 1, reason: 'a refused second Play is no start');
      hold.complete();
      await t.pump(const Duration(seconds: 20));
      expect(r.patternPlaying, isFalse);
      expect(r.patternPlays, 1);
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      expect(r.patternPlays, 2);
      r.closePattern();
    });

    testWidgets('a measured play (first live 60 to last live 100) feeds the '
        'tempo fit', (t) async {
      final r = _runner(
        DeviceLabLog(),
        // The band starts at the write and ends 1200 ms later.
        onSend: (r) {
          r.onBandEvent(_event(60));
          Future<void>.delayed(
            const Duration(milliseconds: 1200),
            () => r.onBandEvent(_event(100)),
          );
        },
      );
      await r.openPattern();
      final s = r.pattern!;
      // Tests 9 and 10 each send one command (the "one command, looped" way).
      for (final test in [8, 9]) {
        r.patternTest(test - s.testIndex);
        expect(s.testIndex, test);
        r.patternTap(4);
        unawaited(r.playPattern());
        await t.pump(const Duration(seconds: 10));
        expect(r.patternPlaying, isFalse);
        expect(s.plays(test), 1);
      }
      // 1200 ms over 4 sixteenths: 300 ms a unit.
      expect(s.fittedUnitMs(), inInclusiveRange(295, 305));
      expect(s.unitMs, inInclusiveRange(295, 305));
      r.patternDynamicTempo(false);
      expect(s.unitMs, 125);
      r.closePattern();
    });

    testWidgets('a play measures the Bluetooth lead (first live 60 minus the '
        'first write landing) and the session keeps it', (t) async {
      final r = _runner(
        DeviceLabLog(),
        // The write lands at once; the band starts 500 ms later.
        onSend: (r) => Future<void>.delayed(
          const Duration(milliseconds: 500),
          () => r.onBandEvent(_event(60)),
        ),
      );
      await r.openPattern();
      final s = r.pattern!;
      expect(s.leadMs, 300, reason: 'the default until a play is measured');
      r.patternTest(8);
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      expect(s.plays(8), 1);
      expect(s.leadMs, inInclusiveRange(495, 505));
      r.closePattern();
    });

    testWidgets('a play without a live 60 leaves the lead alone', (t) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      final s = r.pattern!;
      r.patternTest(8);
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      expect(s.plays(8), 1);
      expect(s.leadMs, 300);
      r.closePattern();
    });

    testWidgets('patternPlayWrittenAt is the moment the play\'s first write '
        'landed', (t) async {
      final hold = Completer<void>();
      final r = _runner(DeviceLabLog(), holdPattern: hold);
      expect(r.patternPlayWrittenAt, isNull);
      await r.openPattern();
      expect(r.patternPlayWrittenAt, isNull);
      unawaited(r.playPattern());
      await t.pump(const Duration(milliseconds: 200));
      expect(r.patternPlaying, isTrue);
      expect(
        r.patternPlayWrittenAt,
        isNull,
        reason: 'the write has not landed yet',
      );

      var heard = 0;
      r.addListener(() => heard++);
      await t.pump(const Duration(milliseconds: 300));
      final landed = DateTime.now();
      hold.complete();
      await t.pump();
      final at = r.patternPlayWrittenAt;
      expect(at, isNotNull);
      expect(
        at!.difference(landed).inMilliseconds.abs(),
        lessThan(100),
        reason: 'the moment of the write, phone clock',
      );
      expect(heard, greaterThan(0), reason: 'the page hears the write land');

      // The test is the band pair: a second command goes out 1.8 s later; the
      // moment stays the first write's.
      await t.pump(const Duration(seconds: 20));
      expect(r.patternPlaying, isFalse);
      expect(r.patternPlayWrittenAt, at, reason: 'kept after the play');
      r.closePattern();
      expect(r.patternPlayWrittenAt, isNull, reason: 'cleared on close');
    });

    testWidgets('a new play clears the moment until its own write lands', (
      t,
    ) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      final first = r.patternPlayWrittenAt;
      expect(first, isNotNull);
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      final second = r.patternPlayWrittenAt;
      expect(second, isNotNull);
      expect(second!.isAfter(first!), isTrue, reason: 'the second play\'s own');
      r.closePattern();
    });

    testWidgets('a play with a 60 but no 100 measures nothing', (t) async {
      final r = _runner(
        DeviceLabLog(),
        onSend: (r) => r.onBandEvent(_event(60)),
      );
      await r.openPattern();
      final s = r.pattern!;
      for (final test in [8, 9]) {
        r.patternTest(test - s.testIndex);
        r.patternTap(4);
        unawaited(r.playPattern());
        await t.pump(const Duration(seconds: 10));
        expect(s.plays(test), 1);
      }
      expect(s.fittedUnitMs(), isNull);
      expect(s.unitMs, 125);
      r.closePattern();
    });

    testWidgets('closing writes what was heard and ends the session', (
      t,
    ) async {
      final lab = DeviceLabLog();
      final r = _runner(
        lab,
        onSend: (r) => r.onBandEvent(_event(100)),
      );
      await r.openPattern();
      r.patternTap(2);
      r.patternTap(1);
      r.patternTap(4);
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      unawaited(r.playPattern());
      await t.pump(const Duration(seconds: 10));
      expect(r.pattern!.plays(0), 2);
      r.patternTest(1);
      r.patternTap(6);
      expect(r.pattern!.testIndex, 1);

      r.closePattern();
      expect(r.running, isNull);
      expect(r.pattern, isNull);
      expect(r.patternPlaying, isFalse);
      final log = lab.steps.join('\n');
      expect(log, contains('Pattern probe heard 1/40'));
      expect(log, contains('Pattern probe heard 2/40'));
      expect(
        log,
        contains('A = eighth note mf, 16th rest, quarter note mf '
            '(N2mf R1 N4mf)'),
      );
      expect(log, contains('A = dotted quarter note mf (N6mf)'));
      expect(log, contains('Pattern probe tempo: '));
      expect(
        log,
        contains('1 sixteenth ≈ 125 ms (fixed)'),
        reason: 'no play measured a span',
      );
      expect(
        lab.sessionSummaries.single,
        contains('2 of 40 tests transcribed, 2 plays'),
      );
      // Closing again, or Stop afterwards, adds nothing.
      r.closePattern();
      r.stop();
      expect(lab.sessionSummaries, hasLength(1));
      expect(r.canRunPattern, isTrue);
    });

    testWidgets('Stop closes the open pattern probe', (t) async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await r.openPattern();
      r.patternTap(1);
      r.stop();
      expect(r.running, isNull);
      expect(r.pattern, isNull);
      expect(lab.steps.join('\n'), contains('Pattern probe heard 1/40'));
      expect(
        lab.sessionSummaries.single,
        contains('1 of 40 tests transcribed, 0 plays'),
      );
    });

    testWidgets('Stop during a play ends the play and the session', (t) async {
      final lab = DeviceLabLog();
      final hold = Completer<void>();
      final r = _runner(lab, holdPattern: hold);
      await r.openPattern();
      unawaited(r.playPattern());
      await t.pump(const Duration(milliseconds: 200));
      expect(r.patternPlaying, isTrue);
      r.stop();
      expect(r.running, isNull);
      hold.complete();
      await t.pump(const Duration(seconds: 20));
      expect(r.patternPlaying, isFalse);
      expect(r.running, isNull);
      expect(lab.sessionSummaries, hasLength(1));
    });

    testWidgets('patternToggleDot flips the one-shot dot, notifies, and the '
        'next tap writes the dotted length', (t) async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      final s = r.pattern!;
      var heard = 0;
      r.addListener(() => heard++);
      expect(s.dotNext, isFalse);
      final before = heard;
      r.patternToggleDot();
      expect(heard, greaterThan(before), reason: 'toggleDot notifies');
      expect(s.dotNext, isTrue);
      r.patternTap(2);
      expect(s.rendition(0, 0).code, 'N3mf');
      expect(s.dotNext, isFalse, reason: 'one-shot');
      r.patternToggleDot();
      r.patternToggleDot();
      expect(s.dotNext, isFalse);
      r.patternToggleDot();
      r.patternTap(8);
      expect(s.rendition(0, 0).code, 'N3mf R12');
      r.closePattern();
      // With nothing open it does nothing.
      _runner(DeviceLabLog()).patternToggleDot();
    });

    group('the rolling command limit (8AB)', () {
      // Every play's band 100 arrives inside its write, so a play takes no
      // fake time and 30 plays write 30 commands at the same instant; the
      // window of 2 minutes then moves only when the test pumps. Test 8 is the
      // first with one command (the 1.8 s waits of the paced tests before it
      // would need pumping).
      const oneCommandTest = 8;
      HardwareProbeRunner quick(DeviceLabLog lab, {_Link? link}) => _runner(
            lab,
            link: link,
            onSend: (r) => r.onBandEvent(_clockEvent(100)),
          );

      testWidgets('no refusal until a play is refused', (t) async {
        final r = quick(DeviceLabLog());
        expect(r.patternRefusal, isNull);
        expect(r.patternRestRemaining, isNull);
        await r.openPattern();
        r.patternTest(oneCommandTest);
        expect(r.patternRefusal, isNull);
        expect(r.patternRestRemaining, isNull);
        await r.playPattern();
        expect(r.patternRefusal, isNull);
        expect(r.patternRestRemaining, isNull);
        r.closePattern();
      });

      testWidgets('after 30 commands the next play is refused: the reason is '
          'resting, the rest counts down, the log says so', (t) async {
        final lab = DeviceLabLog();
        final sent = <_Sent>[];
        final link = _Link();
        final r = _runner(
          lab,
          link: link,
          sent: sent,
          onSend: (r) => r.onBandEvent(_clockEvent(100)),
        );
        await r.openPattern();
        r.patternTest(oneCommandTest);
        for (var i = 0; i < 30; i++) {
          await r.playPattern();
          expect(r.patternRefusal, isNull, reason: 'play ${i + 1}');
        }
        expect(sent, hasLength(30));
        expect(r.pattern!.plays(oneCommandTest), 30);

        var heard = 0;
        r.addListener(() => heard++);
        await r.playPattern();
        expect(sent, hasLength(30), reason: 'nothing written');
        expect(r.patternPlaying, isFalse);
        expect(heard, greaterThan(0), reason: 'the refusal notifies');
        expect(r.patternRefusal, PatternRefusal.resting);
        expect(r.patternRestRemaining, const Duration(minutes: 2));
        expect(r.pattern!.plays(oneCommandTest), 30, reason: 'a refused play is no play');
        expect(
          lab.steps.first,
          endsWith('Pattern probe: resting the band; ready in 120 s '
              '(30 commands per 2 minutes).'),
          reason: 'the lab prefixes the clock times',
        );

        await t.pump(const Duration(seconds: 30));
        expect(r.patternRestRemaining, const Duration(seconds: 90));
        await t.pump(const Duration(seconds: 89));
        expect(r.patternRestRemaining, const Duration(seconds: 1));
        r.closePattern();
      });

      testWidgets('once the window has slid a play is allowed and clears the '
          'refusal', (t) async {
        final r = quick(DeviceLabLog());
        await r.openPattern();
        r.patternTest(oneCommandTest);
        for (var i = 0; i < 31; i++) {
          await r.playPattern();
        }
        expect(r.patternRefusal, PatternRefusal.resting);
        await t.pump(const Duration(minutes: 2));
        expect(r.patternRestRemaining, isNull, reason: 'ready');
        await r.playPattern();
        expect(r.patternRefusal, isNull);
        expect(r.patternRestRemaining, isNull);
        expect(r.pattern!.plays(oneCommandTest), 31);
        r.closePattern();
      });

      testWidgets('not connected: the reason is notConnected, there is no '
          'rest, and the next play after reconnecting clears it', (t) async {
        final link = _Link();
        final sent = <_Sent>[];
        final r = _runner(DeviceLabLog(), link: link, sent: sent);
        await r.openPattern();
        r.patternTest(oneCommandTest);
        link.up = false;
        var heard = 0;
        r.addListener(() => heard++);
        await r.playPattern();
        expect(sent, isEmpty);
        expect(heard, greaterThan(0));
        expect(r.patternRefusal, PatternRefusal.notConnected);
        expect(r.patternRestRemaining, isNull);
        link.up = true;
        unawaited(r.playPattern());
        await t.pump(const Duration(seconds: 10));
        expect(sent, hasLength(1));
        expect(r.patternRefusal, isNull);
        r.closePattern();
      });

      testWidgets('closing and reopening the pattern probe does not reset the '
          'limit: the writes of the first screen still count', (t) async {
        final sent = <_Sent>[];
        final r = _runner(
          DeviceLabLog(),
          sent: sent,
          onSend: (r) => r.onBandEvent(_clockEvent(100)),
        );
        await r.openPattern();
        r.patternTest(oneCommandTest);
        for (var i = 0; i < 30; i++) {
          await r.playPattern();
        }
        expect(sent, hasLength(30));
        r.closePattern();
        await r.openPattern();
        r.patternTest(oneCommandTest);
        await r.playPattern();
        expect(sent, hasLength(30), reason: 'refused, nothing written');
        expect(r.patternRefusal, PatternRefusal.resting);
        expect(r.patternRestRemaining, const Duration(minutes: 2));
        expect(r.pattern!.plays(oneCommandTest), 0);
        await t.pump(const Duration(minutes: 2));
        await r.playPattern();
        expect(sent, hasLength(31), reason: 'the window slid');
        expect(r.patternRefusal, isNull);
        r.closePattern();
      });

      testWidgets('patternCommandsLeft and patternNextFreeIn follow the '
          'rolling window and survive reopening', (t) async {
        final r = quick(DeviceLabLog());
        expect(r.patternCommandsLeft, 30, reason: 'closed, nothing written');
        expect(r.patternNextFreeIn, isNull);
        await r.openPattern();
        r.patternTest(oneCommandTest);
        expect(r.patternCommandsLeft, 30);
        expect(r.patternNextFreeIn, isNull, reason: 'empty window');
        await r.playPattern();
        expect(r.patternCommandsLeft, 29);
        expect(r.patternNextFreeIn, const Duration(minutes: 2));
        await t.pump(const Duration(seconds: 50));
        for (var i = 0; i < 4; i++) {
          await r.playPattern();
        }
        expect(r.patternCommandsLeft, 25);
        expect(r.patternNextFreeIn, const Duration(seconds: 70),
            reason: 'the oldest write leaves first');
        r.closePattern();
        expect(r.patternCommandsLeft, 25, reason: 'the window outlives it');
        expect(r.patternNextFreeIn, const Duration(seconds: 70));
        await r.openPattern();
        r.patternTest(oneCommandTest);
        expect(r.patternCommandsLeft, 25);
        await t.pump(const Duration(seconds: 70));
        expect(r.patternCommandsLeft, 26, reason: 'one has left');
        expect(r.patternNextFreeIn, const Duration(seconds: 50));
        await t.pump(const Duration(seconds: 50));
        expect(r.patternCommandsLeft, 30);
        expect(r.patternNextFreeIn, isNull);
        r.closePattern();
      });

      testWidgets('patternCommandsLeft stops at 0 when the limit is reached',
          (t) async {
        final r = quick(DeviceLabLog());
        await r.openPattern();
        r.patternTest(oneCommandTest);
        for (var i = 0; i < 31; i++) {
          await r.playPattern();
        }
        expect(r.patternCommandsLeft, 0);
        expect(r.patternNextFreeIn, const Duration(minutes: 2));
        r.closePattern();
      });

      testWidgets('closing the pattern probe clears the refusal', (t) async {
        final r = quick(DeviceLabLog());
        await r.openPattern();
        r.patternTest(oneCommandTest);
        for (var i = 0; i < 31; i++) {
          await r.playPattern();
        }
        expect(r.patternRefusal, PatternRefusal.resting);
        r.closePattern();
        expect(r.patternRefusal, isNull);
        expect(r.patternRestRemaining, isNull);
      });
    });
  });

  group('HardwareProbePanel pattern probe', () {
    testWidgets('is offered', (t) async {
      await _pump(t, HardwareProbePanel(
          runner: _runner(DeviceLabLog()),
          logText: () => '',
        ),
      );
      expect(find.byKey(const ValueKey('probe-pattern')), findsOneWidget);
      expect(find.text('Run pattern probe'), findsOneWidget);
    });

    testWidgets('without the band, or on a band that is not an MG, it does '
        'not open', (t) async {
      final off = _runner(DeviceLabLog(), connected: false);
      await _pump(t, HardwareProbePanel(runner: off, logText: () => ''));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump(const Duration(milliseconds: 500));
      expect(off.running, isNull);
      expect(find.byType(PatternProbePage), findsNothing);
      final notMg = _runner(DeviceLabLog(), mg: false);
      await _pump(t, HardwareProbePanel(runner: notMg, logText: () => ''));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump(const Duration(milliseconds: 500));
      expect(notMg.running, isNull);
      expect(find.byType(PatternProbePage), findsNothing);
    });

    testWidgets('the button opens the probe and pushes the page; going back '
        'closes the session', (t) async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await _pump(t, HardwareProbePanel(runner: r, logText: () => ''));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(r.running, ProbeKind.pattern);
      expect(find.byType(PatternProbePage), findsOneWidget);
      expect(find.byKey(const ValueKey('pattern-wheel')), findsOneWidget);

      r.patternTap(2);
      t.state<NavigatorState>(find.byType(Navigator)).pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(PatternProbePage), findsNothing);
      expect(r.running, isNull);
      expect(r.pattern, isNull);
      expect(lab.steps.join('\n'), contains('Pattern probe heard 1/40'));
      expect(find.text('Run pattern probe'), findsOneWidget);
    });

    // 8AB C2: the Device lab gives the panel a closure that builds the same
    // text as its "Save lab log file"; the panel hands it, and its saver, to
    // the page, whose end screen saves it after the session has closed.
    testWidgets('the end screen saves the lab\'s log text, read after the '
        'session closed; Done returns to the panel', (t) async {
      final saved = <String>[];
      final lab = DeviceLabLog();
      final r = _runner(lab);
      var calls = 0;
      await _pump(
        t,
        HardwareProbePanel(
          runner: r,
          logText: () {
            calls++;
            return 'LAB LOG\n${lab.steps.reversed.join('\n')}';
          },
          saveLog: (n, x) async {
            saved.add(x);
            return true;
          },
        ),
      );
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(PatternProbePage), findsOneWidget);
      expect(calls, 0, reason: 'built on demand, not when the page opens');

      r.patternTap(2);
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const ValueKey('pattern-finish')));
      await t.pump(const Duration(milliseconds: 500));
      expect(r.pattern, isNull, reason: 'closed before the end screen');
      expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
      expect(calls, 0, reason: 'Finish alone saves nothing');

      await t.tap(find.byKey(const ValueKey('pattern-copy')));
      await t.pump(const Duration(milliseconds: 400));
      expect(calls, 1);
      expect(saved, hasLength(1));
      expect(saved.single, startsWith('LAB LOG'));
      expect(saved.single, contains('Pattern probe heard 1/40'));
      expect(find.text('Saved'), findsWidgets);

      await t.tap(find.byKey(const ValueKey('pattern-done')));
      await t.pump(const Duration(milliseconds: 500));
      // The exit animation starts on the first frame after the pop.
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(PatternProbePage), findsNothing);
      expect(find.text('Run pattern probe'), findsOneWidget);
      expect(r.running, isNull);
    });
  });

  // 8AD, spec E (runner half): patternSetRendition(List<PatternEntry>) puts a
  // transcription made from taps into the ACTIVE rendition of the open test.
  // Read through `dynamic` so this file compiles before the method exists.
  group('8AD patternSetRendition', () {
    List<PatternEntry> notes(String code) =>
        PatternTranscript.parseCode(code).entries;
    void set(HardwareProbeRunner r, List<PatternEntry> e) =>
        (r as dynamic).patternSetRendition(e);

    test('fills the active rendition A, moves the cursor to the end and '
        'notifies', () async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      var heard = 0;
      r.addListener(() => heard++);
      set(r, notes('N4mf R1 N4mf'));
      final s = r.pattern!;
      expect(s.rendition(0, 0).code, 'N4mf R1 N4mf');
      expect(s.rendition(0, 1).code, '');
      expect(s.cursor, 3);
      expect(s.nextIsNote, isFalse);
      expect(heard, 1);
      r.closePattern();
    });

    test('fills B when B is active, and replaces what was there', () async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      r.patternTap(2);
      r.patternRendition(1);
      r.patternTap(8);
      r.patternTap(8);
      set(r, notes('N1mf R2 N4ff'));
      final s = r.pattern!;
      expect(s.rendition(0, 1).code, 'N1mf R2 N4ff');
      expect(s.rendition(0, 0).code, 'N2mf');
      expect(s.cursor, 3);
      r.closePattern();
    });

    test('fills the open test, not the first', () async {
      final r = _runner(DeviceLabLog());
      await r.openPattern();
      r.patternTest(4);
      set(r, notes('N8mf'));
      expect(r.pattern!.rendition(4, 0).code, 'N8mf');
      expect(r.pattern!.rendition(0, 0).code, '');
      r.closePattern();
    });

    test('logs which test and rendition came from taps', () async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await r.openPattern();
      set(r, notes('N4mf R1 N4mf'));
      r.patternTest(1);
      r.patternRendition(1);
      set(r, notes('N2mf'));
      r.closePattern();
      final log = lab.steps.join('\n');
      expect(
        log,
        contains(
            'Pattern probe: test 1 rendition A from taps: N4mf R1 N4mf'),
      );
      expect(log, contains('Pattern probe: test 2 rendition B from taps: N2mf'));
    });

    test('with no probe open it does nothing', () async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      var heard = 0;
      r.addListener(() => heard++);
      set(r, notes('N4mf'));
      expect(r.pattern, isNull);
      expect(heard, 0);
      expect(lab.steps.where((l) => l.contains('from taps')), isEmpty);
    });

    test('the filled notes are in the heard line when the probe closes',
        () async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await r.openPattern();
      set(r, notes('N4mf R1 N4mf'));
      r.closePattern();
      expect(
        lab.steps.join('\n'),
        contains('A = quarter note mf, 16th rest, quarter note mf '
            '(N4mf R1 N4mf)'),
      );
    });
  });
}
