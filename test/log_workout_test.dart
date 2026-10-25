// THE TWO SCREENS THE UI REBUILD LEFT OUT, RENDERED.
//
// Reading a widget tree does not find layout bugs — this project has paid for
// that three times over (a negative margin asserts, an OverflowBox blanks a
// whole tab, Expanded and Flexible in one Row split it 50/50). Both of these
// are pumped at a real phone width, and both are driven: the form's validation
// is exercised through the controls a thumb would use, not by calling the pure
// function underneath it.
//
// Neither screen gets an AppState here on purpose. `repoOf`/`appOf` return
// null without one, which is exactly the golden case — a screen that cannot
// reach the repository must still render its own absence rather than throw.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/data/day_label.dart' show dayLabelOf;
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// A real phone, and tall enough that nothing under test is below the fold —
/// the default 800x600 harness hides the very controls these tests are about.
Future<void> _pump(WidgetTester t, Widget w,
    {Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(brightness),
    home: w,
  ));
  await t.pumpAndSettle();
}

/// 18:30–19:31 on a fixed day, as the detector would have reported it.
final _now = DateTime(2026, 8, 19, 21);
final _start = DateTime(2026, 8, 19, 18, 30);
final _end = DateTime(2026, 8, 19, 19, 31);

Suggestion _sug({String id = 'a', int? avg = 148, int? peak = 171}) =>
    Suggestion(
      id: id,
      startTs: _start.millisecondsSinceEpoch ~/ 1000,
      endTs: _end.millisecondsSinceEpoch ~/ 1000,
      sport: 'running',
      avgBpm: avg,
      peakBpm: peak,
    );

class _ReviewRepo extends LocalRepository {
  _ReviewRepo(this.items);
  final List<ActivitySuggestion> items;
  @override
  Future<List<ActivitySuggestion>> pendingActivities() async => items;
}

