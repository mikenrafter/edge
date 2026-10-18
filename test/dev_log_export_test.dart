// Exporting the dev log (lib/sync/dev_log_export.dart): one ZIP with every dev
// log day file, the legacy sync log when it is still there, and the recent
// wake trace; handed to the share flow without ever copying a file onto itself.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/dev_log.dart';
import 'package:openstrap_edge/sync/dev_log_export.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

const _trace = [
  WakeTraceEntry(
      wakeEpochSec: 1000, atMs: 1700000000000, kind: 'plan', data: {'a': 1}),
  WakeTraceEntry(
      wakeEpochSec: 1000,
      atMs: 1700000001000,
      kind: 'natural',
      data: {'reason': 'fire'}),
];

Future<List<WakeTraceEntry>> _wakeTrace() async => _trace;

Map<String, List<int>> _unzip(List<int> bytes) => {
      for (final f in ZipDecoder().decodeBytes(bytes).files)
        if (f.isFile) f.name: f.content as List<int>,
    };

void main() {
  late Directory base;
  late Directory out;
  final now = DateTime(2026, 10, 6, 12, 7, 31);

  Future<DevLog> seeded() async {
    final log = DevLog(
      baseDir: () async => base,
      now: () => now,
      devMode: () async => true,
    );
    await log.add('[alarm] armed');
    await log.add('plain line');
    await log.flush();
    File('${base.path}/dev_log/dev-2026-10-05.log')
        .writeAsStringSync('yesterday\n');
    return log;
  }

  setUp(() async {
    base = await Directory.systemTemp.createTemp('dev_log_export_');
    out = await Directory.systemTemp.createTemp('dev_log_export_out_');
  });
  tearDown(() async {
    for (final d in [base, out]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  test('the zip holds every day file, the legacy log and the wake trace',
      () async {
    final log = await seeded();
    File('${base.path}/openstrap_sync.log').writeAsStringSync('legacy\n');
    File('${base.path}/openstrap_sync.log.1').writeAsStringSync('legacy 1\n');
    File('${base.path}/unrelated.txt').writeAsStringSync('no');

    final zip = await exportDevLogZip(log, outDir: out, now: now,
        wakeTrace: _wakeTrace);
    expect(zip.path, '${out.path}/openstrap-dev-log-20261006-120731.zip');
    final files = _unzip(zip.readAsBytesSync());
    expect(files.keys.toSet(), {
      'dev_log/dev-2026-10-05.log',
      'dev_log/dev-2026-10-06.log',
      'openstrap_sync.log',
      'openstrap_sync.log.1',
      'wake_trace.json',
    });
    expect(utf8.decode(files['dev_log/dev-2026-10-05.log']!), 'yesterday\n');
    expect(utf8.decode(files['dev_log/dev-2026-10-06.log']!),
        contains('[alarm] armed'));
    expect(utf8.decode(files['openstrap_sync.log']!), 'legacy\n');
    final trace = jsonDecode(utf8.decode(files['wake_trace.json']!)) as List;
    expect(trace, hasLength(2));
    expect(trace.first['kind'], 'plan');
    expect(trace.first['wake_epoch'], 1000);
    expect(trace.first['at_ms'], 1700000000000);
    expect(trace.first['at'], isA<String>());
    expect(trace.first['data'], {'a': 1});
    expect(trace.last['data'], {'reason': 'fire'});
  });

  test('legacy files are left out when they are not there, and an empty log '
      'still exports', () async {
    final log = DevLog(
        baseDir: () async => base, now: () => now, devMode: () async => true);
    final zip = await exportDevLogZip(log,
        outDir: out, now: now, wakeTrace: () async => const []);
    final files = _unzip(zip.readAsBytesSync());
    expect(files.keys.toSet(), {'wake_trace.json'});
    expect(utf8.decode(files['wake_trace.json']!).trim(), '[]');
  });

  test('a wake trace that cannot be read is said so in the zip, and the logs '
      'still export', () async {
    final log = await seeded();
    final zip = await exportDevLogZip(log,
        outDir: out,
        now: now,
        wakeTrace: () async => throw StateError('db closed'));
    final files = _unzip(zip.readAsBytesSync());
    expect(files, contains('dev_log/dev-2026-10-06.log'));
    expect(utf8.decode(files['wake_trace.json']!), contains('db closed'));
  });

  test('exporting leaves the logs untouched and keeps them writable',
      () async {
    final log = await seeded();
    final before =
        File('${base.path}/dev_log/dev-2026-10-06.log').readAsStringSync();
    await exportDevLogZip(log, outDir: out, now: now, wakeTrace: _wakeTrace);
    expect(File('${base.path}/dev_log/dev-2026-10-06.log').readAsStringSync(),
        before);
    await log.add('after export');
    await log.flush();
    expect(File('${base.path}/dev_log/dev-2026-10-06.log').readAsStringSync(),
        contains('after export'));
  });

  group('shareDevLog', () {
    test('shares the zip that was written into the temp dir as is: not '
        'copied onto itself, not truncated', () async {
      final log = await seeded();
      final shared = <String>[];
      List<int>? bytesAtShare;
      final ok = await shareDevLog(
        log,
        tempDir: out,
        now: now,
        wakeTrace: _wakeTrace,
        share: (p) async {
          shared.add(p);
          bytesAtShare = File(p).readAsBytesSync();
        },
      );
      expect(ok, isTrue);
      expect(shared.single, '${out.path}/openstrap-dev-log-20261006-120731.zip');
      expect(bytesAtShare, isNotEmpty);
      expect(_unzip(bytesAtShare!), contains('dev_log/dev-2026-10-06.log'));
    });

    test('false, not a throw, when the share fails or the export does',
        () async {
      final log = await seeded();
      expect(
          await shareDevLog(log,
              tempDir: out,
              now: now,
              wakeTrace: _wakeTrace,
              share: (p) async => throw StateError('no sheet')),
          isFalse);
      expect(
          await shareDevLog(log,
              tempDir: Directory('${out.path}/missing'),
              now: now,
              wakeTrace: _wakeTrace,
              share: (p) async {}),
          isFalse);
    });
  });
}
