// 8O — the band-write budget of a Save, counted at the engine seam. Uses the
// REAL arm logic (armNextScheduledOccurrence + armReportOf) over a counting
// fake band, so a regression that arms per row, or writes Natural/Gradual to
// the band, shows up as a number.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show AlarmBandWriter;
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

class _CountingBand implements AlarmBandWriter {
  int sets = 0, disables = 0;
  final armed = <DateTime>[];
  bool refuse = false;
  bool throwOnSet = false;

  @override
  Future<DateTime?> setAlarm(DateTime when) async {
    sets++;
    if (throwOnSet) throw Exception('link dropped');
    if (refuse) return null;
    armed.add(when);
    return when;
  }

  @override
  Future<void> disableAlarm() async => disables++;
}

/// Everything a Save touches, with the real arm logic in the middle.
class _Rig {
  _Rig({this.connected = true, List<AlarmScheduleEntry>? saved})
    : persistedRows = fillDefaultAlarmSchedule(saved ?? const []);

  // Monday 2026-10-05 22:00 local; the next occurrence is therefore Tue+.
  final now = DateTime(2026, 10, 5, 22, 0);
  final band = _CountingBand();
  bool connected;
  bool confirms = true;
  List<AlarmScheduleEntry> persistedRows;
  int persists = 0, arms = 0, confirmWaits = 0;
  int? armedEpoch;

  Future<AlarmSaveOutcome> save(List<AlarmScheduleEntry> entries) =>
      saveAlarmSchedule(
        entries: entries,
        isConnected: () => connected,
        persist: (e) async {
          persists++;
          persistedRows = e;
        },
        arm: () async {
          arms++;
          final r = await armNextScheduledOccurrence(
            engine: band,
            schedule: persistedRows,
            currentArmedEpoch: armedEpoch,
            now: now,
          );
          if (r.disabled) armedEpoch = null;
          if (r.epoch != null) armedEpoch = r.epoch;
          return armReportOf(r);
        },
        awaitConfirmed: (_) async {
          confirmWaits++;
          return confirms;
        },
      );

  AlarmDraft draft() => AlarmDraft(persistedRows);
}

