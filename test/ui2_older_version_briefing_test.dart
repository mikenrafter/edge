// RULES B.2 on generated briefings. Model prose cannot be parsed for a
// marker, so the rule is structural: when ANY input finding used an
// older-calculation value, the stored briefing records the versions and every
// place that shows it carries a fixed, localized footnote naming them.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

List<Map<String, dynamic>> _pts({int? todayOlder, int? histOlder}) => [
      for (var back = 30; back >= 1; back--)
        cp(back, 6 + back % 3, older: back == 5 ? histOlder : null),
      cp(0, 20, older: todayOlder),
    ];

Future<Briefing> _evening({int? todayOlder, int? histOlder, String? reply}) {
  return BriefingEngine(
    config: CoachConfig(),
    repo: OlderRepo(charts: {'strain': _pts(todayOlder: todayOlder, histOlder: histOlder)}),
    // A model that quotes the figure with NO marker -- as models do.
    complete: ({required String system, required String user}) async =>
        reply ?? 'Your strain of 20.0 was the highest in a month.\n---\n- Strain 20.0',
  ).generate(BriefingPeriod.evening);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('the engine records the versions behind the inputs', () {
    test('today older', () async {
      final b = await _evening(todayOlder: 104);
      expect(b.olderVersions, [104]);
      expect(b.oneLiner, contains('20.0'), reason: 'prose is stored as given');
    });
    test('only history older', () async {
      expect((await _evening(histOlder: 103)).olderVersions, [103]);
    });
    test('both, ascending', () async {
      expect((await _evening(todayOlder: 104, histOlder: 103)).olderVersions,
          [103, 104]);
    });
    test('nothing older: none', () async {
      expect((await _evening()).olderVersions, isEmpty);
    });
    test('survives the cache round trip', () async {
      final b = await _evening(todayOlder: 104);
      final r = Briefing.fromJson(b.toJson())!;
      expect(r.olderVersions, [104]);
      expect(BriefingStore.read(BriefingPeriod.evening)!.olderVersions, [104]);
      // An old cached entry without the key reads as none.
      expect(
          Briefing.fromJson({'day': 'd', 'one_liner': 'x'})!.olderVersions,
          isEmpty);
    });
  });

  group('the footnote', () {
    Briefing stored(List<int> v) => Briefing(
        day: todayLabel(),
        period: BriefingPeriod.evening,
        oneLiner: 'Strain 20.0 stood out.',
        breakdownMd: '',
        generatedAtMs: 0,
        inputs: const {'unusual_for_you': ['x']},
        olderVersions: v);

    Future<void> screen(WidgetTester t, Briefing b,
        {Locale locale = const Locale('en')}) async {
      t.view.physicalSize = const Size(390 * 3, 1800 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      BriefingStore.write(b);
      final cfg = CoachConfig();
      addTearDown(cfg.dispose);
      await cfg.save(baseUrl: 'http://localhost:11434/v1', model: 'm');
      await t.pumpWidget(ChangeNotifierProvider<CoachConfig>.value(
        value: cfg,
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildTheme(Brightness.light),
          home: const AiBriefingScreen(period: BriefingPeriod.evening),
        ),
      ));
      await t.pumpAndSettle();
    }

    final key = find.byKey(const ValueKey('briefing-older-footnote'));

    testWidgets('a flagged briefing always shows it, naming the version',
        (t) async {
      await screen(t, stored([104]));
      expect(key, findsOneWidget);
      expect(t.widget<Text>(key).data,
          AppLocalizationsEn().briefingOlderFootnote('v104'));
      expect(AppLocalizationsEn().briefingOlderFootnote('v104'),
          contains('older calculation'));
    });

    testWidgets('mixed versions are all named', (t) async {
      await screen(t, stored([103, 104]));
      expect(
          find.text(AppLocalizationsEn().briefingOlderFootnote('v103, v104')),
          findsOneWidget);
    });

    testWidgets('localized', (t) async {
      await screen(t, stored([104]), locale: const Locale('de'));
      expect(find.text(AppLocalizationsDe().briefingOlderFootnote('v104')),
          findsOneWidget);
    });

    testWidgets('a briefing with no older input has none', (t) async {
      await screen(t, stored(const []));
      expect(key, findsNothing);
    });

    testWidgets('Home\'s briefing row carries an asterisk on a flagged one',
        (t) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      for (final period in BriefingPeriod.values) {
        BriefingStore.write(Briefing(
            day: todayLabel(),
            period: period,
            oneLiner: 'Strain 20.0 stood out.',
            breakdownMd: '',
            generatedAtMs: 0,
            inputs: const {},
            olderVersions: const [104]));
      }
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: Scaffold(
              body: HomeScreen(data: HomeData(dayId: todayLabel()), hour: 9)),
        ),
      ));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Strain 20.0 stood out.*'), findsOneWidget);
    });
  });
}
