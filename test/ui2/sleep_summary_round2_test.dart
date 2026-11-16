// WHY: owner phone feedback, CLAIM(sleep-summary-r2). Read the real card:
// coverage is not a sleep timestamp; sent alerts retain their audit trail.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/day_timeline/pilot_flags.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_summary.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import '../sleep_v6_render_test.dart' show renderApp;
import '../support/skeleton_fixture.dart';

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
  testWidgets('R2 real card puts computed timestamp beside sleep window', (t) async {
    skTallView(t, w: 390, h: 2500);
    DayTimelinePilot.debugOverride[DayTimelinePilot.sleep] = true;
    final app = AppState.forTesting(); addTearDown(app.dispose);
    final updated = local(16, 5, 5);
    final start = local(14, 6, 39, 55), end = local(14, 16, 15, 55);
    await t.pumpWidget(renderApp(app, SleepDetail(embedded: true, data: SleepData(day: '2026-11-14', night: {
      'duration_min': 572, 'in_bed_min': 576, 'efficiency': 1.0,
      'onset_ts': start.millisecondsSinceEpoch ~/ 1000, 'wake_ts': end.millisecondsSinceEpoch ~/ 1000,
      'computed_at': updated.millisecondsSinceEpoch, 'sleep_source': 'auto',
    }))));
    await t.pumpAndSettle();
    expect(find.text('9h 36m sleep window · updated 16 Nov, 05:05'), findsOneWidget);
    expect(find.textContaining('recordings through'), findsNothing);
    expect(find.textContaining('through As of'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  // catches: repeating a date on every event, or adding 24h over a DST day.
  testWidgets('R2 midnight is a non-event date row; same-day night has none', (t) async {
    await open(t, [night(local(14, 22), local(15, 7))]);
    expect(find.text('Sunday 15 Nov'), findsOneWidget);
    expect(t.getTopLeft(find.text('Sunday 15 Nov')).dy, greaterThan(t.getTopLeft(find.text('Fell asleep')).dy));
    expect(t.getTopLeft(find.text('Sunday 15 Nov')).dy, lessThan(t.getTopLeft(find.text('Sleep ended')).dy));
    expect(find.textContaining('2026'), findsNothing);
    await open(t, [night(local(14, 6, 39, 55), local(14, 16, 15, 55))]);
    expect(find.text('Sunday 15 Nov'), findsNothing);
    expect(find.text('06:39'), findsOneWidget);
    expect(find.textContaining('55s'), findsNothing);
  });

  // catches: raw alert flood, lost repeats, ambiguous detached seconds.
  testWidgets('R2 adjacent methods collapse and expand all sent alerts', (t) async {
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
    await t.tap(find.text('Natural Wake')); await t.pumpAndSettle();
    for (final time in ['14:21:38', '14:21:43', '14:21:47', '14:21:52', '14:21:57', '14:22:01', '14:22:06', '14:22:10']) {
      expect(find.text(time), findsOneWidget);
    }
    expect(find.text('7m 10s'), findsOneWidget); // 14:22:45 minus 14:15:35
    expect(find.text('Time to wake'), findsOneWidget);
    await t.tap(find.text('Natural Wake')); await t.pumpAndSettle();
    expect(find.text('14:21:38'), findsNothing);
  });

  // catches: a duration borrowed from another epoch or from a band report.
  testWidgets('R2 missing own-epoch acknowledgment never borrows time to wake', (t) async {
    await open(t, [night(local(14, 6), local(14, 7))], wake: WakeNightTimeline(events: [
      sent(local(14, 6, 50), epoch: 1), ack(local(14, 7), epoch: 2),
    ]));
    final stat = find.byKey(const ValueKey('sleep-time-to-wake'));
    expect(find.descendant(of: stat, matching: find.text('—')), findsOneWidget);
    expect(find.text('10m 0s'), findsNothing);
  });

  // catches: merging across a calendar boundary hides the midnight divider.
  testWidgets('R2 runs split at midnight and preserve event orientation', (t) async {
    await open(t, [night(local(14, 22), local(15, 0, 2))], wake: WakeNightTimeline(events: [
      sent(local(14, 23, 59, 55)), sent(local(15, 0, 0, 5)), ack(local(15, 0, 2)),
    ]));
    expect(find.text('Sunday 15 Nov'), findsOneWidget);
    expect(find.text('23:59:55'), findsOneWidget);
    expect(find.text('00:00:05'), findsOneWidget);
    expect(find.text('2m 5s'), findsOneWidget);
  });

  // Run explicitly in UTC and Denver. No conditional skip is permitted.
  testWidgets('R2 DST repeated clock times retain distinct instants and elapsed time', (t) async {
    final denver = Platform.environment['TZ'] == 'America/Denver';
    await open(t, [night(DateTime.utc(2026, 11, 1, 5), DateTime.utc(2026, 11, 1, 9))], wake: WakeNightTimeline(events: [
      sent(DateTime.utc(2026, 11, 1, 7, 59, 50)), ack(DateTime.utc(2026, 11, 1, 8, 0, 10)),
    ]));
    expect(find.text('0m 20s'), findsOneWidget);
    expect(find.text(denver ? '01:59:50 UTC−06:00' : '07:59:50'), findsOneWidget);
    expect(find.text(denver ? '01:00:10 UTC−07:00' : '08:00:10'), findsOneWidget);
    expect(find.text('Sunday 1 Nov'), denver ? findsOneWidget : findsNothing);
  });

  // catches: English fallback or retained in-bed language in the shipped card.
  const windows = {'en': '9h 36m sleep window', 'de': 'Schlaffenster: 9h 36m',
    'es': 'Ventana de sueño: 9h 36m', 'fr': 'Plage de sommeil : 9h 36m',
    'hi': 'नींद की अवधि: 9घं 36मि', 'ru': 'Окно сна: 9ч 36м', 'zh': '睡眠时段：9小时36分钟'};
  for (final entry in windows.entries) {
    testWidgets('R2 inclusive window copy and semantics ${entry.key}', (t) async {
      final semantics = t.ensureSemantics();
      try {
        await open(t, [], locale: Locale(entry.key));
        expect(find.text(entry.value), findsOneWidget);
        expect(find.bySemanticsLabel(entry.value), findsOneWidget);
        final l = lookupAppLocalizations(Locale(entry.key));
        expect(l.sleepSummaryCoverage('X', 'Y').toLowerCase(), isNot(contains('in bed')));
      } finally { semantics.dispose(); }
    });
  }
}
