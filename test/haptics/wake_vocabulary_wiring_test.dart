// 8AF.6 D: the wiring and the words around wake on the vocabulary (the plans
// themselves are in wake_vocabulary_test.dart).
//
//  - Alarm > Wake says, in one caption, that wake buzzes are the band's
//    measured vocabulary (and so are not configurable): "Wake buzzes use the
//    band's measured vocabulary."
//  - AppState: natural wake, the legacy Smart Wake early fire and the gradual
//    steps go through the wake vocabulary; RUN_ALARM stays (gen4 and the
//    fallback). Source guards: AppState needs a whole engine.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';

import '../phase8/support/dart_source.dart';
import '../phase8/support/sections.dart';

const _caption = "Wake buzzes use the band's measured vocabulary.";

final _saved = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 1, hour: 7, minute: 0, enabled: true),
]);

AlarmScreenView _view() => AlarmScreenView(
      connected: true,
      schedule: _saved,
      now: DateTime(2026, 10, 5, 22, 0),
      state: AlarmArmState.none,
      hasExpectedSleep: true,
      onSave: (e) async =>
          const AlarmSaveOutcome(AlarmSaveStatus.sentToBand),
    );

void main() {
  group('Alarm > Wake caption', () {
    testWidgets('the Wake section says wake buzzes use the measured '
        'vocabulary', (t) async {
      await pumpTall(t, _view());
      await t.tap(find.byKey(const ValueKey('wake-day-1')));
      await t.pumpAndSettle();
      expect(
        find.descendant(of: section('Wake'), matching: find.text(_caption)),
        findsOneWidget,
      );
      expect(find.text(_caption), findsOneWidget, reason: 'said once');
    });
  });

  group('AppState wiring (source guards)', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();

    test('the wake haptic no longer asks for RUN_ALARM by kind alone', () {
      final body = codeOnly(bodyOf(src, 'Future<WakeHapticResult> _sendWakeHaptic('));
      expect(body, isNotEmpty);
      expect(body, isNot(contains('alarm: r.kind == WakeHapticKind.natural')),
          reason: 'natural wake plays the vocabulary plan on an MG; RUN_ALARM '
              'is gen4 and the fallback');
      expect(body, contains('WakeHaptics'));
    });

    test('the legacy Smart Wake early fire uses the same plan', () {
      final body = codeOnly(bodyOf(src, 'Future<void> _checkLegacySmartWake('));
      expect(body, isNotEmpty);
      expect(body, isNot(contains('alarm: true')));
    });

    test('RUN_ALARM is still there: the fallback and gen4', () {
      expect(codeOnly(src), contains('engine.runAlarm()'));
    });

    test('the wake plans are not stored patterns: nothing in the pattern '
        'store or its seeding names wake', () {
      final store = File('lib/haptics/pattern_store.dart').readAsStringSync();
      expect(codeOnly(store), isNot(contains('wake_haptics')));
      expect(File('lib/haptics/wake_haptics.dart').existsSync(), isTrue);
    });
  });
}
