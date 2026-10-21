// RED: the sync cluster in the header rows (HomeSyncStatus, the details sheet,
// syncActionsNeedOwnLine) draws English literals in every locale. In a
// non-English locale no English literal may appear in the header block or the
// sync details sheet, and the own-line decision must measure the LOCALIZED
// labels. Time is pinned with package:clock; no real clock.
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/sync_control.dart';

import 'support/bundled_fonts.dart';
import 'support/header_rows_fakes.dart';

const _headerKey = ValueKey('shared:header-rows');

/// English sync-cluster literals (whole-word) that must not survive in de/ru.
final _english = <String, RegExp>{
  'Sync now': RegExp(r'\bSync now\b'),
  'Show details': RegExp(r'\bShow details\b'),
  'Retry': RegExp(r'\bRetry\b'),
  'Sync (sheet title)': RegExp(r'^Sync$'),
  'N h ago': RegExp(r'\d+ h ago'),
  'N min ago': RegExp(r'\d+ min ago'),
  'N d ago': RegExp(r'\d+ d ago'),
  'just now': RegExp(r'\bjust now\b'),
  'Synced': RegExp(r'\bSynced\b'),
  'Not synced yet': RegExp(r'\b[Nn]ot synced yet\b'),
  'Downloading': RegExp(r'\bDownloading\b'),
  'Calculating': RegExp(r'\bCalculating\b'),
  'Connecting': RegExp(r'\bConnecting\b'),
  'Needs another pass': RegExp(r'\bNeeds another pass\b'),
  'Sync failed': RegExp(r'\bSync failed\b'),
  'Please retry': RegExp(r'\bPlease retry\b'),
  'Band not connected': RegExp(r'\bBand not connected\b'),
  'Nothing new': RegExp(r'\bNothing new\b'),
  'Elapsed': RegExp(r'\bElapsed\b'),
  'step label': RegExp(r'^(Connect|Download|Calculate|Done)$'),
  'step line': RegExp(
      r'^(Waiting|Skipped|Failed|Connected|Finished|Working it out…|No records yet)$'),
  'step line 2': RegExp(r'\b(Day \d+ of|Synced through|Band time still)\b'),
  'records/chunks': RegExp(r'\b\d+ (records?|chunks?)\b'),
  'spoken time': RegExp(r'\b\d+ seconds\b|\b\d+ minutes \d+ seconds\b'),
  // Coordinator failure reasons and step notes.
  'Pair a band': RegExp(r'Pair a band'),
  'Already connected': RegExp(r'Already connected'),
  'Not reached': RegExp(r'Not reached'),
  'Not needed': RegExp(r'Not needed'),
  'Skipped nothing new': RegExp(r'Skipped — nothing new'),
  'More remains': RegExp(r'More remains'),
  'Done (partial)': RegExp(r'Done \(partial\)'),
  'Could not connect': RegExp(r'Could not connect'),
  'Band disconnected': RegExp(r'Band disconnected'),
  'Download stopped': RegExp(r'Download stopped'),
  'Another calculation': RegExp(r'Another calculation'),
  'took too long': RegExp(r'took too long'),
  'Waiting generic': RegExp(r'^Waiting'),
  'Skipped': RegExp(r'^Skipped'),
  // formatDayTime without a locale: English weekday / month names.
  'English weekday': RegExp(r'\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b'),
  'English month': RegExp(
      r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b'),
};

const _locales = [
  Locale('de'),
  Locale('es'),
  Locale('fr'),
  Locale('hi'),
  Locale('ru'),
  Locale('zh'),
];

/// Every failure the coordinator itself words, with its stable code.
SyncPresentationState _failedWith(SyncFailure f) => SyncPresentationState(
      phase: 'failed',
      failureReason: f.english,
      failureCode: f,
      lastSuccess: headerNow.subtract(const Duration(minutes: 61)),
      startedAt: headerNow.subtract(const Duration(seconds: 50)),
      finishedAt: headerNow.subtract(const Duration(seconds: 9)),
      steps: [
        SyncStep(id: SyncStepId.connect, status: SyncStepStatus.failed),
        SyncStep(
            id: SyncStepId.download,
            status: SyncStepStatus.skipped,
            noteCode: SyncNote.notReached),
        SyncStep(
            id: SyncStepId.calculate,
            status: SyncStepStatus.skipped,
            noteCode: SyncNote.notReached),
        SyncStep(
            id: SyncStepId.done,
            status: SyncStepStatus.skipped,
            noteCode: SyncNote.notReached),
      ],
    );

/// A partial sync with every note the coordinator writes, a realistic count
/// and a yesterday's "synced through" (so a weekday / month is formatted).
SyncPresentationState _notes() => SyncPresentationState(
      phase: 'completed',
      partial: true,
      lastSuccess: headerNow.subtract(const Duration(minutes: 5)),
      startedAt: headerNow.subtract(const Duration(minutes: 3)),
      finishedAt: headerNow.subtract(const Duration(minutes: 1)),
      steps: [
        SyncStep(
            id: SyncStepId.connect,
            status: SyncStepStatus.skipped,
            noteCode: SyncNote.alreadyConnected),
        SyncStep(
          id: SyncStepId.download,
          status: SyncStepStatus.done,
          startedAt: headerNow.subtract(const Duration(minutes: 3)),
          endedAt: headerNow.subtract(const Duration(minutes: 2)),
          noteCode: SyncNote.moreRemains,
          download: SyncDownloadDetail(
            records: 12400,
            chunks: 31,
            syncedThrough: DateTime(2026, 10, 3, 22, 15),
          ),
        ),
        SyncStep(
            id: SyncStepId.calculate,
            status: SyncStepStatus.skipped,
            noteCode: SyncNote.nothingNew),
        SyncStep(
            id: SyncStepId.done,
            status: SyncStepStatus.done,
            startedAt: headerNow,
            endedAt: headerNow,
            noteCode: SyncNote.donePartial),
      ],
    );

/// Skipped because the sync never got that far or had nothing to do.
SyncPresentationState _notNeeded() => SyncPresentationState(
      phase: 'completed',
      lastSuccess: headerNow.subtract(const Duration(minutes: 5)),
      startedAt: headerNow.subtract(const Duration(minutes: 3)),
      finishedAt: headerNow.subtract(const Duration(minutes: 1)),
      steps: [
        SyncStep(id: SyncStepId.connect, status: SyncStepStatus.done),
        SyncStep(
            id: SyncStepId.download,
            status: SyncStepStatus.skipped,
            noteCode: SyncNote.notNeeded),
        SyncStep(id: SyncStepId.calculate, status: SyncStepStatus.done),
        SyncStep(id: SyncStepId.done, status: SyncStepStatus.done),
      ],
    );

List<String> _texts(WidgetTester t, Finder scope) => [
      for (final w in t
          .widgetList<RichText>(find.descendant(of: scope, matching: find.byType(RichText))))
        w.text.toPlainText(),
    ];

List<String> _semanticsLabels(WidgetTester t, Finder scope) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(t.getSemantics(scope.first));
  return out;
}