Future<void> _review(WidgetTester t, List<Suggestion> suggestions,
    {String? focusId, double scale = 1, Brightness brightness = Brightness.light}) async {
  ClockFormatController.seed(ClockFormat.h12);
  addTearDown(ClockFormatController.debugReset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = _ReviewRepo([for (final s in suggestions) ActivitySuggestion(
    id: s.id, kind: ActivityKind.workout, startTs: s.startTs, endTs: s.endTs,
    revision: 0, details: {'sport': s.sport})]);
  await _pump(t, ChangeNotifierProvider<AppState>.value(value: app,
    child: MediaQuery(data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: DayTimelineScreen(
        data: TimelineData(day: dayLabelOf(_start)), focusId: focusId,
        reviewMoments: const [],
        reviewEditor: const MomentReviewEditor(preloadedAssumed: [])))),
      brightness: brightness);
}

void main() {
  group('day breakdown workout review', () {
    testWidgets('draws the bout and its whole window with staged actions', (t) async {
      await _review(t, [_sug()]);
      final tray = find.byKey(const ValueKey('apk2-review-tray'));
      expect(find.text('Breakdown of your day'), findsOneWidget);
      expect(find.descendant(of: tray, matching: find.text('Possible workout')), findsOneWidget);
      expect(find.descendant(of: tray, matching: find.textContaining('6:30 PM')), findsOneWidget);
      expect(find.descendant(of: tray, matching: find.textContaining('7:31 PM')), findsOneWidget);
      expect(find.descendant(of: tray, matching: find.textContaining('61 min')), findsOneWidget);
      expect(find.byKey(const ValueKey('apk2-review-keep:activity:a')), findsOneWidget);
      expect(find.byKey(const ValueKey('apk2-review-discard:activity:a')), findsOneWidget);
      expect(find.byKey(const ValueKey('day-review-label:activity:a')), findsOneWidget);
      expect(find.textContaining('strain'), findsNothing);
    });

    testWidgets('an empty review says so, without inventing a measurement', (t) async {
      await _review(t, []);
      expect(find.text('Nothing to review'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('a reviewed notification target leaves pending items visible', (t) async {
      await _review(t, [_sug(), _sug(id: 'b')], focusId: 'gone');
      expect(find.byKey(const ValueKey('apk2-review-keep:activity:a')), findsOneWidget);
      expect(find.byKey(const ValueKey('apk2-review-keep:activity:b')), findsOneWidget);
      expect(find.text('Nothing to review'), findsNothing);
      expect(find.byKey(const ValueKey('apk2-day-highlight:activity:gone')), findsNothing);
    });

    testWidgets('notification highlights its bout and keeps other pending items', (t) async {
      await _review(t, [_sug(), _sug(id: 'b')], focusId: 'b');
      expect(find.byKey(const ValueKey('apk2-day-highlight:activity:b')), findsOneWidget);
      expect(find.byKey(const ValueKey('apk2-review-keep:activity:a')), findsOneWidget);
      expect(find.byKey(const ValueKey('apk2-review-keep:activity:b')), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('apk2-day-highlight:activity:b')), findsNothing);
    });

    testWidgets('review fits at 2x text', (t) async {
      await _review(t, [_sug(), _sug(id: 'b')], scale: 2, brightness: Brightness.dark);
      expect(t.takeException(), isNull);
    });
  });

  group('the manual-entry form', () {
    testWidgets('opens on a valid window and offers to save it', (t) async {
      await _pump(t, LogWorkout(now: _now));
      expect(find.text('Log a past workout'), findsOneWidget);
      // Defaults to the last whole hour, which is a WINDOW — a form that opens
      // on "now to now" opens invalid.
      expect(find.text('60 min'), findsOneWidget);
      expect(find.text('That window will not save'), findsNothing);
      expect(find.text('Log it'), findsOneWidget);
    });

    testWidgets('a window that overlaps one already logged is refused', (
      t,
    ) async {
      await _pump(
        t,
        LogWorkout(
          now: _now,
          start: _start,
          end: _end,
          spans: [
            SessionSpan(
              'manual:1',
              _start.millisecondsSinceEpoch ~/ 1000 + 600,
              _end.millisecondsSinceEpoch ~/ 1000 + 600,
            ),
          ],
        ),
      );
      expect(find.text('That window will not save'), findsOneWidget);
      expect(
        find.text('That overlaps a workout already in your log.'),
        findsOneWidget,
      );
    });

    testWidgets('scoring an import never writes over a session at its start '
        '(#325)', (t) async {
      final s = _start.millisecondsSinceEpoch ~/ 1000;
      final e = _end.millisecondsSinceEpoch ~/ 1000;
      final same = [SessionSpan(manualSessionId(s), s, e)];
      await _pump(t, LogWorkout(now: _now, start: _start, end: _end, spans: same));
      expect(find.text('That window will not save'), findsNothing,
          reason: 're-logging the same window updates that row');
      await _pump(
        t,
        LogWorkout(
            now: _now, start: _start, end: _end, spans: same, importedUuid: 'x'),
      );
      expect(find.text('That window will not save'), findsOneWidget);
    });

    testWidgets('a retime keeps the type and does not offer to change it', (
      t,
    ) async {
      await _pump(
        t,
        LogWorkout(
          sessionId: 'manual:123',
          now: _now,
          start: _start,
          end: _end,
          activity: activityByName('running'),
          title: 'Fix the times',
        ),
      );
      expect(find.text('Fix the times'), findsWidgets);
      expect(find.text('Save the new times'), findsOneWidget);
      // The row that would change the activity is absent: a retime is about
      // the window, and the type belongs to the row already.
      expect(find.text('Activity'), findsNothing);
    });

    testWidgets('picking an end time before the start rolls to the next day', (
      t,
    ) async {
      // 23:40 → 00:20 is an ordinary late run, not an invalid window.
      final late = DateTime(2026, 8, 19, 23, 40);
      await _pump(
        t,
        LogWorkout(
          now: DateTime(2026, 8, 20, 8),
          start: late,
          end: late.add(Motion.tick * 2400),
          activity: activityByName('running'),
        ),
      );
      expect(find.text('40 min'), findsOneWidget);
      expect(find.text('the next morning'), findsOneWidget);
      expect(find.text('That window will not save'), findsNothing);
    });
  });

  group('the day label', () {
    final now = DateTime(2026, 8, 19, 12);
    test('names today and yesterday, then the date', () {
      expect(dayLabel(DateTime(2026, 8, 19, 6), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 8, 18, 23), now: now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 8, 11, 9), now: now), 'Tue 11 Aug');
    });

    test('counts calendar days, not 24-hour blocks', () {
      // 23:59 yesterday to 00:01 today is two minutes and one day. An
      // `inDays` on the difference calls it "Today".
      expect(dayLabel(DateTime(2026, 8, 18, 23, 59),
          now: DateTime(2026, 8, 19, 0, 1)), 'Yesterday');
    });
  });
}
