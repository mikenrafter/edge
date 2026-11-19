import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/personal_day_widgets.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart' show DayRowEditListener;
import 'package:openstrap_edge/ui2/screens/metric_detail.dart' show DayNav;
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/naps.dart';
import '../support/apk2_review_harness.dart';
import '../support/as_of_recalc_fakes.dart' show settle;

DateTime at(int day, [int hour = 0, int minute = 0]) => DateTime(2026, 11, day, hour, minute);
PersonalDay get cycle => PersonalDay(at(2, 8), at(3, 8), '2026-11-02', '2026-11-03');
TimelineData timeline([List<Moment> moments = const []]) => TimelineData(
  day: '2026-11-03', personalView: PersonalDayView(cycle, PersonalDayMode.wakeToWake, true, [cycle]),
  moments: moments);

class _Repo extends Apk2Repository {
  _Repo(super.store);
  @override
  Future<List<String>> availableDays() async => ['2026-11-03', '2026-11-02', '2026-11-01'];
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60, String? before}) async => [
    for (final day in [1, 2, 3]) {'date': '2026-11-0${day + 1}',
      'onset_ts': at(day, 23).millisecondsSinceEpoch ~/ 1000,
      'wake_ts': at(day + 1, 8).millisecondsSinceEpoch ~/ 1000},
  ];
}

void main() {
  // WHY / CLAIM(personal-calendar-write): a cycle spanning midnight must not
  // backdate a real log. Kills forwarding either the label or selection ID.
  testWidgets('Home quick log persists the current calendar instant', (t) async {
    final r = await Apk2Rig.create(t, pending: false);
    final now = at(3, 0, 30);
    r.app.repo = _Repo(r.store);
    await Prefs.setPersonalDayMode(PersonalDayMode.sleepToSleep);
    await r.mount(t, size: const Size(430, 1600), screen: Scaffold(body: HomeScreen(
      now: now, data: HomeData(dayId: '2026-11-02', personalDay: cycle,
        personalMode: PersonalDayMode.sleepToSleep, personalCycles: [cycle]))));
    expect(find.byType(DayNav), findsNothing);
    await apk2Tap(t, find.byKey(const ValueKey('track-quick-log')));
    expect(find.byType(TrackLogScreen), findsOneWidget);
    await apk2Tap(t, find.byKey(const ValueKey('track-log-save')));
    final events = (await t.runAsync(() => TracksStore(r.db).events()))!
      .where((e) => e.id.startsWith('track-log:')).toList();
    expect(events, hasLength(1));
    expect(events.single.date, '2026-11-03');
    expect(events.single.atMs, now.millisecondsSinceEpoch);
  });
  // WHY / CLAIM(personal-review-window): exercise the screen/controller merge,
  // not timelineBody alone. Kills score-day-only reads and missing clipping.
  testWidgets('cycle review shows both calendar days and excludes outside marks', (t) async {
    final r = await Apk2Rig.create(t, pending: false);
    r.app.repo = _Repo(r.store);
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    const marks = [PendingMoment(date: '2026-11-02', hhmm: '09:00'),
      PendingMoment(date: '2026-11-03', hhmm: '07:00'),
      PendingMoment(date: '2026-11-03', hhmm: '20:00')];
    await r.mount(t, screen: DayTimelineScreen(day: cycle.start.toIso8601String(), reviewMoments: marks,
      reviewActivities: const [], reviewEditor: MomentReviewEditor(
        preloaded: marks, preloadedAssumed: const [], now: at(4))));
    expect(apk2PageIds(), {'moment:2026-11-02 09:00', 'moment:2026-11-03 07:00'});
    await apk2Tap(t, apk2Keep('moment:2026-11-02 09:00'));
    await apk2Tap(t, apk2Keep('moment:2026-11-03 07:00'));
    await apk2Tap(t, apk2SaveButton());
    final labels = (await t.runAsync(() => LocalDb.momentLabels(sinceDate: '2026-11-02')))!;
    expect(labels.map((m) => m.key).toSet(), {'2026-11-02 09:00', '2026-11-03 07:00'});
  });
  // WHY / CLAIM(personal-row-owner): selected-cycle IDs and score days cannot
  // own a saved row. Drive the production editor lookup for each source day.
  for (final (day, time, hour) in [('2026-11-02', '09:00', 9), ('2026-11-03', '07:00', 7)]) {
    testWidgets('selected cycle edits saved row owned by $day', (t) async {
      final r = await Apk2Rig.create(t, pending: false);
      final saved = MomentLabel(date: day, hhmm: time, label: 'other', answeredAtMs: 1);
      await t.runAsync(() => LocalDb.putMomentLabel(saved));
      final m = Moment(at: at(day.endsWith('02') ? 2 : 3, hour).millisecondsSinceEpoch ~/ 1000,
        title: 'Saved mark', icon: Icons.edit, editRef: 'moment:$day $time');
      await r.mount(t, screen: DayTimelineScreen(day: cycle.start.toIso8601String(),
        data: timeline([m]), reviewActivities: const [], reviewMoments: const [],
        reviewEditor: MomentReviewEditor(preloaded: const [], preloadedAssumed: const [], now: at(4))));
      final editor = t.state(find.byType(DayTimelineScreen)) as DayRowEditListener;
      final opened = editor.openRowEditor(m);
      await settle(t);
      expect(find.byType(MomentAnswerEditScreen), findsOneWidget);
      expect(t.widget<MomentAnswerEditScreen>(find.byType(MomentAnswerEditScreen)).saved.date, day);
      r.navigator.currentState!.pop();
      await settle(t);
      await opened;
    });
  }
  // WHY / CLAIM(personal-row-owner): naps can cross midnight, so the
  // calendar owner passed by the loader must survive joining and editing.
  testWidgets('selected cycle opens a nap on its source calendar day', (t) async {
    final r = await Apk2Rig.create(t, pending: false);
    final nap = dayMoments(calendarDay: '2026-11-03', timeline: {
      'naps': [{'start': at(2,23).millisecondsSinceEpoch ~/ 1000,
        'end': at(3,1).millisecondsSinceEpoch ~/ 1000, 'duration_min': 120}],
    }).single;
    final joined = personalTimelineOf(PersonalDayView(cycle, PersonalDayMode.wakeToWake, true, [cycle]),
      [TimelineData(day: '2026-11-03', moments: [nap])]);
    expect(joined.moments.single.calendarDay, '2026-11-03');
    await r.mount(t, screen: DayTimelineScreen(day: cycle.start.toIso8601String(),
      data: joined, reviewActivities: const [], reviewMoments: const [],
      reviewEditor: MomentReviewEditor(preloaded: const [], preloadedAssumed: const [], now: at(4))));
    final editor = t.state(find.byType(DayTimelineScreen)) as DayRowEditListener;
    final opened = editor.openRowEditor(joined.moments.single);
    await settle(t);
    expect(find.byType(NapsScreen), findsOneWidget);
    expect(t.widget<NapsScreen>(find.byType(NapsScreen)).day, '2026-11-03');
    r.navigator.currentState!.pop();
    await settle(t);
    await opened;
  });
  test('navigation shows actual start date separately from the cycle name', () {
    final d = PersonalDay(at(1,23), at(2,23), '2026-11-02', '2026-11-02');
    expect(personalDayNavLabel(d), contains('2026-11-01'));
  });
}
