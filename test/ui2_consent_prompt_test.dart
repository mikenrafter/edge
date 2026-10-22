// RED: the first-run consent prompt.
//
// Today nothing reads AppState.consentChosen: the onboarding consent tiles
// died with lib/ui (commit 42033703 "rebuild the ui"), and 5e885fcc's message
// records that setHealthShareConsent was left with no caller. The only door
// to the two choices is Settings > Data & privacy.
//
// Choices that still exist (what the deleted screen offered, narrowed):
//   * anonymous diagnostics / crash reports -> AppState.setTelemetryConsent
//   * contribute health data (whole-DB upload) -> setHealthShareConsent, only
//     where the build has the feature (caps Feature.healthShare)
// Both default OFF; nothing is enabled without a tap. Each setter records
// consent_chosen.
//
// Design pinned: ConsentPromptHost(child:) wraps the shell in app.dart and
// draws the prompt (Key 'consent-prompt') OVER the live child when
// AppState.consentPromptDue. The child stays mounted and interactive-by-state
// (an import or sync under it keeps publishing).
//
// RED STUBS in lib/: ConsentPromptHost (lib/ui2/onboarding/consent_prompt.dart,
// draws only its child), AppState.consentLoaded / consentPromptDue (from the
// previous red commit; the getter is always false).
// New keys: consent-prompt, consent-telemetry (Switch), consent-health-share
// (Switch, only when the build offers it), consent-confirm, consent-decline.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/consent_prompt.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'step2/support/p23_support.dart';
import 'support/app_state_derive_harness.dart';

/// Records the choices instead of persisting and posting them; the real
/// setters also set consentChosen, so the fake does the same.
class _App extends AppState {
  _App() : super.forTesting();
  final telemetryCalls = <bool>[];
  final healthCalls = <bool>[];

  void load({bool chosen = false}) {
    consentChosen = chosen;
    consentLoaded = true;
    notifyListeners();
  }

  @override
  Future<void> setTelemetryConsent(bool on) async {
    telemetryCalls.add(on);
    telemetryConsent = on;
    consentChosen = true;
    notifyListeners();
  }

  @override
  Future<void> setHealthShareConsent(bool on) async {
    healthCalls.add(on);
    healthShareConsent = on;
    consentChosen = true;
    notifyListeners();
  }
}

/// A child with state, so "the prompt does not replace the app" is checkable.
class _Underlay extends StatefulWidget {
  const _Underlay(this.app);
  final AppState app;
  @override
  State<_Underlay> createState() => _UnderlayState();
}

int _inits = 0;

class _UnderlayState extends State<_Underlay> {
  @override
  void initState() {
    super.initState();
    _inits++;
  }

  @override
  Widget build(BuildContext c) => ValueListenableBuilder<ImportProgress?>(
        valueListenable: widget.app.importProgress,
        builder: (_, v, _) =>
            Text(key: const ValueKey('underlay'), 'app: ${v.runtimeType}'),
      );
}

Widget _host(_App app) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConsentPromptHost(child: _Underlay(app)),
      ),
    );

Future<_App> _pump(WidgetTester t, {bool load = true, bool chosen = false}) async {
  t.view.physicalSize = const Size(1170, 2400);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  _inits = 0;
  final app = _App();
  addTearDown(app.importProgress.dispose);
  if (load) app.load(chosen: chosen);
  await t.pumpWidget(_host(app));
  await t.pump();
  return app;
}

final _prompt = find.byKey(const ValueKey('consent-prompt'));
final _telemetry = find.byKey(const ValueKey('consent-telemetry'));
final _confirm = find.byKey(const ValueKey('consent-confirm'));
final _decline = find.byKey(const ValueKey('consent-decline'));

