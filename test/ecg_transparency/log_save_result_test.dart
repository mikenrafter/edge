// Design 04 phase 1 (RED) - item 5 / R7'': saveLogFileResult says WHY a log was
// not saved, and the existing saveLogFile stays the thin bool wrapper.
//
// ASSUMED API (lib/util/log_file.dart): sealed LogSaveResult = LogSaveOk |
// LogSaveFailed(reason); `saveLogFileResult(fileName, text, {origin, dir,
// share})` writes UTF-8 to <dir>/<fileName>, hands the path to [share], never
// throws; the reason carries the error's text; never the clipboard.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/log_file.dart';

import 'support/cardio_fixtures.dart' show codeOf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = <String>[];
  late Directory tmp;

  setUp(() async {
    clipboard.clear();
    tmp = await Directory.systemTemp.createTemp('log_save_result_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboard.add(call.method);
      return null;
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('ok: the file holds the text verbatim and the path was shared',
      () async {
    final shared = <String>[];
    final r = await saveLogFileResult(
      'openstrap-ecg-log-20261008-120000.txt',
      'id: A\nµV ✓\n',
      dir: tmp,
      share: (p) async => shared.add(p),
    );
    expect(r, isA<LogSaveOk>());
    final f = File('${tmp.path}/openstrap-ecg-log-20261008-120000.txt');
    expect(f.readAsStringSync(), 'id: A\nµV ✓\n');
    expect(shared, [f.path]);
    expect(clipboard, isEmpty);
  });

  test('a write that fails is failed(reason), not a throw, and nothing is '
      'shared', () async {
    final shared = <String>[];
    final r = await saveLogFileResult(
      'x.txt',
      'text',
      dir: Directory('${tmp.path}/does/not/exist'),
      share: (p) async => shared.add(p),
    );
    expect(r, isA<LogSaveFailed>());
    expect((r as LogSaveFailed).reason.trim(), isNotEmpty);
    expect(shared, isEmpty);
  });

  test('a share that fails is failed(reason) carrying the error text', () async {
    final r = await saveLogFileResult(
      'x.txt',
      'text',
      dir: tmp,
      share: (p) async => throw StateError('no share target'),
    );
    expect(r, isA<LogSaveFailed>());
    expect((r as LogSaveFailed).reason, contains('no share target'));
  });

  test('saveLogFile still answers true / false for the same two cases', () async {
    expect(
      await saveLogFile('a.txt', 't', dir: tmp, share: (p) async {}),
      isTrue,
    );
    expect(
      await saveLogFile('a.txt', 't', dir: tmp, share: (p) async => throw StateError('x')),
      isFalse,
    );
    expect(
      await saveLogFile('a.txt', 't',
          dir: Directory('${tmp.path}/nope/nope'), share: (p) async {}),
      isFalse,
    );
  });

  test('saveLogFile is a thin wrapper over saveLogFileResult (one write path)',
      () {
    final src = File('lib/util/log_file.dart').readAsStringSync();
    final i = src.indexOf('Future<bool> saveLogFile(');
    final body = src.substring(i, src.indexOf('\n}\n', i));
    expect(body.contains('saveLogFileResult('), isTrue);
    expect(body.contains('writeAsString'), isFalse);
  });


  group('saveLogChunksResult: written as it arrives (Sol r1)', () {
    test('the chunks are on disk one by one, in order, byte-exact; the path is '
        'shared once at the end', () async {
      final shared = <String>[];
      final gate = Completer<void>();
      final seen = <String>[];
      final file = File('${tmp.path}/c.txt');
      Stream<String> chunks() async* {
        yield 'header µV\n';
        // The first chunk is already in the file before the second exists.
        seen.add(file.readAsStringSync());
        await gate.future;
        yield 'second ✓\n';
      }

      final done = saveLogChunksResult('c.txt', chunks(), dir: tmp, share: (p) async => shared.add(p));
      await pumpEventQueue();
      gate.complete();
      final r = await done;
      expect(r, isA<LogSaveOk>());
      expect(seen, ['header µV\n']);
      expect(file.readAsStringSync(), 'header µV\nsecond ✓\n');
      expect(shared, [file.path]);
    });

    test('a stream that fails midway is failed(reason): nothing shared, no '
        'half-file left behind', () async {
      final shared = <String>[];
      Stream<String> chunks() async* {
        yield 'first\n';
        throw StateError('db went away');
      }

      final r = await saveLogChunksResult('p.txt', chunks(), dir: tmp, share: (p) async => shared.add(p));
      expect(r, isA<LogSaveFailed>());
      expect((r as LogSaveFailed).reason, contains('db went away'));
      expect(shared, isEmpty);
      expect(File('${tmp.path}/p.txt').existsSync(), isFalse);
    });

    test('saveLogFileResult is the same write path (one chunk)', () {
      final src = File('lib/util/log_file.dart').readAsStringSync();
      final i = src.indexOf('Future<LogSaveResult> saveLogFileResult(');
      final body = src.substring(i, src.indexOf('\n}\n', i));
      expect(body.contains('saveLogChunksResult('), isTrue);
    });
  });

  test('neither ECG export file touches the clipboard (invariant 16)', () {
    for (final f in ['lib/ecg/ecg_export.dart', 'lib/ui2/screens/ecg.dart', 'lib/util/log_file.dart']) {
      expect(codeOf(f).contains('Clipboard'), isFalse, reason: f);
    }
  });
}
