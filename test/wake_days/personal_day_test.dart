import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';

DateTime t(int day, [int hour = 0]) => DateTime(2026, 11, day, hour);
MainSleep s(int day, int onset, int wakeDay, int wake) =>
    MainSleep(t(day, onset), t(wakeDay, wake));
List<PersonalDay> project(List<MainSleep> sleeps, {
  DateTime? from, DateTime? until,
  PersonalDayMode mode = PersonalDayMode.wakeToWake,
  PersonalDayTotals totals = PersonalDayTotals.last,
  List<PersonalWake> wakes = const [],
}) => personalDays(from: from ?? t(2, 8), until: until ?? t(4, 8),
    sleeps: sleeps, wakes: wakes, mode: mode, totals: totals);

void main() {
  // WHY / CLAIM(personal-days): literal owner examples, not computed oracles.
  // catches: splitting every midnight despite two recorded main anchors.
  test('34 hour stay-up remains one cycle', () {
    final days = project([s(1, 23, 2, 8), s(3, 10, 3, 18)], until: t(3, 18));
    expect(days.map((d) => (d.start, d.end)), [(t(2, 8), t(3, 18))]);
    expect(days.single.label, '2026-11-03'); // 16 h vs 18 h: Nov 3 wins.
  });
  test('wake and sleep modes anchor different ends of main sleep', () {
    final sleeps = [s(2, 1, 2, 8), s(3, 1, 3, 8)];
    expect(project(sleeps, until: t(3, 8)).single.start, t(2, 8));
    final days = project(sleeps, from: t(2, 1), until: t(3, 1), mode: PersonalDayMode.sleepToSleep);
    expect((days.single.start, days.single.end), (t(2, 1), t(3, 1)));
  });
  // catches: naps or a short split-sleep block creating a second day.
  test('split sleep does not divide a cycle under twelve hours', () {
    final days = project([s(1, 23, 2, 5), s(2, 7, 2, 10),
      s(2, 23, 3, 5)], from: t(2, 5), until: t(3, 5));
    expect(days.map((d) => (d.start, d.end)), [(t(2, 5), t(3, 5))]);
  });
  // WHY / CLAIM(personal-split-onsets): the 20 h onset rule is separate
  // from the 12 h minimum cycle, including projected wake boundaries.
  for (final mode in [PersonalDayMode.sleepToSleep, PersonalDayMode.wakeToWake]) {
    test('16 hour split onset stays inside the first cycle in ${mode.name}', () {
      final days = project([s(1,23,2,7), s(2,15,2,19), s(2,23,3,7), s(3,23,4,7)],
        from: mode == PersonalDayMode.sleepToSleep ? t(1,23) : t(2,7),
        until: mode == PersonalDayMode.sleepToSleep ? t(3,23) : t(4,7), mode: mode);
      expect(days.map((d) => (d.start, d.end)), mode == PersonalDayMode.sleepToSleep
        ? [(t(1,23), t(2,23)), (t(2,23), t(3,23))]
        : [(t(2,7), t(3,7)), (t(3,7), t(4,7))]);
    });
  }
  test('no sleep and all-nighter use midnight', () {
    final days = project([], from: t(2), until: t(4));
    expect(days.map((d) => (d.start, d.end)), [(t(2), t(3)), (t(3), t(4))]);
  });
  // catches: rounding start +12h to noon, or hard-capping at 36h.
  test('over 36 hours cuts at later of midnight and literal start +12h', () {
    final days = project([s(1, 15, 1, 23), s(3, 6, 3, 14)], from: t(1, 23), until: t(3, 14));
    expect(days.map((d) => (d.start, d.end)), [(t(1, 23), t(2, 11)), (t(2, 11), t(3, 14))]);
  });
  test('exactly 36 hours remains one day', () {
    expect(project([s(1, 23, 2, 8), s(3, 12, 3, 20)], until: t(3, 20)), hasLength(1));
  });
  test('majority names a cycle and ties choose earlier date', () {
    final days = project([], from: t(2, 12), until: t(3, 12), mode: PersonalDayMode.calendarOffset);
    expect(days.single.label, '2026-11-02');
  });
  test('first or last totals skip dates and earlier cycle owns duplicate', () {
    final sleeps = [s(1, 15, 1, 23), s(3, 6, 3, 14)];
    // The window runs past the second cycle: the span ending at `until` is the
    // open cycle and scores Nov 3 (10 h vs Nov 4's 8 h). It reserves that
    // date before the closed cycles choose first/last (fix r3 S2).
    final last = project(sleeps, from: t(1, 23), until: t(4, 8), totals: PersonalDayTotals.last);
    expect(last.map((d) => d.scoreDay), ['2026-11-02', null, '2026-11-03']);
    final first = project(sleeps, from: t(1, 23), until: t(4, 8), totals: PersonalDayTotals.first);
    expect(first.map((d) => d.scoreDay), ['2026-11-01', '2026-11-02', '2026-11-03']);
    final duplicate = project([s(1, 23, 2, 8), s(2, 20, 2, 22), s(3, 23, 4, 8)],
        from: t(2, 8), until: t(4, 9), totals: PersonalDayTotals.first);
    expect(duplicate.map((d) => d.scoreDay), ['2026-11-02', null, '2026-11-04']);
  });
  // catches: waiting for a scored sleep or the learned clock after "I'm up".
  test('I am up turns the day before the sleep is scored', () {
    final sleeps = [MainSleep(t(2, 23), null)];
    final wakes = [PersonalWake(t(2, 23), t(3, 7))];
    expect(personalDayAwake(sleeps, wakes, t(3, 8)), isTrue);
    expect(personalDayAwake(sleeps, wakes, t(3, 6)), isFalse);
    final days = project(sleeps, from: t(3, 7), until: t(4, 7), wakes: wakes);
    expect(days.first.start, t(3, 7));
  });
  test('a short midnight prefix merges back and does not steal the main label', () {
    final days = project([s(1, 23, 2, 8), s(2, 23, 3, 8)],
        from: t(1), until: t(3, 8));
    expect(days.map((d) => (d.start, d.end)), [(t(1), t(2, 8)), (t(2, 8), t(3, 8))]);
    expect(days.map((d) => d.label), ['2026-11-01', '2026-11-02']);
  });
  test('a clipped short prefix is not presented as a complete cycle', () {
    final days = project([s(1, 23, 2, 5), s(2, 23, 3, 5)],
        from: t(2), until: t(3, 5));
    expect(days.map((d) => (d.start, d.end)), [(t(2, 5), t(3, 5))]);
  });
  test('old wake evidence cannot end the next main sleep', () {
    expect(personalDayAwake([s(1, 23, 2, 8), MainSleep(t(2, 23), null)],
        [PersonalWake(t(1, 23), t(2, 8))], t(3, 4)), isFalse);
  });
  test('invalid windows and empty ranges produce no invented sleep', () {
    expect(project([], from: t(3), until: t(2)), isEmpty);
    expect(project([MainSleep(t(3), t(2))], from: t(2), until: t(3)).single.start, t(2));
  });
}
