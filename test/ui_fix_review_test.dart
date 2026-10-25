// The owner's locked day-breakdown / review page (2026-10-25 review, r4):
//  - the review happens IN the list: a pending row carries its own Keep /
//    Discard / Edit in a card with the row; no tray, no pagination;
//  - rows that need no review carry no buttons; saved naps and workouts keep
//    a persistent Edit;
//  - a slim Save bar exists only while something is staged and never covers
//    the list's last row;
//  - the old display is back: charger and battery events fold into one group,
//    each kind of event has the right icon, the chart is inline (not pinned),
//    the title counts what waits ("Review activities · N");
//  - saving moves nothing; a chart marker tap reveals exactly its own row,
//    also when several rows share a minute.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/data/moment_label.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/models/activity_suggestion.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart' show activityByName;
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart' show LogWorkout;
import 'package:openstrap_edge/ui2/screens/naps.dart' show NapsScreen;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/apk2_keys.dart';
import 'support/apk2_review_harness.dart';
import 'support/flutter_errors.dart';
import 'support/pin_tz.dart';

const _bar = 'apk2-review-savebar';

/// The ids of every list row (not group rows), top to bottom.
List<String> _rowIds(WidgetTester t) {
  final rows = <(double, String)>[];
  for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(apk2RowPrefix)).evaluate()) {
    final id = (e.widget.key! as ValueKey<String>).value.substring(apk2RowPrefix.length);
    rows.add((t.getTopLeft(find.byWidget(e.widget)).dy, id));
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final r in rows) r.$2];
}

/// Each row's place in the page (scroll offset included), so scrolling to a
/// button does not look like a row moving.
Map<String, double> _tops(WidgetTester t) {
  final scroll = t.state<ScrollableState>(find.descendant(
      of: apk2Key(apk2List), matching: find.byType(Scrollable)));
  return {for (final id in _rowIds(t))
    id: t.getTopLeft(apk2Row(id)).dy + scroll.position.pixels};
}

Future<void> _stored(Apk2Rig r, {List<Map<String, Object?>> naps = const [],
    List<Map<String, Object?>> sessions = const []}) async {
  r.repo.extraTimeline = {'naps': naps, 'sessions': sessions};
}

