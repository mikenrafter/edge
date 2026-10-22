// RULES B.2: a value served from an older calculation keeps its flag all the
// way to the screen. This file pins the MODEL: the shared chart path, and the
// one shared marker/note widget.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/older_version.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart'
    show lastSevenDaysOlder;
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'support/older_version_fixtures.dart';

void main() {
  group('ChartPoint carries the flag', () {
    test('pointsOf keeps from_older_version per point', () {
      final pts = pointsOf({
        'points': series(5, flagged: {1, 2})
      });
      // series() is oldest first: back 4..0, so back 2 and back 1 sit at 2, 3.
      expect([for (final p in pts) p.olderVersion],
          [null, null, 104, 104, null]);
      // The value and time are untouched.
      expect(pts.length, 5);
    });

    test('the flag travels with the point: parsing another chart cannot '
        'change it', () {
      final a = pointsOf({
        'points': [cp(1, 5, older: 104), cp(0, 6)]
      });
      // The same (t, v) pairs on a CURRENT chart of another metric.
      final b = pointsOf({
        'points': [cp(1, 5), cp(0, 6)]
      });
      expect([for (final p in a) p.olderVersion], [104, null]);
      expect([for (final p in b) p.olderVersion], [null, null]);
      // And the other way round: parsing the flagged one again later.
      pointsOf({
        'points': [cp(1, 5, older: 103)]
      });
      expect([for (final p in a) p.olderVersion], [104, null]);
    });

    test('the reason rides on the point when the payload has one', () {
      final pts = pointsOf({
        'points': [
          {...cp(1, 5, older: 104), 'older_version_reason': kReasonRaw},
          cp(0, 6, older: 104),
          cp(2, 7),
        ]
      });
      expect([for (final p in pts) p.olderReason], [kReasonRaw, null, null]);
    });

    test('a point with no flag, or a non-numeric flag, is current', () {
      final pts = pointsOf({
        'points': [
          cp(1, 5),
          {...cp(0, 6), 'from_older_version': 'x'},
        ]
      });
      expect([for (final p in pts) p.olderVersion], [null, null]);
    });

    test('a flagged point with no value is dropped, never marked', () {
      final pts = pointsOf({
        'points': [
          {'t': cp(0, 1)['t'], 'from_older_version': 104},
          {'t': cp(1, 1)['t'], 'v': null, 'from_older_version': 104},
        ]
      });
      expect(pts, isEmpty);
    });

    test('denseDays slots keep their flag; gaps stay unflagged gaps', () {
      final pts = pointsOf({
        'points': series(7, flagged: {0, 3}, gaps: {2})
      });
      final vals = denseDays(pts, 7);
      final ol = denseOlderVersions(pts, 7);
      expect(ol.length, 7);
      expect(ol[6], 104, reason: 'today');
      expect(ol[3], 104, reason: '3 days back');
      expect(vals[4], isNull, reason: 'the gap');
      expect(ol[4], isNull);
      expect(ol[5], isNull);
      // A longer window pads leading slots with nothing.
      final long = denseOlderVersions(pts, 10);
      expect(long.length, 10);
      expect(long[9], 104);
      expect(long[0], isNull);
    });

    test('workout lastSevenDays keeps the flag per slot', () {
      final end = DateTime(DateTime.now().year, DateTime.now().month,
          DateTime.now().day);
      final ol = lastSevenDaysOlder(series(7, flagged: {0, 2}), end);
      expect(ol, [null, null, null, null, 104, null, 104]);
    });
  });

  group('the shared note and mark', () {
    Future<void> host(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light), home: Scaffold(body: Center(child: w))));

    test('note text: version and the reason sentence, else version alone', () {
      expect(olderVersionNoteText(104, kReasonRaw), kNoteV104Reason);
      expect(olderVersionNoteText(104, null), kNoteV104);
      // A machine token nobody wrote a sentence for is not printed raw.
      expect(olderVersionNoteText(104, 'need_input:name=zzz_unknown'),
          kNoteV104);
    });

    test('spoken form says it is from an older calculation', () {
      expect(olderVersionSemantics(104), matches(kSpoken));
    });

    testWidgets('mark: an asterisk, spoken, and tapping it reveals the note',
        (t) async {
      final h = t.ensureSemantics();
      await host(t,
          const OlderVersionMark(id: 'x', version: 104, reason: kReasonRaw));
      expect(olderMark('x'), findsOneWidget);
      expect(find.descendant(of: olderMark('x'), matching: find.text('*')),
          findsOneWidget);
      expect(find.bySemanticsLabel(kSpoken), findsWidgets);
      expect(find.text(kNoteV104Reason), findsNothing);
      await t.tap(olderMark('x'));
      await t.pumpAndSettle();
      expect(find.text(kNoteV104Reason), findsOneWidget);
      h.dispose();
    });

    testWidgets('note: visible text with the version and the reason',
        (t) async {
      await host(t,
          const OlderVersionNote(id: 'x', version: 104, reason: kReasonRaw));
      expect(olderNote('x'), findsOneWidget);
      expect(find.text(kNoteV104Reason), findsOneWidget);
    });

    testWidgets('no version: nothing at all (current value, or no value)',
        (t) async {
      await host(
          t,
          const Column(children: [
            OlderVersionMark(id: 'x', version: null),
            OlderVersionNote(id: 'x', version: null, reason: kReasonRaw),
          ]));
      expect(anyOlderMarker(), findsNothing);
      expect(find.text('*'), findsNothing);
      expect(find.textContaining('older calculation'), findsNothing);
    });
  });
}
