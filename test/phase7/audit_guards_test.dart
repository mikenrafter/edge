// Phase 7 audit — source guards for the rules the new code must keep:
// local day labels, no 86400 s days, one notification emitter, one band-buzz
// path, and flags that touch no network. Structural tests: they read lib/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../phase8/support/dart_source.dart';

/// Every file the controls/alerts/wake roadmap added.
const _newCode = [
  'lib/notify/alert_dispatcher.dart',
  'lib/notify/alert_rule.dart',
  'lib/notify/buzz_sequence.dart',
  'lib/notify/notification_relay.dart',
  'lib/gestures/tap_ack.dart',
  'lib/gestures/ecg_tap_counter.dart',
  'lib/gestures/ecg_tap_session.dart',
  'lib/gestures/ecg_stream_readiness.dart',
  'lib/gestures/double_tap_repeat.dart',
  'lib/gestures/gesture_dispatcher.dart',
  'lib/gestures/gesture_settings.dart',
  'lib/gestures/lab_log.dart',
  'lib/wake/wake_controller.dart',
  'lib/wake/natural_wake.dart',
  'lib/wake/wake_orchestrator.dart',
  'lib/wake/wake_stores.dart',
  'lib/wake/wake_settings.dart',
  'lib/wake/wake_trace_text.dart',
  'lib/state/alarm_draft.dart',
  'lib/state/live_stream_buffer.dart',
  'lib/state/feature_flags.dart',
  'lib/compute/sleep_blank.dart',
];

String _code(String path) => codeOnly(File(path).readAsStringSync());

