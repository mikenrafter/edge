// Structure: the painter is isolated behind a RepaintBoundary, the
// screen does not overflow at 360 pt and 1.3x text, and absent data draws
// nothing at all.
//
// API: support.dart. ExplorerView.plotKey is the RepaintBoundary
// ITSELF; the scrub cursor (ChartScrub.cursorKey) is outside it, so moving a
// finger repaints the cursor and not the plot. Chosen chips and the picker
// wrap instead of overflowing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart' show specOf;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';

String _back(int back) {
  final d = DateTime(2026, 10, 4 - back);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

const _four = ['resting_hr', 'hrv', 'readiness', 'steps'];

ExplorerRepo _daily() => ExplorerRepo(charts: {
      for (final k in _four)
        specOf(k).chartKey: [
          for (var i = 0; i < 40; i++)
            if (i % 7 != 3) pt(_back(i), 40.0 + (i * 7) % 11),
        ],
    });

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('RepaintBoundary (AGENTS 4.11)', () {
    testWidgets('the plot painter is wrapped in one, and the key names it',
        (t) async {
      await pumpExplorer(t, _daily());
      await tapKey(t, 'explore-pick:hrv');
      expect(t.widget(find.byKey(ExplorerView.plotKey)), isA<RepaintBoundary>());
      expect(
          find.descendant(
              of: find.byKey(ExplorerView.plotKey),
              matching: find.byWidgetPredicate(
                  (w) => w is CustomPaint && w.painter is ExplorePlotPainter)),
          findsOneWidget);
    });

    testWidgets('the scrub cursor is outside the boundary, so scrubbing never repaints the plot',
        (t) async {
      await pumpExplorer(t, _daily());
      await tapKey(t, 'explore-pick:hrv');
      await scrubAt(t, .5);
      expect(find.byKey(ChartScrub.cursorKey), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(ExplorerView.plotKey),
              matching: find.byKey(ChartScrub.cursorKey)),
          findsNothing);
    });

    testWidgets('the same holds on the day scale', (t) async {
      final start = localDayStartSec('2026-10-03')!;
      final repo = ExplorerRepo(timelines: {
        '2026-10-03': {
          'date': '2026-10-03',
          'day_start': start,
          'hr': [
            for (var m = 0; m < 30; m++) {'t': start + m * 60, 'v': 60 + m},
          ],
        },
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-scale:day');
      await tapKey(t, 'explore-day-prev');
      await tapKey(t, 'explore-pick:hr');
      expect(t.widget(find.byKey(ExplorerView.plotKey)), isA<RepaintBoundary>());
    });
  });

  group('layout', () {
    for (final (name, w, scale) in [
      ('360 pt', 360.0, 1.0),
      ('360 pt, text 1.3x', 360.0, 1.3),
      ('320 pt, text 1.3x', 320.0, 1.3),
    ]) {
      testWidgets('daily with four metrics at $name does not overflow',
          (t) async {
        await pumpExplorer(t, _daily(), width: w, scale: scale, height: 4000);
        for (final k in _four) {
          await tapKey(t, 'explore-pick:$k');
        }
        await tapKey(t, 'explore-z:resting_hr');
        await scrubAt(t, .4);
        expect(t.takeException(), isNull);
        // Every chip is on screen horizontally.
        for (final k in _four) {
          final r = t.getRect(chip(k));
          expect(r.left, greaterThanOrEqualTo(0), reason: k);
          expect(r.right, lessThanOrEqualTo(w), reason: k);
        }
        final plot = t.getRect(find.byKey(ExplorerView.plotKey));
        expect(plot.right, lessThanOrEqualTo(w));
        expect(plot.height, greaterThan(100));
      });

      testWidgets('the day scale with every lane at $name does not overflow',
          (t) async {
        final start = localDayStartSec('2026-10-03')!;
        final repo = ExplorerRepo(timelines: {
          '2026-10-03': {
            'date': '2026-10-03',
            'day_start': start,
            'hr': [for (var m = 0; m < 600; m++) {'t': start + m * 60, 'v': 60 + m % 30}],
            'hrv': [for (var m = 0; m < 600; m += 5) {'t': start + m * 60, 'v': 40 + m % 20}],
            'resp': [for (var m = 0; m < 600; m += 5) {'t': start + m * 60, 'v': 14}],
            'activity': [for (var m = 0; m < 600; m += 5) {'t': start + m * 60, 'v': .3}],
            'sleep': [{'onset_ts': start - 3600, 'wake_ts': start + 6 * 3600}],
            'sessions': [{'start_ts': start + 8 * 3600, 'end_ts': start + 9 * 3600}],
          },
        }, calorieCurves: {
          '2026-10-03': {
            'minutes': [for (var m = 0; m < 100; m++) {'t': start + m * 60, 'active': 1.0, 'total': 2.0, 'basal': 1.0}],
          },
        });
        await pumpExplorer(t, repo, width: w, scale: scale, height: 4000);
        await tapKey(t, 'explore-scale:day');
        await tapKey(t, 'explore-day-prev');
        for (final k in ['hr', 'hrv', 'resp', 'calories']) {
          await tapKey(t, 'explore-pick:$k');
        }
        await scrubAt(t, .1);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('the picker alone (nothing chosen) does not overflow at 360 pt, 1.3x',
        (t) async {
      await pumpExplorer(t, _daily(), width: 360, scale: 1.3);
      expect(t.takeException(), isNull);
    });
  });

  group('absent data draws nothing', () {
    testWidgets('no zero line, no flat line, no axis for metrics with no readings',
        (t) async {
      await pumpExplorer(t, ExplorerRepo());
      for (final k in ['hrv', 'steps']) {
        await tapKey(t, 'explore-pick:$k');
      }
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      expect(
          find.byWidgetPredicate(
              (w) => w is CustomPaint && w.painter is ExplorePlotPainter),
          findsNothing);
      expect(find.byKey(const ValueKey('explore-no-data')), findsOneWidget);
      expect(find.byKey(const ValueKey('explore-normalised-note')), findsNothing,
          reason: 'nothing is normalised, so nothing says it was');
    });

    testWidgets('a metric with data beside one without: only the real one is drawn',
        (t) async {
      final repo = ExplorerRepo(charts: {
        specOf('hrv').chartKey: [for (var i = 0; i < 10; i++) pt(_back(i), 50.0 + i)],
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-pick:hrv');
      await tapKey(t, 'explore-pick:steps');
      final p = plotPainter(t);
      expect([for (final l in p.lines) l.key], ['hrv']);
      for (final l in p.lines) {
        for (final r in l.runs) {
          for (final pt in r) {
            expect(pt.y.isFinite, isTrue);
          }
        }
      }
    });

    testWidgets('a readout before anything is scrubbed never invents a value',
        (t) async {
      final repo = ExplorerRepo(charts: {
        specOf('hrv').chartKey: [pt(_back(40), 50)],
      });
      await pumpExplorer(t, repo);
      await tapKey(t, 'explore-pick:hrv');
      // 40 days back is outside the default 30: nothing to read.
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      expect(find.text('0'), findsNothing);
    });
  });
}
