// 8W: the pattern probe in the Device lab. The runner (refusals, the open
// question, the answer reaching the lab log, Stop) and the "Hardware probes"
// panel (the button, the safety caption, the two answer rows and the Next
// button that waits for both). Fake async time: the probe's real waits are
// pumped, not slept.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

typedef _Sent = ({List<int> effects, int loop});

HardwareProbeRunner _runner(
  DeviceLabLog lab, {
  bool connected = true,
  bool mg = true,
  List<_Sent>? sent,
  Completer<void>? holdBuzz,
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
      onSend?.call(r);
      onReply('pending', 40);
      return true;
    },
    isConnected: () => connected,
    ecgSupported: () => mg,
    ecgBusy: () => false,
    beginEcg: () async => false,
    endEcg: () async {},
    isEcgAlive: () => false,
  );
  return r;
}

StrapEvent _event(int id) => StrapEvent(
  eventId: id,
  tsEpoch: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  receivedAt: DateTime.now(),
  hex: '',
  deviceId: 'band',
);

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
  group('HardwareProbeRunner pattern probe', () {
    test('refuses with a reason instead of starting', () async {
      final lab = DeviceLabLog();
      final off = _runner(lab, connected: false);
      await off.runPattern();
      expect(off.note, 'Connect the band first.');
      expect(off.running, isNull);
      final notMg = _runner(lab, mg: false);
      await notMg.runPattern();
      expect(notMg.note, 'This band cannot play custom patterns.');
      expect(notMg.running, isNull);
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
      await r.runPattern();
      expect(r.note, 'A probe is already running.');
      expect(r.running, ProbeKind.buzz);
      expect(sent, isEmpty);
      r.stop();
      hold.complete();
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
    });

    testWidgets('asks after each test; the answer reaches the lab log; Stop '
        'closes the question', (t) async {
      final lab = DeviceLabLog();
      final sent = <_Sent>[];
      final r = _runner(
        lab,
        sent: sent,
        // The band answers with a haptic-start event as it is written.
        onSend: (r) => r.onBandEvent(_event(60)),
      );
      unawaited(r.runPattern());
      await t.pump();
      expect(r.running, ProbeKind.pattern);
      expect(r.patternQuestion, isNull, reason: 'the test is still running');
      expect(r.patternTestCount, 32);
      // Test 1: the band pair, two commands 1.8 s apart, then the settle wait.
      await t.pump(const Duration(seconds: 7));
      final q = r.patternQuestion;
      expect(q, isNotNull);
      expect(q!.waveform.name, 'band pair 47+152');
      expect(q.style, BuzzStyle.paced);
      expect(q.count, 2);
      expect(r.patternQuestionIndex, 0);
      expect(sent.map((s) => s.effects), [
        [47, 152],
        [47, 152],
      ]);
      expect(sent.map((s) => s.loop), [1, 1]);
      r.answerPattern(4, 2);
      await t.pump();
      expect(r.patternQuestion, isNull);
      final log = lab.steps.join('\n');
      expect(
        log,
        contains(
          'Pattern probe 1/32, band pair 47+152, 2 commands '
          '1.8 s apart',
        ),
      );
      expect(log, contains('felt 4 buzzes in 2 groups.'));
      expect(
        log,
        contains('band events 60 at +'),
        reason: 'band events reach the running probe through the runner',
      );
      // Test 2 follows after the rest; Stop closes its question and ends it.
      await t.pump(const Duration(seconds: 20));
      expect(r.patternQuestion, isNotNull);
      expect(r.patternQuestionIndex, 1);
      r.stop();
      expect(r.patternQuestion, isNull);
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
      expect(
        lab.sessionSummaries.single,
        startsWith(
          'Pattern probe | 32 tests: 4 waveforms × 4 ways of '
          'sending × 2 counts | ',
        ),
      );
    });
  });

  group('HardwareProbePanel pattern probe', () {
    testWidgets('is offered with its safety bounds', (t) async {
      await _pump(t, HardwareProbePanel(runner: _runner(DeviceLabLog())));
      expect(find.byKey(const ValueKey('probe-pattern')), findsOneWidget);
      expect(find.text('Run pattern probe'), findsOneWidget);
      expect(
        find.textContaining('up to ${PatternProbe.maxCommands} short commands'),
        findsOneWidget,
      );
      expect(find.textContaining('3 s rest after each test'), findsOneWidget);
      expect(find.textContaining('Stop ends it at once'), findsOneWidget);
    });

    testWidgets('without the band, or on a band that is not an MG, it does '
        'not start', (t) async {
      final off = _runner(DeviceLabLog(), connected: false);
      await _pump(t, HardwareProbePanel(runner: off));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump();
      expect(off.running, isNull);
      final notMg = _runner(DeviceLabLog(), mg: false);
      await _pump(t, HardwareProbePanel(runner: notMg));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump();
      expect(notMg.running, isNull);
    });

    Future<({HardwareProbeRunner r, DeviceLabLog lab})> openQuestion(
      WidgetTester t,
    ) async {
      final lab = DeviceLabLog();
      final r = _runner(lab);
      await _pump(t, HardwareProbePanel(runner: r));
      await t.tap(find.byKey(const ValueKey('probe-pattern')));
      await t.pump();
      expect(r.running, ProbeKind.pattern);
      expect(find.byKey(const ValueKey('probe-stop')), findsOneWidget);
      await t.pump(const Duration(seconds: 7));
      return (r: r, lab: lab);
    }

    testWidgets('a question shows the test and two answer rows; Next waits '
        'for both', (t) async {
      final (:r, :lab) = await openQuestion(t);
      expect(find.textContaining('1 of 32'), findsWidgets);
      expect(
        find.textContaining('band pair 47+152, 2 commands 1.8 s apart'),
        findsWidgets,
      );
      expect(find.text('How many buzzes?'), findsOneWidget);
      expect(find.text('How many groups?'), findsOneWidget);
      for (var n = 0; n <= 6; n++) {
        expect(
          find.byKey(ValueKey('probe-buzzes-$n')),
          findsOneWidget,
          reason: 'buzzes $n',
        );
      }
      for (var n = 0; n <= 4; n++) {
        expect(
          find.byKey(ValueKey('probe-groups-$n')),
          findsOneWidget,
          reason: 'groups $n',
        );
      }
      expect(find.byKey(const ValueKey('probe-buzzes-7')), findsNothing);
      expect(find.byKey(const ValueKey('probe-groups-5')), findsNothing);
      expect(find.byKey(const ValueKey('probe-buzzes-skip')), findsOneWidget);
      expect(find.byKey(const ValueKey('probe-groups-skip')), findsOneWidget);
      final next = find.byKey(const ValueKey('probe-pattern-next'));
      expect(next, findsOneWidget);

      await t.tap(next);
      await t.pump();
      expect(r.patternQuestion, isNotNull, reason: 'nothing chosen yet');
      await t.tap(find.byKey(const ValueKey('probe-buzzes-4')));
      await t.pump();
      await t.tap(next);
      await t.pump();
      expect(r.patternQuestion, isNotNull, reason: 'only the buzzes chosen');
      await t.tap(find.byKey(const ValueKey('probe-groups-2')));
      await t.pump();
      await t.tap(next);
      await t.pump();
      expect(r.patternQuestion, isNull);
      expect(lab.steps.join('\n'), contains('felt 4 buzzes in 2 groups.'));
      await t.tap(find.byKey(const ValueKey('probe-stop')));
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
      expect(find.text('Run pattern probe'), findsOneWidget);
    });

    testWidgets('Not sure counts as a choice and reaches the log as such', (
      t,
    ) async {
      final (:r, :lab) = await openQuestion(t);
      await t.tap(find.byKey(const ValueKey('probe-groups-skip')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('probe-pattern-next')));
      await t.pump();
      expect(r.patternQuestion, isNotNull, reason: 'the buzzes row is open');
      await t.tap(find.byKey(const ValueKey('probe-buzzes-skip')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('probe-pattern-next')));
      await t.pump();
      expect(r.patternQuestion, isNull);
      expect(lab.steps.join('\n'), contains('not sure'));
      await t.tap(find.byKey(const ValueKey('probe-stop')));
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
    });

    testWidgets('Stop with a question open ends the probe', (t) async {
      final (:r, :lab) = await openQuestion(t);
      await t.tap(find.byKey(const ValueKey('probe-stop')));
      await t.pump(const Duration(seconds: 10));
      expect(r.running, isNull);
      expect(r.patternQuestion, isNull);
      expect(find.text('Run pattern probe'), findsOneWidget);
    });
  });
}
