// 8AG-perf P1b: the "As of <time>" decision and the label widget.
//
// ASSUMED API
//
//   lib/state/recalc_state.dart (pure Dart; see recalc_state_test.dart for
//   RecalcState):
//     DateTime? asOfFor({
//       required String? shownDay,        // the local day label the screen shows
//       required DateTime? computedAt,    // computed_at of the row actually read
//       required RecalcState recalc,
//       bool dependsOnCrossDay = false,   // the card shows a cross-day artifact
//     });
//     // non-null (== computedAt) iff computedAt != null AND
//     //   (shownDay in recalc.days OR (dependsOnCrossDay AND recalc.crossDay)).
//     // Never invents a time.
//
//   lib/ui2/as_of.dart (new):
//     class AsOfLabel extends StatelessWidget {
//       const AsOfLabel({super.key, required DateTime? at, DateTime? now});
//       // `now` only decides "is it today" (default DateTime.now()).
//     }
//     - at == null  -> SizedBox.shrink, no widget with key 'as-of-label'
//     - text key    -> ValueKey('as-of-label') on the Text
//     - same local day as now -> "As of 08:42" (24 h, zero padded)
//     - another day           -> "As of 30 Sep, 08:42" ("d Mon", English abbrev)
//     - Semantics label "Showing results calculated at 08:42; new results are
//       being calculated" (date prefix "30 Sep, 08:42" when not today)
//     - muted small text, ellipsised/wrapping, must fit 360 pt at 2x text.
//     - strings localised through AppLocalizations with the English literal as
//       the fallback when it is null (repo pattern `l?.x ?? 'literal'`).
//
//   lib/l10n/app_en.arb gains: asOfTime ("As of {time}"), asOfDateTime
//   ("As of {date}, {time}"), asOfSemantics ("Showing results calculated at
//   {when}; new results are being calculated"); app_localizations*.dart
//   regenerated (de/es/fr/hi/zh fall back to English, as other recent keys do).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/recalc_state.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _t = DateTime(2026, 10, 3, 8, 42);
RecalcState _in(Iterable<String> days, {bool crossDay = false}) => RecalcState(
    days: {...days}, passStartedAt: DateTime(2026, 10, 3, 8, 40), crossDay: crossDay);

Widget _host(Widget child, {double textScale = 1}) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
      ),
    );