void main() {
  test(
    'editing all seven days (switch + time) then Save writes the band once',
    () async {
      final rig = _Rig();
      final d = rig.draft();
      for (var w = 0; w < 7; w++) {
        d.setEnabled(w, true);
        d.setTime(w, 6, 30 + w); // 14 edits, none of them sent anywhere
      }
      expect(rig.band.sets, 0, reason: 'editing never writes');
      expect(rig.persists, 0, reason: 'editing never saves');
      final out = await d.save(rig.save);
      expect(out?.status, AlarmSaveStatus.sentToBand);
      expect(rig.persists, 1, reason: 'one persist for the whole week');
      expect(rig.persistedRows, hasLength(7));
      expect(rig.arms, 1);
      expect(rig.band.sets, 1, reason: 'exactly one SET_ALARM');
      expect(rig.band.disables, 0);
    },
  );

  test('Save with no effective change writes nothing', () async {
    final rig = _Rig(
      saved: const [AlarmScheduleEntry(weekday: 1, hour: 7, minute: 0)],
    );
    // First arm so the band holds the next occurrence (Tue 07:00).
    await rig.save(rig.persistedRows);
    expect(rig.band.sets, 1);
    // Edit and edit back, then Save anyway (Retry-style): same schedule.
    final d = rig.draft();
    d.setTime(1, 8, 0);
    d.setTime(1, 7, 0);
    expect(d.dirty, isFalse);
    final out = await rig.save(d.entries);
    expect(rig.band.sets, 1, reason: 'the band already holds that time');
    expect(rig.band.disables, 0);
    expect(out.status, AlarmSaveStatus.bandAlreadyHasIt);
    expect(rig.confirmWaits, 1, reason: 'only the first save waited');
  });

  test('Cancel (discard) writes nothing and persists nothing', () async {
    final rig = _Rig();
    final d = rig.draft();
    d.setEnabled(0, true);
    d.setTime(0, 5, 0);
    d.discard();
    expect(d.dirty, isFalse);
    expect(
      [rig.persists, rig.arms, rig.band.sets, rig.band.disables],
      [0, 0, 0, 0],
    );
  });

  test('Natural/Gradual edits alone never reach the band', () async {
    final rig = _Rig(
      saved: const [AlarmScheduleEntry(weekday: 1, hour: 7, minute: 0)],
    );
    await rig.save(rig.persistedRows); // band holds Tue 07:00
    final before = rig.band.sets;
    final d = rig.draft();
    d.setNaturalWindow(1, 90);
    d.setGradualWindow(1, 45);
    d.setGradualPattern(1, GradualPattern.steady);
    d.setGradualCadence(1, 300);
    final out = await d.save(rig.save);
    expect(
      rig.persistedRows[1].naturalWindowMinutes,
      90,
      reason: 'the wake settings are saved with the rest',
    );
    expect(rig.band.sets, before, reason: 'T did not change: zero writes');
    expect(rig.band.disables, 0);
    expect(out?.status, AlarmSaveStatus.bandAlreadyHasIt);
  });

  test(
    'Natural edit plus a changed T is still one write, and only for T',
    () async {
      final rig = _Rig(
        saved: const [AlarmScheduleEntry(weekday: 1, hour: 7, minute: 0)],
      );
      await rig.save(rig.persistedRows);
      final before = rig.band.sets;
      final d = rig.draft();
      d.setNaturalWindow(1, 60);
      d.setTime(1, 7, 30);
      await d.save(rig.save);
      expect(rig.band.sets, before + 1);
      expect(
        rig.band.armed.last,
        DateTime(2026, 10, 6, 7, 30),
        reason: 'the band was given T, never the window start',
      );
    },
  );

  test('switching every day off sends one disable, no SET', () async {
    final rig = _Rig(
      saved: const [AlarmScheduleEntry(weekday: 1, hour: 7, minute: 0)],
    );
    await rig.save(rig.persistedRows);
    final sets = rig.band.sets;
    final d = rig.draft();
    d.setEnabled(1, false);
    await d.save(rig.save);
    expect(rig.band.disables, 1);
    expect(rig.band.sets, sets);
  });

  test('offline: persisted, nothing sent, reported as pending', () async {
    final rig = _Rig(connected: false);
    final d = rig.draft();
    d.setEnabled(2, true);
    final out = await d.save(rig.save);
    expect(out?.status, AlarmSaveStatus.savedOffline);
    expect(rig.persists, 1);
    expect(rig.arms, 0);
    expect(rig.band.sets + rig.band.disables, 0);
    expect(d.dirty, isFalse, reason: 'it is saved; only the band is behind');
  });

  test('confirmation: waited for after a write, reported honestly', () async {
    final rig = _Rig();
    var d = rig.draft()..setEnabled(2, true);
    expect((await d.save(rig.save))?.status, AlarmSaveStatus.sentToBand);
    expect(rig.confirmWaits, 1);

    final slow = _Rig()..confirms = false;
    d = slow.draft()..setEnabled(2, true);
    final out = await d.save(slow.save);
    expect(out?.status, AlarmSaveStatus.sentUnconfirmed);
    expect(out?.headline, isNot('Saved and sent to the band'));
  });

  test(
    'a refused arm is a failure with Retry; the retry is one more write',
    () async {
      final rig = _Rig();
      rig.band.refuse = true;
      final d = rig.draft()..setEnabled(2, true);
      final out = await d.save(rig.save);
      expect(out?.status, AlarmSaveStatus.failed);
      expect(out?.persisted, isTrue);
      expect(rig.band.sets, 1);
      expect(d.dirty, isFalse);
      expect(d.canSave, isTrue, reason: 'Retry is available');
      rig.band.refuse = false;
      final again = await d.save(rig.save);
      expect(again?.status, AlarmSaveStatus.sentToBand);
      expect(rig.band.sets, 2, reason: 'one refused, one that landed');
      expect(rig.persists, 2);
      expect(d.canSave, isFalse);
    },
  );

  test(
    'an arm that throws is a failure with Retry, not an unhandled error',
    () async {
      final rig = _Rig();
      rig.band.throwOnSet = true;
      final d = rig.draft()..setEnabled(2, true);
      final out = await d.save(rig.save);
      expect(out?.status, AlarmSaveStatus.failed);
      expect(out?.headline, contains('link dropped'));
      expect(d.canSave, isTrue);
    },
  );

  test('a persist that fails stops before the band is touched', () async {
    final rig = _Rig();
    final d = rig.draft()..setEnabled(2, true);
    final out = await saveAlarmSchedule(
      entries: d.entries,
      isConnected: () => true,
      persist: (_) async => throw Exception('disk full'),
      arm: () async => fail('must not arm when nothing was saved'),
      awaitConfirmed: (_) async => true,
    );
    expect(out.status, AlarmSaveStatus.failed);
    expect(out.persisted, isFalse);
    expect(rig.band.sets, 0);
  });
}
