// Observes real SQLite operations so widget tests await completion without clocks
// or sleeps. Every operation still runs through the production TracksStore.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/tracks_store.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class ObservedTracksStore extends TracksStore {
  ObservedTracksStore(super.db);
  final List<Future<Object?>> _operations = [];
  final Zone _databaseZone = Zone.current;
  int get operationCount => _operations.length;
  Future<T> _observe<T>(Future<T> Function() run) {
    final operation = _databaseZone.run(run);
    _operations.add(operation);
    return operation;
  }

  Future<void> drain() async {
    var seen = 0;
    while (seen < _operations.length) {
      final pending = _operations.sublist(seen);
      seen = _operations.length;
      await Future.wait(pending);
    }
  }

  @override
  Future<Map<String, Map<String, Object?>>> refreshLearning({DateTime? asOf}) =>
      _observe(
        () =>
            super.refreshLearning(asOf: asOf ?? DateTime.utc(2026, 10, 27, 12)),
      );
  @override
  Future<void> confirmNone(String trackId, String date) =>
      _observe(() => super.confirmNone(trackId, date));
  @override
  Future<List<TrackDefinition>> definitions({bool enabledOnly = false}) =>
      _observe(() => super.definitions(enabledOnly: enabledOnly));
  @override
  Future<List<TrackSetupRange>> history(String trackId) =>
      _observe(() => super.history(trackId));
  @override
  Future<Map<String, TrackEvent>> lastEvents() =>
      _observe(() => super.lastEvents());
  @override
  Future<List<TrackEvent>> events({
    String? trackId,
    String? date,
    int limit = 200,
  }) =>
      _observe(() => super.events(trackId: trackId, date: date, limit: limit));
  @override
  Future<void> saveDefinition(
    TrackDefinition definition, {
    List<TrackSetupRange>? history,
  }) => _observe(() => super.saveDefinition(definition, history: history));
  @override
  Future<void> log(TrackEvent event) => _observe(() => super.log(event));
}

const tracksBoundary = ValueKey('tracks-golden');
Future<void> mountTracks(
  WidgetTester tester,
  Widget page, {
  double height = 1400,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(412, height);
  addTearDown(tester.view.reset);
  ClockFormatController.seed(ClockFormat.h24);
  await tester.pumpWidget(
    RepaintBoundary(
      key: tracksBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
}

Future<void> settleTracks(
  WidgetTester tester,
  ObservedTracksStore store,
) async {
  // A completed read can start the next read when the widget's continuation is
  // pumped. Await those concrete operations, without advancing a wall clock.
  for (var i = 0; i < 10; i++) {
    final before = store.operationCount;
    await tester.runAsync(store.drain);
    await tester.pump();
    if (store.operationCount == before) break;
  }
  await tester.pumpAndSettle();
}
