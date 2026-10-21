// RED: the Device details SyncControl (not the header block) puts its action in
// an unconstrained row. At 320 pt x 2.0 a long localized action ("Синхронизировать")
// crowds out the status row. It must move below the status when it does not
// fit, decided from width, scale and locale only: same card rect in every
// state, a target of at least 44 x 44 inside the card, no scaling, no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/sync_control.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'support/bundled_fonts.dart';

final _t0 = DateTime(2026, 10, 2, 9);

final _states = <String, SyncPresentationState>{
  'idle': SyncPresentationState(
      phase: 'idle', lastSuccess: _t0.subtract(const Duration(minutes: 61))),
  'downloading': SyncPresentationState(
    phase: 'downloading',
    busy: true,
    contactedBand: true,
    startedAt: _t0.subtract(const Duration(seconds: 75)),
    lastSuccess: _t0.subtract(const Duration(minutes: 61)),
  ),
  'failed': SyncPresentationState(
    phase: 'failed',
    failureReason: SyncFailure.pairBand.english,
    failureCode: SyncFailure.pairBand,
    lastSuccess: _t0.subtract(const Duration(minutes: 61)),
  ),
  'partial': SyncPresentationState(
    phase: 'completed',
    partial: true,
    lastSuccess: _t0.subtract(const Duration(minutes: 5)),
    finishedAt: _t0.subtract(const Duration(minutes: 1)),
  ),
  'offline': SyncPresentationState(
      phase: 'offline', lastSuccess: _t0.subtract(const Duration(hours: 5))),
  'never': const SyncPresentationState(phase: 'idle'),
};

Widget _host(SyncPresentationState s, Locale locale, double scale) =>
    MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      // The Device details page: 16 pt page padding either side of the card.
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            SyncControl(state: s, onSync: () {}, clock: () => _t0),
          ],
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final locale in const [Locale('ru'), Locale('de'), Locale('fr')]) {
    for (final w in [320.0, 360.0]) {
      for (final scale in [1.3, 1.5, 2.0]) {
        testWidgets(
            'SyncControl fits, card is the same in every state: '
            '${locale.languageCode} ${w.toInt()} pt x $scale', (t) async {
          addTearDown(t.view.reset);
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(w, 1200);
          Rect? idle;
          for (final e in _states.entries) {
            await t.pumpWidget(_host(e.value, locale, scale));
            await t.pump();
            final why = '${e.key} ${locale.languageCode} at $w x $scale';
            expect(t.takeException(), isNull, reason: 'overflow: $why');
            final card = t.getRect(find.byType(SyncControl));
            idle ??= card;
            expect(card, idle, reason: 'card rect differs from idle: $why');
            // The action (when the state has one) is a >= 44 pt target inside
            // the card, with unscaled-by-fit text.
            final presses = find.descendant(
                of: find.byType(SyncControl),
                matching: find.byType(Pressable));
            for (var i = 0; i < presses.evaluate().length; i++) {
              final hit = t.getRect(presses.at(i));
              expect(hit.left, greaterThanOrEqualTo(card.left - 0.01),
                  reason: 'left outside: $why');
              expect(hit.right, lessThanOrEqualTo(card.right + 0.01),
                  reason: 'right outside: $why');
              expect(hit.bottom, lessThanOrEqualTo(card.bottom + 0.01),
                  reason: 'bottom outside: $why');
            }
            final l = await AppLocalizations.delegate.load(locale);
            final hasAction = e.key != 'downloading';
            if (hasAction) {
              final label = e.key == 'failed'
                  ? l.syncActionRetry
                  : l.devicesSyncNow;
              final compact = e.key == 'failed'
                  ? l.syncActionRetryCompact
                  : l.syncActionSyncCompact;
              final f = find.byWidgetPredicate((x) =>
                  x is Text && (x.data == label || x.data == compact));
              expect(f, findsOneWidget, reason: 'action text: $why');
              final hit = t.getRect(
                  find.ancestor(of: f, matching: find.byType(Pressable)).first);
              expect(hit.width, greaterThanOrEqualTo(44), reason: 'w: $why');
              expect(hit.height, greaterThanOrEqualTo(44), reason: 'h: $why');
              expect(find.ancestor(of: f, matching: find.byType(FittedBox)),
                  findsNothing, reason: 'scaled to fit: $why');
            }
          }
        });
      }
    }
  }
}
