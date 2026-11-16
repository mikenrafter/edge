// why: the age qualifier is part of retained health advice in every locale,
// including semantics and chosen clock format. CLAIM(home-cache-freshness).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/home_snapshot_store.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';

const warnings = {
  'en': [
    'Last known STAMP · updating',
    'Last known STAMP · update failed',
    'STATUS. Read READ. Calculated COMPUTED.',
  ],
  'de': [
    'Letzter Stand STAMP · wird aktualisiert',
    'Letzter Stand STAMP · Aktualisierung fehlgeschlagen',
    'STATUS. Gelesen READ. Berechnet COMPUTED.',
  ],
  'es': [
    'Último dato STAMP · actualizando',
    'Último dato STAMP · error al actualizar',
    'STATUS. Leído READ. Calculado COMPUTED.',
  ],
  'fr': [
    'Dernières données STAMP · mise à jour',
    'Dernières données STAMP · échec de la mise à jour',
    'STATUS. Lecture READ. Calcul COMPUTED.',
  ],
  'hi': [
    'पिछली जानकारी STAMP · अपडेट हो रहा है',
    'पिछली जानकारी STAMP · अपडेट विफल',
    'STATUS. पढ़ा गया READ. गणना की गई COMPUTED.',
  ],
  'ru': [
    'Последние данные STAMP · обновление',
    'Последние данные STAMP · ошибка обновления',
    'STATUS. Прочитано READ. Рассчитано COMPUTED.',
  ],
  'zh': [
    '上次数据 STAMP · 正在更新',
    '上次数据 STAMP · 更新失败',
    'STATUS。读取于 READ。计算于 COMPUTED。',
  ],
};

void main() {
  for (final language in warnings.keys) {
    test('retained messages in $language', () {
      final l = lookupAppLocalizations(Locale(language));
      expect([
        l.homeLastKnownUpdating('STAMP'),
        l.homeLastKnownFailed('STAMP'),
        l.homeLastKnownSource('STATUS', 'READ', 'COMPUTED'),
      ], warnings[language]);
    });
  }
  for (final localized in [false, true]) {
    for (final language in localized ? ['en', 'de'] : ['en']) {
      for (final clock in [ClockFormat.h12, ClockFormat.h24]) {
        testWidgets(
          'retained date and local clock $language $clock localized=$localized',
          (t) async {
            SharedPreferences.setMockInitialValues({});
            await Prefs.ensureLoaded();
            await HomeSnapshotStore.invalidate();
            ClockFormatController.seed(clock);
            addTearDown(ClockFormatController.debugReset);
            // Construct a local wall time, then store its UTC instant. The same
            // expectation must hold in UTC, Denver and Kolkata.
            final at = DateTime(2026, 11, 12, 8, 14).toUtc();
            final computed = DateTime(2026, 11, 12, 6, 30).toUtc();
            final locale = localized ? language : 'en_US';
            HomeRingDetailCache.local.record(
              '2026-11-12',
              locale,
              HomeData(
                readiness: const Metric(value: 22),
                overnightAt: computed,
              ),
              null,
              readAt: at,
            );
            final semantics = t.ensureSemantics();
            await t.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: localized
                    ? AppLocalizations.localizationsDelegates
                    : null,
                supportedLocales: localized
                    ? AppLocalizations.supportedLocales
                    : const [Locale('en', 'US')],
                home: const Scaffold(
                  body: SingleChildScrollView(
                    child: RingTrio(
                      d: HomeData(),
                      pending: true,
                      cacheFresh: false,
                      cacheDay: '2026-11-12',
                    ),
                  ),
                ),
              ),
            );
            await t.pump();
            final caption = t.widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('home-since')),
                matching: find.byType(Text),
              ),
            );
            expect(
              caption.data,
              contains(clock == ClockFormat.h12 ? '8:14 AM' : '08:14'),
            );
            expect(
              caption.semanticsLabel,
              contains(clock == ClockFormat.h12 ? '6:30 AM' : '06:30'),
            );
            expect(caption.semanticsLabel, isNot(contains('T08:14')));
            expect(caption.data, contains('12'));
            if (language == 'de') {
              expect(caption.data, startsWith('Letzter Stand'));
              expect(caption.data, contains('12. Nov.'));
              expect(caption.semanticsLabel, contains('Gelesen'));
            } else {
              expect(caption.data, contains('Nov 12'));
            }
            semantics.dispose();
            await t.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
