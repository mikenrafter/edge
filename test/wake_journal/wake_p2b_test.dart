// P2b contracts. Fixed observed instants; run with TZ=UTC.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';

import 'fixtures.dart';
import 'wake_widgets_test.dart' show chartDay, pumpWakePage, sleepFixture;

const _labels = [
  'Natural wake ×3',
  'Gradual wake',
  'Alarm',
  'Snooze ×2',
  'Snooze stopped',
  "I'm up",
];
const _icons = [
  LucideIcons.moon,
  LucideIcons.vibrate,
  LucideIcons.alarmClock,
  LucideIcons.alarmClockMinus,
  LucideIcons.alarmClockOff,
  LucideIcons.sunrise,
];
WakeNightTimeline _night() =>
    WakeNightTimeline.forEpoch(wakeEpochSec: epoch, trace: fullTrace());

ChartAnnotation _point(
  String id,
  double at, [
  AnnotationKind kind = AnnotationKind.moment,
]) => ChartAnnotation(id: id, kind: kind, at: at, label: id);

Future<void> _lane(WidgetTester t, List<ChartAnnotation> marks) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: ChartAnnotationLane(
            set: AnnotationSet(items: marks, domainStart: 0, domainEnd: 600),
            cursor: null,
            plotHeight: 100,
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

List<AnnotationLine> _lines(WidgetTester t) =>
    (t.widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey)).painter
            as AnnotationLinesPainter)
        .lines;

String _clock(double seconds) {
  final at = DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).round(),
    isUtc: true,
  );
  return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

AnnotationSet _sleepAxis(WidgetTester t) => t
    .widget<ChartAnnotationLane>(
      find.descendant(
        of: find.byKey(const ValueKey('card:night')),
        matching: find.byType(ChartAnnotationLane),
      ),
    )
    .set;