void main() {
  group('when it shows', () {
    testWidgets('consent loaded and unanswered: shown over the app', (t) async {
      await _pump(t);
      expect(_prompt, findsOneWidget);
      expect(find.byKey(const ValueKey('underlay')), findsOneWidget,
          reason: 'over the normal app, not instead of it');
      expect(_telemetry, findsOneWidget);
      expect(_confirm, findsOneWidget);
      expect(_decline, findsOneWidget);
    });

    testWidgets('never before consent is loaded (no flash)', (t) async {
      final app = await _pump(t, load: false);
      expect(_prompt, findsNothing);
      app.load();
      await t.pump();
      expect(_prompt, findsOneWidget, reason: 'control: it does show once loaded');
    });

    testWidgets('never once chosen', (t) async {
      await _pump(t, chosen: true);
      expect(_prompt, findsNothing);
      // control in the same test: the unanswered case does show it.
      final app = await _pump(t);
      expect(app.consentPromptDue, isTrue);
      expect(_prompt, findsOneWidget);
    });

    testWidgets('after a real import that leaves consent_chosen absent',
        (t) async {
      const name = 'consent_prompt_import.db';
      final tmp = Directory.systemTemp.createTempSync('consent_prompt_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final app = await _pump(t, load: false);
      await t.runAsync(() async {
        await deriveDbSetUp(name);
        SharedPreferences.setMockInitialValues({});
        app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
        app.debugFinalizeImport = _NoRollup();
        final db = await LocalDb.instance;
        await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70),
            computedAt: 4000, readinessColumn: 70);
        final path = p.join(tmp.path, 'backup.db');
        await db.execute('VACUUM INTO ?', [path]);
        await LocalDb.deleteDays({p23Day(1)});
        await app.importEdgeBackup(path);
        expect(
            (await SharedPreferences.getInstance()).containsKey('consent_chosen'),
            isFalse);
        await deriveDbTearDown(name);
      });
      app.load();
      await t.pump();
      expect(app.consentChosen, isFalse);
      expect(_prompt, findsOneWidget);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('app.dart hosts it around the shell', () {
      final src = File('lib/app.dart').readAsStringSync();
      expect(src, contains('ConsentPromptHost('));
    });
  });

  group('answering', () {
    testWidgets('defaults are off: nothing is opted in without an answer',
        (t) async {
      final app = await _pump(t);
      expect(_prompt, findsOneWidget);
      expect(_telemetry, findsOneWidget);
      expect(t.widget<Switch>(_telemetry).value, isFalse);
      expect(find.byKey(const ValueKey('consent-health-share')), findsNothing,
          reason: 'this build does not offer health-data contribution');
      expect(app.telemetryCalls, isEmpty);
      expect(app.telemetryConsent, isFalse);
      expect(app.healthShareConsent, isFalse);
    });

    testWidgets('Continue records the switch through the existing setter and '
        'dismisses; it stays dismissed on rebuild', (t) async {
      final app = await _pump(t);
      await t.tap(_telemetry);
      await t.pump();
      await t.tap(_confirm);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(app.telemetryCalls, [true]);
      expect(app.consentChosen, isTrue);
      expect(_prompt, findsNothing);

      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_host(app));
      await t.pump();
      expect(_prompt, findsNothing, reason: 'does not reappear');
    });

    testWidgets('"No thanks" records an explicit off, so it is not asked again',
        (t) async {
      final app = await _pump(t);
      await t.tap(_decline);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(app.telemetryCalls, [false]);
      expect(app.healthCalls, isEmpty,
          reason: 'a feature the build does not offer is never recorded');
      expect(app.consentChosen, isTrue);
      expect(_prompt, findsNothing);
    });
  });

  group('under the prompt', () {
    testWidgets('the app stays mounted and a running import keeps reporting',
        (t) async {
      final app = await _pump(t);
      expect(_prompt, findsOneWidget);
      expect(_inits, 1);
      app.importProgress.value =
          const ImportCopying(ImportStage.sleep, 1, 4, 3, 9);
      await t.pump();
      expect(find.text('app: ImportCopying'), findsOneWidget);
      await t.tap(_decline);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(_inits, 1, reason: 'answering must not remount the app');
      expect(find.text('app: ImportCopying'), findsOneWidget);
    });
  });
}

class _NoRollup implements ImportRollupProbe {
  @override
  Future<void> finalize(profile) async {}
}
