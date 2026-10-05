// P4c: the staleness line. "Updated 08:42 · recordings through 08:36", and
// when newer recordings exist and work is held, why.
//
// ASSUMED API (lib/ui2/as_of.dart; AsOfLabel is EXTENDED, not forked):
//
//   enum StaleHold { workout, sync, background, power }
//       Why derive work is held. `power` (P5, "Waiting for power") came with the
//       power hold; its own cases are in test/p5/calc_power_stale_test.dart.
//
//   StaleHold? staleHoldOf(Map<String, dynamic> schedulerSnapshot)
//       Pure read of DeriveScheduler.snapshot():
//         workout_active && !workout_hold_expired          -> workout
//         offload_active || manual_sync_hold               -> sync
//         background                                       -> background
//       Precedence when several are set: workout, then sync, then background.
//       A lapsed workout hold (workout_hold_expired) and a bare `running` /
//       `pending_*` are NOT holds -> null.
//
//   String? stalenessText({
//     DateTime? updatedAt,          // computed_at of the served row
//     DateTime? recordingsThrough,  // the day's derived_fp MAX(rec_ts)
//     DateTime? newestRecording,    // SyncController.lastRecordAt
//     StaleHold? hold,
//     DateTime? now,                // decides "is it today" (default now)
//     AppLocalizations? l,          // null -> the English literals
//   })
//       Parts joined with " · ":
//         "Updated HH:MM"                      (needs updatedAt, else null)
//         "recordings through HH:MM"           (only when recordingsThrough)
//         "Paused during workout" | "Waiting for sync to finish" |
//         "Paused in the background"           (only when hold != null AND both
//                                               recordingsThrough and
//                                               newestRecording are known AND
//                                               newestRecording is strictly
//                                               after recordingsThrough)
//       24 h, zero padded, LOCAL time (a UTC DateTime is converted). A stamp
//       that is not on `now`'s local day carries its date: "2 Oct, 08:42".
//       A missing field drops its part; no time is ever made up.
//
//   AsOfLabel gains optional `recordingsThrough`, `newestRecording`, `hold`.
//       With recordingsThrough or hold it renders stalenessText(...) (Text key
//       'as-of-label'); with neither it is today's "As of 08:42", unchanged.
//
// Failure mode today: stalenessText / StaleHold / staleHoldOf do not exist.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/as_of.dart';
import 'package:openstrap_edge/ui2/theme.dart';

final _now = DateTime(2026, 10, 3, 9, 0);
final _upd = DateTime(2026, 10, 3, 8, 42);
final _thr = DateTime(2026, 10, 3, 8, 36);
final _newer = DateTime(2026, 10, 3, 8, 50);

String? _text({
  DateTime? updatedAt,
  DateTime? recordingsThrough,
  DateTime? newestRecording,
  StaleHold? hold,
  DateTime? now,
}) =>
    stalenessText(
      updatedAt: updatedAt,
      recordingsThrough: recordingsThrough,
      newestRecording: newestRecording,
      hold: hold,
      now: now ?? _now,
    );

Widget _host(Widget child, {double scale = 1}) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
      ),
    );

