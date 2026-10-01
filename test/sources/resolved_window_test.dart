// The resolved-data window is the user's to set: a few presets, or no cutoff.
// Three days is only the default.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/sources/resolved_window.dart';
import 'package:openstrap_edge/ui2/sources/resolved_data_view.dart';
import 'package:openstrap_edge/ui2/theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the stored choice', () {
    test('defaults to 3 days', () async {
      expect(kDefaultResolvedWindowDays, 3);
      expect(await loadResolvedWindowDays(), 3);
    });

    test('round-trips a preset', () async {
      await saveResolvedWindowDays(14);
      expect(await loadResolvedWindowDays(), 14);
    });

    test('round-trips no cutoff as null, not as the default', () async {
      await saveResolvedWindowDays(null);
      expect(await loadResolvedWindowDays(), isNull);
    });

    test('a stored value that is not a choice falls back to the default',
        () async {
      SharedPreferences.setMockInitialValues({'resolved_window_days': 5});
      expect(await loadResolvedWindowDays(), 3);
    });

    test('offers 1, 3, 7, 14, 30 days and no cutoff', () {
      expect(kResolvedWindowChoices, [1, 3, 7, 14, 30, null]);
    });
  });

  group('the window start', () {
    // Local calendar arithmetic: 2026-03-29 is the spring-forward day in
    // Europe, so a 24 h step would land an hour off. Whatever the zone of the
    // machine running this, the start must be a local midnight.
    final now = DateTime(2026, 10, 1, 15, 30);

    test('N days is N local calendar days ending today', () {
      final start = DateTime.fromMillisecondsSinceEpoch(
        resolvedWindowStart(now, 3) * 1000,
      );
      expect(start, DateTime(2026, 9, 29));
      expect(
        DateTime.fromMillisecondsSinceEpoch(
          resolvedWindowStart(now, 1) * 1000,
        ),
        DateTime(2026, 10, 1),
      );
    });

    test('a window spanning a DST change still starts at local midnight', () {
      final late = DateTime(2026, 4, 2, 9);
      final start = DateTime.fromMillisecondsSinceEpoch(
        resolvedWindowStart(late, 7) * 1000,
      );
      expect(start, DateTime(2026, 3, 27));
    });

    test('no cutoff starts at the earliest recorded second', () {
      expect(resolvedWindowStart(now, null, earliest: 1700000000), 1700000000);
    });

    test('no cutoff with nothing recorded is an empty window, not 1970', () {
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      expect(resolvedWindowStart(now, null), nowSec);
    });
  });

  group('the words', () {
    test('say what the window is', () {
      expect(resolvedWindowLabel(1), 'today');
      expect(resolvedWindowLabel(3), 'the last 3 days');
      expect(resolvedWindowLabel(null), 'all recorded time');
    });
  });

  group('the row cap', () {
    List<Map<String, Object?>> rows(int n) => [
          for (var i = 0; i < n; i++) {'start': i, 'end': i + 1},
        ];

    test('keeps everything under the cap', () {
      final r = capResolvedRows(rows(5), cap: 10);
      expect((r.rows.length, r.total), (5, 5));
    });

    test('over the cap keeps the most recent and reports the total', () {
      final r = capResolvedRows(rows(30), cap: 10);
      expect(r.rows.length, 10);
      expect(r.total, 30);
      expect(r.rows.first['start'], 20);
      expect(r.rows.last['start'], 29);
    });
  });

  group('the picker', () {
    Future<void> pump(WidgetTester t, int? days, ValueChanged<int?> on) =>
        t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: ResolvedWindowPicker(days: days, onChanged: on),
          ),
        ));

    testWidgets('names every choice, including no cutoff', (t) async {
      await pump(t, 3, (_) {});
      expect(find.text('3 days'), findsOneWidget);
      expect(find.text('1 day'), findsOneWidget);
      expect(find.text('No cutoff'), findsOneWidget);
    });

    testWidgets('picking no cutoff reports null', (t) async {
      int? picked = 3;
      var called = false;
      await pump(t, 3, (v) {
        picked = v;
        called = true;
      });
      await t.ensureVisible(find.text('No cutoff'));
      await t.tap(find.text('No cutoff'));
      expect(called, isTrue);
      expect(picked, isNull);
    });
  });
}
