// P4b: one placement: Sleep detail shows the shared status line while a step
// is open, and nothing when none is.
//
// ASSUMED API: lib/compute/calc_status.dart (CalcStatus.instance) and
// lib/ui2/calc_status_line.dart (CalcStatusLine, defaulting to
// CalcStatus.instance). SleepDetail builds ONE CalcStatusLine where its
// AsOfLabel / InlineLoading sit today (no new chrome); the same line is wired
// into Home, Health, Readiness, MetricDetail, Beats, Wellness, Circadian and
// Workout detail (those placements are not pinned here).
//
// Failure mode today: the library does not exist (the file fails to load).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_status.dart';
import 'package:openstrap_edge/ui2/calc_status_line.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

SleepData _data() => SleepData(
      day: '2026-05-20',
      night: {
        'duration_min': 443,
        'in_bed_min': 486,
        'awake_min': 20,
        'efficiency': .91,
        'onset_ts': _onset,
        'wake_ts': _onset + 486 * 60,
        'light_min': 170,
        'deep_min': 85,
        'rem_min': 95,
        'hypnogram': [
          {'t': _onset, 'stage': 'light'},
          {'t': _onset + 3600, 'stage': 'deep'},
          {'t': _onset + 486 * 60, 'stage': 'awake'},
        ],
      },
    );

void main() {
  testWidgets('Sleep detail shows the status line while a step is open',
      (t) async {
    t.view.physicalSize = const Size(360 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: SleepDetail(data: _data()),
    ));
    await t.pumpAndSettle();

    expect(find.byType(CalcStatusLine), findsOneWidget,
        reason: 'one line, in the spot AsOfLabel uses');
    expect(find.textContaining(' · '), findsNothing,
        reason: 'nothing is being calculated: the line is empty');

    final token = CalcStatus.instance.begin('Sleep stages');
    addTearDown(() => CalcStatus.instance.end(token));
    await t.pump();
    expect(find.textContaining('Sleep stages · '), findsOneWidget);
    expect(t.takeException(), isNull);

    CalcStatus.instance.end(token);
    await t.pump();
    expect(find.textContaining('Sleep stages · '), findsNothing);
  });
}