void main() {
  group('asOfFor truth table', () {
    test('day in the running pass, with a prior row -> that row\'s time', () {
      expect(
        asOfFor(
            shownDay: '2026-10-03',
            computedAt: _t,
            recalc: _in(['2026-10-03', '2026-10-02'])),
        _t,
      );
    });

    test('day not in the pass -> nothing', () {
      expect(
        asOfFor(
            shownDay: '2026-10-01', computedAt: _t, recalc: _in(['2026-10-03'])),
        isNull,
      );
    });

    test('no computed_at -> nothing, even when the day is recalculating', () {
      expect(
        asOfFor(
            shownDay: '2026-10-03',
            computedAt: null,
            recalc: _in(['2026-10-03'])),
        isNull,
        reason: 'no prior row: the screen keeps its honest building/empty '
            'state; the label never makes a time up',
      );
    });

    test('idle -> nothing', () {
      expect(
        asOfFor(shownDay: '2026-10-03', computedAt: _t, recalc: RecalcState.idle),
        isNull,
      );
    });

    test('null shown day -> nothing', () {
      expect(
        asOfFor(shownDay: null, computedAt: _t, recalc: _in(['2026-10-03'])),
        isNull,
      );
    });

    test('yesterday on screen while only today recalculates -> nothing', () {
      expect(
        asOfFor(
            shownDay: '2026-10-02',
            computedAt: DateTime(2026, 10, 2, 7, 10),
            recalc: _in(['2026-10-03'])),
        isNull,
        reason: 'yesterday keeps its own row and no label',
      );
    });

    test('cross-day: only when the card depends on it AND it is running', () {
      final cd = _in(const [], crossDay: true);
      expect(
          asOfFor(
              shownDay: '2026-09-20',
              computedAt: _t,
              recalc: cd,
              dependsOnCrossDay: true),
          _t);
      expect(
          asOfFor(shownDay: '2026-09-20', computedAt: _t, recalc: cd), isNull,
          reason: 'a per-day card does not depend on the cross-day step');
      expect(
          asOfFor(
              shownDay: '2026-09-20',
              computedAt: _t,
              recalc: _in(const []),
              dependsOnCrossDay: true),
          isNull,
          reason: 'cross-day step is not running');
      expect(
          asOfFor(
              shownDay: '2026-09-20',
              computedAt: null,
              recalc: cd,
              dependsOnCrossDay: true),
          isNull);
    });

    test('returns the row\'s own time, never the pass start or now', () {
      final r = _in(['2026-10-03']);
      final got = asOfFor(shownDay: '2026-10-03', computedAt: _t, recalc: r);
      expect(got, _t);
      expect(got, isNot(r.passStartedAt));
    });
  });

  group('AsOfLabel', () {
    testWidgets('today -> "As of 08:42"', (t) async {
      await t.pumpWidget(_host(AsOfLabel(at: _t, now: DateTime(2026, 10, 3, 9))));
      expect(find.text('As of 08:42'), findsOneWidget);
      expect(find.byKey(const ValueKey('as-of-label')), findsOneWidget);
    });

    testWidgets('single-digit hours and minutes are zero padded, 24 h',
        (t) async {
      await t.pumpWidget(_host(AsOfLabel(
          at: DateTime(2026, 10, 3, 7, 5), now: DateTime(2026, 10, 3, 23))));
      expect(find.text('As of 07:05'), findsOneWidget);
      await t.pumpWidget(_host(AsOfLabel(
          at: DateTime(2026, 10, 3, 20, 5), now: DateTime(2026, 10, 3, 23))));
      expect(find.text('As of 20:05'), findsOneWidget);
    });

    testWidgets('another day -> "As of 30 Sep, 08:42"', (t) async {
      await t.pumpWidget(_host(AsOfLabel(
          at: DateTime(2026, 9, 30, 8, 42), now: DateTime(2026, 10, 3, 9))));
      expect(find.text('As of 30 Sep, 08:42'), findsOneWidget);
    });

    testWidgets('yesterday is dated, not relabelled as today', (t) async {
      await t.pumpWidget(_host(AsOfLabel(
          at: DateTime(2026, 10, 2, 23, 50), now: DateTime(2026, 10, 3, 0, 5))));
      expect(find.text('As of 2 Oct, 23:50'), findsOneWidget);
      expect(find.text('As of 23:50'), findsNothing);
    });

    testWidgets('null -> nothing at all', (t) async {
      await t.pumpWidget(_host(const AsOfLabel(at: null)));
      expect(find.byKey(const ValueKey('as-of-label')), findsNothing);
      expect(find.textContaining('As of'), findsNothing);
      expect(t.getSize(find.byType(AsOfLabel)).height, 0);
    });

    testWidgets('semantics says new results are being calculated', (t) async {
      final h = t.ensureSemantics();
      await t.pumpWidget(_host(AsOfLabel(at: _t, now: DateTime(2026, 10, 3, 9))));
      expect(
        find.bySemanticsLabel(
            'Showing results calculated at 08:42; new results are being calculated'),
        findsOneWidget,
      );
      h.dispose();
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('the dated form fits 360 pt at ${scale}x text', (t) async {
        await t.pumpWidget(_host(
          SizedBox(
            width: 360,
            child: AsOfLabel(
                at: DateTime(2026, 9, 30, 8, 42),
                now: DateTime(2026, 10, 3, 9)),
          ),
          textScale: scale,
        ));
        expect(t.takeException(), isNull, reason: 'overflow');
        expect(t.getSize(find.byKey(const ValueKey('as-of-label'))).width,
            lessThanOrEqualTo(360));
      });
    }
  });
}