void main() {
  group('stalenessText', () {
    test('fresh: updated time and what the recordings cover', () {
      expect(_text(updatedAt: _upd, recordingsThrough: _thr),
          'Updated 08:42 · recordings through 08:36');
    });

    test('recordings no newer than the result covers: no reason, whatever '
        'is held', () {
      for (final h in StaleHold.values) {
        expect(
            _text(
                updatedAt: _upd,
                recordingsThrough: _thr,
                newestRecording: _thr, // equal, not newer
                hold: h),
            'Updated 08:42 · recordings through 08:36',
            reason: '$h');
        expect(
            _text(
                updatedAt: _upd,
                recordingsThrough: _thr,
                newestRecording: DateTime(2026, 10, 3, 8, 30), // older
                hold: h),
            'Updated 08:42 · recordings through 08:36',
            reason: '$h');
      }
    });

    test('newer recordings and each hold: the reason is said', () {
      const want = {
        StaleHold.workout: 'Paused during workout',
        StaleHold.sync: 'Waiting for sync to finish',
        StaleHold.background: 'Paused in the background',
        StaleHold.power: 'Waiting for power',
      };
      for (final e in want.entries) {
        expect(
            _text(
                updatedAt: _upd,
                recordingsThrough: _thr,
                newestRecording: _newer,
                hold: e.key),
            'Updated 08:42 · recordings through 08:36 · ${e.value}',
            reason: '${e.key}');
      }
    });

    test('newer recordings but nothing held: no reason (work is not '
        'paused, so there is nothing to explain)', () {
      expect(
          _text(
              updatedAt: _upd, recordingsThrough: _thr, newestRecording: _newer),
          'Updated 08:42 · recordings through 08:36');
    });

    test('only the power hold mentions power (P5: "Waiting for power")', () {
      for (final h in [null, ...StaleHold.values]) {
        final s = _text(
            updatedAt: _upd,
            recordingsThrough: _thr,
            newestRecording: _newer,
            hold: h);
        expect(s!.toLowerCase().contains('power'), h == StaleHold.power,
            reason: '$h');
      }
    });

    test('absent fields: the missing part is not shown, nothing is '
        'invented', () {
      expect(_text(), isNull, reason: 'nothing known: nothing shown');
      expect(_text(recordingsThrough: _thr, newestRecording: _newer,
              hold: StaleHold.sync),
          isNull,
          reason: 'no stored result to caption');
      expect(_text(updatedAt: _upd), 'Updated 08:42',
          reason: 'no recordings-through: that part is left out');
      expect(
          _text(
              updatedAt: _upd,
              newestRecording: _newer,
              hold: StaleHold.workout),
          'Updated 08:42',
          reason: 'cannot say newer recordings exist without knowing what '
              'the result covers');
      expect(
          _text(
              updatedAt: _upd,
              recordingsThrough: _thr,
              hold: StaleHold.workout),
          'Updated 08:42 · recordings through 08:36',
          reason: 'unknown newest recording: no claim of newer data');
    });

    test('24 h, zero padded', () {
      expect(
          _text(
              updatedAt: DateTime(2026, 10, 3, 0, 5),
              recordingsThrough: DateTime(2026, 10, 3, 0, 1)),
          'Updated 00:05 · recordings through 00:01');
      expect(_text(updatedAt: DateTime(2026, 10, 3, 23, 59)),
          'Updated 23:59');
    });

    test('local time: a UTC instant is shown on the local clock', () {
      final utc = DateTime.utc(2026, 10, 3, 6, 42);
      final loc = utc.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      final wall = '${two(loc.hour)}:${two(loc.minute)}';
      // `now` on the same LOCAL day as the instant, so no date is added.
      final s = _text(updatedAt: utc, now: DateTime(loc.year, loc.month, loc.day, 23));
      expect(s, 'Updated $wall');
    });

    test('another day shows its date, per stamp', () {
      expect(
          _text(
              updatedAt: DateTime(2026, 10, 2, 8, 42),
              recordingsThrough: DateTime(2026, 10, 2, 8, 36)),
          'Updated 2 Oct, 08:42 · recordings through 2 Oct, 08:36');
      expect(
          _text(
              updatedAt: _upd, // today
              recordingsThrough: DateTime(2026, 10, 2, 23, 58)),
          'Updated 08:42 · recordings through 2 Oct, 23:58',
          reason: 'each time carries its own date when it is not today');
    });
  });

  group('staleHoldOf (DeriveScheduler.snapshot())', () {
    Map<String, dynamic> snap({
      bool offload = false,
      bool workout = false,
      bool expired = false,
      bool background = false,
      bool running = false,
      bool pendingLight = false,
      bool pendingHeavy = false,
      bool manual = false,
    }) =>
        {
          'offload_active': offload,
          'workout_active': workout,
          'workout_hold_expired': expired,
          'background': background,
          'running': running,
          'pending_light': pendingLight,
          'pending_heavy': pendingHeavy,
          'manual_sync_hold': manual,
        };

    test('each hold maps to its reason', () {
      expect(staleHoldOf(snap(workout: true)), StaleHold.workout);
      expect(staleHoldOf(snap(offload: true)), StaleHold.sync);
      expect(staleHoldOf(snap(manual: true)), StaleHold.sync);
      expect(staleHoldOf(snap(background: true)), StaleHold.background);
    });

    test('not a hold: idle, running, queued, a lapsed workout hold', () {
      expect(staleHoldOf(snap()), isNull);
      expect(staleHoldOf(const {}), isNull, reason: 'an empty snapshot');
      expect(staleHoldOf(snap(running: true)), isNull);
      expect(staleHoldOf(snap(pendingLight: true, pendingHeavy: true)), isNull);
      expect(staleHoldOf(snap(workout: true, expired: true)), isNull,
          reason: 'a workout forgotten past the 6 h cap no longer holds');
    });

    test('precedence: workout, then sync, then background', () {
      expect(staleHoldOf(snap(workout: true, offload: true, background: true)),
          StaleHold.workout);
      expect(staleHoldOf(snap(offload: true, background: true)),
          StaleHold.sync);
      expect(staleHoldOf(snap(workout: true, expired: true, offload: true)),
          StaleHold.sync,
          reason: 'the lapsed workout hold does not outrank a real one');
    });
  });

  group('AsOfLabel (extended)', () {
    final label = find.byKey(const ValueKey('as-of-label'));

    testWidgets('only `at`: today\'s "As of 08:42", unchanged', (t) async {
      await t.pumpWidget(_host(AsOfLabel(at: _upd, now: _now)));
      expect(t.widget<Text>(label).data, 'As of 08:42');
    });

    testWidgets('with recordings-through: the staleness line', (t) async {
      await t.pumpWidget(_host(
          AsOfLabel(at: _upd, now: _now, recordingsThrough: _thr)));
      expect(t.widget<Text>(label).data,
          'Updated 08:42 · recordings through 08:36');
    });

    testWidgets('newer recordings + a hold: the reason is on the line',
        (t) async {
      await t.pumpWidget(_host(AsOfLabel(
          at: _upd,
          now: _now,
          recordingsThrough: _thr,
          newestRecording: _newer,
          hold: StaleHold.workout)));
      expect(t.widget<Text>(label).data,
          'Updated 08:42 · recordings through 08:36 · Paused during workout');
    });

    testWidgets('null `at`: nothing at all, even with the other fields',
        (t) async {
      await t.pumpWidget(_host(AsOfLabel(
          at: null,
          now: _now,
          recordingsThrough: _thr,
          newestRecording: _newer,
          hold: StaleHold.sync)));
      expect(label, findsNothing);
    });

    testWidgets('the longest line fits 360 pt at 2x text without overflow',
        (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(
          AsOfLabel(
              at: DateTime(2026, 9, 30, 8, 42),
              now: _now,
              recordingsThrough: DateTime(2026, 9, 30, 8, 36),
              newestRecording: _newer,
              hold: StaleHold.sync),
          scale: 2));
      expect(t.takeException(), isNull);
      expect(t.getSize(label).width, lessThanOrEqualTo(360));
    });
  });
}
