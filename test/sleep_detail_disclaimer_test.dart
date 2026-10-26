import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';

const _copy = {
  'en':
      'Experimental research algorithm. Not a medical device. Consult a physician for sleep disorders.',
  'de':
      'Experimenteller Forschungsalgorithmus. Kein Medizinprodukt. Wenden Sie sich bei Schlafstörungen an eine Ärztin oder einen Arzt.',
  'es':
      'Algoritmo de investigación experimental. No es un dispositivo médico. Consulte a un médico si tiene trastornos del sueño.',
  'fr':
      'Algorithme de recherche expérimental. Ceci n’est pas un dispositif médical. Consultez un médecin en cas de troubles du sommeil.',
  'hi':
      'प्रयोगात्मक शोध एल्गोरिदम। यह चिकित्सा उपकरण नहीं है। नींद संबंधी विकारों के लिए चिकित्सक से परामर्श लें।',
  'ru':
      'Экспериментальный исследовательский алгоритм. Не является медицинским устройством. При нарушениях сна обратитесь к врачу.',
  'zh': '实验性研究算法。非医疗器械。如有睡眠障碍，请咨询医生。',
};

class _LoadingRepo extends LocalRepository {
  final pending = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getTodayStored() => pending.future;
  @override
  Future<List<String>> availableDays() async => const [];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(
    WidgetTester t, {
    String code = 'en',
    String state = 'loaded',
    bool embedded = false,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    final locale = LocaleController.seed(code);
    addTearDown(app.dispose);
    addTearDown(locale.dispose);
    if (state == 'loading') app.repo = _LoadingRepo();
    final data = state == 'loading'
        ? null
        : SleepData(
            day: '2026-10-20',
            night: state == 'empty'
                ? const {}
                : const {
                    'duration_min': 420,
                    'in_bed_min': 480,
                    'onset_ts': 1792450800,
                    'wake_ts': 1792479600,
                  },
          );
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LocaleController>.value(value: locale),
        ],
        child: MaterialApp(
          locale: Locale(code),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildTheme(brightness),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SleepDetail(data: data, embedded: embedded),
          ),
        ),
      ),
    );
    // A loading future stays pending; pumpAndSettle would wait on its spinner.
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
  }

  for (final state in ['loaded', 'loading', 'empty']) {
    for (final embedded in [false, true]) {
      testWidgets('disclaimer outside accordions: $state embedded=$embedded', (
        t,
      ) async {
        await pump(t, state: state, embedded: embedded);
        final disclaimer = find.text(_copy['en']!);
        expect(disclaimer, findsOneWidget);
        expect(
          disclaimer.hitTestable(),
          findsOneWidget,
          reason: 'readable without opening an accordion or scrolling',
        );
        expect(
          find.ancestor(
            of: disclaimer,
            matching: find.byType(SettingsAccordion),
          ),
          findsNothing,
        );
        if (state == 'loading') {
          expect(find.text('Reading the night'), findsOneWidget);
        } else if (state == 'loaded') {
          expect(find.text('Total sleep'), findsOneWidget);
        } else if (state == 'empty') {
          expect(find.text('No night to show'), findsWidgets);
        }
        expect(t.takeException(), isNull);
      });
    }
  }

  for (final entry in _copy.entries) {
    testWidgets('localized disclaimer uses ${entry.key} ARB in normal detail', (
      t,
    ) async {
      await pump(t, code: entry.key);
      expect(find.text(entry.value), findsOneWidget);
      final arb =
          jsonDecode(File('lib/l10n/app_${entry.key}.arb').readAsStringSync())
              as Map;
      expect(arb['sleepDetailMedicalDisclaimer'], entry.value);
      expect(t.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('disclaimer uses readable theme text at 2x, $brightness', (
      t,
    ) async {
      await pump(t, brightness: brightness, scale: 2);
      final finder = find.text(_copy['en']!);
      expect(finder, findsOneWidget);
      final text = t.widget<Text>(finder);
      expect(text.style!.fontSize, greaterThanOrEqualTo(14));
      final p = P.of(t.element(finder));
      expect(text.style!.color, p.ink2);
      expect(t.takeException(), isNull);
    });
  }
}
