// The health-exception push, decided end to end without the database.
//
// `planExceptionNotices` plans cross-day findings using stored readiness and
// the frozen morning headline. Daily pulse notices use their own origin gate,
// covered through the native commit owner in pulse_phase1_notification_test.
//
// Low readiness is the ring's number in the ring's lowest band, on a SETTLED
// anchor only, and never the deprecated glass-box score.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';

const _today = '2026-10-02';

Map<String, dynamic> _cd({bool unsettled = false, num? glassBox}) => {
      'recent': [
        {'date': '2026-10-01', 'unsettled': false},
        {'date': _today, 'unsettled': unsettled},
      ],
      if (glassBox != null)
        'readiness_glassbox': {
          'value': {'score': glassBox},
        },
    };

List<Finding> _low(List<ExceptionNotice> notices) => [
      for (final n in notices)
        for (final f in n.findings)
          if (f.kind == FindingKind.lowReadiness) f,
    ];

void main() {
  test('a settled "Rest today" morning pushes, with the ring\'s score', () {
    final notices =
        planExceptionNotices(_cd(), today: _today, storedReadiness: 20);
    final n = notices.single;
    expect(n.date, _today);
    expect(n.dedupeKey, '$_today:exception');
    expect(_low(notices).single.score, 20);
  });

  test('an unsettled night does not push low readiness', () {
    expect(
        planExceptionNotices(_cd(unsettled: true),
            today: _today, storedReadiness: 20),
        isEmpty);
  });

  test('an absent composite does not push, whatever the glass-box says', () {
    expect(planExceptionNotices(_cd(glassBox: 10), today: _today), isEmpty);
  });

  test('when the two models disagree, the composite decides', () {
    expect(
        planExceptionNotices(_cd(glassBox: 10),
            today: _today, storedReadiness: 55),
        isEmpty);
    expect(
        _low(planExceptionNotices(_cd(glassBox: 70),
                today: _today, storedReadiness: 20))
            .single
            .score,
        20);
  });

  test('the pinned headline wins over the stored value', () {
    // The ring shows the pin (30, "Take it easy"), so no push even though a
    // later re-derive stored 24.
    expect(
        planExceptionNotices(_cd(),
            today: _today,
            pin: (day: _today, value: 30),
            storedReadiness: 24),
        isEmpty);
    // And a low pin pushes even when the day has no stored value at all.
    expect(
        _low(planExceptionNotices(_cd(),
                today: _today, pin: (day: _today, value: 22)))
            .single
            .score,
        22);
  });

  test('another day\'s pin is not this day\'s readiness', () {
    expect(
        planExceptionNotices(_cd(),
            today: _today,
            pin: (day: '2026-10-01', value: 10),
            storedReadiness: 50),
        isEmpty);
  });

  test('a stale anchor raises nothing dated on it', () {
    expect(
        planExceptionNotices(_cd(),
            today: '2026-10-05', storedReadiness: 10),
        isEmpty);
  });

  test('the overnight detectors still ride along, on their own dates', () {
    final cd = {
      ..._cd(unsettled: true),
      'illness': {'date': '2026-10-01', 'state': 'red'},
    };
    final n = planExceptionNotices(cd, today: _today).single;
    expect(n.findings, const [Finding(FindingKind.illness, '2026-10-01')]);
  });
}
