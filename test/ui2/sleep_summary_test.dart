// WHY: CLAIM(sleep-summary-truth), CLAIM(sleep-summary-intervals),
// CLAIM(sleep-summary-end). V6 is a read-only projection of stored facts.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_summary.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_timeline.dart';
import '../wake_journal/fixtures.dart' as wake_fixture;

DateTime at(int minute, [int second = 0]) => DateTime.utc(2026, 11, 14, 7, minute, second);
SleepSummaryInterval interval(String id, int start, int end, {bool nap = false}) =>
    SleepSummaryInterval(id: id, start: at(start), end: at(end), nap: nap);

void main() {
  test('disjoint, touching, overlapping and identical intervals retain every entry', () {
    // catches: deduplicating matching bounds or merging entries in storage.
    final entries = [interval('main', -480, 0), interval('shared', -480, 0, nap: true),
      interval('overlap', -10, 10, nap: true), interval('touch', 10, 30, nap: true),
      interval('separate', 120, 140, nap: true)];
    final groups = sleepSummaryGroups(entries.reversed.toList());
    expect(groups.map((g) => g.map((e) => e.id).toSet()), [
      {'main', 'shared', 'overlap', 'touch'}, {'separate'}]);
    final events = [for (final g in groups) ...sleepSummaryEvents(g, const WakeNightTimeline())];
    expect(events.where((e) => e.label == 'Nap started'), hasLength(4));
    expect(events.where((e) => e.label == 'Nap ended'), hasLength(4));
    expect(entries.map((e) => e.id), ['main', 'shared', 'overlap', 'touch', 'separate']);
  });

  test('each acknowledgement uses only its own answer and sent-alert interval', () {
    // catches: copying primary.dream or primary.timeToWake to every epoch.
    final wake = WakeNightTimeline(events: [
      WakeNightEvent(kind: WakeNightEventKind.natural, at: at(-5),
        wakeEpochSec: 1, confirmedDelivery: true, technologyVersion: 'v7'),
      WakeNightEvent(kind: WakeNightEventKind.ack, at: at(0), wakeEpochSec: 1,
        dream: WakeDreamResponse(answer: DreamAnswer.dream, path: WakePath.natural, at: at(1))),
      WakeNightEvent(kind: WakeNightEventKind.ack, at: at(5), wakeEpochSec: 2,
        dream: WakeDreamResponse(answer: DreamAnswer.normal, path: WakePath.alarm, at: at(6))),
      WakeNightEvent(kind: WakeNightEventKind.ack, at: at(8), wakeEpochSec: 3),
    ]);
    final events = sleepSummaryEvents([interval('main', -480, 0)], wake);
    expect(events.map((e) => e.label), ['Fell asleep', 'Natural Wake sent · v7',
      "I'm up from a dream", "I'm up normally", "I'm up"]);
    final acks = events.where((e) => e.ack).toList();
    expect(acks.map((e) => e.detail), ['', '', 'Dream/normal not answered']);
    expect(events.where((e) => e.label == 'Sleep ended'), isEmpty);
  });

  // WHY: CLAIM(sleep-summary-firings). A journal's first-step summary cannot
  // hide later confirmed Gradual deliveries from the detailed sleep timeline.
  // catches: reading only the first-per-method legacy events projection.
  test('every confirmed Gradual step remains visible in the summary', () {
    final wake = WakeNightTimeline.forEpoch(wakeEpochSec: wake_fixture.epoch, confirmedDispatchOnly: true,
      trace: wake_fixture.fullTrace());
    final events = sleepSummaryEvents([SleepSummaryInterval(id: 'main',
      start: wake_fixture.atMinute(-480), end: wake_fixture.atMinute(8))], wake);
    expect(events.where((e) => e.label == 'Gradual Wake sent').map((e) => e.at),
      [wake_fixture.atMinute(-15), wake_fixture.atMinute(-12)]);
  });

  test('band execution evidence does not claim an app alert was sent', () {
    final events = sleepSummaryEvents([interval('main', -480, 0)], WakeNightTimeline(events: [
      WakeNightEvent(kind: WakeNightEventKind.alarm, at: at(-1), wakeEpochSec: 1,
        confirmedDelivery: true),
      WakeNightEvent(kind: WakeNightEventKind.ack, at: at(0), wakeEpochSec: 1),
    ]));
    expect(events[1].label, 'Alarm reported by band');
    expect(events.last.detail, 'Dream/normal not answered');
  });

  test('distinct instants in the same formatted minute retain sleep end', () {
    // catches: comparing minute-level clock strings instead of instants.
    final events = sleepSummaryEvents([interval('main', -480, 0)],
      WakeNightTimeline(events: [WakeNightEvent(kind: WakeNightEventKind.ack,
        at: at(0, 20), wakeEpochSec: 1)]));
    expect(events.map((e) => [e.at, e.label]), [
      [at(-480), 'Fell asleep'], [at(0), 'Sleep ended'], [at(0, 20), "I'm up"]]);
  });

  test('decision-only or missing wake history never invents an alert or dreaming', () {
    final events = sleepSummaryEvents([interval('main', -480, 0)], WakeNightTimeline(events: [
      WakeNightEvent(kind: WakeNightEventKind.natural, at: at(-5), wakeEpochSec: 1),
      WakeNightEvent(kind: WakeNightEventKind.ack, at: at(0), wakeEpochSec: 1),
    ], dream: WakeDreamResponse(answer: DreamAnswer.dream, path: WakePath.natural, at: at(0))));
    expect(events.map((e) => e.label), ['Fell asleep', "I'm up"]);
    expect(events.last.detail, 'Dream/normal not answered');
  });

  for (final values in [(462, 531, .87, 0), (380, 531, .86, 90), (462, 531, .42, 0), (462, 531, null, 0), (null, null, null, null)]) {
    testWidgets('stored efficiency and one action, $values', (t) async {
      // catches: using asleep/in-bed to replace the stored observed-time ratio,
      // or treating absent efficiency as zero percent.
      var edits = 0;
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(
        body: SingleChildScrollView(child: SleepSummary(asleepMin: values.$1,
          inBedMin: values.$2, efficiency: values.$3, unobservedMin: values.$4,
          sourceText: 'This window was staged from the signals',
          intervals: values.$1 == null ? [] : [interval('main', -480, 0)],
          onEdit: () => edits++)))));
      expect(find.byType(TextButton), findsOneWidget);
      expect(find.text('Edit sleep'), findsOneWidget);
      expect(find.text('Not sleep'), findsNothing);
      expect(find.text(values.$3 == null ? '—' : '${(values.$3! * 100).round()}%'), findsWidgets);
      if (values.$4 == 90) expect(find.textContaining('7h 21m watched'), findsOneWidget);
      await t.ensureVisible(find.text('Edit sleep'));
      await t.tap(find.text('Edit sleep'));
      expect(edits, 1);
    });
  }

  // WHY: CLAIM(sleep-summary-accessibility). A decorative empty arc must
  // not expose a fabricated determinate zero to screen readers.
  for (final efficiency in [null, double.nan, double.infinity, -.1, 1.1, 0.0, .87]) {
    testWidgets('R1 efficiency semantics distinguish unavailable from $efficiency', (t) async {
      final semantics = t.ensureSemantics();
      try {
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(
        body: SingleChildScrollView(child: SleepSummary(efficiency: efficiency,
          sourceText: '', onEdit: () {})))));
      final node = t.getSemantics(find.byKey(const ValueKey('sleep-efficiency-ring')));
      final data = node.getSemanticsData();
      final valid = efficiency != null && efficiency.isFinite && efficiency >= 0 && efficiency <= 1;
      expect(data.label, valid ? 'Sleep efficiency' : 'Sleep efficiency, unavailable');
      expect(data.value, valid ? '${(efficiency * 100).round()}%' : '');
      final values = <String>[];
      void visit(SemanticsNode node) {
        final value = node.getSemanticsData().value;
        if (value.isNotEmpty) values.add(value);
        node.visitChildren((child) { visit(child); return true; });
      }
      visit(node);
      expect(values, valid ? ['${(efficiency * 100).round()}%'] : isEmpty);
      } finally { semantics.dispose(); }
    });
  }

  // WHY: the unavailable state must be understandable in every shipped locale.
  for (final entry in const {
    'en': 'Sleep efficiency, unavailable', 'de': 'Schlafeffizienz, nicht verfügbar',
    'es': 'Eficiencia del sueño, no disponible', 'fr': 'Efficacité du sommeil, indisponible',
    'hi': 'नींद की दक्षता, उपलब्ध नहीं', 'ru': 'Эффективность сна, недоступно',
    'zh': '睡眠效率，不可用',
  }.entries) {
    testWidgets('R1 unavailable efficiency semantics in ${entry.key}', (t) async {
      final semantics = t.ensureSemantics();
      try {
        await t.pumpWidget(MaterialApp(locale: Locale(entry.key),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: SleepSummary(sourceText: '', onEdit: () {})))));
        await t.pumpAndSettle();
        final data = t.getSemantics(find.byKey(const ValueKey('sleep-efficiency-ring'))).getSemanticsData();
        expect(data.label, entry.value);
        expect(data.value, '');
      } finally { semantics.dispose(); }
    });
  }

  test('every shipped language has translated summary and editor actions', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(l.sleepSummaryEdit, isNotEmpty);
      expect(l.sleepSummaryAfterAlert('X'), contains('X'));
      expect(l.sleepSummaryCoverage('A', 'B'), allOf(contains('A'), contains('B')));
      if (locale.languageCode != 'en') {
        expect(l.sleepSummaryEdit, isNot('Edit sleep'));
        expect(l.sleepSummaryRecalculate, isNot('Recalculate time in bed'));
        expect(l.sleepSummaryUpDream, isNot("I'm up from a dream"));
      }
    }
  });
}
