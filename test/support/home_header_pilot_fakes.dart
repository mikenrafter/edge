import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/home_header.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'header_rows_fakes.dart';

final pilotNow = DateTime(2026, 11, 19, 22, 49);
final pilotStartEdge = DateTime(2026, 11, 19, 13, 23);
final _committedEdge = DateTime(2026, 11, 19, 14, 48);
final _lastSync = DateTime(2026, 11, 19, 13, 26);
const _day = '2026-11-19';
const _older = '2026-11-17';
class PilotHeaderApp extends HeaderApp {
  PilotHeaderApp({
    super.pres, super.connection, super.battery,
    this.startEdge,
  });
  final DateTime? startEdge;

  @override
  DateTime? get headerSyncedThrough => startEdge;

  @override
  Map<String, dynamic> get user => const {'name': 'T'};
}

SyncPresentationState pilotIdle({DateTime? lastSync}) =>
    SyncPresentationState(phase: 'idle', lastSuccess: lastSync ?? _lastSync);

SyncPresentationState pilotSync(
  String phase, {
  int records = 465,
  DateTime? newest,
  DateTime? syncedThrough,
  DateTime? lastSync,
  int? dayIndex,
  int? dayTotal,
}) {
  final start = DateTime(2026, 11, 19, 22, 46);
  final failed = phase == 'failed';
  final calculating = phase == 'deriving';
  return SyncPresentationState(
    phase: phase,
    busy: !failed,
    lastSuccess: lastSync ?? _lastSync,
    startedAt: start,
    finishedAt: failed ? pilotNow : null,
    failureCode: failed ? SyncFailure.disconnected : null,
    steps: [
      SyncStep(
        id: SyncStepId.download,
        status: failed ? SyncStepStatus.failed
            : calculating ? SyncStepStatus.done : SyncStepStatus.running,
        startedAt: start,
        endedAt: calculating || failed ? pilotNow : null,
        download: SyncDownloadDetail(
          records: records,
          chunks: 86,
          syncedThrough: syncedThrough ?? _committedEdge,
          bandNewest: newest,
        ),
      ),
      SyncStep(
        id: SyncStepId.calculate,
        status: calculating ? SyncStepStatus.running : SyncStepStatus.waiting,
        calculate: dayTotal == null ? null
            : SyncCalculateDetail(dayIndex: dayIndex, dayTotal: dayTotal),
      ),
    ],
  );
}

Widget pilotApp(PilotHeaderApp app, Widget body, {double scale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider(create: (_) => UnitsController.seed(UnitSystem.metric)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: body,
      ),
    );

Widget pilotTab(ShellDomain domain) => switch (domain) {
  ShellDomain.today => HomeScreen(data: const HomeData(dayId: _day), now: pilotNow),
  ShellDomain.sleep => const SleepDetail(
    embedded: true, data: SleepData(day: _day, days: [_day, _older]),
  ),
  ShellDomain.activity => const WorkoutScreen(),
  ShellDomain.health => const SizedBox.shrink(),
};

void pilotSurface(WidgetTester t, {double width = 390}) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 900);
  addTearDown(t.view.reset);
}

Future<void> pilotPrefs({
  bool compact = false, int? alertAt, bool enabled = true, bool sleepSummary = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'labs.home_header': enabled,
    'pilot.day_timeline.sleep': sleepSummary,
    HomeHeader.compactKey: compact,
    'notif_battery_pct': ?alertAt,
  });
  await Prefs.reload();
}
