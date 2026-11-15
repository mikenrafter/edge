// WHY: the pilot's pixels-unchanged bar (owner, 2026-11-15): visible text and
// layout stay exactly as they were; the only visible change is the darker red
// on the four error-text sites. The first pilot localized the VISIBLE words of
// eight sites as well as their spoken labels, so in German the ECG link
// changed from "What the results mean" to "Was die Ergebnisse bedeuten". The
// six English goldens cannot see that. Review round 1, finding S3.
//
// CLAIM(A11Y-VISIBLE-UNCHANGED): in a non-English locale, the touched widgets
// draw the same words as before the pilot, and a screen reader says the
// localized words. Each case compares the drawn text against the base's
// literal and the spoken label against the German catalogue entry.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/ui2/gesture_failure_card.dart';
import 'package:openstrap_edge/ui2/profile/haptic_pattern_editor.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/screens/natural_wake_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'backup/backup_support.dart';
import 'ecg_transparency/support/cardio_fixtures.dart';
import 'support/a11y_tree.dart';
import 'support/apk1_harness.dart';

final _de = AppLocalizationsDe();

Widget _german(Widget home) => MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// The words drawn inside [of] (every Text under it, in tree order).
List<String> _drawn(WidgetTester t, Finder of) => [
      for (final w in t.widgetList<Text>(find.descendant(of: of, matching: find.byType(Text))))
        if (w.data != null) w.data!,
    ];

/// The spoken label of the node that carries [f]'s text.
String _spoken(WidgetTester t, Finder f) => t.getSemantics(f).label;

void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 4000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('a11y_visible_text.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  test('the German catalogue differs from the English words (the cases below can tell)', () {
    expect(_de.ecgWhatResultsMean, isNot('What the results mean'));
    expect(_de.gestureFailureDismiss, isNot('Dismiss'));
    expect(_de.actionSave, isNot('Save'));
    expect(_de.patternEditorFollowRhythm, isNot('Follow rhythm'));
    expect(_de.patternEditorAllowDynamics, isNot('Allow dynamics'));
    expect(_de.naturalWakeBuzzing, isNot('Natural Wake is buzzing'));
    expect(_de.naturalWakeOrTapBand, isNot('or double-tap the band'));
  });

  testWidgets('ECG home: the results link keeps its words, and is spoken in German', (t) async {
    final h = t.ensureSemantics();
    final app = AppState.forTesting()..repo = Apk1Repo();
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app, child: _german(const EcgHomeScreen())));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump();
    final link = find.byKey(const ValueKey('ecg-screener-link'));
    expect(_drawn(t, link), ['What the results mean']);
    expect(_spoken(t, link), _de.ecgWhatResultsMean);
    await t.pumpWidget(const SizedBox());
    app.dispose();
    h.dispose();
  });

  testWidgets('ECG detail: the results link keeps its words, and is spoken in German', (t) async {
    final h = t.ensureSemantics();
    _phone(t);
    await t.pumpWidget(_german(EcgDetailScreen(
        data: EcgDetailData(reading: cardioReading(), packets: const [], attempts: const []))));
    await t.pump();
    final link = find.byKey(const ValueKey('ecg-screener-link'));
    expect(_drawn(t, link), ['What the results mean']);
    expect(_spoken(t, link), _de.ecgWhatResultsMean);
    h.dispose();
  });

  testWidgets('gesture failure card: Dismiss keeps its word, and is spoken in German', (t) async {
    final h = t.ensureSemantics();
    _phone(t);
    final t0 = DateTime.utc(2026, 10, 4, 12, 7, 31);
    String? raw;
    final store = GestureFailureStore(read: () => raw, write: (s) async => raw = s, now: () => t0);
    await store.record(
        kind: GestureFailureKind.ecg, reason: 'start_failed', gestureId: 'g1', log: 'log', at: t0);
    await t.pumpWidget(_german(Scaffold(body: GestureFailureCard(store: store))));
    final dismiss = find.byKey(const ValueKey('gesture-failure-dismiss'));
    expect(_drawn(t, dismiss), ['Dismiss']);
    expect(_spoken(t, dismiss), _de.gestureFailureDismiss);
    h.dispose();
  });

  testWidgets('pattern editor: Save and the two modes keep their words, and are spoken in German', (t) async {
    final h = t.ensureSemantics();
    _phone(t);
    await t.pumpWidget(_german(HapticPatternEditorPage(
      profile: HapticDeviceProfile.whoopMg,
      onPlay: (_) async => true,
      onSave: (a, b) {},
    )));
    await t.pumpAndSettle();
    final save = find.byKey(const ValueKey('pattern-editor-save'));
    final follow = find.byKey(const ValueKey('pattern-editor-mode-follow'));
    final dynamics = find.byKey(const ValueKey('pattern-editor-mode-dynamics'));
    expect(_drawn(t, save), ['Save']);
    expect(_drawn(t, follow), ['Follow rhythm']);
    expect(_drawn(t, dynamics), ['Allow dynamics']);
    expect(_spoken(t, save), _de.actionSave);
    expect(_spoken(t, follow), _de.patternEditorFollowRhythm);
    expect(_spoken(t, dynamics), _de.patternEditorAllowDynamics);
    h.dispose();
  });

  testWidgets('Natural Wake card: title and hint keep their words, and are spoken in German', (t) async {
    final h = t.ensureSemantics();
    final wake = WakeController(
      schedule: () => const [],
      saveEntry: (_) async {},
      loadUpgradeState: () async => throw UnimplementedError(),
      saveUpgradeState: (_) async {},
      acknowledgeWake: (_) async => const WakeAckOutcome(
          nativeCancelRequested: false, nativeCancelled: false, fallbackArmed: true),
      traceFor: (_) async => const [],
    );
    addTearDown(wake.dispose);
    await t.pumpWidget(_german(Scaffold(body: NaturalWakeBuzzingCard(wake: wake))));
    wake.noteNaturalRepeat(true);
    await t.pump();
    expect(find.text('Natural Wake is buzzing'), findsOneWidget);
    expect(find.text('or double-tap the band'), findsOneWidget);
    expect(find.text(_de.naturalWakeBuzzing), findsNothing);
    expect(find.text(_de.naturalWakeOrTapBand), findsNothing);
    final spoken = spokenLabels(t).join('\n');
    expect(spoken, contains(_de.naturalWakeBuzzing));
    expect(spoken, contains(_de.naturalWakeOrTapBand));
    expect(spoken, isNot(contains('Natural Wake is buzzing')),
        reason: 'one language per spoken line: the English words are drawn, not read');
    h.dispose();
  });
}
