// The in-memory draft of the whole week. Pure: no widgets, no DB, no band.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

List<AlarmScheduleEntry> _week() => fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 0, hour: 6, minute: 30, enabled: true),
]);

void main() {
  test('starts clean and equal to the saved schedule', () {
    final d = AlarmDraft(_week());
    expect(d.dirty, isFalse);
    expect(d.entries, _week());
    expect(d.canSave, isFalse);
    expect(d.canCancel, isFalse);
  });

  test('every edit is in memory: dirty, and editing back makes it clean', () {
    final d = AlarmDraft(_week());
    var notified = 0;
    d.addListener(() => notified++);
    d.setEnabled(3, true);
    expect(d.dirty, isTrue);
    expect(d.canSave, isTrue);
    expect(d.canCancel, isTrue);
    expect(d.entry(3).enabled, isTrue);
    expect(d.saved[3].enabled, isFalse, reason: 'the saved copy never moves');
    d.setEnabled(3, false);
    expect(d.dirty, isFalse, reason: 'back to the saved value is not a change');
    expect(notified, 2);
  });

  test('time, Natural and Gradual settings all live in the draft', () {
    final d = AlarmDraft(_week());
    d.setTime(0, 7, 15);
    d.setNaturalWindow(0, 45);
    d.setGradualWindow(0, 30);
    d.setGradualPattern(0, GradualPattern.steady);
    d.setGradualCadence(0, 120);
    final e = d.entry(0);
    expect([e.hour, e.minute], [7, 15]);
    expect(e.naturalWindowMinutes, 45);
    expect(e.gradualWindowMinutes, 30);
    expect(e.gradualPattern, GradualPattern.steady);
    expect(e.gradualCadenceSec, 120);
    expect(d.saved[0].naturalWindowMinutes, 0);
    expect(d.dirty, isTrue);
  });

  test('wake settings are validated like the WakeController setters', () {
    final d = AlarmDraft(_week());
    expect(() => d.setNaturalWindow(0, 20), throwsArgumentError);
    expect(() => d.setNaturalWindow(0, 135), throwsArgumentError);
    expect(() => d.setGradualWindow(0, -15), throwsArgumentError);
    expect(() => d.setGradualCadence(0, 90), throwsArgumentError);
    expect(() => d.setGradualCadence(0, 960), throwsArgumentError);
    expect(() => d.setEnabled(7, true), throwsArgumentError);
    expect(d.dirty, isFalse, reason: 'a rejected edit changes nothing');
  });

  test('discard restores the saved schedule', () {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    d.setNaturalWindow(0, 60);
    d.discard();
    expect(d.dirty, isFalse);
    expect(d.entries, _week());
  });

  test('a successful save makes the draft the saved schedule', () async {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    List<AlarmScheduleEntry>? sent;
    final out = await d.save((e) async {
      sent = e;
      return const AlarmSaveOutcome(AlarmSaveStatus.sentToBand);
    });
    expect(out?.status, AlarmSaveStatus.sentToBand);
    expect(sent, hasLength(7));
    expect(d.dirty, isFalse);
    expect(d.saved[2].enabled, isTrue);
    expect(d.outcome?.status, AlarmSaveStatus.sentToBand);
    expect(d.canSave, isFalse);
  });

  test('an offline save is still a save', () async {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    await d.save(
      (_) async => const AlarmSaveOutcome(AlarmSaveStatus.savedOffline),
    );
    expect(d.dirty, isFalse);
    expect(d.outcome?.status, AlarmSaveStatus.savedOffline);
  });

  test('a save that never reached the DB keeps the draft dirty', () async {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    await d.save(
      (_) async => const AlarmSaveOutcome(
        AlarmSaveStatus.failed,
        persisted: false,
        error: 'disk full',
      ),
    );
    expect(d.dirty, isTrue);
    expect(d.canSave, isTrue);
    expect(d.saved[2].enabled, isFalse);
  });

  test(
    'a save that persisted but could not reach the band offers Retry',
    () async {
      final d = AlarmDraft(_week());
      d.setEnabled(2, true);
      await d.save(
        (_) async =>
            const AlarmSaveOutcome(AlarmSaveStatus.failed, error: 'refused'),
      );
      expect(d.dirty, isFalse, reason: 'the schedule itself is saved');
      expect(d.saved[2].enabled, isTrue);
      expect(d.canSave, isTrue, reason: 'Retry stays enabled');
      expect(d.canCancel, isFalse);
      // Retry works, and clears the failure.
      await d.save(
        (_) async => const AlarmSaveOutcome(AlarmSaveStatus.sentToBand),
      );
      expect(d.canSave, isFalse);
    },
  );

  test('editing after an outcome clears the stale message', () async {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    await d.save(
      (_) async => const AlarmSaveOutcome(AlarmSaveStatus.sentToBand),
    );
    d.setEnabled(3, true);
    expect(d.outcome, isNull);
  });

  test('a second Save while one is sending is ignored', () async {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    final gate = Completer<AlarmSaveOutcome>();
    var calls = 0;
    final first = d.save((_) {
      calls++;
      return gate.future;
    });
    expect(d.sending, isTrue);
    expect(d.canSave, isFalse, reason: 'no double tap while sending');
    expect(await d.save((_) async => throw StateError('second send')), isNull);
    gate.complete(const AlarmSaveOutcome(AlarmSaveStatus.sentToBand));
    await first;
    expect(calls, 1);
    expect(d.sending, isFalse);
  });

  test('a send that throws is reported as a failure, never lost', () async {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true);
    await d.save((_) async => throw Exception('boom'));
    expect(d.sending, isFalse, reason: 'the in-flight flag always clears');
    expect(d.outcome?.status, AlarmSaveStatus.failed);
    expect(d.outcome?.persisted, isFalse);
    expect(d.dirty, isTrue);
  });

  test(
    'disposed mid-flight: the save finishes without touching the draft',
    () async {
      final d = AlarmDraft(_week());
      d.setEnabled(2, true);
      final gate = Completer<AlarmSaveOutcome>();
      final f = d.save((_) => gate.future);
      d.dispose();
      gate.complete(const AlarmSaveOutcome(AlarmSaveStatus.sentToBand));
      await f; // must not throw "used after being disposed"
    },
  );

  test('rebase: untouched days follow the new saved schedule, edits stay', () {
    final d = AlarmDraft(_week());
    d.setEnabled(2, true); // user edit on Wednesday
    final next = _week();
    next[4] = next[4].copyWith(enabled: true, hour: 9); // changed elsewhere
    d.rebase(next);
    expect(d.entry(4).enabled, isTrue, reason: 'untouched day adopts it');
    expect(d.entry(2).enabled, isTrue, reason: 'the user edit survives');
    expect(d.saved[4].hour, 9);
    expect(d.dirty, isTrue);
  });

  test('rebase onto an equal schedule changes nothing and does not notify', () {
    final d = AlarmDraft(_week());
    var n = 0;
    d.addListener(() => n++);
    d.rebase(_week());
    expect(n, 0);
    expect(d.dirty, isFalse);
  });

  test(
    'the outcome headlines are the ones the plan names, plus the failure',
    () {
      expect(
        const AlarmSaveOutcome(AlarmSaveStatus.sentToBand).headline,
        'Saved and sent to the band',
      );
      expect(
        const AlarmSaveOutcome(AlarmSaveStatus.savedOffline).headline,
        'Saved — the band updates when it next connects',
      );
      const f = AlarmSaveOutcome(AlarmSaveStatus.failed, error: 'refused');
      expect(f.headline, contains('refused'));
      expect(
        const AlarmSaveOutcome(AlarmSaveStatus.sentUnconfirmed).headline,
        isNot(contains('Saved and sent to the band')),
        reason: 'unconfirmed never claims the band has it',
      );
    },
  );
}