List<String> _englishHits(Iterable<String> all) => [
      for (final s in all)
        for (final e in _english.entries)
          if (e.value.hasMatch(s)) '${e.key}: "$s"',
    ];

typedef _Setup = void Function(HeaderApp app);

final _states = <String, _Setup>{
  'idle': (a) {},
  'syncing': (a) => a.pres = headerSyncing(),
  'failed': (a) => a.pres = headerFailed(),
  'partial': (a) => a.pres = SyncPresentationState(
        phase: 'completed',
        partial: true,
        lastSuccess: headerNow.subtract(const Duration(minutes: 5)),
        startedAt: headerNow.subtract(const Duration(minutes: 3)),
        finishedAt: headerNow.subtract(const Duration(minutes: 1)),
      ),
  'notes': (a) => a.pres = _notes(),
  'not needed': (a) => a.pres = _notNeeded(),
  for (final f in SyncFailure.values)
    'failed ${f.name}': (a) => a.pres = _failedWith(f),
  'importing': (a) =>
      a.importProgress.value = const ImportCopying(ImportStage.journal, 10, 100, 4, 9),
  'recalculating': (a) =>
      a.derive.value = const DeriveProgress(dayIndex: 3, dayTotal: 40),
  'offline': (a) => a.pres = SyncPresentationState(
        phase: 'offline',
        lastSuccess: headerNow.subtract(const Duration(hours: 5)),
      ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClockFormatController.seed(ClockFormat.h24);
  });
  tearDown(ClockFormatController.debugReset);

  Future<HeaderApp> pump(WidgetTester t, String state, Locale locale,
      {double w = 390, double scale = 1}) async {
    final app = HeaderApp(pres: headerIdle(), through: headerEdge);
    _states[state]!(app);
    addTearDown(app.dispose);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(w, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(titleOnly(app, 'Sleep', scale: scale, locale: locale));
    await t.pump();
    return app;
  }

  for (final locale in _locales) {
    final code = locale.languageCode;
    for (final state in _states.keys) {
      testWidgets('header block has no English sync literal: $state $code',
          (t) async {
        final sem = t.ensureSemantics();
        await withClock(Clock.fixed(headerNow), () async {
          await pump(t, state, locale);
          final block = find.byKey(_headerKey);
          expect(block, findsOneWidget);
          expect(_englishHits(_texts(t, block)), isEmpty,
              reason: 'visible text in $state/$code');
          expect(_englishHits(_semanticsLabels(t, block)), isEmpty,
              reason: 'semantics in $state/$code');
          // The clock for a running sync is announced in the locale too.
          if (state == 'syncing') {
            expect(find.bySemanticsLabel(RegExp(r'^Elapsed')), findsNothing);
          }
          await t.pumpWidget(const SizedBox());
        });
        sem.dispose();
      });
    }

    testWidgets('Sync now action is the localized label: idle $code',
        (t) async {
      await withClock(Clock.fixed(headerNow), () async {
        await pump(t, 'idle', locale);
        final l = await AppLocalizations.delegate.load(locale);
        // Existing key (devicesSyncNow): "Jetzt synchronisieren" / ru.
        expect(find.text(l.devicesSyncNow), findsOneWidget);
        expect(find.text('Sync now'), findsNothing);
        await t.pumpWidget(const SizedBox());
      });
    });

    for (final state in ['syncing', 'failed', 'partial', 'notes', 'not needed', 'failed pairBand', 'failed couldNotConnect', 'failed disconnected', 'failed downloadStopped', 'failed calculationBusy', 'failed timedOut']) {
      testWidgets(
          'details sheet has no English literal: $state $code', (t) async {
        final sem = t.ensureSemantics();
        await withClock(Clock.fixed(headerNow), () async {
          final app = await pump(t, state, locale);
          final ctx = t.element(find.byType(Scaffold));
          showSyncDetails(ctx, app);
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
          final sheet = find.byType(BottomSheet);
          expect(sheet, findsOneWidget);
          expect(_englishHits(_texts(t, sheet)), isEmpty,
              reason: 'sheet text in $state/$code');
          expect(_englishHits(_semanticsLabels(t, sheet)), isEmpty,
              reason: 'sheet semantics in $state/$code');
          // Step status names must not leak into the semantics label either.
          for (final s in _semanticsLabels(t, sheet)) {
            expect(
                RegExp(r', (done|running|failed|skipped|waiting)\.').hasMatch(s),
                isFalse,
                reason: 'English status enum name in "$s"');
          }
          Navigator.of(ctx).pop();
          await t.pumpAndSettle();
          await t.pumpWidget(const SizedBox());
        });
        sem.dispose();
      });
    }
  }

  // syncActionsNeedOwnLine measures the LOCALIZED labels. German is wider than
  // English ("Jetzt synchronisieren" vs "Sync now"), so the width below which
  // the actions need their own line must be larger in de than in en. While the
  // measurement uses English literals both thresholds are identical.
  testWidgets('own-line threshold is wider for German than English',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = HeaderApp(pres: headerIdle(), through: headerEdge);
      addTearDown(app.dispose);
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 900);
      addTearDown(t.view.reset);
      for (final scale in [1.0, 1.3]) {
        Future<double> threshold(Locale locale) async {
          await t.pumpWidget(
              titleOnly(app, 'Sleep', scale: scale, locale: locale));
          final ctx = t.element(find.byType(Scaffold));
          // Smallest width (2 pt steps) at which the actions fit row 1.
          for (var w = 200.0; w <= 700; w += 2) {
            if (!syncActionsNeedOwnLine(ctx, w)) return w;
          }
          return double.infinity;
        }

        final en = await threshold(const Locale('en'));
        final de = await threshold(const Locale('de'));
        expect(de, greaterThan(en),
            reason: 'x$scale: de fits from $de pt, en from $en pt; the German '
                'labels are wider, so the localized measurement must differ');
      }
      await t.pumpWidget(const SizedBox());
    });
  });

  // Geometry (mirrors header_rows_states_shift_test) in every locale at narrow
  // widths and large scales, every state: no overflow, every action target at
  // least 44 x 44 and inside the block, targets never overlap each other, and
  // the block / row 1 / anchor rects are the same as idle (decided from width,
  // scale and locale only).
  final geoLocales = [
    const Locale('ru'),
    const Locale('de'),
    const Locale('es'),
    const Locale('fr'),
    const Locale('hi'),
    const Locale('zh'),
  ];
  const geoStates = [
    'idle',
    'syncing',
    'failed',
    'partial',
    'offline',
    'importing',
    'recalculating',
  ];
  for (final locale in geoLocales) {
    for (final w in [320.0, 360.0]) {
      for (final scale in [1.3, 1.5, 2.0]) {
        testWidgets(
            'actions fit, blocks match idle: ${locale.languageCode} '
            '${w.toInt()} pt x $scale', (t) async {
          await withClock(Clock.fixed(headerNow), () async {
            Future<List<String>> geometry(String state) async {
              await pump(t, state, locale, w: w, scale: scale);
              final why = '$state ${locale.languageCode} at $w x $scale';
              expect(t.takeException(), isNull, reason: 'overflow: $why');
              final blockF = find.byKey(_headerKey);
              final block = t.getRect(blockF);
              final presses = find.descendant(
                  of: blockF, matching: find.byType(Pressable));
              final hits = <Rect>[];
              for (var i = 0; i < presses.evaluate().length; i++) {
                final f = presses.at(i);
                final hit = t.getRect(f);
                final txt = _texts(t, f).join(' ');
                // The status sentence is also a Pressable; actions are short.
                if (txt.isEmpty || txt.length > 40) continue;
                hits.add(hit);
                expect(hit.width, greaterThanOrEqualTo(44),
                    reason: 'width of "$txt": $why');
                expect(hit.height, greaterThanOrEqualTo(44),
                    reason: 'height of "$txt": $why');
                expect(hit.left, greaterThanOrEqualTo(block.left - 0.01),
                    reason: 'left outside the block: "$txt" $why');
                expect(hit.right, lessThanOrEqualTo(block.right + 0.01),
                    reason: 'right outside the block: "$txt" $why');
                expect(hit.bottom, lessThanOrEqualTo(block.bottom + 0.01),
                    reason: 'bottom outside the block: "$txt" $why');
              }
              for (var i = 0; i < hits.length; i++) {
                for (var j = i + 1; j < hits.length; j++) {
                  expect(hits[i].overlaps(hits[j]) &&
                          hits[i].intersect(hits[j]).width > 0.5 &&
                          hits[i].intersect(hits[j]).height > 0.5,
                      isFalse,
                      reason: 'targets overlap: ${hits[i]} ${hits[j]} $why');
                }
              }
              final g = [
                'block $block',
                'row1 ${t.getRect(find.byKey(const ValueKey('shared:status-line')))}',
                'anchor ${t.getTopLeft(find.byKey(headerAnchorKey))}',
              ];
              await t.pumpWidget(const SizedBox());
              return g;
            }

            final idle = await geometry('idle');
            for (final state in geoStates.skip(1)) {
              expect(await geometry(state), idle,
                  reason: '$state differs from idle');
            }
          });
        });
      }
    }
  }

  // Counts keep their locale's digit grouping: 12400 reads "12,400" in English.
  testWidgets('record count is grouped in en and de', (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      for (final (locale, grouped) in [
        (const Locale('en'), '12,400'),
        (const Locale('de'), '12.400'),
      ]) {
        final app = await pump(t, 'notes', locale);
        final ctx = t.element(find.byType(Scaffold));
        showSyncDetails(ctx, app);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(_texts(t, find.byType(BottomSheet)).join('\n'),
            contains(grouped),
            reason: '${locale.languageCode}: grouped record count');
        Navigator.of(ctx).pop();
        await t.pumpAndSettle();
        await t.pumpWidget(const SizedBox());
      }
    });
  });

  // The generic "Waiting" step line is not the calculation-lock message.
  testWidgets('a waiting step says Waiting, not the calculation lock (en)',
      (t) async {
    await withClock(Clock.fixed(headerNow), () async {
      final app = await pump(t, 'syncing', const Locale('en'));
      final ctx = t.element(find.byType(Scaffold));
      showSyncDetails(ctx, app);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final all = _texts(t, find.byType(BottomSheet));
      expect(all.where((x) => x == 'Waiting').length, 2,
          reason: 'Calculate and Done wait; texts: $all');
      expect(all.where((x) => x.contains('another calculation')), isEmpty);
      Navigator.of(ctx).pop();
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
    });
  });

  for (final locale in _locales) {
    final code = locale.languageCode;
    testWidgets('a waiting step is not the calculation lock: $code',
        (t) async {
      await withClock(Clock.fixed(headerNow), () async {
        final app = await pump(t, 'syncing', locale);
        final l = await AppLocalizations.delegate.load(locale);
        final ctx = t.element(find.byType(Scaffold));
        showSyncDetails(ctx, app);
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        final all = _texts(t, find.byType(BottomSheet));
        expect(all, isNot(contains(l.syncStepWaitingCalculation)));
        expect(all, isNot(contains(l.syncStatusWaitingCalculation)));
        Navigator.of(ctx).pop();
        await t.pumpAndSettle();
        await t.pumpWidget(const SizedBox());
      });
    });

    test('"under a minute" is never rendered as a number: $code', () async {
      final l = await AppLocalizations.delegate.load(locale);
      expect(l.syncGapMinutes(0), isNot(matches(RegExp(r'(^|\D)0(\D|$)'))),
          reason: l.syncGapMinutes(0));
      expect(l.syncGapMinutes(0), isNot(l.syncGapMinutes(1)));
    });

    test('homeSyncedThrough is translated: $code', () async {
      final l = await AppLocalizations.delegate.load(locale);
      expect(l.homeSyncedThrough('X'), isNot('Synced through X'));
    });

    test('band-backlog lines are history, not a time estimate: $code',
        () async {
      final l = await AppLocalizations.delegate.load(locale);
      final line = l.syncDownloadGapLine('2 h');
      // The backlog is band data still to fetch; the line must say so rather
      // than read "(it will take) 2 h" (Russian "за 2 ч").
      expect(line, isNot(contains('за 2')), reason: line);
      final data = RegExp(
          r'(Bandzeit|datos|données|डेटा|данных|数据|Band)',
          caseSensitive: false);
      expect(data.hasMatch(line), isTrue, reason: 'names band data: $line');
    });
  }

  test('English: offline suffix stays lowercase, counts are grouped',
      () async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final s = SyncPresentationState(phase: 'offline');
    expect(syncStatusLine(s, headerNow, l),
        'Band not connected · not synced yet');
    expect(l.syncCountRecords(12400), '12,400 records');
    expect(l.syncCountChunks(1), '1 chunk');
  });

  test('Hindi: one hour is singular, zero stays numeric', () async {
    final l = await AppLocalizations.delegate.load(const Locale('hi'));
    expect(l.syncGapHours(1, 5), contains('1 घंटा'));
    expect(l.syncGapHours(1, 5), isNot(contains('1 घंटे')));
    expect(l.syncGapHours(2, 0), contains('2 घंटे'));
    expect(l.syncGapHours(0, 5), contains('0 घंटे'));
    expect(l.syncGapDays(2, 1), contains('1 घंटा'));
    expect(l.syncGapDays(2, 0), contains('0 घंटे'));
    expect(l.syncDurationHours(1, 3), contains('1 घंटा'));
    expect(l.syncDurationHours(0, 3), contains('0 घंटे'));
    expect(l.syncAgoHours(1), contains('1 घंटा'));
  });
}
