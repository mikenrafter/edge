// Scrub panel on every chart: the Data Explorer (multi-series, normalised).
// RED tests; the contract is documented in support/scrub_panel_laws.dart.
// The Explorer has one panel for the whole chart, whichever and however many
// series are picked. Its days are the explorer's own fixed week (kWeek,
// today = kToday), not DateTime.now(), so the dataset is built here and the
// shared "which day does the caption name" check is replaced by kWeek.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:openstrap_edge/ui2/screens/screens.dart' show specOf;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart';
import 'support/scrub_panel_laws.dart';

// kToday = Sun 4 Oct 2026; slot i of the d7 window is kWeek[i].
const _gapDay = '2026-10-02'; // slot 4: no value
const _olderDay = '2026-09-30'; // slot 2: older calculation
const _slotOf = {
  '2026-09-28': 0, '2026-09-29': 1, '2026-09-30': 2, '2026-10-01': 3,
  '2026-10-02': 4, '2026-10-03': 5, '2026-10-04': 6,
};

List<Map<String, dynamic>> _rhr({bool olderLatest = false, int base = 50}) => [
      for (final d in kWeek)
        if (d != _gapDay)
          {
            ...pt(d, base + _slotOf[d]!),
            if (d == _olderDay || (olderLatest && d == kToday))
              'from_older_version': 104,
          },
    ];

Finder _frame() => find.byType(ChartFrame);
Finder _panel() =>
    find.descendant(of: _frame().first, matching: find.byKey(panelKey));

Future<void> _open(WidgetTester t,
    {double width = 390,
    double scale = 1,
    bool olderLatest = false,
    List<String> picks = const ['resting_hr']}) async {
  await pumpExplorer(
      t,
      ExplorerRepo(charts: {
        specOf('resting_hr').chartKey: _rhr(olderLatest: olderLatest),
        specOf('hrv').chartKey: [
          for (final d in kWeek) pt(d, 30 + _slotOf[d]!)
        ],
      }),
      width: width,
      scale: scale);
  await tapKey(t, 'explore-range:d7');
  for (final k in picks) {
    await tapKey(t, 'explore-pick:$k');
  }
}

Future<void> _scrubSlot(WidgetTester t, int slot) => scrubAt(t, (slot + .5) / 7);

Color _series(WidgetTester t) =>
    t.widget<ChartScrub>(find.byType(ChartScrub)).keys.first.color;

bool _names(String cap, String day) {
  final c = cap.toLowerCase();
  final d = DateTime.parse(day);
  const wd = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  return c.contains(wd[d.weekday - 1]) && RegExp('\\b${d.day}\\b').hasMatch(c);
}

