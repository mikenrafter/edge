// RED (owner UI feedback 2026-10-22): B5 Latest/Latest, B6 charger time
// repeated, B7 raw workout slug.
//
// B5: LiveHrCard feeds ChartScrub a `time` of 'Latest' for the newest reading,
//     and ChartKeyReadout's own label for the unscrubbed row is also 'Latest'
//     (lib/ui2/live_hr.dart:176, grammar.dart:809). The two slots must differ.
// B6: charger / battery-pack moments carry `detail: clockOfTs(t)` - the time
//     the left column already shows (day_timeline.dart, event moments).
// B7: a stored workout type that the catalogue does not know ('other', a new
//     sport slug) is printed raw via `type.replaceAll('_', ' ')`
//     (day_timeline.dart:267). It must show the localized "Workout"
//     (dayTimelineWorkout). The annotation title and the "What happened" row
//     are the same Moment.title, so both are covered.
//
// No new ARB keys: the fallback is the existing `dayTimelineWorkout`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/live_hr.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show clockOfTs;
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: home)),
    );

int _ts(int h, int m) =>
    DateTime(2026, 10, 22, h, m).millisecondsSinceEpoch ~/ 1000;

Future<AppLocalizations> _en() => AppLocalizations.delegate.load(const Locale('en'));

void main() {
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(ClockFormatController.debugReset);

  testWidgets('B5: the live card never says "Latest" twice', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(const LiveHrCard.preview(
        hr: 85, trace: [85, 85, 85, 85, 85, 85])));
    await t.pumpAndSettle();
    final texts = find
        .descendant(
            of: find.byKey(ChartKeyReadout.timeKey), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .toList();
    expect(texts.length, 2, reason: 'label slot and value slot');
    expect(texts[0], isNot(texts[1]),
        reason: 'label and value are both "${texts[0]}"');
    expect(texts[1], isNot('—'), reason: 'there is a latest reading');
  });

  group('B6: a charger event does not repeat its time', () {
    for (final id in const [7, 8, 21, 22]) {
      test('event $id: the detail is not the clock the row already has', () {
        final at = _ts(14, 42);
        final m = dayMoments(timeline: {
          'events': [
            {'event_id': id, 'ts': at}
          ],
        }, l: null).single;
        expect(m.detail, isNot(clockOfTs(at)));
        expect(m.detail, isNot(contains(clockOfTs(at))),
            reason: 'empty, or something new (battery level) - never the time');
      });
    }

    testWidgets('the day breakdown shows 14:42 once for a charger event',
        (t) async {
      t.view.physicalSize = const Size(390 * 3, 2000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final moments = dayMoments(timeline: {
        'events': [
          {'event_id': 8, 'ts': _ts(14, 42)},
          {'event_id': 7, 'ts': _ts(14, 47)},
        ],
      });
      await t.pumpWidget(_app(Builder(
        builder: (c) => Column(
            children: timelineBody(
                c, TimelineData(day: '2026-10-22', moments: moments))),
      )));
      await t.pumpAndSettle();
      expect(find.text('Off the charger'), findsOneWidget);
      expect(find.text('14:42'), findsOneWidget);
      expect(find.text('14:47'), findsOneWidget);
    });
  });

  group('B7: a workout type slug never reaches the UI', () {
    Future<List<Moment>> moments(String? type) async => dayMoments(
          timeline: {
            'sessions': [
              {
                'start_ts': _ts(9, 0),
                'end_ts': _ts(10, 0),
                'duration_min': 60,
                if (type != null) 'type': type,
              }
            ],
          },
          l: await _en(),
        );

    for (final slug in const ['other', 'Other', 'kite_surfing_2', '']) {
      test('"$slug" shows as "Workout"', () async {
        final m = (await moments(slug)).single;
        expect(m.title, 'Workout');
      });
    }

    test('a known type still uses its catalogue name', () async {
      expect((await moments('running')).single.title, 'Running');
    });

    testWidgets('What happened shows "Workout", not the slug', (t) async {
      t.view.physicalSize = const Size(390 * 3, 2000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final ms = await moments('other');
      await t.pumpWidget(_app(Builder(
        builder: (c) => Column(
            children:
                timelineBody(c, TimelineData(day: '2026-10-22', moments: ms))),
      )));
      await t.pumpAndSettle();
      expect(find.text('Workout'), findsWidgets);
      expect(find.text('other'), findsNothing);
    });
  });
}
