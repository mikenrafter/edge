// 8AL (red): the pattern probe's end screen "Copy all logs" becomes "Save probe
// log file".
//
// ASSUMED API (see log_file_test.dart for lib/util/log_file.dart):
//   * `PatternProbePage({required runner, required logText, LogFileSaver?
//     saveLog})` and `HardwareProbePanel({..., LogFileSaver? saveLog})`, which
//     forwards it to the page it pushes. null means the real `saveLogFile`.
//   * The end screen's button reads "Save probe log file" (key `pattern-copy`
//     may stay; found here by text). "Copy all logs" is gone, and the hint
//     above it no longer says to copy.
//   * Tapping it calls `saveLog(logFileName('pattern-probe', now), logText())`
//     once, with logText() read AFTER the session closed (the heard lines are
//     in it), as the copy did.
//   * `_copied` becomes a saved state: "Saved" (with the check icon) appears
//     only after a save that returned true; never "Copied". A false (or
//     throwing) saver shows the SnackBar "Could not save the log file." and no
//     "Saved".
//   * Nothing ever reaches the clipboard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/pattern_probe_page.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/util/log_file.dart';

HardwareProbeRunner _runner(DeviceLabLog lab) => HardwareProbeRunner(
      lab: lab,
      sendBuzz: (onReply) async {
        onReply('pending', 40);
        return true;
      },
      sendPattern: (effects, loop, onReply) async {
        onReply('pending', 40);
        return true;
      },
      isConnected: () => true,
      ecgSupported: () => true,
      ecgBusy: () => false,
      beginEcg: () async => false,
      endEcg: () async {},
      isEcgAlive: () => false,
    );

final _name = RegExp(r'^openstrap-pattern-probe-log-\d{8}-\d{6}\.txt$');

Future<void> _tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await t.pump(const Duration(milliseconds: 400));
}

/// Opens the page on an open runner, transcribes test 1 and finishes, so the
/// end screen shows.
Future<HardwareProbeRunner> _toEndScreen(
  WidgetTester t,
  DeviceLabLog lab, {
  required String Function() logText,
  required LogFileSaver saveLog,
}) async {
  t.view.physicalSize = const Size(390, 844) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final r = _runner(lab);
  await r.openPattern();
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: PatternProbePage(runner: r, logText: logText, saveLog: saveLog),
  ));
  await t.pump(const Duration(milliseconds: 300));
  await _tapKey(t, 'pattern-len-2');
  await _tapKey(t, 'pattern-finish');
  expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
  return r;
}

Future<void> _teardown(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

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

  final saveButton = find.text('Save probe log file');

  testWidgets('the end screen offers Save probe log file, not Copy', (t) async {
    await _toEndScreen(t, DeviceLabLog(),
        logText: () => 'log', saveLog: (n, x) async => true);
    expect(saveButton, findsOneWidget);
    expect(find.text('Copy all logs'), findsNothing);
    expect(
        _allText(t).where((s) => s.toLowerCase().contains('copy')), isEmpty,
        reason: 'no copy wording left on the end screen, hint included');
    await _teardown(t);
  });

  testWidgets('saves logText(), read after the session closed, as a named '
      'file; nothing before the tap', (t) async {
    final lab = DeviceLabLog();
    final calls = <bool>[];
    final saved = <(String, String)>[];
    late final HardwareProbeRunner r;
    r = await _toEndScreen(
      t,
      lab,
      logText: () {
        calls.add(r.pattern != null);
        return 'LAB LOG\n${lab.steps.reversed.join('\n')}';
      },
      saveLog: (n, x) async {
        saved.add((n, x));
        return true;
      },
    );
    expect(saved, isEmpty, reason: 'Finish saves nothing by itself');
    expect(calls, isEmpty);
    await t.tap(saveButton);
    await t.pump(const Duration(milliseconds: 400));
    expect(saved, hasLength(1));
    expect(calls, [false], reason: 'built after closePattern');
    final (name, text) = saved.single;
    expect(name, matches(_name));
    expect(text, startsWith('LAB LOG'));
    expect(text, contains('Pattern probe heard 1/40'),
        reason: 'the heard lines are in the file');
    expect(text, contains('Pattern probe tempo'));
    expect(clipboard, isEmpty);
    await _teardown(t);
  });

  testWidgets('says Saved after a save, never Copied; not before', (t) async {
    await _toEndScreen(t, DeviceLabLog(),
        logText: () => 'log', saveLog: (n, x) async => true);
    expect(find.text('Saved'), findsNothing);
    await t.tap(saveButton);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Saved'), findsWidgets);
    expect(find.text('Copied'), findsNothing);
    expect(find.text('Could not save the log file.'), findsNothing);
    await _teardown(t);
  });

  testWidgets('a failed save says so and does not say Saved', (t) async {
    await _toEndScreen(t, DeviceLabLog(),
        logText: () => 'log', saveLog: (n, x) async => false);
    await t.tap(saveButton);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Could not save the log file.'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    expect(find.text('Copied'), findsNothing);
    await _teardown(t);
  });

  testWidgets('a saver that throws is reported, not left unhandled',
      (t) async {
    await _toEndScreen(t, DeviceLabLog(),
        logText: () => 'log',
        saveLog: (n, x) async => throw StateError('no disk'));
    await t.tap(saveButton);
    await t.pump(const Duration(milliseconds: 400));
    expect(t.takeException(), isNull);
    expect(find.text('Could not save the log file.'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    await _teardown(t);
  });

  testWidgets('through the Device lab panel: the page it pushes saves with '
      'the panel\'s saver and logText', (t) async {
    final lab = DeviceLabLog();
    final r = _runner(lab);
    final saved = <(String, String)>[];
    t.view.physicalSize = const Size(1200, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: HardwareProbePanel(
            runner: r,
            logText: () => 'LAB LOG\n${lab.steps.reversed.join('\n')}',
            saveLog: (n, x) async {
              saved.add((n, x));
              return true;
            },
          ),
        ),
      ),
    ));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('probe-pattern')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(PatternProbePage), findsOneWidget);
    r.patternTap(2);
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('pattern-finish')));
    await t.pump(const Duration(milliseconds: 500));
    expect(saved, isEmpty);
    await t.tap(saveButton);
    await t.pump(const Duration(milliseconds: 400));
    expect(saved, hasLength(1));
    expect(saved.single.$1, matches(_name));
    expect(saved.single.$2, startsWith('LAB LOG'));
    expect(saved.single.$2, contains('Pattern probe heard 1/40'));
    expect(clipboard, isEmpty);
    await t.tap(find.byKey(const ValueKey('pattern-done')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    await _teardown(t);
  });
}
