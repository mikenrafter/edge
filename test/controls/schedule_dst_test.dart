import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';

void main() {
  test('expected schedule preserves local clock times across DST', () {
    const schedule = ExpectedSleepSchedule(
      onsetMinute: 22 * 60,
      wakeMinute: 7 * 60,
    );
    for (final date in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
      final (onset, wake) = schedule.windowFor(date);
      expect(onset.hour, 22);
      expect(wake.hour, 7);
      expect(
        wake.difference(onset).inMinutes,
        9 * 60 - (wake.timeZoneOffset - onset.timeZoneOffset).inMinutes,
      );
      if (Platform.environment['TZ'] == 'America/Denver') {
        expect(wake.difference(onset).inHours, date.month == 3 ? 8 : 10);
      }
      final plan = HighFreqWakeWindow.planFromRows(
        [],
        DateTime(date.year, date.month, date.day, 6),
        expectedSchedule: schedule,
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.targetWake, wake);
      expect(plan.source, 'expected_sleep_schedule');
    }
  });
  test('invalid saved schedule is rejected', () {
    for (final value in [-1, 1440]) {
      expect(
        () => ExpectedSleepSchedule.fromJson({
          'onsetMinute': value,
          'wakeMinute': 420,
        }),
        throwsFormatException,
      );
    }
  });
  test('timed out persistence cannot overwrite a later edit', () async {
    final gate = Completer<void>();
    final writes = <int>[];
    var attempts = 0;
    final c = SleepCoordinator(
      timeout: const Duration(milliseconds: 10),
      persist: (_, start, _) async {
        if (attempts++ == 0) await gate.future;
        writes.add(start);
      },
      derive: (_) async => {},
      saveSchedule: (_) async {},
    );
    final first = await c.setOverride(
      '2026-09-30',
      DateTime(2026, 9, 29, 22),
      DateTime(2026, 9, 30, 7),
    );
    expect(first.success, isFalse);
    expect(c.busy, isFalse);
    final second = c.setOverride(
      '2026-09-30',
      DateTime(2026, 9, 29, 23),
      DateTime(2026, 9, 30, 7),
    );
    gate.complete();
    expect((await second).success, isTrue);
    expect(writes, [
      DateTime(2026, 9, 29, 22).millisecondsSinceEpoch ~/ 1000,
      DateTime(2026, 9, 29, 23).millisecondsSinceEpoch ~/ 1000,
    ]);
    c.dispose();
  });
  test(
    'disposing during an edit retires listeners and queued mutations',
    () async {
      final gate = Completer<void>();
      var writes = 0;
      final c = SleepCoordinator(
        persist: (_, _, _) async {
          writes++;
        },
        derive: (_) async {
          await gate.future;
          return {};
        },
        saveSchedule: (_) async {},
      );
      final first = c.setOverride(
        '2026-09-30',
        DateTime(2026, 9, 29, 22),
        DateTime(2026, 9, 30, 7),
      );
      await Future<void>.delayed(Duration.zero);
      final second = c.setOverride(
        '2026-09-30',
        DateTime(2026, 9, 29, 23),
        DateTime(2026, 9, 30, 7),
      );
      c.dispose();
      gate.complete();
      expect((await first).success, isTrue);
      expect((await second).success, isFalse);
      expect(writes, 1);
    },
  );
}
