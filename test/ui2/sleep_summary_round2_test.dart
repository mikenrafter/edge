// WHY: owner phone feedback, CLAIM(sleep-summary-r2). Read the real card:
// coverage is not a sleep timestamp; sent alerts retain their audit trail.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/recalc_state.dart';
import '../support/as_of_recalc_fakes.dart' show SleepRepo;
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_summary.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import '../sleep_v6_render_test.dart' show renderApp;
import '../support/skeleton_fixture.dart';

class _CoverageRepo extends SleepRepo {
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => DateTime(2026, 11, 14, 23, 59);
}

DateTime local(int day, int hour, [int minute = 0, int second = 0]) => DateTime(2026, 11, day, hour, minute, second);
SleepSummaryInterval night(DateTime start, DateTime end) => SleepSummaryInterval(id: 'main', start: start, end: end);
WakeNightEvent sent(DateTime at, {WakeNightEventKind kind = WakeNightEventKind.natural, int epoch = 1}) =>
  WakeNightEvent(kind: kind, at: at, confirmedDelivery: true, wakeEpochSec: epoch);
WakeNightEvent ack(DateTime at, {int epoch = 1}) => WakeNightEvent(kind: WakeNightEventKind.ack, at: at, wakeEpochSec: epoch);
Future<void> open(WidgetTester t, List<SleepSummaryInterval> intervals, {WakeNightTimeline wake = const WakeNightTimeline(), Locale locale = const Locale('en')}) async {
  skTallView(t, w: 390, h: 2500);
  await t.pumpWidget(skHost(Scaffold(body: SingleChildScrollView(child: SleepSummary(
    asleepMin: 572, inBedMin: 576, efficiency: 1, sourceText: '', intervals: intervals, wake: wake, onEdit: () {}))), locale: locale));
  await t.pumpAndSettle();
}
void main() {
  setUp(() => ClockFormatController.seed(ClockFormat.h24));
  tearDown(() { ClockFormatController.debugReset(); DayTimelinePilot.debugOverride.clear(); });

  // catches: putting the day fingerprint's end-of-day time under the night.
  testWidgets('R2 real card uses included recording timestamp beside sleep window', (t) async {
    skTallView(t, w: 390, h: 2500);
    DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true;
    final app = AppState.forTesting(); addTearDown(app.dispose);
    final computed = local(16, 5, 5);
    final included = local(14, 16, 15);
    final start = local(14, 6, 39, 55), end = local(14, 16, 15, 55);
    await t.pumpWidget(renderApp(app, SleepDetail(embedded: true, data: SleepData(day: '2026-11-14', night: {
      'duration_min': 572, 'in_bed_min': 576, 'efficiency': 1.0,
      'onset_ts': start.millisecondsSinceEpoch ~/ 1000, 'wake_ts': end.millisecondsSinceEpoch ~/ 1000,
      'computed_at': computed.millisecondsSinceEpoch,
      'recordings_through': included.millisecondsSinceEpoch, 'sleep_source': 'auto',
    }))));
    await t.pumpAndSettle();
    expect(find.text('9h 36m sleep window · updated 16:15'), findsOneWidget);
    expect(find.textContaining('recordings through'), findsNothing);
    expect(find.textContaining('through As of'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('R2 absent included-recording timestamp omits updated rather than using computed_at', (t) async {
    skTallView(t, w: 390, h: 2500);
    DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true;
    final app = AppState.forTesting(); addTearDown(app.dispose);
    await t.pumpWidget(renderApp(app, SleepDetail(embedded: true, data: SleepData(day: '2026-11-14', night: {
      'duration_min': 572, 'in_bed_min': 576, 'efficiency': 1.0,
      'computed_at': local(16, 5, 5).millisecondsSinceEpoch, 'sleep_source': 'auto',
    }))));
    await t.pumpAndSettle();
    expect(find.text('9h 36m sleep window'), findsOneWidget);
    expect(find.textContaining('updated'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  // WHY: recalculation must retain its status without restoring the old two-template line.
  testWidgets('R2 updating a shown night keeps one included-recording timestamp', (t) async {
    skTallView(t, w: 390, h: 2500);
    DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true;
    final app = AppState.forTesting()..repo = _CoverageRepo(); addTearDown(app.dispose);
    app.debugSetRecalc(RecalcState(days: const {'2026-11-14'}));
    await t.pumpWidget(renderApp(app, SleepDetail(embedded: true, data: SleepData(day: '2026-11-14', night: {
      'duration_min': 572, 'in_bed_min': 576, 'efficiency': 1.0,
      'computed_at': local(16, 5, 5).millisecondsSinceEpoch,
      'recordings_through': local(14, 16, 15).millisecondsSinceEpoch, 'sleep_source': 'auto',
    }))));
    await t.pumpAndSettle();
    expect(find.text('9h 36m sleep window · updated 16:15'), findsOneWidget);
    expect(find.text('Updating this night'), findsOneWidget);
    expect(find.textContaining('recordings through'), findsNothing);
    expect(find.textContaining('05:05'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  // catches: repeating a date on every event, or adding 24h over a DST day.
  testWidgets('R2 midnight is a non-event date row; same-day night has none', (t) async {
    await open(t, [night(local(14, 22), local(15, 7))]);
    expect(find.text('SUN 15'), findsOneWidget);
    expect(t.getTopLeft(find.text('SUN 15')).dy, greaterThan(t.getTopLeft(find.text('Fell asleep')).dy));
    expect(t.getTopLeft(find.text('SUN 15')).dy, lessThan(t.getTopLeft(find.text('Sleep ended')).dy));
    expect(find.textContaining('2026'), findsNothing);
    await open(t, [night(local(14, 6, 39, 55), local(14, 16, 15, 55))]);
    expect(find.text('SUN 15'), findsNothing);
    expect(find.text('06:39'), findsOneWidget);
    expect(find.textContaining('55s'), findsNothing);
  });

  // catches: raw alert flood, lost repeats, ambiguous detached seconds.
  testWidgets('R2 adjacent methods collapse into static ranges and counts', (t) async {
    final wake = WakeNightTimeline(events: [ack(local(14, 14, 22, 45))], deliveries: [
      sent(local(14, 14, 15, 35), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 18, 6), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 21, 5), kind: WakeNightEventKind.gradual),
      for (final second in [38, 43, 47, 52, 57, 61, 66, 70]) sent(local(14, 14, 21, second), kind: WakeNightEventKind.repeat),
    ]);
    await open(t, [night(local(14, 6, 39, 55), local(14, 14, 22, 45))], wake: wake);
    expect(find.text('Gradual Wake'), findsOneWidget);
    expect(find.text('Natural Wake'), findsOneWidget);
    expect(find.text('14:15–14:21 · 3 alerts'), findsOneWidget);
    expect(find.text('14:21–14:22 · 8 alerts'), findsOneWidget);
    expect(find.text('Alerts were sent; band vibration is unconfirmed.'), findsOneWidget);
    expect(find.text('14:21:38'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(InkWell), findsOneWidget); // Edit sleep only.
    expect(find.text('7m 10s'), findsOneWidget); // 14:22:45 minus 14:15:35
    expect(find.text('Time to wake'), findsOneWidget);
  });

  // catches: hiding the first sent-to-ack interval below the event flood.
  testWidgets('R2 time to wake is a top-level stat with exact sent-to-ack duration', (t) async {
    await open(t, [night(local(14, 6), local(14, 7))], wake: WakeNightTimeline(events: [
      sent(local(14, 6, 50, 35)), ack(local(14, 7, 0, 45)),
    ]));
    expect(find.text('10m 10s'), findsOneWidget);
    expect(find.text('Time to wake'), findsOneWidget);
    expect(t.getTopLeft(find.text('Time to wake')).dy, lessThan(t.getTopLeft(find.text('Sleep timeline')).dy));
  });

  // WHY: interleaved methods can overlap. Ordering by alert arrival must
  // not split one method's range or pretend the methods happened in sequence.
  testWidgets('R2 overlapping Gradual and Natural ranges share a bracket', (t) async {
    final semantics = t.ensureSemantics();
    try {
    await open(t, [night(local(14, 6), local(14, 14, 23))], wake: WakeNightTimeline(events: [
      sent(local(14, 14, 15), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 18), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 20)),
      sent(local(14, 14, 21), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 22), kind: WakeNightEventKind.repeat),
      ack(local(14, 14, 23)),
    ]));
    expect(find.text('14:15–14:21 · 3 alerts'), findsOneWidget);
    expect(find.text('14:20–14:22 · 2 alerts'), findsOneWidget);
    final bracket = find.byKey(const ValueKey('sleep-wake-overlap-bracket'));
    expect(bracket, findsOneWidget);
    expect(find.bySemanticsLabel('Overlapping wake alerts'), findsOneWidget);
    final group = find.byKey(const ValueKey('sleep-wake-overlap'));
    expect(find.descendant(of: group, matching: find.text('Gradual Wake')), findsOneWidget);
    expect(find.descendant(of: group, matching: find.text('Natural Wake')), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    } finally { semantics.dispose(); }
  });

  testWidgets('R2 sequential alert ranges do not acquire an overlap bracket', (t) async {
    await open(t, [night(local(14, 6), local(14, 14, 23))], wake: WakeNightTimeline(events: [
      sent(local(14, 14, 15), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 18), kind: WakeNightEventKind.gradual),
      sent(local(14, 14, 20)), sent(local(14, 14, 22)), ack(local(14, 14, 23)),
    ]));
    expect(find.text('14:15–14:18 · 2 alerts'), findsOneWidget);
    expect(find.text('14:20–14:22 · 2 alerts'), findsOneWidget);
    expect(find.byKey(const ValueKey('sleep-wake-overlap-bracket')), findsNothing);
  });

  // WHY: a same-minute range must distinguish sent alerts seconds apart.
  testWidgets('R2 same-minute alert range keeps readable seconds', (t) async {
    await open(t, [night(local(14, 6), local(14, 7))], wake: WakeNightTimeline(events: [
      sent(local(14, 6, 59, 38)), sent(local(14, 6, 59, 57),), ack(local(14, 7)),
    ]));
    expect(find.text('06:59:38–06:59:57 · 2 alerts'), findsOneWidget);
  });

  // catches: a duration borrowed from another epoch or from a band report.
  testWidgets('R2 missing own-epoch acknowledgment never borrows time to wake', (t) async {
    final semantics = t.ensureSemantics();
    try {
    await open(t, [night(local(14, 6), local(14, 7))], wake: WakeNightTimeline(events: [
      sent(local(14, 6, 50), epoch: 1), ack(local(14, 7), epoch: 2),
    ]));
    final stat = find.byKey(const ValueKey('sleep-time-to-wake'));
    expect(find.descendant(of: stat, matching: find.text('—')), findsOneWidget);
    expect(find.text('10m 0s'), findsNothing);
    final spoken = t.getSemantics(stat).getSemanticsData();
    expect(spoken.label, 'Time to wake, unavailable');
    expect(spoken.value, '');
    } finally { semantics.dispose(); }
  });

  // catches: merging across a calendar boundary hides the midnight divider.
  testWidgets('R2 runs split at midnight and preserve event orientation', (t) async {
    await open(t, [night(local(14, 22), local(15, 0, 2))], wake: WakeNightTimeline(events: [
      sent(local(14, 23, 59, 55)), sent(local(15, 0, 0, 5)), ack(local(15, 0, 2)),
    ]));
    expect(find.text('SUN 15'), findsOneWidget);
    expect(find.text('23:59:55'), findsOneWidget);
    expect(find.text('00:00:05'), findsOneWidget);
    expect(find.text('2m 5s'), findsOneWidget);
  });

  // WHY: no-alert and no-ack cases are independent absence states.
  for (final events in [<WakeNightEvent>[ack(local(14, 7))], <WakeNightEvent>[sent(local(14, 6, 50))]]) {
    testWidgets('R2 missing wake endpoint stays unavailable ${events.first.kind}', (t) async {
      await open(t, [night(local(14, 6), local(14, 7))], wake: WakeNightTimeline(events: events));
      expect(find.descendant(of: find.byKey(const ValueKey('sleep-time-to-wake')), matching: find.text('—')), findsOneWidget);
      expect(find.text('0m 0s'), findsNothing);
    });
  }

  // WHY: same method separated by another event/epoch/version is another run.
  test('R2 collapsing retains every observation and respects run boundaries', () {
    final events = [
      SleepSummaryEvent(local(14, 6), 'first', wakeKind: WakeNightEventKind.natural, wakeEpochSec: 1),
      SleepSummaryEvent(local(14, 6, 0, 5), 'repeat', wakeKind: WakeNightEventKind.repeat, wakeEpochSec: 1),
      SleepSummaryEvent(local(14, 6, 0, 6), 'nap'),
      SleepSummaryEvent(local(14, 6, 0, 7), 'repeat', wakeKind: WakeNightEventKind.repeat, wakeEpochSec: 1),
      SleepSummaryEvent(local(14, 6, 0, 8), 'repeat', wakeKind: WakeNightEventKind.repeat, wakeEpochSec: 2),
      SleepSummaryEvent(local(14, 6, 0, 9), 'repeat', wakeKind: WakeNightEventKind.repeat, wakeEpochSec: 2, technologyVersion: 'v2'),
    ];
    final runs = sleepSummaryRuns(events);
    expect(runs.map((e) => e.length), [2, 1, 1, 1, 1]);
    expect(runs.expand((run) => run), orderedEquals(events));
  });

  // WHY: elapsed time uses instants through both clock changes. Run in UTC
  // and Denver; the same assertions execute in each environment without skips.
  for (final season in ['spring', 'fall']) {
    testWidgets('R2 DST $season keeps elapsed time and distinct offset clocks', (t) async {
      final denver = Platform.environment['TZ'] == 'America/Denver';
      final spring = season == 'spring';
      final start = spring ? DateTime.utc(2026, 3, 8, 6) : DateTime.utc(2026, 11, 1, 5);
      final fire = spring ? DateTime.utc(2026, 3, 8, 8, 59, 50) : DateTime.utc(2026, 11, 1, 7, 59, 50);
      final up = spring ? DateTime.utc(2026, 3, 8, 9, 0, 10) : DateTime.utc(2026, 11, 1, 8, 0, 10);
      await open(t, [night(start, up.add(const Duration(hours: 1)))], wake: WakeNightTimeline(events: [sent(fire), ack(up)]));
      expect(find.text('0m 20s'), findsOneWidget);
      expect(find.text(denver ? (spring ? '01:59:50 UTC−07:00' : '01:59:50 UTC−06:00') : (spring ? '08:59:50' : '07:59:50')), findsOneWidget);
      expect(find.text(denver ? (spring ? '03:00:10 UTC−06:00' : '01:00:10 UTC−07:00') : (spring ? '09:00:10' : '08:00:10')), findsOneWidget);
      expect(find.text(spring ? 'SUN 8' : 'SUN 1'), denver ? findsOneWidget : findsNothing);
    });
  }

  // catches: English fallback or retained in-bed language in the shipped card.
  const windows = {'en': '9h 36m sleep window', 'de': 'Schlaffenster: 9 Std. 36 Min.',
    'es': 'Ventana de sueño: 9 h 36 min', 'fr': 'Plage de sommeil : 9 h 36 min',
    'hi': 'नींद की अवधि: 9 घं 36 मि', 'ru': 'Окно сна: 9 ч 36 мин', 'zh': '睡眠时段：9小时36分钟'};
  const notes = {
    'en': 'Asleep percentage is time asleep out of the time the band recorded in your sleep window.',
    'de': 'Der Schlafanteil ist die Schlafzeit geteilt durch die Zeit, die das Band in deinem Schlaffenster aufgezeichnet hat.',
    'es': 'El porcentaje dormido es el tiempo que dormiste dividido por el tiempo que la pulsera registró en tu ventana de sueño.',
    'fr': 'Le pourcentage de sommeil est le temps passé à dormir divisé par le temps enregistré par le bracelet dans votre plage de sommeil.',
    'hi': 'नींद का प्रतिशत आपकी नींद की अवधि में बैंड द्वारा रिकॉर्ड किए गए समय में से सोने के समय का अनुपात है।',
    'ru': 'Процент сна — это время сна от всего времени, записанного браслетом в вашем окне сна.',
    'zh': '睡眠百分比是睡眠时间占手环在您的睡眠时段内所记录时间的比例。',
  };
  for (final entry in windows.entries) {
    testWidgets('R2 inclusive window copy and semantics ${entry.key}', (t) async {
      final semantics = t.ensureSemantics();
      try {
        await open(t, [], locale: Locale(entry.key));
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text(notes[entry.key]!), findsOneWidget);
        expect(find.bySemanticsLabel(entry.value), findsOneWidget);
        final l = lookupAppLocalizations(Locale(entry.key));
        expect(l.sleepSummaryCoverage('X', 'Y').toLowerCase(), isNot(contains('in bed')));
      } finally { semantics.dispose(); }
    });
  }
}
