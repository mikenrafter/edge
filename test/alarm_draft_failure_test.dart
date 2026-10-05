// Failure injection — the alarm screen's Save path.
// A database that throws or hangs, a band that never answers, a disconnect in
// the middle, a duplicate Save and a process restart. Each ends in a failure
// the header can show with Retry still available, `sending` cleared, and at
// most one band write per attempt.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';

List<AlarmScheduleEntry> _week() => fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 0, hour: 6, minute: 30, enabled: true),
]);

const _fast = Duration(milliseconds: 40);

class _Rig {
  _Rig({
    this.persistHangs = false,
    this.persistThrows = false,
    this.armHangs = false,
    this.armThrows = false,
    this.confirmHangs = false,
    this.connected = true,
  });
  bool persistHangs, persistThrows, armHangs, armThrows, confirmHangs, connected;
  int persists = 0, arms = 0;
  List<AlarmScheduleEntry>? stored;

  Future<AlarmSaveOutcome> save(List<AlarmScheduleEntry> entries) =>
      saveAlarmSchedule(
        entries: entries,
        isConnected: () => connected,
        persist: (e) {
          persists++;
          if (persistHangs) return Completer<void>().future;
          if (persistThrows) throw StateError('database is locked');
          stored = e;
          return Future.value();
        },
        arm: () {
          arms++;
          if (armHangs) return Completer<AlarmArmReport>().future;
          if (armThrows) throw StateError('gatt disconnected');
          return Future.value(const AlarmArmReport(wrote: true, awaitsConfirmation: true));
        },
        awaitConfirmed: (t) =>
            confirmHangs ? Completer<bool>().future : Future.value(true),
        confirmWait: _fast,
        persistTimeout: _fast,
        armTimeout: _fast,
      );
}

void main() {
  test('DB failure: nothing is written to the band and the draft stays dirty',
      () async {
    final rig = _Rig(persistThrows: true);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final out = await d.save(rig.save);
    expect(out!.status, AlarmSaveStatus.failed);
    expect(out.persisted, isFalse);
    expect(rig.arms, 0);
    expect(d.dirty, isTrue);
    expect(d.sending, isFalse);
    expect(d.canSave, isTrue);
  });

  test('a database that never answers ends in a failure, not a busy Save',
      () async {
    final rig = _Rig(persistHangs: true);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final out = await d.save(rig.save).timeout(const Duration(seconds: 5));
    expect(out!.status, AlarmSaveStatus.failed);
    expect(out.persisted, isFalse);
    expect(out.headline, startsWith('Not saved:'));
    expect(rig.arms, 0);
    expect(d.sending, isFalse);
    expect(d.dirty, isTrue);
    // Retry after the database recovers: exactly one band write.
    rig.persistHangs = false;
    final retry = await d.save(rig.save);
    expect(retry!.status, AlarmSaveStatus.sentToBand);
    expect(rig.arms, 1);
    expect(d.dirty, isFalse);
  });

  test('a band that never answers: the schedule is saved, the header says the '
      'band did not answer, and Retry stays available', () async {
    final rig = _Rig(armHangs: true);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final out = await d.save(rig.save).timeout(const Duration(seconds: 5));
    expect(out!.status, AlarmSaveStatus.failed);
    expect(out.persisted, isTrue);
    expect(out.headline, contains('the band did not answer'));
    expect(rig.arms, 1, reason: 'one band write per attempt');
    expect(d.dirty, isFalse, reason: 'the schedule itself is saved');
    expect(d.canSave, isTrue);
    expect(d.sending, isFalse);
  });

  test('a confirmation that never arrives is "sent, not confirmed yet"',
      () async {
    final rig = _Rig(confirmHangs: true);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final out = await d.save(rig.save).timeout(const Duration(seconds: 5));
    expect(out!.status, AlarmSaveStatus.sentUnconfirmed);
    expect(rig.arms, 1);
  });

  test('BLE disconnect mid-save (the write throws): saved, failed, and each '
      'Retry makes one more write, never two', () async {
    final rig = _Rig(armThrows: true);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final first = await d.save(rig.save);
    expect(first!.persisted, isTrue);
    expect(first.status, AlarmSaveStatus.failed);
    expect(rig.arms, 1);
    final second = await d.save(rig.save);
    expect(second!.status, AlarmSaveStatus.failed);
    expect(rig.arms, 2);
    rig.armThrows = false;
    expect((await d.save(rig.save))!.status, AlarmSaveStatus.sentToBand);
    expect(rig.arms, 3);
  });

  test('offline at Save: persisted, zero band writes', () async {
    final rig = _Rig(connected: false);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final out = await d.save(rig.save);
    expect(out!.status, AlarmSaveStatus.savedOffline);
    expect((rig.persists, rig.arms), (1, 0));
  });

  test('a whole send that outlives its ceiling clears the sending latch',
      () async {
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final out = await d
        .save((_) => Completer<AlarmSaveOutcome>().future,
            sendTimeout: _fast)
        .timeout(const Duration(seconds: 5));
    expect(out!.status, AlarmSaveStatus.failed);
    expect(d.sending, isFalse);
    expect(d.canSave, isTrue);
    expect(d.dirty, isTrue);
  });

  test('a duplicate Save tap while one is in flight sends once', () async {
    final rig = _Rig();
    final d = AlarmDraft(_week())..setEnabled(2, true);
    final a = d.save(rig.save);
    final b = d.save(rig.save);
    expect(await b, isNull);
    await a;
    expect(rig.persists, 1);
    expect(rig.arms, 1);
  });

  test('process restart after the schedule was stored but before the band '
      'write: the new draft is the stored schedule, clean', () async {
    final rig = _Rig(armThrows: true);
    final d = AlarmDraft(_week())..setEnabled(2, true);
    await d.save(rig.save);
    d.dispose(); // process killed
    final reloaded = AlarmDraft(rig.stored!); // state reloaded from the DB
    expect(reloaded.dirty, isFalse);
    expect(reloaded.entry(2).enabled, isTrue);
    expect(reloaded.outcome, isNull, reason: 'the old failure is not carried over');
  });

  test('a band that refuses the alarm (permission or state) is a failure with '
      'the schedule saved', () async {
    final out = await saveAlarmSchedule(
      entries: _week(),
      isConnected: () => true,
      persist: (_) async {},
      arm: () async => armReportOf((epoch: null, disabled: false, refused: true)),
      awaitConfirmed: (_) async => true,
    );
    expect(out.status, AlarmSaveStatus.failed);
    expect(out.persisted, isTrue);
  });
}
