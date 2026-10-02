// What the Device lab remembers and how it reads back: every line carries its
// wall time to the millisecond, the time since the session's tap and the time
// since the previous line; sessions end with a one-line summary; the whole log
// copies out as plain text. RAM only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';

DateTime _at(int ms) => DateTime(2026, 10, 2, 9, 15, 3, 250).add(Duration(milliseconds: ms));

void main() {
  group('line format', () {
    test('wall time with ms, time since the tap, time since the last line', () {
      final log = DeviceLabLog();
      log.beginSession(
        method: 'ECG sensor touches',
        settings: 'start 300 ms, gap 200 ms, confirm 200 ms',
        tapAt: _at(0),
        at: _at(0),
      );
      log.addStep('Double tap received.', at: _at(10));
      log.addStep('ECG stream command written.', at: _at(1210));
      expect(log.steps.first,
          '09:15:04.460 | tap +1210 ms | last +1200 ms | ECG stream command written.');
      expect(log.steps[1],
          '09:15:03.260 | tap +10 ms | last +10 ms | Double tap received.');
    });

    test('lines outside a session say so instead of inventing a tap time', () {
      final log = DeviceLabLog();
      log.addStep('No wrist remembered.', at: _at(0));
      log.addStep('Again.', at: _at(500));
      expect(log.steps.last, endsWith('| tap n/a | last +0 ms | No wrist remembered.'));
      expect(log.steps.first, contains('| tap n/a | last +500 ms | Again.'));
    });

    test('a new session restarts the tap clock', () {
      final log = DeviceLabLog();
      log.beginSession(method: 'a', settings: 's', tapAt: _at(0), at: _at(0));
      log.addStep('one', at: _at(100));
      log.endSession(count: 2, at: _at(200));
      log.beginSession(method: 'b', settings: 's', tapAt: _at(10000), at: _at(10000));
      log.addStep('two', at: _at(10050));
      expect(log.steps.first, contains('| tap +50 ms |'));
    });

    test('the tap can have been received before the session began', () {
      final log = DeviceLabLog();
      log.beginSession(
          method: 'a', settings: 's', tapAt: _at(0), at: _at(300));
      log.addStep('x', at: _at(400));
      expect(log.steps.first, contains('| tap +400 ms |'));
    });
  });

  group('session summary', () {
    test('a counted session: method, settings, count and total time', () {
      final log = DeviceLabLog();
      log.beginSession(
        method: 'ECG sensor touches',
        settings: 'start 300 ms, gap 200 ms, confirm 200 ms',
        tapAt: _at(0),
        at: _at(0),
      );
      log.endSession(count: 3, at: _at(6400));
      expect(
        log.sessionSummaries.single,
        'ECG sensor touches | start 300 ms, gap 200 ms, confirm 200 ms | '
        '3 taps | 6.4 s in total',
      );
    });

    test('an abandoned session says why', () {
      final log = DeviceLabLog();
      log.beginSession(
          method: 'More double taps', settings: 'window 2500 ms', tapAt: _at(0), at: _at(0));
      log.endSession(reason: 'no_stream', at: _at(20100));
      expect(
        log.sessionSummaries.single,
        'More double taps | window 2500 ms | abandoned (no_stream) | '
        '20.1 s in total',
      );
    });

    test('the end is also a line in the log', () {
      final log = DeviceLabLog();
      log.beginSession(method: 'm', settings: 's', tapAt: _at(0), at: _at(0));
      log.endSession(count: 2, at: _at(2500));
      expect(log.steps.first, contains('Session ended: m | s | 2 taps'));
      expect(log.steps.first, contains('| tap +2500 ms |'));
    });

    test('ending twice, or with no session, adds nothing', () {
      final log = DeviceLabLog();
      log.endSession(count: 2, at: _at(0));
      expect(log.sessionSummaries, isEmpty);
      log.beginSession(method: 'm', settings: 's', tapAt: _at(0), at: _at(0));
      log.endSession(count: 2, at: _at(100));
      log.endSession(count: 3, at: _at(200));
      expect(log.sessionSummaries, hasLength(1));
    });
  });

  group('tracing window (for late band replies)', () {
    test('open during a session and for 5 s after it', () {
      final log = DeviceLabLog();
      expect(log.tracingAt(_at(0)), isFalse);
      log.beginSession(method: 'm', settings: 's', tapAt: _at(0), at: _at(0));
      expect(log.tracingAt(_at(50000)), isTrue);
      log.endSession(count: 2, at: _at(1000));
      expect(log.tracingAt(_at(5999)), isTrue);
      expect(log.tracingAt(_at(6001)), isFalse);
    });
  });

  group('plain text for copying', () {
    test('header, sessions, the log oldest first, then band events', () {
      final log = DeviceLabLog();
      log.beginSession(method: 'm', settings: 's', tapAt: _at(0), at: _at(0));
      log.addStep('first', at: _at(10));
      log.addStep('second', at: _at(20));
      log.endSession(count: 2, at: _at(30));
      log.addEntry(DeviceLabEntry(
        eventId: 14,
        eventTime: _at(-1000),
        receivedAt: _at(0),
        live: true,
        actions: const ['log_water'],
      ));
      final text = log.toPlainText(at: _at(40000));
      final i = [
        'OpenStrap Device lab log',
        'Sessions',
        'm | s | 2 taps',
        'Log, oldest first',
        '| first',
        '| second',
        'Band events',
        'Event 14 | Live',
      ].map(text.indexOf).toList();
      expect(i, everyElement(isNonNegative), reason: text);
      expect(i, [...i]..sort(), reason: text);
      expect(text, contains('Ran log_water'));
      expect(text, endsWith('\n'));
    });

    test('an empty log still copies something readable', () {
      final text = DeviceLabLog().toPlainText(at: _at(0));
      expect(text, contains('No sessions yet'));
      expect(text, contains('No log lines yet'));
      expect(text, contains('No band events yet'));
    });
  });

  group('bounds', () {
    test('old lines fall off the end; clear empties everything', () {
      final log = DeviceLabLog();
      for (var i = 0; i < DeviceLabLog.maxSteps + 20; i++) {
        log.addStep('line $i', at: _at(i));
      }
      expect(log.steps, hasLength(DeviceLabLog.maxSteps));
      expect(log.steps.first, endsWith('line ${DeviceLabLog.maxSteps + 19}'));
      log.clear();
      expect(log.steps, isEmpty);
      expect(log.sessionSummaries, isEmpty);
    });

    test('room for a full 20 s session at one packet line per second', () {
      expect(DeviceLabLog.maxSteps, greaterThanOrEqualTo(300));
    });
  });

  test('the log stays in memory: no database, no preferences, no files', () {
    final src = File('lib/gestures/lab_log.dart').readAsStringSync();
    for (final banned in ['data/db.dart', 'shared_preferences', 'dart:io']) {
      expect(src, isNot(contains(banned)));
    }
  });
}
