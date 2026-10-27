import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/screens/track_log.dart';
import 'package:openstrap_edge/ui2/screens/tracks_screen.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/screens/typical_day.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import '../support/bundled_fonts.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';

Future<void> _mount(WidgetTester t, Widget child) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(412, 5000);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<LocaleController>(
          create: (_) => LocaleController.seed(null),
        ),
        ChangeNotifierProvider<ThemeController>(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadFonts);
  testWidgets('Settings exposes Tracks among the personal tools', (t) async {
    await _mount(t, const MoreSettingsView());
    expect(find.text('Tracks'), findsOneWidget);
    final row = t.widget<SetRow>(
      find.ancestor(of: find.text('Tracks'), matching: find.byType(SetRow)),
    );
    expect(row.onTap, isNotNull, reason: 'Tracks must open its hub');
    await t.tap(find.text('Tracks'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(TracksScreen), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('Typical day offers a reachable Tracks hub', (t) async {
    await _mount(t, const TypicalDayScreen(data: TypicalDayData()));
    expect(find.text('Tracks'), findsOneWidget);
    await t.tap(find.text('Tracks'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(TracksScreen), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('Home quick log opens the persisted timed logger', (t) async {
    await _mount(
      t,
      const HomeScreen(
        data: HomeData(dayId: '2026-10-20', pendingActivities: 0),
      ),
    );
    await t.ensureVisible(find.byKey(const ValueKey('track-quick-log')));
    await t.tap(find.byKey(const ValueKey('track-quick-log')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(TrackLogScreen), findsOneWidget);
    expect(
      t.widget<TrackLogScreen>(find.byType(TrackLogScreen)).date,
      '2026-10-20',
    );
    expect(t.takeException(), isNull);
  });
  testWidgets('Journal quick log keeps the day being edited', (t) async {
    final app = AppState.forTesting()..repo = _JournalRepo();
    addTearDown(app.dispose);
    await _mount(
      t,
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const JournalCompose(date: '2026-10-19'),
      ),
    );
    await t.tap(find.byKey(const ValueKey('track-quick-log')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(TrackLogScreen), findsOneWidget);
    expect(
      t.widget<TrackLogScreen>(find.byType(TrackLogScreen)).date,
      '2026-10-19',
    );
    expect(t.takeException(), isNull);
  });
}

class _JournalRepo extends LocalRepository {
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(
    String date,
  ) async => {};
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      [];
}
