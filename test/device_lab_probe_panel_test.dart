// 8V: the Device lab's "Hardware probes" panel over a runner with fake band
// effects (fake async time: the probe's waits are pumped, not slept).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1200, 2400);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: w)),
  ));
}

HardwareProbeRunner _runner(DeviceLabLog lab,
        {bool connected = true, List<int>? sent}) =>
    HardwareProbeRunner(
      lab: lab,
      sendBuzz: (onReply) async {
        sent?.add(1);
        onReply('pending', 40);
        return true;
      },
      sendPattern: (effects, loop, onReply) async {
        onReply('pending', 40);
        return true;
      },
      isConnected: () => connected,
      ecgSupported: () => true,
      ecgBusy: () => false,
      beginEcg: () async => false,
      endEcg: () async {},
      isEcgAlive: () => false,
    );

void main() {
  testWidgets('both probes are offered, with the safety limits spelled out',
      (t) async {
    await _pump(t, HardwareProbePanel(
        runner: _runner(DeviceLabLog()),
        logText: () => '',
      ));
    expect(find.text('Run buzz probe'), findsOneWidget);
    expect(find.text('Run ECG touch probe'), findsOneWidget);
    expect(find.textContaining('up to 30 short buzzes'), findsOneWidget);
    expect(find.textContaining('at most 60 s'), findsOneWidget);
    expect(find.textContaining('Stop ends either at once'), findsOneWidget);
  });

  testWidgets('the buzz probe asks how many were felt; Stop ends it',
      (t) async {
    final lab = DeviceLabLog();
    final sent = <int>[];
    final r = _runner(lab, sent: sent);
    await _pump(t, HardwareProbePanel(runner: r, logText: () => ''));
    await t.tap(find.byKey(const ValueKey('probe-buzz')));
    await t.pump();
    expect(find.text('Stop'), findsOneWidget);
    expect(find.textContaining('count the buzzes'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(find.textContaining('Group 1 of 8: 3 buzzes sent 200 ms apart'),
        findsOneWidget);
    expect(find.textContaining('bzz-bzz'), findsWidgets,
        reason: 'one command is one bzz-bzz: that is what the wearer counts');
    expect(sent, hasLength(3));
    await t.tap(find.byKey(const ValueKey('probe-felt-2')));
    await t.pump();
    expect(lab.steps.join('\n'), contains('felt 2.'));
    await t.tap(find.byKey(const ValueKey('probe-stop')));
    await t.pump(const Duration(seconds: 10));
    expect(r.running, isNull);
    expect(find.text('Run buzz probe'), findsOneWidget);
    expect(sent.length, lessThanOrEqualTo(6),
        reason: 'nothing after the trial that was running at Stop');
  });

  testWidgets('without a band the probes cannot start', (t) async {
    final r = _runner(DeviceLabLog(), connected: false);
    await _pump(t, HardwareProbePanel(runner: r, logText: () => ''));
    await t.tap(find.byKey(const ValueKey('probe-buzz')));
    await t.pump();
    expect(r.running, isNull);
  });

  testWidgets('leaving the screen stops a running probe', (t) async {
    final r = _runner(DeviceLabLog());
    await _pump(t, HardwareProbePanel(runner: r, logText: () => ''));
    await t.tap(find.byKey(const ValueKey('probe-buzz')));
    await t.pump();
    expect(r.running, ProbeKind.buzz);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 10));
    expect(r.running, isNull);
  });

  testWidgets('the Device lab shows the section when given the panel',
      (t) async {
    t.view.physicalSize = const Size(1200, 8000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: DeviceLabView(
        ecgSupported: true,
        probes: HardwareProbePanel(
        runner: _runner(DeviceLabLog()),
        logText: () => '',
      ),
      ),
    ));
    expect(find.text('Hardware probes'), findsOneWidget);
    expect(find.text('Run buzz probe'), findsOneWidget);
  });
}