ChartFrame _sleepFrame(WidgetTester t) => t
    .widgetList<ChartFrame>(find.byType(ChartFrame))
    .firstWhere((frame) => frame.title == 'Through the night');

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    ClockFormatController.seed(ClockFormat.h24);
  });

  test(
    'same-type wake projection collapses at first fire, preserving raw observations',
    () {
      final night = _night();
      expect(night.events, hasLength(9)); // Raw audit history remains intact.
      expect(night.collapsedEvents.map((e) => e.kind), [
        WakeNightEventKind.natural,
        WakeNightEventKind.gradual,
        WakeNightEventKind.alarm,
        WakeNightEventKind.snooze,
        WakeNightEventKind.snoozeStop,
        WakeNightEventKind.ack,
      ]);
      expect(
        night.collapsedEvents.map((e) => e.at),
        [-20, -15, 0, 1, 8, 8].map(atMinute),
      );
      expect(night.collapsedEvents.first.count, 3);
      expect(night.collapsedEvents[3].count, 2);
      expect(night.timeToWake, const Duration(minutes: 28));
      expect(night.snoozeCount, 2);
    },
  );

  test(
    'collapse keeps two recorded wake-ups separate even when kinds match',
    () {
      final combined = WakeNightTimeline(
        events: [
          WakeNightEvent(
            kind: WakeNightEventKind.natural,
            at: atMinute(-20),
            wakeEpochSec: epoch,
          ),
          WakeNightEvent(
            kind: WakeNightEventKind.repeat,
            at: atMinute(-19),
            wakeEpochSec: epoch,
          ),
          WakeNightEvent(
            kind: WakeNightEventKind.ack,
            at: atMinute(8),
            wakeEpochSec: epoch,
          ),
          WakeNightEvent(
            kind: WakeNightEventKind.natural,
            at: atMinute(40),
            wakeEpochSec: epoch + 3600,
          ),
          WakeNightEvent(
            kind: WakeNightEventKind.repeat,
            at: atMinute(41),
            wakeEpochSec: epoch + 3600,
          ),
          WakeNightEvent(
            kind: WakeNightEventKind.ack,
            at: atMinute(68),
            wakeEpochSec: epoch + 3600,
          ),
        ],
      );
      expect(combined.collapsedEvents.map((e) => e.kind), [
        WakeNightEventKind.natural,
        WakeNightEventKind.ack,
        WakeNightEventKind.natural,
        WakeNightEventKind.ack,
      ]);
      expect(
        combined.collapsedEvents.map((e) => e.at),
        [-20, 8, 40, 68].map(atMinute),
      );
      expect(
        combined.collapsedEvents
            .where((e) => e.kind == WakeNightEventKind.natural)
            .map((e) => e.count),
        [2, 2],
      );
    },
  );

  test(
    'chart and list projections share collapsed labels and six distinct icons',
    () {
      final moments = dayMoments(timeline: chartDay(), wakeTimeline: _night());
      final wakes = moments
          .where((m) => m.annotationKind == AnnotationKind.wake)
          .toList();
      expect(wakes.map((m) => m.title), _labels);
      expect(wakes.map((m) => m.icon), _icons);
      expect(dayAnnotations(wakes).map((a) => a.label), _labels);
      expect(
        wakeAnnotations(_night()).map((a) => a.at),
        [
          -20,
          -15,
          0,
          1,
          8,
          8,
        ].map((m) => atMinute(m).millisecondsSinceEpoch / 1000),
      );
    },
  );

  testWidgets('actual annotation glyphs distinguish all wake kinds', (t) async {
    // Space the six projected marks apart so each icon is independently visible.
    final marks = wakeAnnotations(_night());
    expect(marks, hasLength(6));
    for (var i = 0; i < marks.length; i++) {
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: ChartAnnotationLane(
                set: AnnotationSet(
                  items: [marks[i]],
                  domainStart: marks[i].at - 100,
                  domainEnd: marks[i].at + 100,
                ),
                cursor: null,
                plotHeight: 100,
              ),
            ),
          ),
        ),
      );
      final glyph = find.descendant(
        of: find.byType(AnnotationIcon),
        matching: find.byType(Icon),
      );
      expect(t.widget<Icon>(glyph).icon, _icons[i], reason: _labels[i]);
    }
  });

  testWidgets(
    'one wake-up is one expandable row containing collapsed kind rows',
    (t) async {
      final raw = chartDay();
      final data = TimelineData(
        day: '2026-10-26',
        graph: dayGraph(raw),
        moments: dayMoments(timeline: raw, wakeTimeline: _night()),
      );
      await pumpWakePage(
        t,
        Builder(
          builder: (c) => Scaffold(
            body: ListView(children: timelineBody(c, data, fineDetail: false)),
          ),
        ),
      );
      final summary = find.text('Wake-up 06:40–07:08 · 28 min to wake');
      expect(summary, findsOneWidget);
      expect(find.text('Natural wake ×3'), findsNothing);
      await t.tap(summary);
      await t.pumpAndSettle();
      for (final label in _labels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await t.tap(summary);
      await t.pumpAndSettle();
      expect(find.text('Natural wake ×3'), findsNothing);
    },
  );

  testWidgets(
    'an acknowledgement without fire keeps the grouped duration unknown',
    (t) async {
      final night = WakeNightTimeline.forEpoch(
        wakeEpochSec: epoch,
        trace: [row('ack', 8)],
      );
      final data = TimelineData(
        day: '2026-10-26',
        moments: dayMoments(timeline: chartDay(), wakeTimeline: night),
      );
      await pumpWakePage(
        t,
        Builder(
          builder: (c) => Scaffold(
            body: ListView(children: timelineBody(c, data, fineDetail: false)),
          ),
        ),
      );
      expect(find.textContaining('Time to wake: —'), findsOneWidget);
      expect(find.textContaining('0 min to wake'), findsNothing);
    },
  );

  test('generic thin cluster has a shaded time range', () {
    final layout = layoutAnnotations(
      annotations: [_point('a', 100), _point('b', 103), _point('c', 110)],
      scale: const AnnotationScale(domainStart: 0, domainEnd: 600, width: 300),
    );
    expect(layout.items, hasLength(1));
    expect(layout.items.single.memberIds, ['a', 'b', 'c']);
    expect(layout.shades, hasLength(1));
    // 300px / 600 time units: the span 100..110 is exactly 50..55px.
    expect(layout.shades.single.left, 50);
    expect(layout.shades.single.right, 55);
  });

  test(
    'cluster geometry exposes two proportional edges with a distinct end colour',
    () {
      final geometry = annotationGeometry(
        annotations: [_point('a', 100), _point('b', 103), _point('c', 110)],
        scale: const AnnotationScale(
          domainStart: 0,
          domainEnd: 600,
          width: 300,
        ),
      );
      final lines = geometry.lines.toList()..sort((a, b) => a.x.compareTo(b.x));
      expect(lines.map((l) => l.x), [50, 55]);
      expect(lines.first.color, isNot(lines.last.color));
      expect(geometry.shades.single.left, 50);
      expect(geometry.shades.single.right, 55);
    },
  );

  test(
    'range geometry retains primary edges and only the outer side lines',
    () {
      final geometry = annotationGeometry(
        annotations: [
          _point('before', 70, AnnotationKind.water),
          _point('near-before', 75, AnnotationKind.water),
          const ChartAnnotation(
            id: 'range',
            kind: AnnotationKind.mainSleep,
            at: 80,
            until: 100,
            label: 'Main sleep',
          ),
          _point('after', 104, AnnotationKind.symptom),
          _point('middle', 108, AnnotationKind.symptom),
          _point('last', 110, AnnotationKind.symptom),
        ],
        scale: const AnnotationScale(
          domainStart: 0,
          domainEnd: 600,
          width: 300,
        ),
      );
      expect((geometry.lines.map((l) => l.x).toList()..sort()), [
        35,
        40,
        50,
        55,
      ]);
      final primary = geometry.shades.singleWhere((s) => s.id == 'range');
      expect((primary.left, primary.right), (40, 50));
    },
  );

  test(
    'a cluster widened to fit a narrow lane still has only its true outer edges',
    () {
      final marks = [
        _point('first', 0),
        _point('middle', 300),
        _point('last', 600),
      ];
      const scale = AnnotationScale(domainStart: 0, domainEnd: 600, width: 60);
      final layout = layoutAnnotations(annotations: marks, scale: scale);
      expect(layout.items.single.memberIds, ['first', 'middle', 'last']);
      final geometry = annotationGeometry(annotations: marks, scale: scale);
      expect((geometry.lines.map((l) => l.x).toList()..sort()), [0, 60]);
      expect(
        (geometry.shades.single.left, geometry.shades.single.right),
        (0, 60),
      );
    },
  );

  testWidgets(
    'same-kind thin cluster draws both true-time edges in different colours',
    (t) async {
      await _lane(t, [_point('a', 100), _point('b', 103), _point('c', 110)]);
      final lines = _lines(t)..sort((a, b) => a.x.compareTo(b.x));
      expect(lines.map((l) => l.x), [50, 55]);
      expect(lines.last.color, isNot(lines.first.color));
      expect(find.text('+2'), findsOneWidget);
      // Cycling focus must keep the geometry at the first/last event times.
      await t.tap(find.text('+2'));
      await t.pump();
      expect((_lines(t).map((l) => l.x).toList()..sort()), [50, 55]);
    },
  );

  testWidgets(
    'primary duration survives crowding with at most one line on either side',
    (t) async {
      await _lane(t, [
        _point('before', 70, AnnotationKind.water),
        _point('near-before', 75, AnnotationKind.water),
        const ChartAnnotation(
          id: 'range',
          kind: AnnotationKind.mainSleep,
          at: 80,
          until: 100,
          label: 'Main sleep',
        ),
        _point('after', 104, AnnotationKind.symptom),
        _point('middle', 108, AnnotationKind.symptom),
        _point('last', 110, AnnotationKind.symptom),
      ]);
      final lines = _lines(t)..sort((a, b) => a.x.compareTo(b.x));
      expect(lines.map((l) => l.x), [35, 40, 50, 55]);
      expect(lines.first.color, isNot(lines.last.color));
      final shade = find.byKey(ChartAnnotationLane.shadeKey('range'));
      expect(shade, findsOneWidget);
      expect(t.getSize(shade).width, 10); // (100 - 80) * 300 / 600
      expect(find.byKey(ChartAnnotationLane.iconKey('range')), findsOneWidget);
    },
  );

  testWidgets('display setting defaults on and can be switched off', (t) async {
    expect(Prefs.sleepWakeZoomOn, isTrue);
    var enabled = true;
    await pumpWakePage(
      t,
      StatefulBuilder(
        builder: (c, setState) => MoreSettingsView(
          sleepWakeZoom: enabled,
          onToggleSleepWakeZoom: () => setState(() => enabled = !enabled),
        ),
      ),
    );
    final row = find.text('Zoom wake-up events');
    expect(row, findsOneWidget);
    await t.tap(row);
    await t.pumpAndSettle();
    expect(enabled, isFalse);
  });

  testWidgets(
    'sleep zoom labels both endpoints, reacts to toggle, and persists off',
    (t) async {
      Prefs.setSleepWakeZoom(true);
      await pumpWakePage(t, SleepDetail(data: sleepFixture()));
      final zoom = _sleepFrame(t);
      final axis = _sleepAxis(t);
      final onset = atMinute(-480).millisecondsSinceEpoch / 1000;
      expect(axis.domainStart, greaterThan(onset));
      expect(
        axis.domainStart,
        lessThanOrEqualTo(atMinute(-20).millisecondsSinceEpoch / 1000),
      );
      expect(zoom.xLabels.first, _clock(axis.domainStart));
      expect(zoom.xLabels.last, _clock(axis.domainEnd));
      Prefs.setSleepWakeZoom(false);
      await t.pumpAndSettle();
      expect(_sleepAxis(t).domainStart, onset);
      expect(
        (await SharedPreferences.getInstance()).getBool(Prefs.sleepWakeZoom),
        false,
      );
      // A newly built screen reads the saved OFF value without an ON flash.
      await t.pumpWidget(const SizedBox());
      await pumpWakePage(t, SleepDetail(data: sleepFixture()));
      expect(_sleepAxis(t).domainStart, onset);
      Prefs.setSleepWakeZoom(true);
    },
  );

  test(
    'zoom resampling keeps stage boundaries and the unobserved tail at their times',
    () {
      final stages = SleepData.stagesOf(
        sleepFixture().night,
        domainStart: atMinute(-30).millisecondsSinceEpoch ~/ 1000,
        domainEnd: atMinute(18).millisecondsSinceEpoch ~/ 1000,
      );
      // 48 minutes / 240 columns = 12 seconds per column.
      expect(stages[0], SleepStage.light);
      expect(stages[49], SleepStage.light);
      expect(stages[50], SleepStage.rem); // 06:40, original REM start.
      expect(stages[190], SleepStage.awake); // 07:08, last observation.
      expect(stages[191], isNull);
      expect(stages.last, isNull);
    },
  );

  testWidgets('zoomed hypnogram and full-night signals select the same instant', (
    t,
  ) async {
    final fixture = sleepFixture();
    await pumpWakePage(
      t,
      SleepDetail(
        data: SleepData(
          day: fixture.day,
          night: fixture.night,
          wakeTimeline: fixture.wakeTimeline,
          timeline: {
            'hr': [
              for (var minute = -480; minute <= 8; minute++)
                {
                  't': atMinute(minute).millisecondsSinceEpoch ~/ 1000,
                  'v': 55.0,
                },
            ],
          },
        ),
      ),
    );
    Scrubber scrubber(String label) => t.widget<Scrubber>(
      find.byWidgetPredicate((w) => w is Scrubber && w.label == label),
    );
    scrubber('Hypnogram').onChanged(.5);
    await t.pump();
    // Zoom spans 06:30..07:08; its midpoint is 06:49.
    // Full night spans 23:00..07:08, so the same instant is 469/488 through it.
    expect(scrubber('Through the night').value, closeTo(469 / 488, 1e-9));
    expect(scrubber('Hypnogram').value, .5);
    scrubber('Through the night').onChanged(.5);
    await t.pump();
    expect(
      scrubber('Hypnogram').value,
      isNull,
      reason: 'the earlier selected instant is outside the zoomed window',
    );
    final panels = t.widgetList<ChartKeyReadout>(find.byType(ChartKeyReadout));
    expect(panels.map((p) => p.time).toSet(), {'03:04'});
  });

  for (final locale in ['en', 'de', 'es', 'fr', 'hi', 'ru', 'zh']) {
    test('group/count/zoom labels are localized in $locale', () {
      final arb =
          jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
              as Map;
      for (final key in [
        'sleepWakeZoom',
        'sleepWakeZoomDescription',
        'wakeJournalCount',
        'wakeJournalGroup',
      ]) {
        expect(arb[key], isA<String>(), reason: '$locale/$key');
        expect((arb[key] as String).trim(), isNotEmpty);
      }
      expect(arb['wakeJournalCount'], contains('{event}'));
      expect(arb['wakeJournalCount'], contains('{count}'));
      expect(arb['wakeJournalGroup'], contains('{start}'));
      expect(arb['wakeJournalGroup'], contains('{end}'));
      expect(arb['wakeJournalGroup'], contains('{minutes}'));
    });
  }
}
