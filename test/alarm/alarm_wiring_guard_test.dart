// 8O — wiring guards. The write budget is proven by alarm_band_writes_test.dart
// on the pure Save path; these pin that the REAL screen and AppState reach it
// the one way they should, and that the WakeController setters cannot write the
// band.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

import '../phase8/support/dart_source.dart';

final _app = File('lib/state/app_state.dart').readAsStringSync();

String _app_(String signature) => codeOnly(bodyOf(_app, signature));

/// Anything that could put an alarm on the band (word-bounded, so the DB
/// call `setAlarmScheduleRows` is not mistaken for `setAlarm(`).
final _bandWrite = RegExp(
  r'[\s\S]*(\bengine\b|\bsetAlarm\s*\(|\bdisableAlarm\s*\(|'
  r'_armNextAlarmOccurrence|_onArmed)[\s\S]*',
);

int _count(String hay, String needle) => needle.allMatches(hay).length;

void main() {
  group('the alarm screen', () {
    final screen = codeOnly(
      File('lib/ui2/profile/alarm.dart').readAsStringSync(),
    );

    test('cannot reach setScheduleDay (it saves and arms at once)', () {
      expect(screen, isNot(contains('setScheduleDay')));
    });

    test('never writes the band alarm itself; Save goes through AppState', () {
      expect(screen, isNot(contains('.setAlarm(')));
      expect(screen, isNot(contains('_armNextAlarmOccurrence')));
      expect(screen, contains('onSave: app.saveAlarmDraft'));
    });

    test('does not use the per-setter WakeController writes', () {
      for (final setter in [
        'setNaturalWindow',
        'setGradualWindow',
        'setGradualPattern',
        'setGradualCadenceSeconds',
      ]) {
        expect(screen.contains('wake.$setter'), isFalse, reason: setter);
      }
    });
  });

  group('AppState', () {
    test('Save: one batch persist, one arm, no per-row writes', () {
      final save = _app_('Future<AlarmSaveOutcome> saveAlarmDraft(');
      expect(save, contains('persist: _persistScheduleBatch'));
      expect(_count(save, '_armNextAlarmOccurrence'), 1);
      expect(save, isNot(contains('setScheduleDay')));
      expect(save, isNot(contains('_persistScheduleEntry')));
    });

    test('the batch persist is one DB call and never touches the band', () {
      final batch = _app_('Future<void> _persistScheduleBatch(');
      expect(_count(batch, 'LocalDb.setAlarmScheduleRows('), 1);
      expect(batch, isNot(contains('setAlarmScheduleDay(')));
      expect(batch, isNot(matches(_bandWrite)));
    });

    test('the entry persist behind the WakeController setters never writes '
        'the band', () {
      final entry = _app_('Future<void> _persistScheduleEntry(');
      expect(entry, contains('LocalDb.setAlarmScheduleDay('));
      expect(entry, isNot(matches(_bandWrite)));
    });

    test('setScheduleDay stays for programmatic callers (Siri)', () {
      expect(_app, contains('Future<void> setScheduleDay('));
      expect(
        _app_('_maybeEnableTomorrowAlarmFromSiri('),
        contains('setScheduleDay('),
      );
    });

    test('Natural and Gradual are never sent to the band', () {
      final arm = _app_('Future<AlarmArmReport> _armNextAlarmOccurrence(');
      for (final field in [
        'naturalWindowMinutes',
        'gradualWindowMinutes',
        'gradualPattern',
        'gradualCadence',
      ]) {
        expect(arm, isNot(contains(field)), reason: field);
      }
    });
  });

  group('WakeController', () {
    test('has no route to the band', () {
      final src = codeOnly(
        File('lib/wake/wake_controller.dart').readAsStringSync(),
      );
      expect(src, isNot(contains('ble_engine')));
      expect(src, isNot(contains('setAlarm')));
      expect(src, isNot(contains('disableAlarm')));
    });

    test('every setter does exactly one thing: save one entry', () async {
      var saves = 0, acks = 0, traces = 0, upgradeSaves = 0;
      final c = WakeController(
        schedule: () => fillDefaultAlarmSchedule(const []),
        saveEntry: (_) async => saves++,
        loadUpgradeState: () async => WakeUpgradeState.none,
        saveUpgradeState: (_) async => upgradeSaves++,
        acknowledgeWake: (_) async {
          acks++;
          return const WakeAckOutcome(
            nativeCancelRequested: false,
            nativeCancelled: false,
            fallbackArmed: true,
          );
        },
        traceFor: (_) async {
          traces++;
          return const [];
        },
      );
      await c.setNaturalWindow(1, 45);
      await c.setGradualWindow(1, 30);
      await c.setGradualPattern(1, GradualPattern.steady);
      await c.setGradualCadenceSeconds(1, 120);
      expect(saves, 4);
      expect(
        [acks, traces, upgradeSaves],
        [0, 0, 0],
        reason: 'no wake acknowledgement, no native cancel, nothing else',
      );
    });

    test('previewing a draft day does not read or change saved state', () {
      final saved = fillDefaultAlarmSchedule(const []);
      final c = WakeController(
        schedule: () => saved,
        saveEntry: (_) async => fail('a preview must not save'),
        loadUpgradeState: () async => WakeUpgradeState.none,
        saveUpgradeState: (_) async {},
        acknowledgeWake: (_) async => fail('no ack'),
        traceFor: (_) async => const [],
      );
      final at = DateTime(2026, 10, 6, 7, 0);
      final tl = c.timelineAt(
        at,
        entry: const AlarmScheduleEntry(
          weekday: 1,
          hour: 7,
          minute: 0,
          naturalWindowMinutes: 60,
          gradualWindowMinutes: 30,
        ),
      );
      expect(tl.naturalMinutes, 60);
      expect(tl.gradualMinutes, 30);
      expect(
        c.timelineAt(at).naturalMinutes,
        0,
        reason: 'saved state unchanged',
      );
    });
  });
}
