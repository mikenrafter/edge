// The persistent dev log (lib/sync/dev_log.dart): one timestamped, source-tagged
// line per write, one file per LOCAL day, a week of history, a size backstop,
// alarm/wake/sync lines always kept and everything else only in developer mode,
// and whole lines when two isolates write the same file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/dev_log.dart';

final _lineRe = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} \[[a-z]+\] ');

void main() {
  late Directory base;
  var clockNow = DateTime(2026, 10, 6, 12, 0, 0, 123);
  var dev = false;

  DevLog make({int maxBytes = kDevLogMaxBytes, int sizeCheckEvery = 1}) =>
      DevLog(
        baseDir: () async => base,
        now: () => clockNow,
        devMode: () async => dev,
        maxBytes: maxBytes,
        sizeCheckEvery: sizeCheckEvery,
      );

  Directory dir() => Directory('${base.path}/dev_log');
  String read(String day) => File('${dir().path}/dev-$day.log').readAsStringSync();
  List<String> names() =>
      dir().existsSync()
          ? (dir().listSync().map((e) => e.uri.pathSegments.last).toList()
            ..sort())
          : [];
  // Lines other than the per-file "opened" header.
  List<String> lines(String day) => read(day)
      .split('\n')
      .where((l) => l.isNotEmpty && !l.contains('[devlog] opened'))
      .toList();

  setUp(() async {
    base = await Directory.systemTemp.createTemp('dev_log_');
    clockNow = DateTime(2026, 10, 6, 12, 0, 0, 123);
    dev = false;
  });
  tearDown(() async {
    if (await base.exists()) await base.delete(recursive: true);
  });

  group('format', () {
    test('offset is +HH:MM / -HH:MM, with half-hour zones', () {
      expect(devLogOffset(Duration.zero), '+00:00');
      expect(devLogOffset(const Duration(hours: 2)), '+02:00');
      expect(devLogOffset(const Duration(hours: 5, minutes: 30)), '+05:30');
      expect(devLogOffset(const Duration(hours: -3, minutes: -30)), '-03:30');
      expect(devLogOffset(const Duration(hours: -8)), '-08:00');
    });

    test('a line is local ISO time to the millisecond, the source, the text',
        () {
      final at = DateTime(2026, 10, 6, 7, 5, 9, 4);
      final off = devLogOffset(at.timeZoneOffset);
      expect(devLogLine(at, 'ui', '[alarm] armed'),
          '2026-10-06T07:05:09.004$off [ui] [alarm] armed');
    });

    test('a UTC instant is written in local time', () {
      final utc = DateTime.utc(2026, 10, 6, 7, 5, 9, 4);
      final l = utc.toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      expect(devLogLine(utc, 'ui', 'x'),
          startsWith('${l.year}-${two(l.month)}-${two(l.day)}T${two(l.hour)}:'));
    });
  });

  group('sanitize', () {
    test('one record is one line: newlines and tabs are escaped', () {
      expect(sanitizeDevLogText('a\nb\r\nc\td'), r'a\nb\r\nc d');
    });

    test('other control characters become visible escapes', () {
      expect(sanitizeDevLogText('a\u0000b\u001bc\u007fd'),
          r'a\x00b\x1bc\x7fd');
    });

    test('a lone surrogate (what encodes to invalid UTF-8) becomes U+FFFD, a '
        'real pair and plain unicode are kept', () {
      expect(sanitizeDevLogText('a\ud800b'), 'a�b');
      expect(sanitizeDevLogText('a\udc00'), 'a�');
      expect(sanitizeDevLogText('ünï ≈ 😀'), 'ünï ≈ 😀');
    });

    test('a very long message is cut and says by how much', () {
      final out = sanitizeDevLogText('x' * 5000);
      expect(out.length, lessThan(2100));
      expect(out, contains('…'));
      expect(out, contains('+'));
    });

    test('cutting never splits a surrogate pair', () {
      final out = sanitizeDevLogText('😀' * 5000);
      expect(out.contains('�'), isFalse);
    });
  });

  group('always-on lines', () {
    test('alarm, wake and sync prefixes, any case', () {
      for (final l in [
        '[alarm] armed',
        '[wake] tick',
        '[smart-wake] early buzz',
        '[bgsync] drain',
        '[sync] partial',
        '[SYNC] HighFreq enter',
        '[keepalive] resumed',
        '[bgsync] [alarm] headless arm',
      ]) {
        expect(isAlwaysOnLogLine(l), isTrue, reason: l);
      }
    });

    test('an unprefixed line that is about the alarm is always on too', () {
      expect(isAlwaysOnLogLine('SET_ALARM_TIME accepted'), isTrue);
      expect(isAlwaysOnLogLine('Alarm rejected by band'), isTrue);
    });

    test('everything else is developer-mode only', () {
      for (final l in [
        'Link priority → high.',
        '[derive] day done',
        '[workout] started',
        '[notify] sent',
        '',
      ]) {
        expect(isAlwaysOnLogLine(l), isFalse, reason: l);
      }
    });

    test('filtering: developer mode off keeps only the always-on lines', () async {
      final log = make();
      await log.add('[alarm] armed epoch=1');
      await log.add('Link priority → high.');
      await log.add('[derive] day done');
      await log.add('[bgsync] [alarm] headless arm');
      await log.flush();
      expect(lines('2026-10-06'), hasLength(2));
      expect(read('2026-10-06'), contains('[alarm] armed epoch=1'));
      expect(read('2026-10-06'), contains('[bgsync] [alarm] headless arm'));
      expect(read('2026-10-06'), isNot(contains('[derive]')));
      expect(read('2026-10-06'), isNot(contains('Link priority')));
      dev = true;
      await log.add('Link priority → high.');
      await log.add('[derive] day done');
      await log.flush();
      expect(read('2026-10-06'), contains('Link priority'));
      expect(read('2026-10-06'), contains('[derive] day done'));
    });

    test('an explicit always: overrides the prefix either way', () async {
      final log = make();
      await log.add('[bgsync] chatty drain line', always: false);
      await log.add('plain but vital', always: true);
      await log.flush();
      final text = read('2026-10-06');
      expect(text, isNot(contains('chatty')));
      expect(text, contains('plain but vital'));
    });

    test('developer mode off and nothing always-on writes no file at all',
        () async {
      final log = make();
      await log.add('Link priority → high.');
      await log.flush();
      expect(names(), isEmpty);
    });
  });

  group('files', () {
    test('lines carry the timestamp and the source; a per-line source wins',
        () async {
      dev = true;
      final log = DevLog(
          baseDir: () async => base,
          now: () => clockNow,
          devMode: () async => dev,
          source: 'ui');
      await log.add('one');
      await log.add('two', source: 'headless');
      await log.flush();
      final l = lines('2026-10-06');
      expect(l, hasLength(2));
      expect(l[0], matches(_lineRe));
      expect(l[0], contains('.123'));
      expect(l[0], endsWith(' [ui] one'));
      expect(l[1], endsWith(' [headless] two'));
    });

    test('a file opens with one header naming the source and process',
        () async {
      dev = true;
      final log = make();
      await log.add('one');
      await log.add('two');
      await log.flush();
      final headers = read('2026-10-06')
          .split('\n')
          .where((l) => l.contains('[devlog] opened'));
      expect(headers, hasLength(1));
      expect(headers.single, contains('pid=$pid'));
    });

    test('one file per local day, named by the local day, across midnight',
        () async {
      dev = true;
      final log = make();
      clockNow = DateTime(2026, 10, 6, 23, 59, 59, 900);
      await log.add('before midnight');
      clockNow = DateTime(2026, 10, 7, 0, 0, 0, 100);
      await log.add('after midnight');
      await log.flush();
      expect(names(), ['dev-2026-10-06.log', 'dev-2026-10-07.log']);
      expect(read('2026-10-06'), contains('before midnight'));
      expect(read('2026-10-06'), isNot(contains('after midnight')));
      expect(read('2026-10-07'), contains('after midnight'));
      expect(read('2026-10-07'), contains('2026-10-07T00:00:00.100'));
      expect(read('2026-10-07'), contains('[devlog] opened'),
          reason: 'each day file stands on its own');
    });

    test('file names parse back to their day, and only theirs', () {
      expect(devLogFileName(DateTime(2026, 3, 8, 23, 59)), 'dev-2026-03-08.log');
      expect(devLogDayOf('dev-2026-03-08.log'), '2026-03-08');
      expect(devLogDayOf('dev-2026-03-08.log.1'), isNull);
      expect(devLogDayOf('openstrap_sync.log'), isNull);
      expect(devLogDayOf('dev-latest.log'), isNull);
    });

    test('lines written in a row stay in order', () async {
      dev = true;
      final log = make();
      for (var i = 0; i < 100; i++) {
        log.add('n=$i'); // deliberately not awaited
      }
      await log.flush();
      expect([for (final l in lines('2026-10-06')) l.split('n=').last],
          [for (var i = 0; i < 100; i++) '$i']);
    });

    test('a garbled message never leaves a broken line behind', () async {
      dev = true;
      final log = make();
      await log.add('bad \ud800 surrogate\nsecond line\u0000');
      await log.flush();
      final bytes = File('${dir().path}/dev-2026-10-06.log').readAsBytesSync();
      final text = const Utf8Decoder(allowMalformed: false).convert(bytes);
      expect(text.split('\n').where((l) => l.isNotEmpty), hasLength(2),
          reason: 'header plus exactly one record');
    });

    test('Clear removes every day file and the legacy sync log', () async {
      dev = true;
      final log = make();
      await log.add('one');
      File('${base.path}/openstrap_sync.log').writeAsStringSync('old');
      File('${base.path}/openstrap_sync.log.1').writeAsStringSync('older');
      File('${base.path}/unrelated.txt').writeAsStringSync('keep');
      await log.flush();
      await log.clear();
      expect(names(), isEmpty);
      expect(File('${base.path}/openstrap_sync.log').existsSync(), isFalse);
      expect(File('${base.path}/openstrap_sync.log.1').existsSync(), isFalse);
      expect(File('${base.path}/unrelated.txt').existsSync(), isTrue);
      await log.add('after clear');
      await log.flush();
      expect(read('2026-10-06'), contains('after clear'));
      expect(read('2026-10-06'), contains('[devlog] opened'),
          reason: 'the new file says where it starts');
    });
  });

  group('retention', () {
    test('the oldest kept day is six days before today (a week with today)',
        () {
      expect(devLogOldestKeptDay(DateTime(2026, 10, 6, 12)), '2026-09-30');
      expect(devLogOldestKeptDay(DateTime(2026, 3, 1, 0, 5)), '2026-02-23');
    });

    test('calendar arithmetic, not 24 h steps: the spring-forward and '
        'fall-back weeks keep exactly seven labels', () {
      // Run under TZ=America/New_York this crosses the real transitions; under
      // UTC it pins the same labels.
      expect(devLogOldestKeptDay(DateTime(2026, 3, 9, 0, 30)), '2026-03-03');
      expect(devLogOldestKeptDay(DateTime(2026, 3, 8, 23, 30)), '2026-03-02');
      expect(devLogOldestKeptDay(DateTime(2026, 11, 2, 0, 30)), '2026-10-27');
      expect(devLogOldestKeptDay(DateTime(2026, 11, 1, 23, 30)), '2026-10-26');
    });

    test('older day files are deleted on the first write; seven days stay',
        () async {
      dev = true;
      dir().createSync(recursive: true);
      for (final d in [
        '2026-09-28',
        '2026-09-29',
        '2026-09-30',
        '2026-10-03',
        '2026-10-05',
      ]) {
        File('${dir().path}/dev-$d.log').writeAsStringSync('old $d\n');
      }
      File('${dir().path}/notes.txt').writeAsStringSync('not ours');
      final log = make(sizeCheckEvery: 1000);
      await log.add('today');
      await log.flush();
      expect(names(), [
        'dev-2026-09-30.log',
        'dev-2026-10-03.log',
        'dev-2026-10-05.log',
        'dev-2026-10-06.log',
        'notes.txt',
      ]);
    });

    test('pruning runs again when the day changes, not on every write',
        () async {
      dev = true;
      dir().createSync(recursive: true);
      File('${dir().path}/dev-2026-09-30.log').writeAsStringSync('x\n');
      final log = make(sizeCheckEvery: 1000);
      await log.add('today');
      await log.flush();
      expect(names(), contains('dev-2026-09-30.log'));
      clockNow = DateTime(2026, 10, 7, 0, 1);
      await log.add('tomorrow');
      await log.flush();
      expect(names(), isNot(contains('dev-2026-09-30.log')));
    });
  });

  group('size cap', () {
    String blob(int n) => 'x' * n;

    test('over the cap, the oldest day goes first and today stays', () async {
      dev = true;
      dir().createSync(recursive: true);
      File('${dir().path}/dev-2026-10-04.log').writeAsStringSync(blob(600));
      File('${dir().path}/dev-2026-10-05.log').writeAsStringSync(blob(600));
      final log = make(maxBytes: 1000);
      await log.add('today');
      await log.flush();
      expect(names(), ['dev-2026-10-05.log', 'dev-2026-10-06.log']);
    });

    test('a runaway day stops at the cap instead of growing without end',
        () async {
      dev = true;
      final log = make(maxBytes: 1000);
      for (var i = 0; i < 60; i++) {
        await log.add('line $i ${blob(80)}');
      }
      await log.flush();
      final size = File('${dir().path}/dev-2026-10-06.log').lengthSync();
      expect(size, lessThan(1000 + 400));
      expect(read('2026-10-06'), contains('size cap'));
      final before = size;
      for (var i = 0; i < 20; i++) {
        await log.add('more $i ${blob(80)}');
      }
      await log.flush();
      expect(File('${dir().path}/dev-2026-10-06.log').lengthSync(), before);
    });

    test('past the cap, alarm and wake lines are still written', () async {
      dev = true;
      final log = make(maxBytes: 1000);
      for (var i = 0; i < 60; i++) {
        await log.add('line $i ${blob(80)}');
      }
      await log.add('more 0 ${blob(80)}');
      await log.add('[alarm] arm pass: wrote 07:00');
      await log.add('more 1 ${blob(80)}');
      await log.flush();
      final text = read('2026-10-06');
      expect(text, contains('[alarm] arm pass: wrote 07:00'));
      expect(text, isNot(contains('more 0')));
      expect(text, isNot(contains('more 1')));
      expect('size cap'.allMatches(text), hasLength(1),
          reason: 'the drop notice is written once, not after each alarm line');
    });

    test('a new day starts writing again once the old day is aged out',
        () async {
      dev = true;
      final log = make(maxBytes: 1000);
      for (var i = 0; i < 30; i++) {
        await log.add('line $i ${blob(80)}');
      }
      clockNow = DateTime(2026, 10, 7, 0, 5);
      await log.add('next day');
      await log.flush();
      expect(read('2026-10-07'), contains('next day'));
    });
  });

  group('two isolates', () {
    test('a lock left by a writer that died is taken over, not waited on '
        'forever', () async {
      dev = true;
      dir().createSync(recursive: true);
      File('${dir().path}/.append.lock').createSync();
      final log = DevLog(
        baseDir: () async => base,
        now: () => clockNow,
        devMode: () async => dev,
        lockWait: const Duration(milliseconds: 30),
      );
      await log.add('after a crash');
      await log.flush();
      expect(read('2026-10-06'), contains('after a crash'));
      expect(File('${dir().path}/.append.lock').existsSync(), isFalse,
          reason: 'released after the write');
    });

    test('whole lines from the UI isolate and another one, none torn',
        () async {
      const perWriter = 150;
      final path = base.path;
      final other = Isolate.run(() async {
        final log = DevLog(
          baseDir: () async => Directory(path),
          now: DateTime.now,
          devMode: () async => true,
          source: 'headless',
          sizeCheckEvery: 1000,
        );
        for (var i = 0; i < perWriter; i++) {
          log.add('id=h$i ${'ß≈' * 120}');
        }
        await log.flush();
      });
      dev = true;
      final mine = DevLog(
        baseDir: () async => base,
        now: DateTime.now,
        devMode: () async => true,
        source: 'ui',
        sizeCheckEvery: 1000,
      );
      for (var i = 0; i < perWriter; i++) {
        mine.add('id=u$i ${'ß≈' * 120}');
      }
      await mine.flush();
      await other;

      final files = dir().listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      final text = const Utf8Decoder(allowMalformed: false)
          .convert(files.single.readAsBytesSync());
      final seen = <String>{};
      for (final l in text.split('\n').where((l) => l.isNotEmpty)) {
        if (l.contains('[devlog] opened')) continue;
        final m = RegExp(r'^(\S+) \[(ui|headless)\] id=([uh]\d+) ((?:ß≈){120})$')
            .firstMatch(l);
        expect(m, isNotNull, reason: 'torn line: $l');
        expect(m!.group(2) == 'ui', m.group(3)!.startsWith('u'));
        seen.add(m.group(3)!);
      }
      expect(seen, hasLength(2 * perWriter));
    });
  });
}