void main() {
  group('day labels are local', () {
    test('no UTC-derived day label anywhere in lib/', () {
      final offenders = <String>[];
      final pattern = RegExp(
        r'toUtc\(\)[^;]*substring\(\s*0\s*,\s*10\s*\)|'
        r'toIso8601String\(\)\s*\.\s*(substring\(\s*0\s*,\s*10\s*\)|split)',
      );
      for (final f in dartFilesIn('lib')) {
        if (f.path.endsWith('lib/data/day_label.dart')) continue;
        // String interpolations count: a label is often built inside one.
        final code = [
          for (final l in f.readAsStringSync().split('\n'))
            l.trimLeft().startsWith('//') ? '' : l,
        ].join('\n');
        for (final m in pattern.allMatches(code)) {
          offenders.add('${f.path}:${lineOf(code, m.start)}');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('no 86400 s day in the new code (DST)', () {
    for (final path in _newCode) {
      test(path, () {
        final code = _code(path);
        for (final banned in [
          RegExp(r'\b86400\b'),
          RegExp(r'Duration\(\s*days\s*:'),
          RegExp(r'Duration\(\s*hours\s*:\s*24\b'),
          RegExp(r'24\s*\*\s*60\s*\*\s*60'),
        ]) {
          expect(banned.hasMatch(code), isFalse,
              reason: '$path matches ${banned.pattern}');
        }
      });
    }
  });

  group('one phone-notification emitter', () {
    test('presentEvent is called by NotificationCenter only', () {
      final offenders = <String>[];
      for (final f in dartFilesIn('lib')) {
        if (f.path.endsWith('lib/notify/notification_service.dart') ||
            f.path.endsWith('lib/notify/notification_center.dart')) {
          continue;
        }
        final code = _code(f.path);
        for (final m in RegExp(r'\.presentEvent\b').allMatches(code)) {
          offenders.add('${f.path}:${lineOf(code, m.start)}');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the only other direct NotificationService use that POSTS is the '
        'two-hour stillness nudge (an OS-scheduled slot, gated on its rule)',
        () {
      final offenders = <String>[];
      for (final f in dartFilesIn('lib')) {
        if (f.path.endsWith('lib/notify/notification_service.dart') ||
            f.path.endsWith('lib/notify/notification_center.dart')) {
          continue;
        }
        final code = _code(f.path);
        for (final m in RegExp(r'NotificationService\.instance\s*\.\s*'
                r'(scheduleOnce|schedule|show|post)\w*\(')
            .allMatches(code)) {
          offenders.add('${f.path}:${lineOf(code, m.start)}');
        }
      }
      expect(offenders.length, 1, reason: offenders.join('\n'));
      expect(offenders.single, startsWith('lib/state/app_state.dart'));
      final app = _code('lib/state/app_state.dart');
      final body = bodyOf(File('lib/state/app_state.dart').readAsStringSync(),
          'Future<void> _rescheduleStillnessNudge(');
      expect(body, contains("phoneDeliveryEnabled('movement')"));
      expect(app, contains('_rescheduleStillnessNudge'));
    });
  });

  group('every band buzz goes through AlertDispatcher', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    final code = codeOnly(src);

    test('each engine buzz call in AppState sits inside a dispatcher delivery '
        'or a constructor that hands it to one', () {
      final calls =
          RegExp(r'engine\.(buzz|buzzBand|runAlarm|buzzPattern)\(').allMatches(code);
      expect(calls, isNotEmpty);
      final openers = [
        RegExp(r'\bdispatch\('),
        RegExp(r'\bAlertDispatcher\('),
        RegExp(r'\bNotificationRelay\('),
        RegExp(r'\bWaterBuzzer\('),
        RegExp(r'\bMedBuzzer\('),
        RegExp(r'\b_userBuzz\('),
        RegExp(r'\bplayBuzzSequence\('),
      ];
      final offenders = <String>[];
      for (final m in calls) {
        final line = code.substring(
            code.lastIndexOf('\n', m.start) + 1, code.indexOf('\n', m.start));
        final before = code.lastIndexOf('\n', code.lastIndexOf('\n', m.start) - 1);
        final context = code.substring(before + 1, code.indexOf('\n', m.start));
        final named = context.contains('Future<bool> _bandBuzz');  // the two one-step transports
        final enclosed = openers.any((o) => enclosedByCall(code, m.start, o));
        if (!named && !enclosed) {
          offenders.add('app_state.dart:${lineOf(code, m.start)}  ${line.trim()}');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the user-facing test buzz, pattern test and find-my-strap use '
        '_userBuzz', () {
      for (final sig in const [
        'Future<void> testAlarmBuzz(',
        'Future<void> testBuzzPattern(',
        'Future<void> buzzBand(',
      ]) {
        final body = bodyOf(src, sig);
        expect(body, isNotEmpty, reason: sig);
        expect(body, contains('_userBuzz('), reason: sig);
      }
    });

    test('no other file in lib/ calls an engine buzz', () {
      final offenders = <String>[];
      for (final f in dartFilesIn('lib')) {
        if (f.path.endsWith('lib/ble/ble_engine.dart') ||
            f.path.endsWith('lib/state/app_state.dart')) {
          continue;
        }
        final c = _code(f.path);
        for (final m in RegExp(r'\b(engine|_engine|bleEngine)\s*\.\s*'
                r'(buzz|buzzBand|runAlarm|buzzPattern)\(')
            .allMatches(c)) {
          offenders.add('${f.path}:${lineOf(c, m.start)}');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('heavy compute stays off the UI isolate', () {
    test('the wake orchestrator reaches the stager only through its observer '
        'seam, whose default runs in Isolate.run', () {
      expect(_code('lib/wake/wake_orchestrator.dart'),
          contains('IsolateNaturalStageObserver()'));
      expect(_code('lib/wake/natural_wake.dart'), contains('Isolate.run('));
    });

    test('feature flags are read on the isolate that acts on them, never '
        'inside an Isolate.run closure', () {
      for (final path in _newCode) {
        final code = _code(path);
        for (final m in RegExp(r'Isolate\.run\(').allMatches(code)) {
          final close = closingOf(code, m.end - 1);
          final closure = code.substring(m.end, close < 0 ? code.length : close);
          expect(closure.contains('FeatureFlags'), isFalse,
              reason: '$path reads a flag inside an isolate closure');
        }
      }
    });
  });

  group('live streams stay RAM-only (invariant 14)', () {
    test('LiveStreamBuffer imports no storage', () {
      final src = File('lib/state/live_stream_buffer.dart').readAsStringSync();
      for (final banned in ['sqflite', 'db.dart', 'shared_preferences', 'dart:io']) {
        expect(src.contains(banned), isFalse, reason: banned);
      }
    });
  });
}
