// 8AL (red): the Device lab's "Copy all logs" becomes "Save lab log file".
//
// ASSUMED API (see log_file_test.dart for lib/util/log_file.dart):
//   * `DeviceLabView({..., LogFileSaver? saveLog})` in
//     lib/ui2/profile/device_lab.dart; null means the real `saveLogFile`.
//   * The bottom button reads "Save lab log file" (the key `lab-copy-all` may
//     stay; these tests find it by its text). "Copy all logs" is gone.
//   * Tapping it calls `saveLog(logFileName('device-lab', now), text)` once,
//     where text is `logText()` when given, else `labLogText(entries, steps,
//     sessions, packets)` (the same text the copy used, ECG packets included).
//   * A SnackBar says "Log file saved" when the saver returns true and "Could
//     not save the log file." when it returns false (or throws).
//   * Nothing ever reaches the clipboard (no `Clipboard.*` platform call).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/ecg_trace.dart';

final _strapAt = DateTime(2026, 10, 2, 9, 15, 3, 250);

StrapEvent _tap() {
  final utc = _strapAt.toUtc();
  return StrapEvent(
    eventId: 14,
    tsEpoch: utc.millisecondsSinceEpoch ~/ 1000,
    tsSubsec: (utc.millisecond * 32768) ~/ 1000,
    receivedAt: utc.add(const Duration(milliseconds: 1200)),
    hex: '',
    deviceId: 'band',
  );
}

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

final _name = RegExp(r'^openstrap-device-lab-log-\d{8}-\d{6}\.txt$');

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

  final saveButton = find.text('Save lab log file');

  testWidgets('the button says Save lab log file, not Copy all logs',
      (t) async {
    await _pump(t, DeviceLabView(ecgSupported: false, saveLog: (n, x) async => true));
    expect(saveButton, findsOneWidget);
    expect(find.text('Copy all logs'), findsNothing);
  });

  testWidgets('it stays at the bottom, below every section', (t) async {
    await _pump(
        t,
        DeviceLabView(
          ecgSupported: true,
          steps: const ['09:15:03.260 | tap +10 ms | last +10 ms | Double tap.'],
          entries: [DeviceLabEntry.fromEvent(_tap())],
          saveLog: (n, x) async => true,
        ));
    final y = t.getTopLeft(saveButton).dy;
    for (final heading in ['Band events', 'Step by step']) {
      expect(y, greaterThan(t.getTopLeft(find.text(heading)).dy),
          reason: 'below $heading');
    }
    expect(y, greaterThan(t.getSize(find.byType(Scaffold)).height * 0.8));
  });

  testWidgets('tapping saves the lab log, with the packets, as a named file',
      (t) async {
    final saved = <(String, String)>[];
    final lab = DeviceLabLog()
      ..addPacket(
        r17(
          strapSeconds: 1790986679,
          samples: [1, 2, 3, 4],
          flags: 0x0a,
          s2State: 1,
          progress: 3,
        ),
        DateTime(2026, 10, 2, 9, 15),
        tag: 'tap 09:15:03.250',
      );
    await _pump(
        t,
        DeviceLabView(
          ecgSupported: true,
          steps: const [
            '09:15:04.460 | tap +1210 ms | last +1200 ms | ECG stream command written.',
            '09:15:03.260 | tap +10 ms | last +10 ms | Double tap received.',
          ],
          sessions: const ['ECG sensor touches | 3 taps | 6.4 s in total'],
          entries: [DeviceLabEntry.fromEvent(_tap())],
          packets: lab.packets,
          saveLog: (n, x) async {
            saved.add((n, x));
            return true;
          },
        ));
    await t.tap(saveButton);
    await t.pump();
    expect(saved, hasLength(1));
    final (name, text) = saved.single;
    expect(name, matches(_name));
    expect(text, contains('OpenStrap Device lab log'));
    expect(text, contains('3 taps | 6.4 s in total'));
    expect(text, contains('Double tap received.'));
    expect(text, contains('ECG stream command written.'));
    expect(text, contains('Event 14 | Live'));
    expect(text, contains('ECG packets, oldest first'));
    expect(text.indexOf('Double tap received.'),
        lessThan(text.indexOf('ECG stream command written.')),
        reason: 'oldest first, as the copy was');
    expect(clipboard, isEmpty, reason: 'never the clipboard');
  });

  testWidgets('a given logText() is what is saved, verbatim', (t) async {
    final saved = <(String, String)>[];
    var calls = 0;
    await _pump(
        t,
        DeviceLabView(
          ecgSupported: false,
          logText: () {
            calls++;
            return 'LAB LOG\nverbatim ≈ text\n';
          },
          saveLog: (n, x) async {
            saved.add((n, x));
            return true;
          },
        ));
    expect(calls, 0, reason: 'built when asked, not on build');
    await t.tap(saveButton);
    await t.pump();
    expect(calls, 1);
    expect(saved.single.$2, 'LAB LOG\nverbatim ≈ text\n');
    expect(clipboard, isEmpty);
  });

  testWidgets('says "Log file saved" when it worked, not "Log copied"',
      (t) async {
    await _pump(
        t, DeviceLabView(ecgSupported: false, saveLog: (n, x) async => true));
    await t.tap(saveButton);
    await t.pump();
    expect(find.text('Log file saved'), findsOneWidget);
    expect(find.text('Log copied'), findsNothing);
    expect(find.text('Could not save the log file.'), findsNothing);
  });

  testWidgets('says it could not save when the saver returns false',
      (t) async {
    await _pump(
        t, DeviceLabView(ecgSupported: false, saveLog: (n, x) async => false));
    await t.tap(saveButton);
    await t.pump();
    expect(find.text('Could not save the log file.'), findsOneWidget);
    expect(find.text('Log file saved'), findsNothing);
    expect(find.text('Log copied'), findsNothing);
  });

  testWidgets('a saver that throws is reported, not left unhandled',
      (t) async {
    await _pump(
        t,
        DeviceLabView(
            ecgSupported: false,
            saveLog: (n, x) async => throw StateError('no disk')));
    await t.tap(saveButton);
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('Could not save the log file.'), findsOneWidget);
    expect(find.text('Log file saved'), findsNothing);
  });

  testWidgets('it can be tapped again after a failure', (t) async {
    final results = [false, true];
    var calls = 0;
    await _pump(
        t,
        DeviceLabView(
            ecgSupported: false,
            saveLog: (n, x) async => results[calls++]));
    await t.tap(saveButton);
    await t.pump();
    await t.pump(const Duration(seconds: 5));
    await t.tap(saveButton);
    await t.pump();
    expect(calls, 2);
    expect(find.text('Log file saved'), findsOneWidget);
  });

  testWidgets('no Clipboard call on any outcome', (t) async {
    for (final r in [true, false]) {
      await _pump(
          t, DeviceLabView(ecgSupported: false, saveLog: (n, x) async => r));
      await t.tap(saveButton);
      await t.pump();
      await t.pump(const Duration(seconds: 5));
    }
    expect(clipboard, isEmpty);
  });
}
