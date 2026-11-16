// A synthetic night for the day-timeline pilot tests and shots: 20:00 on
// Fri 13 Nov 2026 for 24 hours, asleep 23:12-07:04, a nap 13:30-14:10,
// movement and heart rate shaped like the mock-up's (seeded, so every run
// draws the same night).
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';

final int dtNightStart = DateTime(2026, 11, 13, 20).millisecondsSinceEpoch ~/ 1000;
int dtAt(int minutesFrom20) => dtNightStart + minutesFrom20 * 60;

SleepEditorData dtNight({bool withNap = true, bool usual = true}) {
  var seed = 11;
  double rnd() => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const on1 = 192, off1 = 664, on2 = 1050, off2 = 1090; // minutes from 20:00
  final hr = <double?>[], mv = <double?>[];
  for (var m = 0; m < 1440; m++) {
    final a1 = m >= on1 && m < off1, a2 = m >= on2 && m < off2;
    // Movement is 5-minute buckets, like activity_curve.
    if (m % 5 == 0) {
      final v = a1 || a2 ? (rnd() < .06 ? .5 + rnd() * .4 : rnd() * .12) : .35 + rnd() * .6;
      for (var k = 0; k < 5; k++) {
        mv.add(v);
      }
    }
    final into = (m - on1) / 90;
    hr.add(a1
        ? 54 + 4 * _cos(into) + rnd() * 3 - (6 - into * 2).clamp(0, 6)
        : a2 ? 58 + rnd() * 3 : 70 + rnd() * 12);
  }
  return SleepEditorData(
    day: '2026-11-14',
    domainStart: dtNightStart,
    hr: hr,
    movement: mv.sublist(0, 1440),
    main: SleepBlock('main', BlockKind.main, dtAt(160), dtAt(690)),
    naps: withNap ? [SleepBlock('nap:${dtAt(on2)}', BlockKind.nap, dtAt(on2), dtAt(off2))] : const [],
    usualBed: usual ? dtAt(185) : null,
    usualWake: usual ? dtAt(670) : null,
  );
}

double _cos(double x) {
  // cos(2πx) without dart:math in the fixture's signature.
  const twoPi = 6.283185307179586;
  var t = (x * twoPi) % twoPi;
  var r = 1.0, term = 1.0;
  for (var i = 1; i < 12; i++) {
    term *= -t * t / ((2 * i - 1) * (2 * i));
    r += term;
  }
  return r;
}
