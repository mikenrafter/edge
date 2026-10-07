// The general "Save log file" seam that replaces every "Copy log"
// button. A big log pasted from the clipboard locked up a second device, so the
// log leaves the phone as a .txt through the platform share sheet, the way the
// gesture-failure saver already does.
//
// ASSUMED API (NEW lib/util/log_file.dart):
//   * `typedef LogFileSaver = Future<bool> Function(String fileName, String text)`
//     how a screen saves a log; injectable so widgets are tested with a fake.
//   * `String logFileName(String kind, DateTime at)`:
//     `openstrap-<kind>-log-<yyyyMMdd-HHmmss>.txt`, in LOCAL time of [at].
//   * `Future<bool> saveLogFile(String fileName, String text, {Rect? origin,
//       Directory? dir, Future<void> Function(String path)? share})`: writes
//     [text] verbatim (UTF-8) to `<dir>/<fileName>` (default the temporary
//     directory) and hands the path to [share] (default share_plus, anchored at
//     [origin]). True when both worked; false, never a throw, otherwise. Never
//     the clipboard.
//   * `saveGestureLog` (lib/gestures/gesture_log_file.dart) keeps its
//     behaviour (test/log_save_file_test.dart still passes).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/log_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboardCalls = <String>[];
  late Directory tmp;

  setUp(() async {
    clipboardCalls.clear();
    tmp = await Directory.systemTemp.createTemp('log_file_');
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

  group('logFileName', () {
    test('openstrap-<kind>-log-<local yyyyMMdd-HHmmss>.txt', () {
      expect(logFileName('device-lab', DateTime(2026, 10, 4, 9, 5, 7)),
          'openstrap-device-lab-log-20261004-090507.txt');
      expect(logFileName('pattern-probe', DateTime(2026, 1, 2, 23, 59, 59)),
          'openstrap-pattern-probe-log-20260102-235959.txt');
    });

    test('a UTC time is named in local time', () {
      final utc = DateTime.utc(2026, 10, 4, 12, 7, 31);
      final l = utc.toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      expect(
          logFileName('device-lab', utc),
          'openstrap-device-lab-log-${l.year}${two(l.month)}${two(l.day)}-'
          '${two(l.hour)}${two(l.minute)}${two(l.second)}.txt');
    });

    test('no spaces, colons or path separators', () {
      expect(logFileName('device-lab', DateTime(2026, 10, 4, 9, 5, 7)),
          isNot(contains(RegExp(r'[\s:/\\]'))));
    });

    test('two logs a second apart do not share a name', () {
      final a = DateTime(2026, 10, 4, 9, 5, 7);
      expect(logFileName('device-lab', a),
          isNot(logFileName('device-lab', a.add(const Duration(seconds: 1)))));
    });

    test('a zip is named the same way with its own extension', () {
      expect(logFileName('dev', DateTime(2026, 10, 4, 9, 5, 7), ext: 'zip'),
          'openstrap-dev-log-20261004-090507.zip');
    });

    test('two kinds at the same second do not share a name', () {
      final a = DateTime(2026, 10, 4, 9, 5, 7);
      expect(logFileName('device-lab', a),
          isNot(logFileName('pattern-probe', a)));
    });
  });

  group('shareFileCopy', () {
    test('shares a copy in the temp dir and leaves the original alone',
        () async {
      final src = Directory('${tmp.path}/saved')..createSync();
      final temp = Directory('${tmp.path}/temp')..createSync();
      final f = File('${src.path}/rec.jsonl')..writeAsStringSync('abc');
      final shared = <String>[];
      final ok = await shareFileCopy(f.path,
          tempDir: temp, share: (p) async => shared.add(p));
      expect(ok, isTrue);
      expect(shared.single, '${temp.path}/rec.jsonl');
      expect(File(shared.single).readAsStringSync(), 'abc');
      expect(f.readAsStringSync(), 'abc');
    });

    test('a file already in the temp dir is shared as is, never copied onto '
        'itself (that truncates it to 0 bytes)', () async {
      final f = File('${tmp.path}/export.zip')..writeAsStringSync('payload');
      final shared = <String>[];
      final ok = await shareFileCopy(f.path,
          tempDir: tmp,
          mimeType: 'application/zip',
          share: (p) async => shared.add(p));
      expect(ok, isTrue);
      expect(shared.single, f.path);
      expect(f.readAsStringSync(), 'payload');
    });

    test('false, not a throw, when the file is missing or the share fails',
        () async {
      final temp = Directory('${tmp.path}/temp')..createSync();
      expect(
          await shareFileCopy('${tmp.path}/nope',
              tempDir: temp, share: (p) async {}),
          isFalse);
      final f = File('${tmp.path}/a.txt')..writeAsStringSync('x');
      expect(
          await shareFileCopy(f.path,
              tempDir: tmp, share: (p) async => throw StateError('no sheet')),
          isFalse);
      expect(f.readAsStringSync(), 'x');
    });
  });

  group('saveLogFile', () {
    test('writes the text verbatim and hands the path to the share flow, once',
        () async {
      const text = 'OpenStrap Device lab log\n'
          'line with ünïcode ≈ and a tab\t\n'
          '\n'
          'trailing spaces   \n';
      final shared = <String>[];
      final ok = await saveLogFile(
        'openstrap-device-lab-log-20261004-090507.txt',
        text,
        dir: tmp,
        share: (p) async => shared.add(p),
      );
      expect(ok, isTrue);
      expect(shared, hasLength(1));
      final file = File(shared.single);
      expect(file.parent.path, tmp.path);
      expect(file.uri.pathSegments.last,
          'openstrap-device-lab-log-20261004-090507.txt');
      expect(await file.readAsString(), text,
          reason: 'no header, no trimming, no truncation');
      expect(clipboardCalls, isEmpty, reason: 'never the clipboard');
    });

    test('a very large log is written whole (the reason for the change)',
        () async {
      final big = List.generate(40000, (i) => 'line $i | ${'x' * 40}').join('\n');
      final shared = <String>[];
      expect(
          await saveLogFile('big.txt', big,
              dir: tmp, share: (p) async => shared.add(p)),
          isTrue);
      expect(await File(shared.single).readAsString(), big);
      expect(clipboardCalls, isEmpty);
    });

    test('false, not a throw, when the share flow fails', () async {
      final ok = await saveLogFile('a.txt', 'x',
          dir: tmp, share: (p) async => throw StateError('no share sheet'));
      expect(ok, isFalse);
    });

    test('false, not a throw, when the file cannot be written', () async {
      final gone = Directory('${tmp.path}/does/not/exist');
      var shared = false;
      final ok = await saveLogFile('a.txt', 'x',
          dir: gone, share: (p) async => shared = true);
      expect(ok, isFalse);
      expect(shared, isFalse, reason: 'nothing to share');
    });

    test('is assignable to the LogFileSaver seam', () {
      // Compile-time pin: a screen can take saveLogFile's shape as its saver.
      Future<bool> saver(String n, String t) => saveLogFile(n, t);
      expect(saver, isA<LogFileSaver>());
    });
  });
}
