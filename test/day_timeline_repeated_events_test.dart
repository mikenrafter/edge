// 8G — Day breakdown: collapse repeated band events.
//
// A run of consecutive identical band events (same event id, nothing else
// between them in time order) becomes ONE row reading
// "<title> · N times", which expands to the individual times. A single event
// stays a plain row. See test/phase8/CONTRACTS.md §8G.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show clockOfTs;
import 'package:openstrap_edge/ui2/ui2.dart';

const _tapTitle = 'You double-tapped the band';

/// Local wall-clock instants, one minute apart, so every clock label differs.
int _ts(int minute) =>
    DateTime(2026, 9, 30, 9, minute).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _ev(int id, int minute) => {
      'event_id': id,
      'ts': _ts(minute),
    };

List<Moment> _moments(List<Map<String, dynamic>> events) =>
    dayMoments(timeline: {'events': events});

Future<void> _pumpBody(WidgetTester t, List<Moment> moments) async {
  t.view.physicalSize = const Size(1170, 6000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (c) => ListView(
          children: timelineBody(
            c,
            TimelineData(day: '2026-09-30', moments: moments),
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  group('dayMoments tags band events with their event id', () {
    test('a band event carries eventId; other moments carry none', () {
      final m = dayMoments(timeline: {
        'events': [_ev(14, 0)],
        'naps': [
          {'start': _ts(30), 'end': _ts(50), 'duration_min': 20},
        ],
      });
      final tap = m.firstWhere((x) => x.title == _tapTitle);
      expect(tap.eventId, 14);
      final nap = m.firstWhere((x) => x.title != _tapTitle);
      expect(nap.eventId, isNull);
    });
  });

  group('groupRepeatedEvents (pure)', () {
    test('five consecutive double taps collapse into one group of five', () {
      final groups = groupRepeatedEvents(
          _moments([for (var i = 0; i < 5; i++) _ev(14, i)]));
      expect(groups, hasLength(1));
      expect(groups.single.count, 5);
      expect(groups.single.moments.map((m) => m.at),
          [for (var i = 0; i < 5; i++) _ts(i)]);
      expect(groups.single.first.at, _ts(0));
    });

    test('a different event between taps splits the run', () {
      // tap, tap, charger on, tap
      final groups = groupRepeatedEvents(
          _moments([_ev(14, 0), _ev(14, 1), _ev(7, 2), _ev(14, 3)]));
      expect(groups.map((g) => g.count), [2, 1, 1]);
      expect(groups.map((g) => g.first.eventId), [14, 7, 14]);
    });

    test('a single tap is its own group of one', () {
      final groups = groupRepeatedEvents(_moments([_ev(14, 0)]));
      expect(groups, hasLength(1));
      expect(groups.single.count, 1);
    });

    test('two different band events in a row never merge', () {
      final groups = groupRepeatedEvents(_moments([_ev(7, 0), _ev(8, 1)]));
      expect(groups.map((g) => g.count), [1, 1]);
    });

    test('moments without an event id never merge, even with equal titles',
        () {
      const a = Moment(at: 100, title: 'Asleep', icon: LucideIcons.moon);
      const b = Moment(at: 200, title: 'Asleep', icon: LucideIcons.moon);
      final groups = groupRepeatedEvents(const [a, b]);
      expect(groups.map((g) => g.count), [1, 1]);
    });

    test('order is preserved and every moment appears exactly once', () {
      final input =
          _moments([_ev(14, 0), _ev(14, 1), _ev(7, 2), _ev(14, 3), _ev(14, 4)]);
      final groups = groupRepeatedEvents(input);
      expect([for (final g in groups) ...g.moments], input);
    });

    test('empty in, empty out', () {
      expect(groupRepeatedEvents(const []), isEmpty);
    });
  });

  group('the timeline row', () {
    testWidgets('a run of five reads "· 5 times" and expands to the times',
        (t) async {
      await _pumpBody(t, _moments([for (var i = 0; i < 5; i++) _ev(14, i)]));
      expect(find.text('$_tapTitle · 5 times'), findsOneWidget);
      // Collapsed: the individual rows are not drawn.
      expect(find.text(_tapTitle), findsNothing);
      for (var i = 1; i < 5; i++) {
        expect(find.text(clockOfTs(_ts(i))), findsNothing,
            reason: 'tap $i is hidden while collapsed');
      }

      await t.tap(find.text('$_tapTitle · 5 times'));
      await t.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        expect(find.text(clockOfTs(_ts(i))), findsWidgets,
            reason: 'tap $i time is listed once expanded');
      }

      await t.tap(find.text('$_tapTitle · 5 times'));
      await t.pumpAndSettle();
      for (var i = 1; i < 5; i++) {
        expect(find.text(clockOfTs(_ts(i))), findsNothing,
            reason: 'collapses again on a second tap');
      }
    });

    testWidgets('a single tap stays a plain row', (t) async {
      await _pumpBody(t, _moments([_ev(14, 0)]));
      expect(find.text(_tapTitle), findsOneWidget);
      expect(find.textContaining(RegExp(r'· \d+ times')), findsNothing);
    });

    testWidgets('interleaved events keep their own rows', (t) async {
      await _pumpBody(
          t, _moments([_ev(14, 0), _ev(14, 1), _ev(7, 2), _ev(14, 3)]));
      expect(find.text('$_tapTitle · 2 times'), findsOneWidget);
      expect(find.text('On the charger'), findsOneWidget);
      // The lone tap after the charger is a plain row.
      expect(find.text(_tapTitle), findsOneWidget);
    });
  });
}