void main() {
  pinProcessTimeZone('America/Denver');

  group('pending rows', () {
    testWidgets('carry Keep, Discard and Edit in one card with the row', (t) async {
      final semantics = t.ensureSemantics();
      final r = await Apk2Rig.create(t);
      await r.mount(t);
      await apk2Show(t, apk2NapA);
      final p = P.of(t.element(apk2Row(apk2NapA)));
      final card = find.ancestor(of: apk2Keep(apk2NapA),
          matching: find.byWidgetPredicate((w) {
        if (w is! Container) return false;
        final d = w.decoration;
        return d is BoxDecoration && d.color == p.card2 && d.borderRadius != null;
      }));
      expect(card, findsWidgets, reason: 'the row and its buttons share a card');
      for (final inside in [
        find.text('Possible nap'),
        apk2Keep(apk2NapA),
        apk2Discard(apk2NapA),
        apk2Key('day-review-label:$apk2NapA'),
      ]) {
        expect(find.descendant(of: card.first, matching: inside), findsOneWidget);
      }
      // Real buttons: at least a tap target tall.
      for (final b in [apk2Keep(apk2NapA), apk2Discard(apk2NapA),
          apk2Key('day-review-label:$apk2NapA')]) {
        expect(t.getSize(b).height, greaterThanOrEqualTo(44));
      }
      semantics.dispose();
    });

    testWidgets('have no tray and no pagination under the list', (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t);
      for (final key in ['apk2-review-tray', 'apk2-review-next', 'apk2-review-page',
          'apk2-review-previous', 'apk2-review-empty']) {
        expect(apk2Key(key), findsNothing, reason: key);
      }
      expect(find.textContaining(RegExp(r'\d+ of \d+')), findsNothing);
    });
  });

  testWidgets('rows that need no review have no buttons at all', (t) async {
    final r = await Apk2Rig.create(t);
    await r.mount(t);
    final pending = apk2PageIds();
    final others = [for (final id in _rowIds(t)) if (!pending.contains(id)) id];
    expect(others, isNotEmpty);
    expect(others, containsAll([apk2Answered, apk2Meal]));
    for (final id in others) {
      expect(find.descendant(of: apk2Row(id), matching: find.byType(Pressable)),
          findsNothing, reason: '$id carries a button');
    }
    expect(find.text('No review needed'), findsNothing);
    expect(find.text('Already reviewed'), findsNothing);
  });

  testWidgets('saved naps and workouts keep a persistent Edit that opens their editor', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t, pending: false);
    await _stored(r,
        naps: [{'start': apk2At(13), 'end': apk2At(13, 30), 'duration_min': 30}],
        sessions: [{'id': 'stored-run', 'start_ts': apk2At(14),
          'end_ts': apk2At(14, 45), 'type': 'running', 'duration_min': 45}]);
    await r.mount(t);
    final nap = 'nap:${apk2At(13)}', run = 'session:stored-run';
    for (final id in [nap, run]) {
      await apk2Show(t, id);
      expect(apk2Key('day-row-edit:$id'), findsOneWidget, reason: '$id Edit');
      expect(apk2Keep(id), findsNothing, reason: 'reviewed: no Keep');
      expect(apk2Discard(id), findsNothing, reason: 'reviewed: no Discard');
    }
    await apk2Tap(t, apk2Key('day-row-edit:$nap'));
    expect(find.byType(NapsScreen), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await apk2Tap(t, apk2Key('day-row-edit:$run'));
    expect(find.byType(LogWorkout), findsOneWidget);
    semantics.dispose();
  });

  group('the Save bar', () {
    testWidgets('exists only while something is staged and covers no row', (t) async {
      final errors = captureFlutterErrors();
      final r = await Apk2Rig.create(t);
      await r.mount(t);
      expect(apk2Key(_bar), findsNothing);
      final before = _tops(t);
      await apk2Tap(t, apk2Keep(apk2NapA));
      expect(apk2Key(_bar), findsOneWidget);
      final bar = t.getRect(apk2Key(_bar));
      final list = t.getRect(apk2Key(apk2List));
      expect(list.bottom, lessThanOrEqualTo(bar.top + .5),
          reason: 'the list ends where the bar begins, so the last row is not under it');
      // Scrolled to the very end, the last row still clears the bar.
      final scroll = t.state<ScrollableState>(find.descendant(
          of: apk2Key(apk2List), matching: find.byType(Scrollable)));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await t.pump();
      final last = _rowIds(t).last;
      expect(t.getRect(apk2Row(last)).bottom, lessThanOrEqualTo(bar.top + .5));
      scroll.position.jumpTo(0);
      await t.pump();
      expect(_tops(t), before, reason: 'the bar appearing moves no row');
      await apk2Tap(t, apk2Keep(apk2NapA));
      expect(apk2Key(_bar), findsNothing, reason: 'unstaged: no bar');
      expect(errors, isEmpty);
    });
  });

  group('the old display', () {
    testWidgets('folds the charger and battery events into ONE group row', (t) async {
      final r = await Apk2Rig.create(t, pending: false);
      r.repo.extraTimeline = {'events': [
        {'event_id': 7, 'ts': apk2At(3)},
        {'event_id': 8, 'ts': apk2At(3, 1)},
        {'event_id': 21, 'ts': apk2At(3, 2)},
        {'event_id': 22, 'ts': apk2At(3, 3)},
      ]};
      await r.mount(t);
      expect(find.byType(MomentGroupRow), findsOneWidget);
      expect(find.text('Charger and battery · 4 events'), findsOneWidget);
      for (final title in ['On the charger', 'Off the charger',
          'Battery pack attached', 'Battery pack removed']) {
        expect(find.text(title), findsNothing, reason: '$title is collapsed');
      }
      await t.tap(find.byType(MomentGroupRow));
      await t.pump();
      for (final title in ['On the charger', 'Off the charger',
          'Battery pack attached', 'Battery pack removed']) {
        expect(find.textContaining(title), findsOneWidget, reason: '$title once expanded');
      }
    });

    test('every kind of thing has the right icon', () {
      // Marked moments, by what they were answered as.
      expect({
        for (final c in MomentChoice.values) c.name: momentChoiceIcon(c),
      }, {
        'pillsMeds': LucideIcons.pill,
        'nap': LucideIcons.bedDouble,
        'caffeine': LucideIcons.coffee,
        'alcohol': LucideIcons.wine,
        'meal': LucideIcons.utensils,
        'workout': LucideIcons.dumbbell,
        'symptom': LucideIcons.heartPulse,
        'water': LucideIcons.glassWater,
        'other': LucideIcons.bookmark,
      });
      expect(momentChoiceIcon(null), LucideIcons.bookmark);
      // The list rows built from the day's own data.
      final ms = dayMoments(timeline: {
        'day_start': apk2At(0),
        'events': [
          {'event_id': 7, 'ts': apk2At(1)},
          {'event_id': 8, 'ts': apk2At(2)},
          {'event_id': 15, 'ts': apk2At(3)},
          {'event_id': 21, 'ts': apk2At(4)},
          {'event_id': 22, 'ts': apk2At(5)},
          {'event_id': 57, 'ts': apk2At(6)},
        ],
        'naps': [{'start': apk2At(7), 'end': apk2At(8), 'duration_min': 60}],
        'sessions': [{'id': 's', 'start_ts': apk2At(9), 'end_ts': apk2At(10),
          'type': 'running'}],
      }, momentLabels: [
        for (final (i, c) in ['water', 'caffeine', 'meal', 'alcohol', 'other'].indexed)
          MomentLabel(date: apk2Day, hhmm: '${12 + i}:00', label: c, answeredAtMs: 1),
      ]);
      IconData iconAt(int at) => ms.singleWhere((m) => m.at == at).icon;
      expect(iconAt(apk2At(1)), LucideIcons.plugZap, reason: 'on the charger');
      expect(iconAt(apk2At(2)), LucideIcons.unplug, reason: 'off the charger');
      expect(iconAt(apk2At(3)), LucideIcons.rotateCw, reason: 'band restart');
      expect(iconAt(apk2At(4)), LucideIcons.batteryPlus, reason: 'pack attached');
      expect(iconAt(apk2At(5)), LucideIcons.battery, reason: 'pack removed');
      expect(iconAt(apk2At(6)), LucideIcons.alarmClock, reason: 'alarm');
      expect(iconAt(apk2At(7)), LucideIcons.bedDouble, reason: 'nap');
      expect(iconAt(apk2At(9)), activityByName('running')!.icon, reason: 'workout by type');
      expect(iconAt(apk2At(12)), LucideIcons.glassWater, reason: 'water');
      expect(iconAt(apk2At(13)), LucideIcons.coffee, reason: 'caffeine');
      expect(iconAt(apk2At(14)), LucideIcons.utensils, reason: 'meal');
      expect(iconAt(apk2At(15)), LucideIcons.wine, reason: 'alcohol');
      expect(iconAt(apk2At(16)), LucideIcons.bookmark, reason: 'other');
    });

    testWidgets('the title says it is a review and how many wait', (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t);
      expect(find.text('Review activities · 4'), findsOneWidget);
      expect(find.text('Breakdown of your day'), findsNothing);
    });

    testWidgets('a day with nothing to review is the plain Breakdown of your day', (t) async {
      final r = await Apk2Rig.create(t, pending: false);
      await r.mount(t);
      expect(find.text('Breakdown of your day'), findsOneWidget);
      expect(find.textContaining('Review activities'), findsNothing);
    });

    testWidgets('the chart is inline in the scrolling page, not pinned', (t) async {
      final r = await Apk2Rig.create(t);
      await r.mount(t);
      expect(find.descendant(of: apk2Key(apk2List), matching: apk2Key(apk2Chart)),
          findsOneWidget);
      final top = t.getRect(apk2Key(apk2Chart)).top;
      await t.drag(apk2Key(apk2List), const Offset(0, -300));
      await t.pumpAndSettle();
      expect(t.getRect(apk2Key(apk2Chart)).top, lessThan(top - 100),
          reason: 'it scrolls away with the page');
    });
  });

  testWidgets('saving a nap moves no row: those after it keep their offsets', (t) async {
    final semantics = t.ensureSemantics();
    final r = await Apk2Rig.create(t);
    await r.mount(t);
    final before = _tops(t);
    expect(before.keys, contains(apk2NapA));
    await apk2Tap(t, apk2Keep(apk2NapA));
    await apk2Tap(t, apk2Key(apk2Save));
    expect(await r.status(t, apk2NapA), ActivityReviewStatus.confirmed);
    final after = _tops(t);
    expect(after.keys, containsAll(before.keys),
        reason: 'the saved row stays; it is not removed and re-inserted later');
    for (final id in before.keys) {
      expect(after[id], closeTo(before[id]!, .5), reason: '$id moved');
    }
    expect(apk2Keep(apk2NapA), findsNothing, reason: 'no longer waiting');
    semantics.dispose();
  });

  testWidgets('a chart marker tap reveals its own row, also when rows share a minute', (t) async {
    final errors = captureFlutterErrors();
    final r = await Apk2Rig.create(t, pending: false);
    final at = apk2At(13);
    await _stored(r, sessions: [
      {'id': 'run-a', 'start_ts': at, 'end_ts': at + 1800, 'type': 'walking'},
      {'id': 'run-b', 'start_ts': at, 'end_ts': at + 2700, 'type': 'running'},
    ]);
    await r.mount(t);
    const a = 'session:run-a', b = 'session:run-b';
    // The revealed row is tinted, the others are not.
    bool tinted(String id) => t.widget<Container>(apk2Row(id)).color != null;
    // Two workouts at one minute: two chart annotations, ids workout:T and
    // workout:T#1, made from the first and the second row.
    final first = find.byKey(ValueKey('annotation-icon:workout:$at'));
    final second = find.byKey(ValueKey('annotation-icon:workout:$at#1'));
    for (final (icon, want, other) in [(first, a, b), (second, b, a)]) {
      await t.ensureVisible(icon);
      await t.pump();
      await t.tap(icon, warnIfMissed: false);
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(tinted(want), isTrue, reason: '$want is the revealed row');
      expect(tinted(other), isFalse, reason: '$other is not');
      await t.pump(const Duration(seconds: 6));
    }
    expect(errors, isEmpty);
  });
}
