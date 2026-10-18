// "Save log file" writes a .txt through the platform save/share
// flow, never the clipboard.
//
// USER: "Save log file (writes a .txt of the relevant session/gesture log via
// the platform save/share flow, NOT the clipboard; reuse whatever log source
// the dev ECG lab uses)". The log source is the Device lab's own plain-text log
// (`DeviceLabLog.toPlainText` / `labLogText`, lib/gestures/lab_log.dart); a
// failure record carries the text it had at the time (gesture_failures.dart).
//
// ASSUMED API (NEW lib/gestures/gesture_log_file.dart):
//   * `String gestureLogFileName(GestureFailure f)`: a plain file name ending
//     ".txt", no spaces, colons or path separators, naming the kind
//     ("ecg" / "double-tap") and the failure's time, e.g.
//     `openstrap-gesture-failure-ecg-20261004-120731.txt`.
//   * `String gestureLogFileText(GestureFailure f)`: a short header (what
//     failed: the kind in words, the reason, the gesture id, the local time)
//     followed by `f.log` verbatim.
//   * `Future<bool> saveGestureLog(GestureFailure f, {Directory? dir,
//       Future<void> Function(String path)? share})`: writes the text as UTF-8
//     to `<dir>/<file name>` (default the app's temporary directory) and hands
//     the file path to `share` (default: the platform share sheet through
//     share_plus, which is also how the repo's other exports leave the phone).
//     True when the file was written and shared without error; false (never a
//     throw) when the write or the share failed. It never touches the
//     clipboard.
//   * The Home card and the Settings list reach it through an injectable
//     `GestureLogSaver = Future<bool> Function(GestureFailure)` (see
//     d_home_card_test.dart), so the widgets are tested with a fake saver.
//
// Failure mode today: the file does not exist (this file does not compile
// until it does).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/gestures/gesture_log_file.dart';

final DateTime _at = DateTime.utc(2026, 10, 4, 12, 7, 31);

GestureFailure _failure({
  GestureFailureKind kind = GestureFailureKind.ecg,
  String reason = 'start_failed',
  String log = 'Double tap received. Starting the ECG stream.\n'
      'ECG failed (start_failed): one long buzz.',
}) =>
    GestureFailure(
      gestureId: '1791101224:14',
      at: _at,
      kind: kind,
      reason: reason,
      log: log,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboardCalls = <String>[];
  late Directory tmp;

  setUp(() async {
    clipboardCalls.clear();
    tmp = await Directory.systemTemp.createTemp('gesture_log_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboardCalls.add(call.method);
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('the file name', () {
    test('a plain .txt name that says what and when', () {
      final n = gestureLogFileName(_failure());
      expect(n, endsWith('.txt'));
      expect(n, isNot(contains(RegExp(r'[\s:/\\]'))));
      expect(n, contains('ecg'));
      expect(n, contains('20261004'));
    });

    test('a double-tap failure is named as one', () {
      expect(gestureLogFileName(_failure(kind: GestureFailureKind.doubleTap)),
          contains('double-tap'));
    });

    test('two failures a second apart do not share a name', () {
      final a = _failure();
      final b = GestureFailure(
        gestureId: 'other',
        at: _at.add(const Duration(seconds: 1)),
        kind: GestureFailureKind.ecg,
        reason: 'start_failed',
        log: '',
      );
      expect(gestureLogFileName(a), isNot(gestureLogFileName(b)));
    });
  });

  group('the text', () {
    test('a header that says what failed, then the log verbatim', () {
      final f = _failure();
      final text = gestureLogFileText(f);
      expect(text, contains('start_failed'));
      expect(text, contains('1791101224:14'));
      expect(text, contains('2026-10-04'));
      expect(text, contains('ECG'));
      expect(text.trimRight(), endsWith(f.log.trimRight()));
      expect(text.indexOf('start_failed'), lessThan(text.indexOf(f.log)),
          reason: 'the header comes first');
    });

    test('a double-tap failure says so', () {
      final text = gestureLogFileText(_failure(
          kind: GestureFailureKind.doubleTap, reason: 'log_water: no band'));
      expect(text, contains('log_water: no band'));
      expect(text, isNot(contains('ECG gesture')));
    });
  });

  group('saveGestureLog', () {
    test('writes the file and hands its path to the share flow, once',
        () async {
      final f = _failure();
      final shared = <String>[];
      final ok = await saveGestureLog(f, dir: tmp, share: (p) async {
        shared.add(p);
      });
      expect(ok, isTrue);
      expect(shared, hasLength(1));
      final file = File(shared.single);
      expect(file.parent.path, tmp.path);
      expect(file.uri.pathSegments.last, gestureLogFileName(f));
      expect(await file.readAsString(), gestureLogFileText(f));
    });

    test('shares only after the file exists on disk', () async {
      var existed = false;
      await saveGestureLog(_failure(), dir: tmp, share: (p) async {
        existed = File(p).existsSync() && File(p).lengthSync() > 0;
      });
      expect(existed, isTrue);
    });

    test('a share that throws is a false, not a throw', () async {
      final ok = await saveGestureLog(_failure(),
          dir: tmp, share: (p) async => throw StateError('no share sheet'));
      expect(ok, isFalse);
    });

    test('a directory that cannot be written is a false and shares nothing',
        () async {
      var shared = 0;
      final ok = await saveGestureLog(_failure(),
          dir: Directory('${tmp.path}/missing/deeper'),
          share: (p) async => shared++);
      expect(ok, isFalse);
      expect(shared, 0);
    });

    test('NEVER the clipboard', () async {
      await saveGestureLog(_failure(), dir: tmp, share: (p) async {});
      expect(clipboardCalls, isEmpty);
    });

    test('a long log is written whole', () async {
      final big = List.generate(2000, (i) => 'line $i').join('\n');
      final f = _failure(log: big);
      String? text;
      await saveGestureLog(f, dir: tmp, share: (p) async {
        text = await File(p).readAsString();
      });
      expect(text, contains('line 1999'));
    });
  });
}
