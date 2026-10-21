// Fixtures for the shared three-row header block (date / sync cluster, then
// "Synced through", then battery · connection) under every tab title.
// Every instant here is a fixed DateTime; the code under test must read time
// from package:clock, so tests pin it with `withClock(Clock.fixed(...))`.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show ScreenTitle;
import 'package:openstrap_edge/ui2/theme.dart';

/// Sunday 4 October 2026, 15:40 local.
final headerNow = DateTime(2026, 10, 4, 15, 40);

/// The data edge the "Synced through" row reports (today, so a clock time).
final headerEdge = DateTime(2026, 10, 4, 15, 33);

/// The date row 1 shows when idle.
const headerDate = 'Sunday, 4 October';

class HeaderApp extends AppState {
  HeaderApp({
    this.pres = const SyncPresentationState(phase: 'idle'),
    String connection = 'connected',
    double? battery = 59,
    this.through,
  })  : _device = DeviceState(connection: connection)
          ..batteryPct = battery
          ..charging = battery == null ? null : false,
        super.forTesting();

  SyncPresentationState pres;
  final DeviceState _device;
  DateTime? through;
  int syncs = 0;

  @override
  SyncPresentationState get syncPresentation => pres;
  @override
  DeviceState get device => _device;
  @override
  DateTime? get lastRecordAt => through;
  @override
  Future<void> syncNow() async => syncs++;

  /// Changes the presentation and rebuilds listeners.
  void setPres(SyncPresentationState p) {
    pres = p;
    notifyListeners();
  }
}

SyncStep _step(SyncStepId id, SyncStepStatus s, {DateTime? at}) =>
    SyncStep(id: id, status: s, startedAt: at, endedAt: null);

SyncPresentationState headerIdle() => SyncPresentationState(
      phase: 'idle',
      lastSuccess: headerNow.subtract(const Duration(minutes: 61)),
    );

SyncPresentationState headerSyncing() {
  final start = headerNow.subtract(const Duration(seconds: 42));
  return SyncPresentationState(
    phase: 'downloading',
    busy: true,
    contactedBand: true,
    startedAt: start,
    lastSuccess: headerNow.subtract(const Duration(minutes: 61)),
    steps: [
      _step(SyncStepId.connect, SyncStepStatus.done, at: start),
      _step(SyncStepId.download, SyncStepStatus.running, at: start),
      _step(SyncStepId.calculate, SyncStepStatus.waiting),
      _step(SyncStepId.done, SyncStepStatus.waiting),
    ],
  );
}

SyncPresentationState headerFailed() => SyncPresentationState(
      phase: 'failed',
      failureReason: 'Pair a band before syncing',
      lastSuccess: headerNow.subtract(const Duration(minutes: 61)),
      startedAt: headerNow.subtract(const Duration(seconds: 50)),
      finishedAt: headerNow.subtract(const Duration(seconds: 9)),
      steps: [
        _step(SyncStepId.connect, SyncStepStatus.failed),
        _step(SyncStepId.download, SyncStepStatus.skipped),
        _step(SyncStepId.calculate, SyncStepStatus.skipped),
        _step(SyncStepId.done, SyncStepStatus.skipped),
      ],
    );

/// A bare tab root: just the shared title block, nothing else.
Widget titleOnly(AppState app, String title, {double width = 390}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LocaleController>.value(
            value: LocaleController.seed(null)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Column(children: [ScreenTitle(title, statusLine: true)]),
        ),
      ),
    );

void h24() => ClockFormatController.seed(ClockFormat.h24);
