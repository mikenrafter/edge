// The Device lab's termination probe card: one button per scenario, Stop and
// the status while it runs, the timeline and verdict after, and "Save report
// file" - the log-file path (logFileName + saveLogFile), never the clipboard
// (AGENTS.md invariant 16). Leaving the screen stops the run, which clears
// the probe's alarm slot and restores the real alarm. Over the shared fake
// band, on fake time.
//
// Keys: `term-run-<scenario.name>`, `term-stop`, `term-status`,
// `term-result-<scenario.name>`, `term-save`, `term-reason`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/termination_probe.dart';
import 'package:openstrap_edge/ui2/profile/termination_probe_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/termination_probe_rig.dart';

typedef _S = TerminationScenario;

final _name = RegExp(r'^openstrap-termination-probe-log-\d{8}-\d{6}\.txt$');

Future<void> _pump(WidgetTester t, TerminationRig rig,
    {Future<bool> Function(String, String)? saveLog}) async {
  t.view.physicalSize = const Size(1200, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(
          child: TerminationProbeCard(runner: rig.runner, saveLog: saveLog)),
    ),
  ));
}

Finder _run(_S s) => find.byKey(ValueKey('term-run-${s.name}'));

List<String> _allText(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = <String>[];

  setUp(() {
    clipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboard.add(call.method);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('a button per scenario, each with its title and instruction',
      (t) async {
    final rig = TerminationRig();
    await _pump(t, rig);
    for (final s in _S.values) {
      expect(_run(s), findsOneWidget, reason: s.name);
      expect(find.text(s.title), findsOneWidget);
      expect(find.text(s.instruction), findsOneWidget);
      expect(t.widget<BigButton>(_run(s)).onTap, isNotNull);
    }
    expect(find.byKey(const ValueKey('term-save')), findsNothing,
        reason: 'nothing to save before a run');
  });

  testWidgets('developer mode off: the card is not there', (t) async {
    await _pump(t, TerminationRig()..dev = false);
    expect(_run(_S.appFinishes), findsNothing);
  });

  testWidgets('a gen4 band disables every button and says why', (t) async {
    await _pump(t, TerminationRig(family: 'gen4'));
    for (final s in _S.values) {
      expect(t.widget<BigButton>(_run(s)).onTap, isNull);
    }
    expect(find.textContaining('WHOOP 5'), findsWidgets);
  });

  testWidgets('a real alarm within 10 minutes disables only the alarm '
      'scenarios, with the reason', (t) async {
    await _pump(t, TerminationRig(heldIn: const Duration(minutes: 6)));
    for (final s in _S.values) {
      expect(t.widget<BigButton>(_run(s)).onTap == null, s.usesAlarm,
          reason: s.name);
    }
    expect(find.textContaining('10 minutes'), findsWidgets);
  });

  testWidgets('a run shows Stop and the status, then the timeline and the '
      'verdict', (t) async {
    final rig = TerminationRig();
    await _pump(t, rig);
    await t.tap(_run(_S.appFinishes));
    await t.pump(const Duration(seconds: 1));
    expect(rig.runner.running, isTrue);
    expect(find.byKey(const ValueKey('term-stop')), findsOneWidget);
    expect(find.byKey(const ValueKey('term-status')), findsOneWidget);
    expect(t.widget<BigButton>(_run(_S.appDoubleTap)).onTap, isNull,
        reason: 'one run at a time');
    await t.pump(const Duration(seconds: 30));
    expect(rig.runner.running, isFalse);
    expect(find.byKey(const ValueKey('term-stop')), findsNothing);
    final result = find.byKey(const ValueKey('term-result-appFinishes'));
    expect(result, findsOneWidget);
    expect(find.descendant(of: result, matching: find.textContaining('cause expired')),
        findsWidgets);
    final r = rig.runner.resultOf(_S.appFinishes)!;
    expect(find.text(r.verdict), findsOneWidget);
    for (final e in r.timeline) {
      expect(find.text(e.line), findsOneWidget);
    }
  });

  testWidgets('Stop clears the probe slot and restores the real alarm at once',
      (t) async {
    final rig = TerminationRig();
    await _pump(t, rig);
    await t.tap(_run(_S.alarmExpires));
    await t.pump(const Duration(seconds: 6));
    expect(rig.stored.keys, contains(1));
    await t.tap(find.byKey(const ValueKey('term-stop')));
    await t.pump(const Duration(seconds: 5));
    expect(rig.runner.running, isFalse);
    expect(rig.calls, contains('clear1'));
    expect(rig.calls, contains('restore:${rig.held}'));
    expect(rig.stored, {0: rig.held!});
  });

  testWidgets('leaving the screen mid-run clears the slot and restores the '
      'real alarm', (t) async {
    final rig = TerminationRig();
    await _pump(t, rig);
    await t.tap(_run(_S.overlap));
    await t.pump(const Duration(seconds: 6));
    expect(rig.runner.running, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    expect(rig.runner.running, isFalse);
    expect(rig.calls, contains('clear1'));
    expect(rig.calls, contains('restore:${rig.held}'));
    expect(rig.stored, {0: rig.held!});
  });

  testWidgets('Save report file saves the report as a named log file; '
      'nothing reaches the clipboard', (t) async {
    final rig = TerminationRig();
    final saved = <(String, String)>[];
    await _pump(t, rig, saveLog: (n, x) async {
      saved.add((n, x));
      return true;
    });
    await t.tap(_run(_S.appFinishes));
    await t.pump(const Duration(seconds: 30));
    expect(saved, isEmpty, reason: 'a run saves nothing by itself');
    expect(find.text('Save report file'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('term-save')));
    await t.pump(const Duration(milliseconds: 400));
    expect(saved, hasLength(1));
    final (name, text) = saved.single;
    expect(name, matches(_name));
    expect(text, contains('HAPTICS_TERMINATED'));
    expect(text, contains(rig.runner.resultOf(_S.appFinishes)!.verdict));
    expect(clipboard, isEmpty);
    expect(find.text('Report file saved'), findsOneWidget);
  });

  testWidgets('a failed or throwing save says so and does not say saved',
      (t) async {
    final rig = TerminationRig();
    var throwIt = false;
    await _pump(t, rig, saveLog: (n, x) async {
      if (throwIt) throw StateError('no disk');
      return false;
    });
    await t.tap(_run(_S.appFinishes));
    await t.pump(const Duration(seconds: 30));
    await t.tap(find.byKey(const ValueKey('term-save')));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Could not save the log file.'), findsOneWidget);
    expect(find.text('Report file saved'), findsNothing);
    throwIt = true;
    await t.tap(find.byKey(const ValueKey('term-save')));
    await t.pump(const Duration(milliseconds: 400));
    expect(t.takeException(), isNull);
    expect(find.text('Could not save the log file.'), findsWidgets);
  });

  testWidgets('no copy wording anywhere on the card', (t) async {
    final rig = TerminationRig();
    await _pump(t, rig);
    await t.tap(_run(_S.appFinishes));
    await t.pump(const Duration(seconds: 30));
    expect(_allText(t).where((s) => s.toLowerCase().contains('copy')), isEmpty);
    expect(find.text('Copy report'), findsNothing);
    expect(clipboard, isEmpty);
  });
}
