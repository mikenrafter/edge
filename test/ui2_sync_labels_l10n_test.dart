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
import 'package:openstrap_edge/state/clock_format.dart';
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
  'spoken time': RegExp(r'\b\d+ (seconds|minutes)\b'),
};

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

  for (final locale in const [Locale('de'), Locale('ru')]) {
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

    for (final state in ['syncing', 'failed', 'partial']) {
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

  // Geometry in German (mirrors header_rows_states_shift_test): no overflow,
  // every action target >= 44 x 44 and inside the block, localized labels.
  for (final w in [320.0, 360.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('de actions fit: ${w.toInt()} pt x $scale', (t) async {
        await withClock(Clock.fixed(headerNow), () async {
          for (final state in ['idle', 'syncing', 'failed', 'partial']) {
            await pump(t, state, const Locale('de'), w: w, scale: scale);
            final why = '$state at $w x $scale';
            expect(t.takeException(), isNull, reason: 'overflow: $why');
            final blockF = find.byKey(_headerKey);
            final block = t.getRect(blockF);
            final presses = find.descendant(
                of: blockF, matching: find.byType(Pressable));
            // idle: Sync now; syncing: Show details; failed/partial: both.
            final expectedActions = state == 'idle' || state == 'syncing' ? 1 : 2;
            var actions = 0;
            for (var i = 0; i < presses.evaluate().length; i++) {
              final f = presses.at(i);
              final hit = t.getRect(f);
              if (hit.width < 44 || hit.height < 44) continue;
              final txt = _texts(t, f).join(' ');
              // The status sentence is also a Pressable; actions are short.
              if (txt.isEmpty || txt.length > 40) continue;
              actions++;
              expect(hit.left, greaterThanOrEqualTo(block.left - 0.01),
                  reason: 'left outside the block: "$txt" $why');
              expect(hit.right, lessThanOrEqualTo(block.right + 0.01),
                  reason: 'right outside the block: "$txt" $why');
              expect(hit.bottom, lessThanOrEqualTo(block.bottom + 0.01),
                  reason: 'bottom outside the block: "$txt" $why');
            }
            expect(actions, greaterThanOrEqualTo(expectedActions),
                reason: 'actions not found: $why');
            expect(_englishHits(_texts(t, blockF)), isEmpty,
                reason: 'English literal in $why');
            await t.pumpWidget(const SizedBox());
          }
        });
      });
    }
  }
}