void main() {
  setUpAll(() async {
    await initPrefs();
    await loadType();
  });
  setUp(clearPrefs);

  group('scrub panel: Explorer, one series', () {
    testWidgets('at rest: LATEST, the latest day, value and unit', (t) async {
      await _open(t);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      final cap = captionOf(t, _panel());
      expect(cap.toLowerCase(), startsWith('latest'));
      expect(_names(cap, kToday), isTrue, reason: '"$cap"');
      expect(valueOf(t, _panel()), '56bpm');
    });

    testWidgets('scrubbing: SELECTED, the scrubbed day, its value, a border '
        'in the series colour', (t) async {
      await _open(t);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      await _scrubSlot(t, 3);
      final cap = captionOf(t, _panel());
      expect(cap.toLowerCase(), startsWith('selected'));
      expect(_names(cap, '2026-10-01'), isTrue, reason: '"$cap"');
      expect(valueOf(t, _panel()), '53bpm');
      final b = decorationOf(t, _panel()).border;
      expect(b, isNotNull);
      expect(rgb(b!.top.color), rgb(_series(t)));
      final capText = t.widget<Text>(
          find.descendant(of: _panel(), matching: find.byKey(captionKey)));
      expect(rgb(capText.style!.color!), rgb(_series(t)));
    });

    testWidgets('a gap day reads "—"', (t) async {
      await _open(t);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      await _scrubSlot(t, 4);
      expect(captionOf(t, _panel()).toLowerCase(), startsWith('selected'));
      expect(valueOf(t, _panel()), startsWith('—'));
    });

    testWidgets('the panel and the frame do not move: rest, scrub, gap, '
        'older day', (t) async {
      await _open(t);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      final rect = t.getRect(_panel());
      final frame = t.getRect(_frame().first);
      for (final slot in [3, 4, 2, 6]) {
        await _scrubSlot(t, slot);
        expect(t.getRect(_panel()), rect, reason: 'slot $slot');
        expect(t.getRect(_frame().first), frame, reason: 'slot $slot');
      }
    });

    testWidgets('inset style: card2, rMd', (t) async {
      await _open(t);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      final d = decorationOf(t, _panel());
      expect(d.color, P.of(t.element(_panel())).card2);
      expect(d.borderRadius, R.rMd);
    });

    testWidgets('latest older: strip inside the inset on load, unchanged '
        'after a scrub, panel does not move', (t) async {
      await _open(t, olderLatest: true);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      expect(noteIn(_panel()), findsOneWidget);
      expect(
          find.descendant(
              of: _panel(), matching: find.byIcon(LucideIcons.history)),
          findsOneWidget);
      final rect = t.getRect(_panel());
      final at = t.getTopLeft(noteIn(_panel()));
      await _scrubSlot(t, 3);
      expect(noteIn(_panel()), findsOneWidget);
      expect(t.getTopLeft(noteIn(_panel())), at);
      expect(t.getRect(_panel()), rect);
    });

    testWidgets('latest current: scrubbing onto an older day shows the * in '
        'the inset and no reason row', (t) async {
      await _open(t);
      expect(_panel(), findsOneWidget, reason: 'no panel at rest');
      expect(noteIn(_panel()), findsNothing);
      final rect = t.getRect(_panel());
      await _scrubSlot(t, 2);
      expect(markIn(_panel()), findsOneWidget);
      expect(noteIn(_panel()), findsNothing);
      expect(t.getRect(_panel()), rect);
    });
  });

  group('scrub panel: Explorer, several series', () {
    testWidgets('two series: still ONE panel, the same rect at rest and '
        'scrubbing, and both series speak in it', (t) async {
      await _open(t, picks: const ['resting_hr', 'hrv']);
      expect(find.byKey(panelKey), findsOneWidget, reason: 'no panel at rest');
      final rect = t.getRect(_panel());
      expect(captionOf(t, _panel()).toLowerCase(), startsWith('latest'));
      await _scrubSlot(t, 3);
      expect(find.byKey(panelKey), findsOneWidget);
      expect(t.getRect(_panel()), rect);
      expect(captionOf(t, _panel()).toLowerCase(), startsWith('selected'));
      final all = [
        for (final x in t.widgetList<Text>(
            find.descendant(of: _panel(), matching: find.byType(Text))))
          x.data ?? ''
      ].join(' ');
      expect(all, contains('53'), reason: 'resting HR on 1 Oct');
      expect(all, contains('33'), reason: 'HRV on 1 Oct');
    });
  });

  for (final w in [360.0, 390.0]) {
    for (final s in [1.0, 1.3]) {
      testWidgets('Explorer: no overflow at width $w, text scale $s',
          (t) async {
        await _open(t,
            width: w,
            scale: s,
            olderLatest: true,
            picks: const ['resting_hr', 'hrv']);
        expect(_panel(), findsOneWidget, reason: 'no panel at rest');
        expect(t.takeException(), isNull);
        final box = t.getRect(_frame().first);
        final rect = t.getRect(_panel());
        expect(rect.left, greaterThanOrEqualTo(box.left - .01));
        expect(rect.right, lessThanOrEqualTo(box.right + .01));
        await _scrubSlot(t, 3);
        expect(t.takeException(), isNull);
        expect(t.getRect(_panel()), rect);
        await _scrubSlot(t, 4);
        expect(t.takeException(), isNull);
        expect(t.getRect(_panel()), rect);
      });
    }
  }
}
