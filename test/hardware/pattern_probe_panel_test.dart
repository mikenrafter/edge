// 8Y: the pattern probe as a transcriber, runner half and entry point. The
// runner opens a session (refusals, the session line), plays the current test
// on demand, passes edits through to the entry session, and writes what was
// transcribed into the lab log when it closes (or when Stop is pressed). The
// "Hardware probes" panel only opens the probe page. The page itself is
// pinned in pattern_probe_page_test.dart. Fake async time: the probe's real
// waits are pumped, not slept.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/pattern_probe_page.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

typedef _Sent = ({List<int> effects, int loop});

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
      expect(s.rendition(0, 0).lengths, [2, 1, 4]);
      expect(s.cursor, 3);

      expectNotified('move', () => r.patternMove(-2));
      expect(s.cursor, 1);
      r.patternTap(3);
      expect(s.rendition(0, 0).lengths, [2, 3, 4], reason: 'replaced in place');
      expect(s.cursor, 2);

      expectNotified('delete', r.patternDelete);
      expect(s.rendition(0, 0).lengths, [2, 3]);

      expectNotified('rendition', () => r.patternRendition(1));
      expect(s.activeRendition, 1);
      r.patternTap(4);
      expect(s.rendition(0, 1).lengths, [4]);
      expect(s.rendition(0, 0).lengths, [2, 3]);

      expectNotified('next test', () => r.patternTest(1));
      expect(s.testIndex, 1);
      expect(s.activeRendition, 0, reason: 'a new test starts on A');
      expectNotified('previous test', () => r.patternTest(-1));
      expect(s.testIndex, 0);
      r.patternTest(-1);
      expect(s.testIndex, 0, reason: 'clamped at the first test');
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
      r.patternTap(3);
      expect(r.pattern!.testIndex, 1);

      r.closePattern();
      expect(r.running, isNull);
      expect(r.pattern, isNull);
      expect(r.patternPlaying, isFalse);
      final log = lab.steps.join('\n');
      expect(log, contains('Pattern probe heard 1/40'));
      expect(log, contains('Pattern probe heard 2/40'));
      expect(log, contains('A = buzz 2, gap 1, buzz 4 (B2 G1 B4)'));
      expect(log, contains('A = buzz 3 (B3)'));
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
  });

  group('HardwareProbePanel pattern probe', () {
    testWidgets('is offered', (t) async {
      await _pump(t, HardwareProbePanel(runner: _runner(DeviceLabLog())));
      expect(find.byKey(const ValueKey('probe-pattern')), findsOneWidget);
      expect(find.text('Run pattern probe'), findsOneWidget);
    });

    testWidgets('without the band, or on a band that is not an MG, it does '
        'not open', (t) async {
      final off = _runner(DeviceLabLog(), connected: false);
      await _pump(t, HardwareProbePanel(runner: off));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump(const Duration(milliseconds: 500));
      expect(off.running, isNull);
      expect(find.byType(PatternProbePage), findsNothing);
      final notMg = _runner(DeviceLabLog(), mg: false);
      await _pump(t, HardwareProbePanel(runner: notMg));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump(const Duration(milliseconds: 500));
      expect(notMg.running, isNull);
      expect(find.byType(PatternProbePage), findsNothing);
    });

    testWidgets('the button opens the probe and pushes the page; going back '
        'closes the session', (t) async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await _pump(t, HardwareProbePanel(runner: r));
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
  });
}
